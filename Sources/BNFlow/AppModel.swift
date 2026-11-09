import AppKit
import SwiftUI
import BNFlowCore

enum BarMode: Equatable {
    case idle
    case recording(RecordingFlavor, handsFree: Bool)
    case processing(String?)
    case error(String)
    case polishProcessing
    case polishDone
    case notice(String)
}

enum RecordingFlavor: Equatable { case dictation, command, instruct }

/// Az alkalmazás teljes állapota (beállítások, előzmények, sáv), a fő szálon.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings { didSet { if settings != oldValue { settingsStore.save(settings); onSettingsChanged?(oldValue, settings) } } }
    @Published private(set) var history: [HistoryItem] = []
    @Published var bar: BarMode = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 10)
    @Published var hovering = false
    @Published var hasAPIKey = false
    /// Szolgáltatónként: van-e mentett kulcs.
    @Published var keyStatus: [AIProvider: Bool] = [:]
    @Published var lastPolish: (before: String, after: String)? = nil
    @Published var permissionTick = 0
    @Published var hubSection: HubSection = .home
    @Published var settingsTab: SettingsTab = .general
    @Published var recordingSince: Date? = nil

    var onSettingsChanged: ((AppSettings, AppSettings) -> Void)?

    private let settingsStore = JSONFileStore<AppSettings>(url: AppPaths.supportDirectory.appendingPathComponent("settings.json"))
    private let historyStore = JSONFileStore<[HistoryItem]>(url: AppPaths.supportDirectory.appendingPathComponent("history.json"))
    let recordings = RecordingArchive(directory: AppPaths.supportDirectory.appendingPathComponent("recordings", isDirectory: true))
    /// A futó mentés ezt nézi: törlés vagy „ne mentsen” közben a későn beérkező hang nem kerül vissza.
    private(set) var historyEpoch = 0

    private init() {
        settings = settingsStore.load() ?? AppSettings()
        history = HistoryLogic.prune(historyStore.load() ?? [], retention: settings.retention)
        recordings.deleteUnreferenced(keeping: Set(history.compactMap(\.audioFile)))
        // Csak a kulcs meglétét kérdezzük (adat nélkül): ez nem kér Kulcskarika-jóváhagyást indításkor.
        refreshKey()
    }

    var stats: HistoryStats { HistoryLogic.stats(history) }

    func addHistory(_ item: HistoryItem) {
        var ledger = snapshot()
        ledger.add(item)
        apply(ledger, save: settings.retention != .never)
    }

    func updateHistory(_ item: HistoryItem) {
        var ledger = snapshot()
        let drop = ledger.update(item)
        drop.forEach { recordings.delete($0) }
        apply(ledger, save: settings.retention != .never)
    }

    func deleteHistory(_ id: UUID) {
        var ledger = snapshot()
        if let name = ledger.remove(id: id) { recordings.delete(name) }
        apply(ledger, save: true)
    }

    func clearHistory() {
        historyEpoch += 1
        var ledger = snapshot()
        ledger.removeAll().forEach { recordings.delete($0) }
        apply(ledger, save: true)
        recordings.deleteUnreferenced(keeping: [])
    }

    func applyRetention() {
        if settings.retention == .never { historyEpoch += 1 }
        var ledger = snapshot()
        ledger.retention = settings.retention
        ledger.prune().forEach { recordings.delete($0) }
        apply(ledger, save: true)
        if settings.retention == .never { recordings.deleteUnreferenced(keeping: []) }
    }

    /// A helyi hang fájlneve, ha a megőrzés engedi a mentést. Üres hangot nem ír ki.
    func archiveAudio(_ wav: Data, id: UUID) -> String? {
        guard settings.retention != .never else { return nil }
        return recordings.save(wav: wav, id: id)
    }

    private func snapshot() -> HistoryLedger {
        HistoryLedger(items: history, lastTranscript: lastTranscript, retention: settings.retention)
    }

    private func apply(_ ledger: HistoryLedger, save: Bool) {
        history = ledger.items
        lastTranscript = ledger.lastTranscript
        if save { saveHistory() }
    }

    private func saveHistory() { historyStore.save(history) }

    /// Az utolsó átirat akkor is elérhető, ha az előzmények mentése ki van kapcsolva (csak memóriában).
    /// Üres, sikertelen sor nem írja felül.
    var lastTranscript: String?
    var lastText: String? { snapshot().lastText }

    func pushLevel(_ l: Float) {
        var v = levels
        v.removeFirst()
        v.append(CGFloat(l))
        levels = v
    }
    func resetLevels() { levels = Array(repeating: 0, count: 10) }

    func refreshKey() {
        let k = Keychain.all()
        hasAPIKey = k.canTranscribe
        keyStatus = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { ($0, k[$0] != nil) })
    }

    /// Egy adott beállítás-lap megnyitása (pl. az „Első lépések” listából).
    /// A Hub ablak megnyitása (az AppDelegate köti be); így a beállítás-ugrások az ablakon kívülről is működnek.
    var showHub: ((HubSection?) -> Void)?
    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab; hubSection = .settings
        showHub?(.settings)
    }

    func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 })
    }
}

enum HubSection: String, CaseIterable, Identifiable {
    case home, dictionary, snippets, style, polish, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Kezdőlap"
        case .dictionary: return "Szótár"
        case .snippets: return "Szövegrészletek"
        case .style: return "Stílus"
        case .polish: return "Polírozás"
        case .settings: return "Beállítások"
        }
    }
    /// Lucide ikonnév.
    var icon: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "book-open"
        case .snippets: return "text-quote"
        case .style: return "type"
        case .polish: return "sparkles"
        case .settings: return "settings"
        }
    }
}
