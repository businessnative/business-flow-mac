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

    private init() {
        settings = settingsStore.load() ?? AppSettings()
        history = HistoryLogic.prune(historyStore.load() ?? [], retention: settings.retention)
        // Csak a kulcs meglétét kérdezzük (adat nélkül): ez nem kér Kulcskarika-jóváhagyást indításkor.
        refreshKey()
    }

    var stats: HistoryStats { HistoryLogic.stats(history) }

    func addHistory(_ item: HistoryItem) {
        guard settings.retention != .never else { lastTranscript = item.text; return }
        history.insert(item, at: 0)
        lastTranscript = item.text
        saveHistory()
    }
    func deleteHistory(_ id: UUID) { history.removeAll { $0.id == id }; saveHistory() }
    func clearHistory() { history.removeAll(); saveHistory() }
    func applyRetention() { history = HistoryLogic.prune(history, retention: settings.retention); saveHistory() }
    private func saveHistory() { historyStore.save(history) }

    /// Az utolsó átirat akkor is elérhető, ha az előzmények mentése ki van kapcsolva (csak memóriában).
    var lastTranscript: String?
    var lastText: String? { lastTranscript ?? history.first?.text }

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
