import Foundation

public enum DictationLanguage: String, Codable, CaseIterable, Sendable {
    case auto, hu, en
    public var label: String {
        switch self { case .auto: return "Automatikus (magyar + angol)"; case .hu: return "Magyar"; case .en: return "Angol" }
    }
    /// Az átíró modellnek átadott nyelvek.
    public var codes: [String] {
        switch self { case .auto: return ["hu", "en"]; case .hu: return ["hu"]; case .en: return ["en"] }
    }
}

public enum StyleTone: String, Codable, CaseIterable, Sendable {
    case formal, casual, veryCasual
    public var label: String {
        switch self { case .formal: return "Formális"; case .casual: return "Laza"; case .veryCasual: return "Nagyon laza" }
    }
    public var example: String {
        switch self {
        case .formal: return "Szia! Holnap 10-kor tudok jönni, ha neked is jó."
        case .casual: return "Szia! Holnap 10-kor tudok jönni, ha neked is jó"
        case .veryCasual: return "szia holnap 10-kor tudok jönni ha neked is jó"
        }
    }
}

public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case personal, work, email, other
    public var label: String {
        switch self {
        case .personal: return "Személyes üzenetek"
        case .work: return "Munkahelyi üzenetek"
        case .email: return "E-mail"
        case .other: return "Minden más"
        }
    }
    public var detail: String {
        switch self {
        case .personal: return "Üzenetek, WhatsApp, Messenger, Telegram, Signal, Viber"
        case .work: return "Slack, Teams, Discord, Linear, Notion"
        case .email: return "Mail, Outlook, Spark, Superhuman"
        case .other: return "Minden egyéb alkalmazás"
        }
    }
}

/// Bal/jobb oldalt megkülönböztető módosítóbillentyűk (nyomva tartható parancsokhoz).
public enum ModifierKey: String, Codable, CaseIterable, Sendable, Hashable {
    case fn, leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand, leftShift, rightShift

    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftShift: return 56
        case .rightShift: return 60
        }
    }
    public static func from(keyCode: UInt16) -> ModifierKey? { allCases.first { $0.keyCode == keyCode } }

    public var modifierClass: ModifierClass {
        switch self {
        case .fn: return .fn
        case .leftControl, .rightControl: return .control
        case .leftOption, .rightOption: return .option
        case .leftCommand, .rightCommand: return .command
        case .leftShift, .rightShift: return .shift
        }
    }
    public var symbol: String {
        switch self {
        case .fn: return "fn"
        case .leftControl: return "⌃"
        case .rightControl: return "jobb ⌃"
        case .leftOption: return "⌥"
        case .rightOption: return "jobb ⌥"
        case .leftCommand: return "⌘"
        case .rightCommand: return "jobb ⌘"
        case .leftShift: return "⇧"
        case .rightShift: return "jobb ⇧"
        }
    }
}

/// Oldalfüggetlen módosító-osztály billentyűkombinációkhoz.
public enum ModifierClass: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case fn, control, option, shift, command
    public static func < (a: ModifierClass, b: ModifierClass) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
    public var symbol: String {
        switch self { case .fn: return "fn"; case .control: return "⌃"; case .option: return "⌥"; case .shift: return "⇧"; case .command: return "⌘" }
    }
}

/// Egy parancs kiváltója.
public enum ShortcutTrigger: Codable, Hashable, Sendable {
    /// Módosítók nyomva tartása (pl. fn, vagy fn+⌃). Pontos egyezés kell.
    case hold([ModifierKey])
    /// Billentyű + módosító-osztályok (pl. fn+Space, ⌃⌘V).
    case combo(keyCode: UInt16, modifiers: [ModifierClass])
    /// Egérgomb (CGEvent buttonNumber: 2 = középső, 3 = 4. gomb, 4 = 5. gomb).
    case mouse(button: Int)

    public var label: String {
        switch self {
        case .hold(let keys): return keys.map(\.symbol).joined(separator: " + ")
        case .combo(let code, let mods):
            return (mods.sorted().map(\.symbol) + [KeyNames.name(for: code)]).joined(separator: " + ")
        case .mouse(let b): return "Egér \(b + 1). gomb"
        }
    }
}

public enum KeyNames {
    static let names: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    public static func name(for code: UInt16) -> String { names[code] ?? "#\(code)" }
}

public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case pushToTalk, handsFree, command, pasteLast, polish
    public var label: String {
        switch self {
        case .pushToTalk: return "Diktálás (nyomva tartva)"
        case .handsFree: return "Kihangosított diktálás (be/ki)"
        case .command: return "Parancs mód (nyomva tartva)"
        case .pasteLast: return "Utolsó átirat beillesztése"
        case .polish: return "Kijelölés polírozása"
        }
    }
}

public struct ShortcutSettings: Codable, Equatable, Sendable {
    public var pushToTalk: [ShortcutTrigger]
    public var handsFree: [ShortcutTrigger]
    public var command: [ShortcutTrigger]
    public var pasteLast: [ShortcutTrigger]
    public var polish: [ShortcutTrigger]

    public static let `default` = ShortcutSettings(
        pushToTalk: [.hold([.fn])],
        handsFree: [.combo(keyCode: 49, modifiers: [.fn])],
        command: [.hold([.fn, .leftControl])],
        pasteLast: [.combo(keyCode: 9, modifiers: [.control, .command])],
        polish: [.combo(keyCode: 35, modifiers: [.control, .command])]
    )

    public func triggers(for action: ShortcutAction) -> [ShortcutTrigger] {
        switch action {
        case .pushToTalk: return pushToTalk
        case .handsFree: return handsFree
        case .command: return command
        case .pasteLast: return pasteLast
        case .polish: return polish
        }
    }
    public mutating func set(_ triggers: [ShortcutTrigger], for action: ShortcutAction) {
        switch action {
        case .pushToTalk: pushToTalk = triggers
        case .handsFree: handsFree = triggers
        case .command: command = triggers
        case .pasteLast: pasteLast = triggers
        case .polish: polish = triggers
        }
    }
}

public struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// A helyes írásmód (pl. „BusinessNative”).
    public var term: String
    /// Ahogy a felismerő tévesen írhatja (pl. „biznisz nétív”). Üres = csak kulcsszó.
    public var heardAs: [String]
    /// Automatikusan tanult bejegyzés (a beillesztés utáni kézi javításból).
    public var autoLearned: Bool
    public init(id: UUID = UUID(), term: String, heardAs: [String] = [], autoLearned: Bool = false) {
        self.id = id; self.term = term; self.heardAs = heardAs; self.autoLearned = autoLearned
    }
    enum CodingKeys: String, CodingKey { case id, term, heardAs, autoLearned }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        term = try c.decode(String.self, forKey: .term)
        heardAs = (try? c.decodeIfPresent([String].self, forKey: .heardAs)) ?? []
        autoLearned = (try? c.decodeIfPresent(Bool.self, forKey: .autoLearned)) ?? false
    }
}

public struct Snippet: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public init(id: UUID = UUID(), trigger: String, expansion: String) { self.id = id; self.trigger = trigger; self.expansion = expansion }
}

public struct PolishPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String
    public var builtIn: Bool
    public init(id: String = UUID().uuidString, name: String, prompt: String, builtIn: Bool = false) {
        self.id = id; self.name = name; self.prompt = prompt; self.builtIn = builtIn
    }

    public static let builtIns: [PolishPreset] = [
        PolishPreset(id: "clean", name: "Tisztázás", prompt: "Javítsd a nyelvtant, a helyesírást és az írásjeleket, simítsd a fogalmazást, de a jelentést, a hangnemet és a nyelvet tartsd meg.", builtIn: true),
        PolishPreset(id: "concise", name: "Tömörítés", prompt: "Fogalmazd meg rövidebben és lényegretörőbben, minden fontos információ maradjon meg.", builtIn: true),
        PolishPreset(id: "formal", name: "Hivatalos", prompt: "Írd át udvarias, professzionális, üzleti hangnemre.", builtIn: true),
        PolishPreset(id: "friendly", name: "Barátságos", prompt: "Írd át barátságos, közvetlen, de igényes hangnemre.", builtIn: true),
        PolishPreset(id: "bullets", name: "Pontokba szedés", prompt: "Szedd tömör, áttekinthető felsorolásba (gondolatjeles pontok).", builtIn: true),
        PolishPreset(id: "to-en", name: "Angolra fordítás", prompt: "Fordítsd természetes, igényes angolra.", builtIn: true),
        PolishPreset(id: "to-hu", name: "Magyarra fordítás", prompt: "Fordítsd természetes, igényes magyarra.", builtIn: true),
    ]
}

public enum HistoryKind: String, Codable, Sendable { case dictation, command, polish }

/// Egy előzmény-sor állapota. A régi history.json sorai `success`ként olvasódnak.
public enum HistoryStatus: String, Codable, Sendable, Equatable {
    case success, failed, interrupted, empty, pasteFailed

    public var label: String {
        switch self {
        case .success: return "Kész"
        case .failed: return "Sikertelen"
        case .interrupted: return "Megszakadt"
        case .empty: return "Üres"
        case .pasteFailed: return "Nincs beillesztve"
        }
    }

    /// A beszédtempóba csak az a diktálás számít, amiből szöveg lett.
    public var countsTowardPace: Bool { self == .success || self == .pasteFailed }

    /// Ezekhez érdemes a helyi hangot megőrizni, amíg a megőrzési idő engedi.
    public var storesAudio: Bool {
        switch self {
        case .failed, .interrupted, .empty: return true
        case .success, .pasteFailed: return false
        }
    }
}

public struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var rawText: String
    public var appName: String
    public var bundleID: String
    public var durationSeconds: Double
    public var kind: HistoryKind
    public var status: HistoryStatus
    /// Rövid, felhasználónak szóló ok. Soha nem nyers HTTP-törzs és nem kulcs.
    public var failureReason: String?
    /// Csak a fájlnév (`UUID.wav`) az adatmappa recordings könyvtárában. Nem abszolút útvonal.
    public var audioFile: String?

    public init(id: UUID = UUID(), date: Date = Date(), text: String, rawText: String, appName: String, bundleID: String, durationSeconds: Double, kind: HistoryKind, status: HistoryStatus = .success, failureReason: String? = nil, audioFile: String? = nil) {
        self.id = id; self.date = date; self.text = text; self.rawText = rawText; self.appName = appName
        self.bundleID = bundleID; self.durationSeconds = durationSeconds; self.kind = kind
        self.status = status
        self.failureReason = HistoryPrivacy.sanitize(failureReason)
        self.audioFile = audioFile.flatMap { RecordingArchive.isSafeName($0) ? $0 : nil }
    }

    public var wordCount: Int { TextStats.wordCount(text) }
    public var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var canCopy: Bool { hasText }
    /// Újra csak akkor, ha a hang megvan, és az átírás nem készült el (hiba, megszakadás vagy üres eredmény).
    public var canRetry: Bool {
        guard let audioFile, RecordingArchive.isSafeName(audioFile) else { return false }
        switch status {
        case .failed, .interrupted, .empty: return true
        case .success, .pasteFailed: return false
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, date, text, rawText, appName, bundleID, durationSeconds, kind, status, failureReason, audioFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Hiányzó vagy idegen mező nem dobja el a régi history.json-t.
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        rawText = (try? c.decode(String.self, forKey: .rawText)) ?? ""
        appName = (try? c.decode(String.self, forKey: .appName)) ?? ""
        bundleID = (try? c.decode(String.self, forKey: .bundleID)) ?? ""
        durationSeconds = (try? c.decode(Double.self, forKey: .durationSeconds)) ?? 0
        kind = (try? c.decode(HistoryKind.self, forKey: .kind)) ?? .dictation
        status = (try? c.decode(HistoryStatus.self, forKey: .status)) ?? .success
        failureReason = HistoryPrivacy.sanitize(try? c.decode(String.self, forKey: .failureReason))
        let audio = try? c.decode(String.self, forKey: .audioFile)
        audioFile = audio.flatMap { RecordingArchive.isSafeName($0) ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(text, forKey: .text)
        try c.encode(rawText, forKey: .rawText)
        try c.encode(appName, forKey: .appName)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(kind, forKey: .kind)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(failureReason, forKey: .failureReason)
        try c.encodeIfPresent(audioFile, forKey: .audioFile)
    }
}

public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case forever, days30, days7, never
    public var label: String {
        switch self { case .forever: return "Mindig"; case .days30: return "30 nap"; case .days7: return "7 nap"; case .never: return "Ne mentsen" }
    }
    public var maxAge: TimeInterval? {
        switch self { case .forever: return nil; case .days30: return 30 * 86400; case .days7: return 7 * 86400; case .never: return 0 }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var language: DictationLanguage = .auto
    public var shortcuts: ShortcutSettings = .default
    public var styles: [AppCategory: StyleTone] = [.personal: .casual, .work: .casual, .email: .formal, .other: .formal]
    public var dictionary: [DictionaryEntry] = [DictionaryEntry(term: "Business Native"), DictionaryEntry(term: "businessnative.hu")]
    public var snippets: [Snippet] = []
    public var customPolish: [PolishPreset] = []
    public var defaultPolishID: String = "clean"
    public var smartFormatting: Bool = true
    public var removeFillers: Bool = true
    public var voiceCommands: Bool = true
    public var muteMedia: Bool = true
    /// Hangjelzések – alapból kikapcsolva (0.3.1-től csendes alapértelmezés).
    public var sounds: Bool = false
    /// Hangjelzések hangereje 0…1 (alapból nagyon halk).
    public var soundVolume: Double = 0.15
    /// Beállítás-séma verziója; 2 alatt a hangjelzés egyszeri kikapcsolása (migráció 0.3.1).
    public var settingsVersion: Int = AppSettings.currentVersion
    public var hideBarWhenIdle: Bool = false
    public var launchAtLogin: Bool = false
    public var microphoneUID: String? = nil
    public var retention: HistoryRetention = .forever
    public var transcriptionModel: String = "gpt-transcribe"
    public var fallbackTranscriptionModel: String = "gpt-4o-transcribe"
    public var chatModel: String = "gpt-5.6-luna"
    public var fallbackChatModel: String = "gpt-4.1-mini"
    /// Saját kulcsos szolgáltatók (0.4.0): az átírás és a szövegtisztítás külön választható.
    public var transcriptionProvider: AIProvider = .openai
    public var cleanupProvider: AIProvider = .openai
    public var geminiTranscriptionModel: String = "gemini-3.5-flash-lite"
    public var geminiChatModel: String = "gemini-3.5-flash-lite"
    public var anthropicChatModel: String = "claude-haiku-5-5"
    public var onboardingDone: Bool = false
    /// A kurzor körüli szöveg és az ablakcím felhasználása (csak memóriában; jelszómezőben soha).
    public var contextAwareness: Bool = true
    /// Szótár automatikus bővítése, ha a beillesztett szövegben egy szót kézzel kijavítasz.
    public var autoLearnDictionary: Bool = true
    /// Ennyi másodperc után a helyi formázás megy ki, ha a nyelvi modell nem válaszol.
    public var llmTimeoutSeconds: Double = 8
    /// Fizetős előretöltés a beszédszünet alatt. Alapból KI: a folytatás vagy a megszakítás a már elküldött kérést akkor is felszámoltathatja.
    public var paidPrefetch: Bool = false
    /// Meeting-jegyzetelő (0.5.0): alapból KI; csak a Beállításokban kapcsolható be.
    public var meetingsEnabled: Bool = false
    public var meetingBotName: String = "Business Flow jegyzetelő"
    /// Kihagyott alkalmak (MeetingEvent.id).
    public var skippedMeetings: [String] = []

    public static let currentVersion = 2

    public init() {}

    public var allPolishPresets: [PolishPreset] { PolishPreset.builtIns + customPolish }
    public var defaultPolish: PolishPreset { allPolishPresets.first { $0.id == defaultPolishID } ?? PolishPreset.builtIns[0] }
    public func tone(for category: AppCategory) -> StyleTone { styles[category] ?? .formal }

    // Tolerant decoding: new fields fall back to defaults when the stored JSON is older.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? cur }
        language = d(.language, language); shortcuts = d(.shortcuts, shortcuts); styles = d(.styles, styles)
        dictionary = d(.dictionary, dictionary); snippets = d(.snippets, snippets); customPolish = d(.customPolish, customPolish)
        defaultPolishID = d(.defaultPolishID, defaultPolishID); smartFormatting = d(.smartFormatting, smartFormatting)
        removeFillers = d(.removeFillers, removeFillers); voiceCommands = d(.voiceCommands, voiceCommands)
        muteMedia = d(.muteMedia, muteMedia); sounds = d(.sounds, sounds); hideBarWhenIdle = d(.hideBarWhenIdle, hideBarWhenIdle)
        launchAtLogin = d(.launchAtLogin, launchAtLogin); microphoneUID = d(.microphoneUID, microphoneUID)
        retention = d(.retention, retention); transcriptionModel = d(.transcriptionModel, transcriptionModel)
        fallbackTranscriptionModel = d(.fallbackTranscriptionModel, fallbackTranscriptionModel)
        chatModel = d(.chatModel, chatModel); fallbackChatModel = d(.fallbackChatModel, fallbackChatModel)
        transcriptionProvider = d(.transcriptionProvider, transcriptionProvider); cleanupProvider = d(.cleanupProvider, cleanupProvider)
        geminiTranscriptionModel = d(.geminiTranscriptionModel, geminiTranscriptionModel); geminiChatModel = d(.geminiChatModel, geminiChatModel)
        anthropicChatModel = d(.anthropicChatModel, anthropicChatModel)
        onboardingDone = d(.onboardingDone, onboardingDone)
        contextAwareness = d(.contextAwareness, contextAwareness); autoLearnDictionary = d(.autoLearnDictionary, autoLearnDictionary)
        llmTimeoutSeconds = d(.llmTimeoutSeconds, llmTimeoutSeconds)
        paidPrefetch = d(.paidPrefetch, paidPrefetch)
        meetingsEnabled = d(.meetingsEnabled, meetingsEnabled); meetingBotName = d(.meetingBotName, meetingBotName)
        skippedMeetings = d(.skippedMeetings, skippedMeetings)
        soundVolume = min(1, max(0, d(.soundVolume, soundVolume)))
        let stored = d(.settingsVersion, 1)
        if stored < 2 { sounds = false; soundVolume = 0.15 } // 0.3.1: régi telepítések csendesre állnak
        settingsVersion = AppSettings.currentVersion
    }
}
