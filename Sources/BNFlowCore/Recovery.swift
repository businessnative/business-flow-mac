import Foundation

/// Véletlen koppintás és a megőrzendő diktálás határa. A fél másodpercnél rövidebb, beszéd nélküli érintés nem kerül előzménybe.
public enum DictationRecovery {
    public static let accidentalMaxSeconds = 0.5

    /// `elapsed` a falióra, `speechSeconds` a hangaktivitás. A tesztmód hosszú mintája rövid koppintásnál nem számít beszédnek.
    public static func shouldRecord(elapsed: Double, speechSeconds: Double) -> Bool {
        if elapsed < accidentalMaxSeconds {
            return speechSeconds >= 0.15 && speechSeconds <= elapsed + 0.05
        }
        return true
    }
}

/// Felhasználónak szóló, rövid okok. Nem tartalmaznak kulcsot, tokent vagy HTTP-törzset.
public enum HistoryCopy {
    public static let generic = "Az átírás nem sikerült."
    public static let silence = "Nem hallottam beszédet."
    public static let emptyTranscript = "Nem érkezett szöveg."
    public static let interrupted = "A diktálás megszakadt."
    public static let timeout = "A feldolgozás nem fejeződött be időben."
    public static let stuck = "Az előző feldolgozás elakadt."
    public static let pasteFailed = "A szöveg nem került be a mezőbe."

    public static func reason(for error: FlowError, quotaMessage: String? = nil) -> String {
        switch error {
        case .quota, .rateLimit:
            return quotaMessage ?? error.message
        case .badRequest:
            return "A szolgáltatás elutasította a kérést."
        case .emptyResult:
            return emptyTranscript
        default:
            return error.message
        }
    }
}

/// Az előzménybe és a naplóba kerülő szövegből kiveszi a kulcsra vagy válasz-törzsre hasonlító részeket.
public enum HistoryPrivacy {
    static let markers = ["sk-", "sk_", "bearer ", "api_key", "api-key", "authorization", "x-api-key", "token=", "secret"]

    public static func sanitize(_ reason: String?) -> String? {
        guard let raw = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let low = raw.lowercased()
        if markers.contains(where: { low.contains($0) }) { return HistoryCopy.generic }
        if raw.count > 240 { return String(raw.prefix(240)) }
        return raw
    }

    public static func containsSecret(_ text: String) -> Bool {
        let low = text.lowercased()
        return markers.contains { low.contains($0) }
    }
}

/// Helyi WAV-fájlok. Csak ezen a gépen, csak a recordings mappában, csak `UUID.wav` néven.
public struct RecordingArchive: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func fileName(for id: UUID) -> String { "\(id.uuidString).wav" }

    public static func isSafeName(_ name: String) -> Bool {
        guard name.count < 80, name.hasSuffix(".wav"), !name.contains("/"), !name.contains("\\"), !name.contains("..") else { return false }
        return UUID(uuidString: String(name.dropLast(4))) != nil
    }

    /// A mentett fájlnév, vagy nil ha nincs mit menteni.
    public func save(wav: Data, id: UUID) -> String? {
        guard !wav.isEmpty else { return nil }
        let name = Self.fileName(for: id)
        guard Self.isSafeName(name) else { return nil }
        AppPaths.ensure(directory)
        let url = directory.appendingPathComponent(name)
        do {
            try wav.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return name
        } catch {
            return nil
        }
    }

    public func load(_ name: String) -> Data? {
        guard Self.isSafeName(name) else { return nil }
        let url = directory.appendingPathComponent(name)
        let base = directory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        return try? Data(contentsOf: url)
    }

    public func delete(_ name: String?) {
        guard let name, Self.isSafeName(name) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// A listában nem szereplő wav-okat törli. Más fájlhoz nem nyúl.
    public func deleteUnreferenced(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "wav" {
            let name = file.lastPathComponent
            guard Self.isSafeName(name), !names.contains(name) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

public enum HistoryRetryOutcome: Equatable, Sendable {
    case success(text: String, raw: String, pasted: Bool)
    case failure(FlowError, quotaMessage: String?)
}

/// Előzmény-sorok felépítése és az újrapróbálás eredményének ugyanarra a sorra írása.
public enum HistoryAttempt {
    public static func succeeded(id: UUID = UUID(), date: Date = Date(), text: String, raw: String, appName: String, bundleID: String, seconds: Double, kind: HistoryKind) -> HistoryItem {
        HistoryItem(id: id, date: date, text: text, rawText: raw, appName: appName, bundleID: bundleID, durationSeconds: seconds, kind: kind, status: .success, failureReason: nil, audioFile: nil)
    }

    public static func pasteFailed(id: UUID = UUID(), date: Date = Date(), text: String, raw: String, appName: String, bundleID: String, seconds: Double, kind: HistoryKind) -> HistoryItem {
        HistoryItem(id: id, date: date, text: text, rawText: raw, appName: appName, bundleID: bundleID, durationSeconds: seconds, kind: kind, status: .pasteFailed, failureReason: HistoryCopy.pasteFailed, audioFile: nil)
    }

    public static func failed(id: UUID = UUID(), date: Date = Date(), appName: String, bundleID: String, seconds: Double, kind: HistoryKind, reason: String, audioFile: String? = nil) -> HistoryItem {
        HistoryItem(id: id, date: date, text: "", rawText: "", appName: appName, bundleID: bundleID, durationSeconds: seconds, kind: kind, status: .failed, failureReason: reason, audioFile: audioFile)
    }

    public static func interrupted(id: UUID = UUID(), date: Date = Date(), appName: String, bundleID: String, seconds: Double, kind: HistoryKind, reason: String = HistoryCopy.interrupted, audioFile: String? = nil) -> HistoryItem {
        HistoryItem(id: id, date: date, text: "", rawText: "", appName: appName, bundleID: bundleID, durationSeconds: seconds, kind: kind, status: .interrupted, failureReason: reason, audioFile: audioFile)
    }

    public static func empty(id: UUID = UUID(), date: Date = Date(), appName: String, bundleID: String, seconds: Double, kind: HistoryKind, reason: String = HistoryCopy.silence, audioFile: String? = nil) -> HistoryItem {
        HistoryItem(id: id, date: date, text: "", rawText: "", appName: appName, bundleID: bundleID, durationSeconds: seconds, kind: kind, status: .empty, failureReason: reason, audioFile: audioFile)
    }

    /// Az újrapróbálás csak a már lemezre mentett hangot adja vissza. Kulcsot nem olvas, hálózatot nem nyit.
    public static func audioForRetry(item: HistoryItem, load: (String) -> Data?) -> Data? {
        guard item.canRetry, let name = item.audioFile else { return nil }
        guard let data = load(name), !data.isEmpty else { return nil }
        return data
    }

    /// Ugyanaz a sor: siker után a hang már nem kell, hiba után megmarad.
    public static func applyRetry(_ item: HistoryItem, outcome: HistoryRetryOutcome) -> HistoryItem {
        var next = item
        switch outcome {
        case .failure(let error, let quota):
            next.status = error == .emptyResult ? .empty : .failed
            next.failureReason = HistoryPrivacy.sanitize(HistoryCopy.reason(for: error, quotaMessage: quota))
            next.text = ""
            next.rawText = ""
            return next
        case .success(let text, let raw, let pasted):
            next.text = text
            next.rawText = raw
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next.status = .empty
                next.failureReason = HistoryCopy.emptyTranscript
                return next
            }
            next.audioFile = nil
            if pasted {
                next.status = .success
                next.failureReason = nil
            } else {
                next.status = .pasteFailed
                next.failureReason = HistoryCopy.pasteFailed
            }
            return next
        }
    }
}

/// Az előzmények és az utolsó átirat közös szabálya (a Hub és a vezérlő ugyanezt használja).
public struct HistoryLedger: Equatable, Sendable {
    public var items: [HistoryItem]
    public var lastTranscript: String?
    public var retention: HistoryRetention

    public init(items: [HistoryItem] = [], lastTranscript: String? = nil, retention: HistoryRetention = .forever) {
        self.items = items
        self.lastTranscript = lastTranscript
        self.retention = retention
    }

    public var lastText: String? {
        if let t = lastTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return lastTranscript }
        return items.first(where: \.canCopy)?.text
    }

    public mutating func add(_ item: HistoryItem) {
        if item.canCopy { lastTranscript = item.text }
        guard retention != .never else { return }
        items.insert(item, at: 0)
    }

    /// Az azonos sor frissítése. A visszaadott fájlneveket törölni kell.
    @discardableResult
    public mutating func update(_ item: HistoryItem) -> [String] {
        if item.canCopy { lastTranscript = item.text }
        guard retention != .never else { return [] }
        var next = item
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            if next.audioFile == nil, let old = items[i].audioFile, next.status.storesAudio {
                next.audioFile = old
            }
            var drop: [String] = []
            if let old = items[i].audioFile, old != next.audioFile { drop.append(old) }
            items[i] = next
            return drop
        }
        items.insert(next, at: 0)
        return []
    }

    @discardableResult
    public mutating func remove(id: UUID) -> String? {
        let audio = items.first { $0.id == id }?.audioFile
        items.removeAll { $0.id == id }
        return audio
    }

    public mutating func removeAll() -> [String] {
        let names = items.compactMap(\.audioFile)
        items.removeAll()
        return names
    }

    /// A megőrzési időn kívül eső sorok hangfájljainak nevei.
    public mutating func prune(now: Date = Date()) -> [String] {
        let kept = HistoryLogic.prune(items, retention: retention, now: now)
        let keptIDs = Set(kept.map(\.id))
        let drop = items.filter { !keptIDs.contains($0.id) }.compactMap(\.audioFile)
        items = kept
        return drop
    }
}
