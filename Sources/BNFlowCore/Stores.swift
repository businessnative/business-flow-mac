import Foundation

public enum AppPaths {
    /// A felhasználónak látszó alkalmazásnév.
    public static let appName = "Business Flow"
    /// A 0.3.0 előtti név (adatmappa-migrációhoz).
    public static let legacyFolderName = "BN Flow"

    /// Az adatmappa (beállítások, előzmények). A `BUSINESS_FLOW_SUPPORT_DIR` környezeti változó felülírja (önteszt).
    public static var supportDirectory: URL = {
        if let o = ProcessInfo.processInfo.environment["BUSINESS_FLOW_SUPPORT_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return resolveSupportDirectory(base: base)
    }()

    /// Az új adatmappa útvonala; ha csak a régi („BN Flow”) létezik, átnevezi, így a beállítások és az előzmények megmaradnak.
    @discardableResult
    public static func resolveSupportDirectory(base: URL, fileManager fm: FileManager = .default) -> URL {
        let new = base.appendingPathComponent(appName, isDirectory: true)
        let old = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue {
            if (try? fm.moveItem(at: old, to: new)) == nil {
                // Ha az átnevezés nem sikerül, a régi mappát használjuk tovább (adatvesztés nélkül).
                return old
            }
        }
        return new
    }

    static func ensure(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

public final class JSONFileStore<T: Codable> {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: d)
    }
    public func save(_ value: T) {
        AppPaths.ensure(url.deletingLastPathComponent())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(value) else { return }
        try? d.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct HistoryStats: Equatable, Sendable {
    public var totalWords: Int
    public var weekWords: Int
    public var averageWPM: Int
    public var streakDays: Int
    public var sessions: Int
}

public enum HistoryLogic {
    public static func prune(_ items: [HistoryItem], retention: HistoryRetention, now: Date = Date()) -> [HistoryItem] {
        guard let age = retention.maxAge else { return items }
        if age == 0 { return [] }
        return items.filter { now.timeIntervalSince($0.date) <= age }
    }

    public static func stats(_ items: [HistoryItem], now: Date = Date(), calendar: Calendar = .current) -> HistoryStats {
        let total = items.reduce(0) { $0 + $1.wordCount }
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let week = items.filter { $0.date >= weekAgo }.reduce(0) { $0 + $1.wordCount }
        let dictated = items.filter { $0.kind == .dictation && $0.durationSeconds > 1 && $0.status.countsTowardPace }
        let words = dictated.reduce(0) { $0 + TextStats.wordCount($1.rawText) }
        let secs = dictated.reduce(0) { $0 + $1.durationSeconds }
        let wpm = secs > 0 ? Int((Double(words) / (secs / 60)).rounded()) : 0
        let days = Set(items.map { calendar.startOfDay(for: $0.date) })
        var streak = 0
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        while days.contains(day) { streak += 1; day = calendar.date(byAdding: .day, value: -1, to: day)! }
        return HistoryStats(totalWords: total, weekWords: week, averageWPM: wpm, streakDays: streak, sessions: items.count)
    }
}
