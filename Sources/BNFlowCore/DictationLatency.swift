import Foundation

/// FNV-1a. Csak azonosításhoz (egyezik-e két felvétel); a hang és a szöveg nem naplózható belőle.
public enum AudioFingerprint {
    public static func hash(_ data: Data) -> UInt64 {
        var h: UInt64 = 14695981039346656037
        for b in data {
            h ^= UInt64(b)
            h &*= 1099511628211
        }
        return h
    }
}

/// A végleges átírási kérés azonosítója: a feltöltött WAV és a prompt (modell, nyelv, szótár). Kulcs nincs benne.
public struct TranscriptRequestID: Equatable, Sendable {
    public var audio: UInt64
    public var prompt: UInt64
    public init(audio: UInt64, prompt: UInt64) { self.audio = audio; self.prompt = prompt }

    public static func promptHash(provider: String, model: String, fallback: String, language: String, terms: [String]) -> UInt64 {
        var s = provider + "\n" + model + "\n" + fallback + "\n" + language
        for t in terms { s += "\n"; s += t }
        return AudioFingerprint.hash(Data(s.utf8))
    }

    public static func make(wav: Data, provider: String, model: String, fallback: String, language: String, terms: [String]) -> TranscriptRequestID {
        TranscriptRequestID(audio: AudioFingerprint.hash(wav), prompt: promptHash(provider: provider, model: model, fallback: fallback, language: language, terms: terms))
    }
}

/// Az átírandó, előkészített hang és az, ami a fájlkérésbe kerül. A `trailingSilence` a nyers felvétel vége.
public struct PreparedTurn: Sendable, Equatable {
    public var wav: Data
    public var stats: AudioStats
    public var fingerprint: UInt64
    public var trailingSilence: Double

    public static func make(_ raw: [Float], sampleRate: Int = 16_000) -> PreparedTurn {
        let stats = AudioPrep.analyze(raw, sampleRate: sampleRate)
        let prepared = AudioPrep.prepare(raw, sampleRate: sampleRate)
        let wav = WAV.encode(samples: WAV.floatToInt16(prepared), sampleRate: sampleRate)
        let trail: Double
        if let r = stats.speechRange {
            trail = Double(raw.count - r.upperBound) / Double(max(1, sampleRate))
        } else {
            trail = stats.seconds
        }
        return PreparedTurn(wav: wav, stats: stats, fingerprint: AudioFingerprint.hash(wav), trailingSilence: trail)
    }
}

/// Beszéd közben gyűjti a mintákat, hogy a szünet végén a kész WAV azonnal meglegyen (nem a felengedés után kódolunk először).
public final class IncrementalCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [Float] = []
    private let sampleRate: Int
    public init(sampleRate: Int = 16_000) { self.sampleRate = sampleRate }
    public func reset() { lock.lock(); raw.removeAll(keepingCapacity: true); lock.unlock() }
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock(); raw.append(contentsOf: samples); lock.unlock()
    }
    public func snapshot() -> PreparedTurn {
        lock.lock(); let copy = raw; lock.unlock()
        return PreparedTurn.make(copy, sampleRate: sampleRate)
    }
}

/// Mikor indulhatna el egy fizetős átírás még a felengedés előtt.
/// A helyi `Task.cancel` csak a kliens feltöltését szakítja meg: a szolgáltató a már átvett kérést kiszámlázhatja.
public enum SpeculationPolicy {
    /// Ennyi csend a beszéd után: a `prepare` levágása (0,4 s) már nem változtat a mintákon, ha nem szólal meg újra.
    public static let trailingSilence = 0.45
    public static let minimumSpeech = 0.35
    /// Hezitáló beszédnél ne indítsunk korlátlan külön hívást. A megszakítottak ettől még számlázódhatnak.
    public static let maxStarts = 2

    public static func shouldStart(stats: AudioStats, trailingSilence trail: Double, starts: Int, inflight: TranscriptRequestID?, candidate: TranscriptRequestID,
                                   enabled: Bool = true, recording: Bool = true, closed: Bool = false, micInactive: Bool = false) -> Bool {
        if !enabled || !recording || closed || micInactive { return false }
        if starts >= maxStarts { return false }
        if inflight == candidate { return false }
        if AudioPrep.isSilent(stats) { return false }
        if stats.speechSeconds < minimumSpeech { return false }
        if trail < trailingSilence { return false }
        return true
    }
}

/// Egy felvétel számlázható hívásai. Az alapút 1 átírás + 1 tisztítás. Az előretöltés ki van kapcsolva, amíg nem bizonyított, hogy nem növeli a hívásszámot.
public enum CallBudget {
    public static let baselineTranscriptions = 1
    public static let baselineCleanups = 1

    /// `abandonedStarts`: olyan előretöltés, amit az app helyben megszakított vagy eldobott. A szolgáltató ezeket akkor is felszámíthatja.
    public static func perTake(prefetchEnabled: Bool, abandonedStarts: Int) -> (transcriptions: Int, cleanups: Int) {
        let extra = prefetchEnabled ? min(SpeculationPolicy.maxStarts, max(0, abandonedStarts)) : 0
        return (baselineTranscriptions + extra, baselineCleanups + extra)
    }

    /// Bekapcsolt előretöltésnél a legrosszabb eset: `maxStarts` eldobott pár + a felengedéskori pár.
    /// Kikapcsolva (alapértelmezés) ez megegyezik az alapúttal: 1 + 1. Megszakítás felengedés előtt az alapúton 0 hívás.
    public static func worstCase(prefetchEnabled: Bool) -> (transcriptions: Int, cleanups: Int) {
        perTake(prefetchEnabled: prefetchEnabled, abandonedStarts: prefetchEnabled ? SpeculationPolicy.maxStarts : 0)
    }
}

/// Előretöltés állapota. A `start` jegyét a hívás előtt `confirmSend` ellenőrzi; a megszakítás generációt növel, ezért a későn érkező jegy nem küldhet.
public final class PrefetchSession: @unchecked Sendable {
    public struct Ticket: Equatable, Sendable {
        public var generation: Int
        public var id: TranscriptRequestID
        public init(generation: Int, id: TranscriptRequestID) { self.generation = generation; self.id = id }
    }
    public enum Verdict: Equatable, Sendable { case ignore, abandon, start(Ticket) }

    private let lock = NSLock()
    private var generation = 0
    private var closed = false
    private var starts = 0
    private var inflight: TranscriptRequestID?

    public init() {}

    public func beginRecording() {
        lock.lock(); generation += 1; closed = false; starts = 0; inflight = nil; lock.unlock()
    }

    /// Felhasználói megszakítás vagy néma mikrofon. A már elküldött kérést a szolgáltató ettől még felszámíthatja.
    public func close() {
        lock.lock(); generation += 1; closed = true; inflight = nil; lock.unlock()
    }

    public func consider(enabled: Bool, recording: Bool, micInactive: Bool, stats: AudioStats, trailingSilence: Double, candidate: TranscriptRequestID) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        let blocked = !enabled || !recording || closed || micInactive
        if blocked {
            if inflight != nil { inflight = nil; return .abandon }
            return .ignore
        }
        if let current = inflight, current != candidate {
            inflight = nil
            guard SpeculationPolicy.shouldStart(stats: stats, trailingSilence: trailingSilence, starts: starts, inflight: nil, candidate: candidate, enabled: true, recording: true) else { return .abandon }
            starts += 1
            inflight = candidate
            return .start(Ticket(generation: generation, id: candidate))
        }
        guard SpeculationPolicy.shouldStart(stats: stats, trailingSilence: trailingSilence, starts: starts, inflight: inflight, candidate: candidate, enabled: true, recording: true) else { return .ignore }
        starts += 1
        inflight = candidate
        return .start(Ticket(generation: generation, id: candidate))
    }

    /// Hamis, ha közben megszakították, a mikrofon elhallgatott, vagy új felvétel indult. Ilyenkor nem szabad hálózatot nyitni.
    public func confirmSend(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && ticket.generation == generation && inflight == ticket.id
    }

    /// A küldés mégsem történt meg: a foglalást visszaadjuk, hogy egy későbbi, még nyitott szünet elindulhasson.
    public func cancelSend(_ ticket: Ticket) {
        lock.lock()
        if !closed, ticket.generation == generation, inflight == ticket.id {
            inflight = nil
            if starts > 0 { starts -= 1 }
        }
        lock.unlock()
    }
}

/// Helyi WAV-előállítás felvétel közben. Nem küld hálózatot. Felengedéskor csak akkor használható, ha a mintaszám változatlan.
public final class LocalTurnPrep: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [Float] = []
    private var readyTurn: PreparedTurn?
    private var readyCount = -1
    private var busy = false
    private let sampleRate: Int

    public init(sampleRate: Int = 16_000) { self.sampleRate = sampleRate }

    public func reset() {
        lock.lock(); raw.removeAll(keepingCapacity: true); readyTurn = nil; readyCount = -1; busy = false; lock.unlock()
    }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock(); raw.append(contentsOf: samples); lock.unlock()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return raw.count }

    /// Ha már fut egy előkészítés, `nil` (nem indít másodikat). A visszaadott szám a másolat hossza; ha közben új minta jött, a cache nem ezt a WAV-ot tárolja.
    public func prepareLatestIfIdle() -> (turn: PreparedTurn, count: Int)? {
        lock.lock()
        if busy { lock.unlock(); return nil }
        busy = true
        let copy = raw
        let n = raw.count
        lock.unlock()
        let turn = PreparedTurn.make(copy, sampleRate: sampleRate)
        lock.lock()
        busy = false
        if raw.count == n { readyTurn = turn; readyCount = n }
        lock.unlock()
        return (turn, n)
    }

    public func ready(count: Int) -> PreparedTurn? {
        lock.lock(); defer { lock.unlock() }
        guard readyCount == count else { return nil }
        return readyTurn
    }
}

/// Felengedéskor csak akkor vesszük át a már futó átiratot, ha a WAV és a prompt bitre ugyanaz.
public enum TurnSelection {
    public static func useInflight(_ inflight: TranscriptRequestID?, final: TranscriptRequestID) -> Bool { inflight == final }
}

/// Szakaszidők. Szöveget, kulcsot és hangot nem tartalmaz.
public struct DictationTrace: Sendable, Equatable {
    public var finalizeMs: Int
    public var transcribeWaitMs: Int
    /// A felengedés előtt már futó átírásból ennyi esett a beszéd utáni csendbe.
    public var overlappedMs: Int
    public var cleanupMs: Int
    public var pasteMs: Int
    public var postSpeechMs: Int
    public var speculated: Bool
    public var bytes: Int

    public init(finalizeMs: Int, transcribeWaitMs: Int, overlappedMs: Int, cleanupMs: Int, pasteMs: Int, postSpeechMs: Int, speculated: Bool, bytes: Int) {
        self.finalizeMs = finalizeMs
        self.transcribeWaitMs = transcribeWaitMs
        self.overlappedMs = overlappedMs
        self.cleanupMs = cleanupMs
        self.pasteMs = pasteMs
        self.postSpeechMs = postSpeechMs
        self.speculated = speculated
        self.bytes = bytes
    }

    public var logLine: String {
        "lat finalize=\(finalizeMs)ms transcribeWait=\(transcribeWaitMs)ms overlapped=\(overlappedMs)ms cleanup=\(cleanupMs)ms paste=\(pasteMs)ms postSpeech=\(postSpeechMs)ms bytes=\(bytes) spec=\(speculated ? 1 : 0)"
    }
}

/// Beillesztés-ellenőrzés: a szöveg a ⌘V pillanatában kerül a mezőbe; utána csak addig várunk, amíg a mező értéke meg nem változik.
public enum PasteConfirm {
    public static let firstWaitMs = 40
    public static let pollMs = 40
    public static let maxPolls = 8
    public static let slowExtraMs = 200

    public static func shouldPoll(pollsDone: Int, valueChanged: Bool, canRead: Bool) -> Bool {
        canRead && !valueChanged && pollsDone < maxPolls
    }
}

/// Időzítési modell (nem mérés): megmutatja, a csend alatti pontos átírás mennyit vesz le a felengedés utáni várakozásból.
/// A bemenő másodpercek feltételezések. Az eredmény nem p50/p95 és nem élő hálózati adat.
public struct LatencyModel: Sendable, Equatable {
    public var audioSeconds: Double
    public var wavBytesPerSecond: Double
    public var uplinkBytesPerSecond: Double
    public var transcribeComputeSeconds: Double
    public var cleanupSeconds: Double
    public var predictedCleanupSeconds: Double
    public var finalizeSeconds: Double
    public var pasteSeconds: Double
    public var trailingSilenceSeconds: Double
    public var speculateAfterSeconds: Double

    public init(audioSeconds: Double, wavBytesPerSecond: Double = 32_000, uplinkBytesPerSecond: Double, transcribeComputeSeconds: Double, cleanupSeconds: Double, predictedCleanupSeconds: Double, finalizeSeconds: Double, pasteSeconds: Double, trailingSilenceSeconds: Double, speculateAfterSeconds: Double = SpeculationPolicy.trailingSilence) {
        self.audioSeconds = audioSeconds
        self.wavBytesPerSecond = wavBytesPerSecond
        self.uplinkBytesPerSecond = uplinkBytesPerSecond
        self.transcribeComputeSeconds = transcribeComputeSeconds
        self.cleanupSeconds = cleanupSeconds
        self.predictedCleanupSeconds = predictedCleanupSeconds
        self.finalizeSeconds = finalizeSeconds
        self.pasteSeconds = pasteSeconds
        self.trailingSilenceSeconds = trailingSilenceSeconds
        self.speculateAfterSeconds = speculateAfterSeconds
    }

    public func uploadSeconds() -> Double {
        guard uplinkBytesPerSecond > 0 else { return 0 }
        return audioSeconds * wavBytesPerSecond / uplinkBytesPerSecond
    }
    public func transcribeSeconds() -> Double { uploadSeconds() + transcribeComputeSeconds }

    public func baselinePostSpeech(prediction: Bool) -> Double {
        finalizeSeconds + transcribeSeconds() + (prediction ? predictedCleanupSeconds : cleanupSeconds) + pasteSeconds
    }

    /// `speculationMatched`: a felengedéskori WAV megegyezik a csend alatt elindított kéréssel.
    public func improvedPostSpeech(prediction: Bool, speculationMatched: Bool) -> Double {
        let cleanup = prediction ? predictedCleanupSeconds : cleanupSeconds
        let headStart = speculationMatched ? max(0, trailingSilenceSeconds - speculateAfterSeconds) : 0
        let transcribeLeft = max(0, transcribeSeconds() - headStart)
        return finalizeSeconds + transcribeLeft + cleanup + pasteSeconds
    }
}
