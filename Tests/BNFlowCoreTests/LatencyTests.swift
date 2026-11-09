import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BNFlowCore

/// A régi, mintánként appendelő WAV-kódoló. Csak a gyorsítás előtti költség mérésére.
private func encodeSlow(_ samples: [Int16], sampleRate: Int = 16_000) -> Data {
    var d = Data()
    let dataBytes = samples.count * 2
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
    samples.withUnsafeBufferPointer { buf in
        for s in buf { var x = s.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    }
    return d
}

private func speechLike(_ seconds: Double, rate: Int = 16_000, amplitude: Float = 0.4) -> [Float] {
    let n = Int(seconds * Double(rate))
    return (0..<n).map { i in
        let t = Double(i) / Double(rate)
        return amplitude * Float(sin(2 * Double.pi * 180 * t) + 0.35 * sin(2 * Double.pi * 540 * t))
    }
}

private func silence(_ seconds: Double, rate: Int = 16_000) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * Double(rate)))
}

private func percentiles(_ values: [Int]) -> (p50: Int, p95: Int) {
    let s = values.sorted()
    let p50 = s[s.count / 2]
    let p95 = s[min(s.count - 1, Int(Double(s.count - 1) * 0.95))]
    return (p50, p95)
}

private func timeMs(_ n: Int, _ body: () -> Void) -> [Int] {
    var out: [Int] = []
    out.reserveCapacity(n)
    for _ in 0..<n {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        out.append(Int((DispatchTime.now().uptimeNanoseconds &- t) / 1_000_000))
    }
    return out
}

struct LatencyTests {
    @Test func fastWavMatchesSlowAndDecodes() {
        let samples = WAV.floatToInt16(speechLike(0.25))
        let fast = WAV.encode(samples: samples)
        let slow = encodeSlow(samples)
        #expect(fast == slow)
        let decoded = WAV.decode(fast)
        #expect(decoded?.sampleRate == 16_000)
        #expect(decoded?.samples.count == samples.count)
    }

    /// Helyi CPU-mérés (nem hálózat): rövid és hosszú hang kódolása és előkészítése.
    @Test func localFinalizeBenchmark() {
        let runs = 21
        let shortPCM = WAV.floatToInt16(speechLike(2))
        let longPCM = WAV.floatToInt16(speechLike(30))
        _ = WAV.encode(samples: shortPCM)
        _ = encodeSlow(shortPCM)
        let fastShort = timeMs(runs) { _ = WAV.encode(samples: shortPCM) }
        let slowShort = timeMs(runs) { _ = encodeSlow(shortPCM) }
        let fastLong = timeMs(runs) { _ = WAV.encode(samples: longPCM) }
        let slowLong = timeMs(runs) { _ = encodeSlow(longPCM) }
        let prepShort = timeMs(runs) { _ = AudioPrep.prepare(speechLike(2)) }
        let prepLong = timeMs(runs) { _ = AudioPrep.prepare(speechLike(30)) }
        let fs = percentiles(fastShort), ss = percentiles(slowShort)
        let fl = percentiles(fastLong), sl = percentiles(slowLong)
        let ps = percentiles(prepShort), pl = percentiles(prepLong)
        print("LOCAL encode short 2s fast p50=\(fs.p50)ms p95=\(fs.p95)ms slow p50=\(ss.p50)ms p95=\(ss.p95)ms")
        print("LOCAL encode long 30s fast p50=\(fl.p50)ms p95=\(fl.p95)ms slow p50=\(sl.p50)ms p95=\(sl.p95)ms")
        print("LOCAL prepare short 2s p50=\(ps.p50)ms p95=\(ps.p95)ms long 30s p50=\(pl.p50)ms p95=\(pl.p95)ms runs=\(runs)")
        #expect(fl.p50 < sl.p50)
        #expect(fastLong.max() ?? 0 < 500)
    }

    @Test func chunkedCaptureMatchesOneShot() {
        let raw = silence(0.3) + speechLike(1.0) + silence(0.7)
        let cap = IncrementalCapture()
        var i = 0
        while i < raw.count {
            let n = min(320, raw.count - i)
            cap.append(Array(raw[i..<i + n]))
            i += n
        }
        #expect(cap.snapshot().wav == PreparedTurn.make(raw).wav)
    }

    @Test func extraTrailingSilenceKeepsTheSameWav() {
        let head = speechLike(1.2, amplitude: 0.45)
        let paused = head + silence(0.55)
        let held = paused + silence(1.0)
        let a = PreparedTurn.make(paused)
        let b = PreparedTurn.make(held)
        #expect(a.trailingSilence >= SpeculationPolicy.trailingSilence)
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.wav == b.wav)
        let idA = TranscriptRequestID(audio: a.fingerprint, prompt: 9)
        let idB = TranscriptRequestID(audio: b.fingerprint, prompt: 9)
        #expect(TurnSelection.useInflight(idA, final: idB))
        #expect(SpeculationPolicy.shouldStart(stats: a.stats, trailingSilence: a.trailingSilence, starts: 0, inflight: nil, candidate: idA))
        #expect(!SpeculationPolicy.shouldStart(stats: a.stats, trailingSilence: a.trailingSilence, starts: 0, inflight: idA, candidate: idA))
    }

    @Test func moreSpeechOrDifferentPromptRejectsInflight() {
        let paused = speechLike(1.0, amplitude: 0.45) + silence(0.6)
        let continued = paused + speechLike(0.4, amplitude: 0.45)
        let a = PreparedTurn.make(paused)
        let b = PreparedTurn.make(continued)
        #expect(a.fingerprint != b.fingerprint)
        let samePrompt = TranscriptRequestID(audio: a.fingerprint, prompt: 3)
        #expect(!TurnSelection.useInflight(samePrompt, final: TranscriptRequestID(audio: b.fingerprint, prompt: 3)))
        let otherPrompt = TranscriptRequestID.make(wav: a.wav, provider: "openai", model: "gpt-transcribe", fallback: "gpt-4o-transcribe", language: "auto", terms: ["Dorottya"])
        let original = TranscriptRequestID.make(wav: a.wav, provider: "openai", model: "gpt-transcribe", fallback: "gpt-4o-transcribe", language: "auto", terms: ["ClickUp"])
        #expect(otherPrompt != original)
        #expect(!TurnSelection.useInflight(original, final: otherPrompt))
        #expect(!SpeculationPolicy.shouldStart(stats: a.stats, trailingSilence: 0.1, starts: 0, inflight: nil, candidate: original))
        #expect(!SpeculationPolicy.shouldStart(stats: a.stats, trailingSilence: 2, starts: SpeculationPolicy.maxStarts, inflight: nil, candidate: original))
    }

    @Test func traceLineHasDurationsOnly() {
        let secret = "sk-live-not-a-real-key"
        let dictated = "Dorottya holnap küldi a Business Native ajánlatot."
        let trace = DictationTrace(finalizeMs: 12, transcribeWaitMs: 40, overlappedMs: 900, cleanupMs: 30, pasteMs: 40, postSpeechMs: 122, speculated: true, bytes: dictated.utf8.count)
        #expect(!trace.logLine.contains(secret))
        #expect(!trace.logLine.contains(dictated))
        #expect(!trace.logLine.contains("Dorottya"))
        #expect(trace.logLine.contains("overlapped=900ms"))
        #expect(trace.logLine.contains("spec=1"))
    }

    @Test func pasteConfirmStopsWhenTheFieldChanges() {
        #expect(PasteConfirm.shouldPoll(pollsDone: 0, valueChanged: false, canRead: true))
        #expect(!PasteConfirm.shouldPoll(pollsDone: 0, valueChanged: true, canRead: true))
        #expect(!PasteConfirm.shouldPoll(pollsDone: 0, valueChanged: false, canRead: false))
        #expect(!PasteConfirm.shouldPoll(pollsDone: PasteConfirm.maxPolls, valueChanged: false, canRead: true))
        let worst = PasteConfirm.firstWaitMs + PasteConfirm.maxPolls * PasteConfirm.pollMs + PasteConfirm.slowExtraMs
        #expect(worst < 350 + 400)
        #expect(PasteConfirm.firstWaitMs < 350)
    }

    @Test func paidPrefetchIsOffByDefaultAndOldSettingsStayOff() throws {
        #expect(!AppSettings().paidPrefetch)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"chatModel":"gpt-4.1-mini"}"#.utf8))
        #expect(!old.paidPrefetch)
        #expect(old.chatModel == "gpt-4.1-mini")
        var on = AppSettings(); on.paidPrefetch = true
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(on))
        #expect(back.paidPrefetch)
    }

    @Test func defaultPathDoesNotAddBillableCalls() {
        let off = CallBudget.worstCase(prefetchEnabled: false)
        let on = CallBudget.worstCase(prefetchEnabled: true)
        #expect(off.transcriptions == CallBudget.baselineTranscriptions)
        #expect(off.cleanups == CallBudget.baselineCleanups)
        #expect(on.transcriptions == 1 + SpeculationPolicy.maxStarts)
        #expect(on.cleanups == 1 + SpeculationPolicy.maxStarts)
        #expect(CallBudget.perTake(prefetchEnabled: false, abandonedStarts: 2).transcriptions == 1)
        // A helyi cancel nem vonja vissza a már átvett kérést: az eldobott indulások benne vannak a felső határban.
        #expect(CallBudget.perTake(prefetchEnabled: true, abandonedStarts: 2).transcriptions == 3)
        #expect(CallBudget.perTake(prefetchEnabled: true, abandonedStarts: 99).cleanups == 3)
    }

    @Test func prefetchStaysOffAcrossPauseResumeCancelAndDeadMic() {
        let session = PrefetchSession()
        session.beginRecording()
        let audio = PreparedTurn.make(speechLike(1.0, amplitude: 0.45) + silence(0.6))
        let id = TranscriptRequestID(audio: audio.fingerprint, prompt: 1)
        let stats = audio.stats
        #expect(session.consider(enabled: false, recording: true, micInactive: false, stats: stats, trailingSilence: audio.trailingSilence, candidate: id) == .ignore)
        let later = TranscriptRequestID(audio: audio.fingerprint &+ 1, prompt: 1)
        #expect(session.consider(enabled: false, recording: true, micInactive: false, stats: stats, trailingSilence: audio.trailingSilence, candidate: later) == .ignore)
        session.close()
        #expect(session.consider(enabled: true, recording: true, micInactive: false, stats: stats, trailingSilence: audio.trailingSilence, candidate: id) == .ignore)
        #expect(session.consider(enabled: true, recording: true, micInactive: true, stats: stats, trailingSilence: audio.trailingSilence, candidate: id) == .ignore)
        #expect(!SpeculationPolicy.shouldStart(stats: stats, trailingSilence: audio.trailingSilence, starts: 0, inflight: nil, candidate: id, enabled: false))
        #expect(!SpeculationPolicy.shouldStart(stats: stats, trailingSilence: audio.trailingSilence, starts: 0, inflight: nil, candidate: id, closed: true))
        #expect(!SpeculationPolicy.shouldStart(stats: stats, trailingSilence: audio.trailingSilence, starts: 0, inflight: nil, candidate: id, micInactive: true))
    }

    @Test func prefetchPauseResumeCancelRaceDoesNotSendStaleTicket() {
        let session = PrefetchSession()
        session.beginRecording()
        let firstAudio = PreparedTurn.make(speechLike(1.0, amplitude: 0.45) + silence(0.6))
        let first = TranscriptRequestID(audio: firstAudio.fingerprint, prompt: 7)
        guard case .start(let ticket) = session.consider(enabled: true, recording: true, micInactive: false, stats: firstAudio.stats, trailingSilence: firstAudio.trailingSilence, candidate: first) else {
            Issue.record("az első szünetnek indulnia kellene"); return
        }
        #expect(session.confirmSend(ticket))
        let resumed = TranscriptRequestID(audio: first.audio &+ 9, prompt: 7)
        let again = session.consider(enabled: true, recording: true, micInactive: false, stats: firstAudio.stats, trailingSilence: firstAudio.trailingSilence, candidate: resumed)
        guard case .start(let second) = again else { Issue.record("a folytatás utáni új szünet új jegyet ad"); return }
        #expect(!session.confirmSend(ticket))
        #expect(session.confirmSend(second))
        session.close()
        #expect(!session.confirmSend(second))
        #expect(session.consider(enabled: true, recording: true, micInactive: false, stats: firstAudio.stats, trailingSilence: firstAudio.trailingSilence, candidate: resumed) == .ignore)
        session.beginRecording()
        let after = session.consider(enabled: true, recording: true, micInactive: false, stats: firstAudio.stats, trailingSilence: firstAudio.trailingSilence, candidate: first)
        guard case .start(let fresh) = after else { Issue.record("új felvétel újra indíthat"); return }
        session.close()
        #expect(!session.confirmSend(fresh))
        session.cancelSend(fresh)
        #expect(session.consider(enabled: true, recording: false, micInactive: false, stats: firstAudio.stats, trailingSilence: firstAudio.trailingSilence, candidate: first) == .ignore)
    }

    @Test func prefetchCapsAbandonedStarts() {
        let session = PrefetchSession()
        session.beginRecording()
        let base = PreparedTurn.make(speechLike(1.0, amplitude: 0.45) + silence(0.6))
        var started = 0
        for i in 0..<5 {
            let id = TranscriptRequestID(audio: UInt64(i + 1), prompt: 3)
            switch session.consider(enabled: true, recording: true, micInactive: false, stats: base.stats, trailingSilence: base.trailingSilence, candidate: id) {
            case .start(let ticket):
                started += 1
                #expect(session.confirmSend(ticket))
            case .abandon, .ignore:
                break
            }
        }
        #expect(started == SpeculationPolicy.maxStarts)
    }

    @Test func localPrepIsReusableOnlyForTheSameSampleCount() {
        let prep = LocalTurnPrep()
        let raw = speechLike(0.8, amplitude: 0.45) + silence(0.2)
        var i = 0
        while i < raw.count {
            prep.append(Array(raw[i..<min(raw.count, i + 480)]))
            i += 480
        }
        let first = prep.prepareLatestIfIdle()
        #expect(first?.count == raw.count)
        #expect(prep.ready(count: raw.count)?.wav == PreparedTurn.make(raw).wav)
        #expect(prep.prepareLatestIfIdle()?.count == raw.count)
        prep.append(speechLike(0.2, amplitude: 0.45))
        #expect(prep.ready(count: raw.count)?.wav == PreparedTurn.make(raw).wav)
        #expect(prep.ready(count: prep.count) == nil)
        let grown = raw + speechLike(0.2, amplitude: 0.45)
        let second = prep.prepareLatestIfIdle()
        #expect(second?.count == grown.count)
        #expect(prep.ready(count: grown.count)?.wav == PreparedTurn.make(grown).wav)
    }

    /// Feltételezett szakaszidők. Nem mérés. Az alapút nem indít második hívást; a szünet alatti átfedés csak a kikapcsolt előretöltés modellje.
    @Test func timingModelShowsOverlapOnlyWhenTheWavMatches() {
        let uplink = 2_000_000.0 // 2 MB/s
        func model(_ silence: Double) -> LatencyModel {
            LatencyModel(audioSeconds: 8, uplinkBytesPerSecond: uplink, transcribeComputeSeconds: 1.2, cleanupSeconds: 2.5, predictedCleanupSeconds: 0.6, finalizeSeconds: 0.02, pasteSeconds: 0.04, trailingSilenceSeconds: silence)
        }
        let paused = model(1.2)
        let instant = model(0.05)
        let base = paused.baselinePostSpeech(prediction: false)
        let matched = paused.improvedPostSpeech(prediction: false, speculationMatched: true)
        let missed = paused.improvedPostSpeech(prediction: false, speculationMatched: false)
        print("MODEL 8s audio, 2MB/s uplink, 1.2s compute, 2.5s cleanup — baseline \(base)s, pause-matched \(matched)s, instant-release \(instant.improvedPostSpeech(prediction: false, speculationMatched: false))s")
        #expect(matched < base)
        #expect(missed == base)
        #expect(instant.improvedPostSpeech(prediction: false, speculationMatched: false) == instant.baselinePostSpeech(prediction: false))
        // Azonnali felengedés, előretöltés nélkül: csak a mért kódolás és a rögzített várakozási plafon változik. Nem hálózati mérés.
        let network = 1.2 + (8 * 32_000 / 2_000_000)
        let oldFinalize = 0.025
        let newFinalize = 0.0
        let oldPaste = 0.350
        let newPaste = Double(PasteConfirm.firstWaitMs) / 1000
        let oldImmediate = oldFinalize + network + 2.5 + oldPaste
        let newImmediate = newFinalize + network + 2.5 + newPaste
        #expect(newImmediate < oldImmediate)
        #expect(abs((oldImmediate - newImmediate) - (oldFinalize - newFinalize + oldPaste - newPaste)) < 0.0001)
    }
}

final class PredictionChat: ChatProvider, @unchecked Sendable {
    var seen: String?
    let reply: String
    init(reply: String) { self.reply = reply }
    func complete(system: String, user: String) async -> Result<String, FlowError> { .success(reply) }
    func complete(system: String, user: String, prediction: String?) async -> Result<String, FlowError> {
        seen = prediction
        return await complete(system: system, user: user)
    }
}

struct QualityEquivalenceTests {
    private let names = "Holnap Dorottyának küldöm a Business Native ajánlatot a ClickUpba, és utána egyeztetünk a Slackben Sarah-val."
    private let correction = "Találkozunk kettőkor, nem, inkább háromkor Attilával a ClickUpban."
    private let question = "Mikor érsz oda a Business Native irodába, Dorottya?"
    private let longMixed = """
    Szia Dorottya! Holnap délelőtt átküldöm a Business Native ajánlatot, a ClickUpban pedig létrehozom a feladatot. \
    Az első pont a szerződés, a második a határidő, a harmadik a számla. \
    Kérlek, nézd át, és írd meg, hogy a deck csütörtökre jó-e Sarah-nak. \
    Az e-mail cím: info kukac pelda pont hu.
    """

    private func local(_ raw: String) -> String {
        TextPipeline.process(raw, settings: AppSettings(), tone: .formal, context: .empty, category: .other)
    }

    @Test func hungarianFixturesKeepNamesPunctuationAndCorrection() {
        let n = local(names)
        #expect(n.contains("Dorottyának"))
        #expect(n.contains("Business Native"))
        #expect(n.contains("ClickUp"))
        #expect(n.contains("Slack"))
        #expect(n.contains("Sarah"))
        let c = local(correction)
        #expect(c.contains("háromkor"))
        #expect(c.contains("Attilával"))
        #expect(c.contains("ClickUp"))
        #expect(!c.lowercased().contains("kettőkor"))
        let q = local(question)
        #expect(q.contains("?"))
        #expect(q.contains("Dorottya"))
        #expect(q.contains("Business Native"))
        let l = local(longMixed)
        #expect(l.contains("Dorottya"))
        #expect(l.contains("Business Native"))
        #expect(l.contains("ClickUp"))
        #expect(l.contains("Sarah"))
        #expect(l.contains("deck"))
        #expect(l.contains("@") || l.contains("businessnative"))
        #expect(l.contains("1.") || l.contains("első") || l.contains("Első"))
        #expect(local(names) == n)
        #expect(local(correction) == c)
        #expect(local(longMixed) == l)
        let trace = DictationTrace(finalizeMs: 1, transcribeWaitMs: 1, overlappedMs: 1, cleanupMs: 1, pasteMs: 1, postSpeechMs: 4, speculated: false, bytes: 8)
        for fixture in [n, c, q, l] {
            #expect(!trace.logLine.contains(fixture))
        }
    }

    @Test func formatterPastesModelTextNotThePrediction() async {
        let raw = correction + " " + names
        let localText = local(raw)
        #expect(FormatPolicy.needsLLM(raw: raw))
        let agreed = PredictionChat(reply: localText)
        let edited = "Holnap háromkor találkozunk Attilával a ClickUpban, és Dorottyának küldöm a Business Native ajánlatot."
        let diverged = PredictionChat(reply: edited)
        let s = AppSettings()
        let a = await DictationFormatter.format(raw: raw, settings: s, context: .empty, chat: agreed)
        let b = await DictationFormatter.format(raw: raw, settings: s, context: .empty, chat: diverged)
        #expect(agreed.seen == localText)
        #expect(diverged.seen == localText)
        #expect(a.usedLLM)
        #expect(b.usedLLM)
        #expect(a.text == local(localText) || a.text == localText)
        #expect(b.text.contains("háromkor"))
        #expect(b.text.contains("ClickUp"))
        #expect(b.text.contains("Business Native"))
        #expect(!b.text.contains("kettőkor"))
        let again = await DictationFormatter.format(raw: raw, settings: s, context: .empty, chat: PredictionChat(reply: edited))
        #expect(again.text == b.text)
    }
}

final class PredictionStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [Data] = []
    static let lock = NSLock()
    static func reset() { lock.lock(); bodies = []; lock.unlock() }
    static func snapshot() -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let s = request.httpBodyStream {
            s.open(); var buf = [UInt8](repeating: 0, count: 8192)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            s.close()
        }
        Self.lock.lock(); Self.bodies.append(data); let n = Self.bodies.count; Self.lock.unlock()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let hasPrediction = json?["prediction"] != nil
        let status: Int
        let body: Data
        if n == 1 && hasPrediction {
            status = 400
            body = Data(#"{"error":{"code":"unknown_parameter","param":"prediction","message":"unknown prediction"}}"#.utf8)
        } else {
            status = 200
            body = Data(#"{"choices":[{"message":{"content":"Holnap háromkor találkozunk Attilával."}}]}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct PredictionRequestTests {
    @Test func chatRequestCarriesPredictionWithoutReplacingTheUserText() throws {
        let c = OpenAIClient()
        let r = c.makeChatRequest(apiKey: "sk-test", model: "gpt-5.6-luna", system: "rendszer", user: "Holnap Dorottyának.", prediction: "Holnap Dorottyának küldöm.")
        let j = try #require(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        let pred = try #require(j["prediction"] as? [String: Any])
        #expect(pred["type"] as? String == "content")
        #expect(pred["content"] as? String == "Holnap Dorottyának küldöm.")
        let messages = try #require(j["messages"] as? [[String: Any]])
        #expect(messages.last?["content"] as? String == "Holnap Dorottyának.")
        #expect(j["reasoning_effort"] as? String == "low")
        #expect(j["model"] as? String == "gpt-5.6-luna")
        let plain = c.makeChatRequest(apiKey: "sk-test", model: "gpt-4.1-mini", system: "s", user: "u")
        let j2 = try #require(JSONSerialization.jsonObject(with: plain.httpBody!) as? [String: Any])
        #expect(j2["prediction"] == nil)
    }

    @Test func rejectedPredictionRetriesSameModelAndKeepsModelText() async throws {
        PredictionSupport.reset()
        PredictionStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PredictionStub.self]
        let client = OpenAIClient(session: URLSession(configuration: cfg))
        let first = await client.chat(apiKey: "sk-test", model: "gpt-5.6-luna", fallbackModel: "gpt-4.1-mini", system: "s", user: "nyers", prediction: "piszkozat")
        #expect(try first.get() == "Holnap háromkor találkozunk Attilával.")
        let bodies = PredictionStub.snapshot()
        #expect(bodies.count == 2)
        let firstJSON = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        let secondJSON = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect(firstJSON["prediction"] != nil)
        #expect(secondJSON["prediction"] == nil)
        #expect(firstJSON["model"] as? String == "gpt-5.6-luna")
        #expect(secondJSON["model"] as? String == "gpt-5.6-luna")
        PredictionStub.reset()
        let second = await client.chat(apiKey: "sk-test", model: "gpt-5.6-luna", fallbackModel: "gpt-4.1-mini", system: "s", user: "nyers", prediction: "piszkozat")
        #expect(try second.get() == "Holnap háromkor találkozunk Attilával.")
        let later = PredictionStub.snapshot()
        #expect(later.count == 1)
        let laterJSON = try #require(JSONSerialization.jsonObject(with: later[0]) as? [String: Any])
        #expect(laterJSON["prediction"] == nil)
        #expect(laterJSON["model"] as? String == "gpt-5.6-luna")
        PredictionSupport.reset()
    }
}
