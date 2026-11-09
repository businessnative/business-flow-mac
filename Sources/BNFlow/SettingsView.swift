import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import BNFlowCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, languages, microphone, shortcuts, meetings, permissions, apiKey, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "Általános"
        case .languages: return "Nyelvek"
        case .microphone: return "Mikrofon"
        case .shortcuts: return "Billentyűk"
        case .meetings: return "Meetingek"
        case .permissions: return "Engedélyek"
        case .apiKey: return "API-kulcs"
        case .advanced: return "Haladó"
        }
    }
    var icon: String {
        switch self {
        case .general: return "settings"
        case .languages: return "languages"
        case .microphone: return "mic"
        case .shortcuts: return "keyboard"
        case .meetings: return "book-open"
        case .permissions: return "shield-check"
        case .apiKey: return "key-round"
        case .advanced: return "folder-open"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Beállítások")
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { t in
                    Button { withAnimation(BN.colorEase) { model.settingsTab = t } } label: {
                        HStack(spacing: 6) { LucideIcon(t.icon, size: 14, color: model.settingsTab == t ? BN.light : BN.textMedium); Text(t.title).lineLimit(1).fixedSize() }
                    }
                    .buttonStyle(TabStyle(selected: model.settingsTab == t))
                    .accessibilityLabel(t.title)
                }
            }
            .onAppear { if !model.hasAPIKey && model.settingsTab == .general { model.settingsTab = .apiKey } }
            Group {
                switch model.settingsTab {
                case .general: GeneralSettings(model: model)
                case .languages: LanguageSettings(model: model)
                case .microphone: MicrophoneSettings(model: model)
                case .shortcuts: ShortcutSettingsView(model: model)
                case .meetings: MeetingSettings(model: model, svc: MeetingService.shared)
                case .permissions: PermissionsView(model: model)
                case .apiKey: APIKeyView(model: model)
                case .advanced: AdvancedSettings(model: model)
                }
            }
            .id(model.settingsTab)
            .modifier(BNRise(index: 1))
        }
    }
}

/// Másodlagos navigáció (lapfülek): inaktív light-64 szöveg, hover light-8, aktív light-16 háttér #f6f3ec szöveggel, radius 8.
struct TabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, selected: selected) }
    struct Inner: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(BN.button2)
                .foregroundColor(selected ? BN.light : BN.textMedium)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: BN.radius).fill(selected ? BN.light(0.16) : (hover ? BN.light(0.08) : .clear)))
                .overlay(RoundedRectangle(cornerRadius: BN.radius).strokeBorder(selected ? BN.light(0.16) : .clear, lineWidth: 1))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(BN.colorEase) { hover = h } }
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @State private var loginError: String?
    var body: some View {
        BNCard {
            VStack(alignment: .leading, spacing: 0) {
                BNToggle(title: "Okos formázás", detail: "Az átiratot egy gyors nyelvi modell tisztázza (önjavítás, listák, bekezdések). Ha lassú vagy elrontaná, a helyi formázás megy ki.", isOn: model.binding(\.smartFormatting))
                BNDivider()
                BNToggle(title: "Környezetfigyelés", detail: "A kurzor körüli szöveg és az ablakcím alapján igazítja a kis/nagybetűt, a neveket és a stílust (pl. Gmail a böngészőben). Csak memóriában, jelszómezőben soha.", isOn: model.binding(\.contextAwareness))
                BNDivider()
                BNToggle(title: "Szótár automatikus tanulása", detail: "Ha beillesztés után kézzel kijavítasz egy szót (pl. egy nevet), felveszi a szótárba.", isOn: model.binding(\.autoLearnDictionary))
                BNDivider()
                BNToggle(title: "Töltelékszavak eltávolítása", detail: "ö, öhm, hmm, izé, um, uh — helyben, modell nélkül is.", isOn: model.binding(\.removeFillers))
                BNDivider()
                BNToggle(title: "Hangparancsok", detail: "„új sor”, „új bekezdés”, valamint kimondott írásjelek: „vessző”, „kérdőjel”, „felkiáltójel”, „kettőspont”, „pontosvessző” (angolul is).", isOn: model.binding(\.voiceCommands))
                BNDivider()
                BNToggle(title: "Zene és média némítása diktálás közben", isOn: model.binding(\.muteMedia))
                BNDivider()
                BNToggle(title: "Hangok", detail: "Halk jelzés a felvétel indításakor és leállításakor. Alapból kikapcsolva.", isOn: model.binding(\.sounds))
                if model.settings.sounds {
                    HStack(spacing: 10) {
                        Text("Hangerő").font(BN.sans(13)).foregroundColor(BN.textMedium)
                        Slider(value: model.binding(\.soundVolume), in: 0...1, onEditingChanged: { editing in
                            if !editing { SoundPlayer.preview(volume: model.settings.soundVolume) }
                        })
                        .tint(BN.accent)
                        Text("\(Int((model.settings.soundVolume * 100).rounded())) %").font(BN.mono(12)).foregroundColor(BN.textMedium).frame(width: 44, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                }
                BNDivider()
                BNToggle(title: "Sáv elrejtése, ha nem diktálsz", detail: "A Flow-sáv csak felvétel és feldolgozás közben látszik.", isOn: model.binding(\.hideBarWhenIdle))
                BNDivider()
                BNToggle(title: "Indítás bejelentkezéskor", isOn: Binding(get: { model.settings.launchAtLogin }, set: { v in
                    loginError = LoginItem.set(v)
                    model.settings.launchAtLogin = loginError == nil ? v : LoginItem.enabled
                }))
                if let loginError { Text(loginError).font(BN.sans(12)).foregroundColor(BN.error) }
            }
        }
    }
}

struct LanguageSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        BNCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Diktálás nyelve").font(BN.sans(16, .medium)).foregroundColor(BN.light)
                Text("Automatikus módban a magyar és az angol is felismerhető, akár egy mondaton belül is (a modell mindkét nyelvet megkapja).").font(BN.sans(12)).foregroundColor(BN.textMedium)
                HStack(spacing: 8) {
                    ForEach(DictationLanguage.allCases, id: \.self) { l in
                        Button(l.label) { model.settings.language = l }.buttonStyle(TabStyle(selected: model.settings.language == l))
                            .accessibilityLabel("Nyelv: \(l.label)").accessibilityValue(model.settings.language == l ? "kiválasztva" : "")
                    }
                }
            }
        }
    }
}

struct MicrophoneSettings: View {
    @ObservedObject var model: AppModel
    @State private var devices: [AudioInputDevice] = []
    var body: some View {
        BNCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mikrofon").font(BN.sans(16, .medium)).foregroundColor(BN.light)
                row(name: "Rendszer alapértelmezett", selected: model.settings.microphoneUID == nil) { model.settings.microphoneUID = nil }
                ForEach(devices) { d in
                    row(name: d.name, selected: model.settings.microphoneUID == d.uid) { model.settings.microphoneUID = d.uid }
                }
                Button("Lista frissítése") { devices = AudioDevices.inputs() }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true)).accessibilityLabel("Mikrofonlista frissítése")
            }
        }
        .onAppear { devices = AudioDevices.inputs() }
    }
    func row(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                LucideIcon(selected ? "circle-dot" : "circle", size: 16, color: selected ? BN.accent : BN.textMedium)
                Text(name).font(BN.body3).foregroundColor(BN.light)
                Spacer()
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel("Mikrofon: \(name)")
        .accessibilityValue(selected ? "kiválasztva" : "")
    }
}

// MARK: Billentyűparancsok

@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published var recording: ShortcutAction?
    @Published var preview = ""
    private var maxMods: Set<ModifierKey> = []
    var onDone: ((ShortcutAction, ShortcutTrigger) -> Void)?

    func begin(_ a: ShortcutAction) {
        guard let m = Services.shared.monitor else { return }
        recording = a; preview = "Nyomd meg…"; maxMods = []
        m.recorder = { [weak self] input in MainActor.assumeIsolated { self?.handle(input) } }
    }
    func end() {
        Services.shared.monitor?.recorder = nil
        recording = nil; preview = ""; maxMods = []
    }
    private func handle(_ input: HotkeyMonitor.RecordedInput) {
        guard let a = recording else { return }
        switch input {
        case .modifiers(let set):
            if set.count >= maxMods.count && !set.isEmpty { maxMods = set }
            preview = maxMods.sorted { $0.keyCode < $1.keyCode }.map(\.symbol).joined(separator: " + ")
            if set.isEmpty, !maxMods.isEmpty {
                // Csak módosítók: nyomva tartós parancs (diktálás / parancs módhoz).
                let order = ModifierKey.allCases
                finish(a, .hold(maxMods.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }))
            }
        case .key(let code, let classes):
            if code == 53 && classes.isEmpty { end(); return }
            finish(a, .combo(keyCode: code, modifiers: classes.sorted()))
        case .mouse(let b):
            finish(a, .mouse(button: b))
        }
    }
    private func finish(_ a: ShortcutAction, _ t: ShortcutTrigger) {
        onDone?(a, t)
        end()
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var rec = ShortcutRecorderModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BNCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ShortcutAction.allCases, id: \.self) { a in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.label).font(BN.body3).foregroundColor(BN.light)
                                Text(hint(a)).font(BN.sans(11)).foregroundColor(BN.textWeak)
                            }
                            Spacer()
                            ForEach(model.settings.shortcuts.triggers(for: a), id: \.self) { t in
                                HStack(spacing: 4) {
                                    Tooltip.Key(t.label)
                                    Button { remove(t, from: a) } label: { LucideIcon("x", size: 12, color: BN.textWeak) }.buttonStyle(.plain)
                                        .accessibilityLabel("Parancs törlése: \(a.label) \(t.label)")
                                }
                            }
                            if rec.recording == a {
                                Text(rec.preview).font(BN.label1).foregroundColor(BN.accent)
                                Button("Mégse") { rec.end() }.buttonStyle(BNButtonStyle(kind: .tertiary, compact: true))
                                    .accessibilityLabel("Rögzítés megszakítása")
                            } else {
                                Button("+ Hozzáadás") { rec.begin(a) }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true))
                                    .disabled(Services.shared.monitor?.isRunning != true && !TestMode.isOn)
                                    .accessibilityLabel("Parancs hozzáadása: \(a.label)")
                            }
                        }
                        .padding(.vertical, 10)
                        BNDivider()
                    }
                    HStack {
                        Spacer()
                        Button("Alapértelmezések visszaállítása") { model.settings.shortcuts = .default }.accessibilityLabel("Parancsok alapértelmezése").buttonStyle(BNButtonStyle(kind: .tertiary, compact: true))
                    }.padding(.top, 8)
                }
            }
            BNCard {
                VStack(alignment: .leading, spacing: 6) {
                    BNLabel("Tipp", size: 10)
                    Text("Az fn (🌐) billentyűhöz állítsd be: Rendszerbeállítások → Billentyűzet → „A 🌐 billentyű megnyomásakor: Ne csináljon semmit”, különben az emoji-választó is megnyílhat.")
                        .font(BN.sans(12)).foregroundColor(BN.textMedium).fixedSize(horizontal: false, vertical: true)
                    Text("Egérgomb: a + Hozzáadás után nyomd meg az egér oldalsó (4./5.) gombját.").font(BN.sans(12)).foregroundColor(BN.textMedium)
                    Button("Billentyűzet-beállítások megnyitása") { Permissions.openKeyboardSettings() }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true))
                }
            }
        }
        .onAppear {
            rec.onDone = { a, t in
                var s = model.settings.shortcuts
                var list = s.triggers(for: a)
                if !list.contains(t) { list.append(t) }
                s.set(list, for: a)
                model.settings.shortcuts = s
            }
        }
        .onDisappear { rec.end() }
    }
    func remove(_ t: ShortcutTrigger, from a: ShortcutAction) {
        var s = model.settings.shortcuts
        s.set(s.triggers(for: a).filter { $0 != t }, for: a)
        model.settings.shortcuts = s
    }
    func hint(_ a: ShortcutAction) -> String {
        switch a {
        case .pushToTalk: return "Tartsd lenyomva, beszélj, engedd el — beilleszti."
        case .handsFree: return "Egyszer nyomd meg a kezdéshez, újra a befejezéshez."
        case .command: return "Kijelöléssel: átírja (pl. „fordítsd angolra”). Kijelölés nélkül: megírja, amit kérsz."
        case .pasteLast: return "Az utolsó átiratot újra beilleszti."
        case .polish: return "A kijelölt szöveget az alapértelmezett utasítással átírja."
        }
    }
}

// MARK: Engedélyek

struct PermissionsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let _ = model.permissionTick
        VStack(alignment: .leading, spacing: 12) {
            PermissionRow(title: "Mikrofon", detail: "A hangod felvételéhez.", ok: Permissions.microphone == .authorized,
                          action: {
                              if Permissions.microphone == .notDetermined { Permissions.requestMicrophone { _ in model.permissionTick += 1 } }
                              else { Permissions.open(.microphone) }
                          })
            PermissionRow(title: "Kisegítő hozzáférés", detail: "A szöveg beillesztéséhez és a kijelölés olvasásához.", ok: Permissions.accessibility,
                          action: { Permissions.promptAccessibility(); Permissions.open(.accessibility) })
            PermissionRow(title: "Bemenetfigyelés", detail: "A globális billentyűparancsokhoz (fn, egérgombok).", ok: Permissions.inputMonitoring,
                          action: { Permissions.requestInputMonitoring(); Permissions.open(.input) })
            HStack {
                Button("Állapot frissítése") { model.permissionTick += 1; Services.shared.restartMonitor?() }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true)).accessibilityLabel("Engedélyek frissítése")
                Text("A Bemenetfigyelés megadása után az appot újra kell indítani.").font(BN.sans(12)).foregroundColor(BN.textWeak)
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let action: () -> Void
    var body: some View {
        BNCard {
            HStack {
                Circle().fill(ok ? BN.success : BN.warning).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(BN.sans(14, .medium)).foregroundColor(BN.light)
                    Text(detail).font(BN.sans(12)).foregroundColor(BN.textMedium)
                }
                Spacer()
                if ok { BNLabel("Engedélyezve", size: 10, color: BN.success) }
                else { Button("Engedélyezés", action: action).buttonStyle(BNButtonStyle(kind: .primary, compact: true)).accessibilityLabel("Engedélyezés: \(title)") }
            }
        }
    }
}

// MARK: API-kulcs

struct APIKeyView: View {
    @ObservedObject var model: AppModel
    @State private var pasted: [AIProvider: String] = [:]
    @State private var keyName = "OPENAI_API_KEY"
    @State private var message: String?
    @State private var foundKeys: [String] = []
    @State private var envURL: URL?
    @State private var testing: AIProvider?
    @State private var testResult: [AIProvider: String] = [:]
    private let router = AIRouter(http: OpenAIClient(session: TestMode.isOn ? TestMode.session : nil))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BNCard {
                VStack(alignment: .leading, spacing: 10) {
                    BNLabel("Szolgáltatók és modellek", size: 10)
                    providerRow("Átírás (beszéd → szöveg)", selection: model.binding(\.transcriptionProvider), options: AIProvider.transcribers, models: transcriptionModelBinding)
                    providerRow("Szövegtisztítás / parancs / polírozás", selection: model.binding(\.cleanupProvider), options: AIProvider.allCases, models: chatModelBinding)
                    Text("A Claude-nak (Anthropic) nincs beszédfelismerő API-ja, ezért átírásra az OpenAI vagy a Gemini választható; a Claude a szöveg tisztítására használható. Ha a választott szolgáltató hibázik, a Business Flow automatikusan a következőre vált, amihez van kulcs. Az első modell mindig a legtakarékosabb.")
                        .font(BN.sans(12)).foregroundColor(BN.textWeak).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(AIProvider.allCases, id: \.self) { p in keyCard(p) }
            BNCard {
                VStack(alignment: .leading, spacing: 8) {
                    BNLabel("Importálás .env fájlból", size: 10)
                    HStack {
                        Button("Fájl kiválasztása…", action: pickEnv).buttonStyle(BNButtonStyle(kind: .secondary, compact: true)).accessibilityLabel(".env fájl kiválasztása")
                        if let envURL { Text(envURL.path).font(BN.mono(11, .light)).foregroundColor(BN.textWeak).lineLimit(1).truncationMode(.middle) }
                    }
                    if !foundKeys.isEmpty {
                        Picker("Kulcs neve", selection: $keyName) { ForEach(foundKeys, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 360)
                        Button("Importálás", action: importEnv).buttonStyle(BNButtonStyle(kind: .primary, compact: true)).accessibilityLabel("Kulcs importálása")
                    }
                }
            }
            Text("A kulcsokat a Business Flow a saját, titkosított fájljában tárolja (Application Support/Business Flow/keys.enc, csak a te felhasználód olvashatja). Nem használja a Kulcskarikát, így nem kér rendszer-jóváhagyást. Kulcs soha nem kerül naplóba vagy a repóba; a kérések közvetlenül a választott szolgáltatóhoz mennek.")
                .font(BN.sans(12)).foregroundColor(BN.textWeak).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(BN.sans(12)).foregroundColor(BN.textMedium).accessibilityLabel("Üzenet: \(message)") }
        }
    }

    private var transcriptionModelBinding: Binding<String> {
        Binding(get: { model.settings.transcriptionProvider == .gemini ? model.settings.geminiTranscriptionModel : model.settings.transcriptionModel },
                set: { v in if model.settings.transcriptionProvider == .gemini { model.settings.geminiTranscriptionModel = v } else { model.settings.transcriptionModel = v } })
    }
    private var chatModelBinding: Binding<String> {
        Binding(get: {
            switch model.settings.cleanupProvider { case .openai: return model.settings.chatModel; case .anthropic: return model.settings.anthropicChatModel; case .gemini: return model.settings.geminiChatModel }
        }, set: { v in
            switch model.settings.cleanupProvider { case .openai: model.settings.chatModel = v; case .anthropic: model.settings.anthropicChatModel = v; case .gemini: model.settings.geminiChatModel = v }
        })
    }

    func providerRow(_ title: String, selection: Binding<AIProvider>, options: [AIProvider], models: Binding<String>) -> some View {
        let isTr = options.count < AIProvider.allCases.count
        let list = isTr ? selection.wrappedValue.transcriptionModels : selection.wrappedValue.chatModels
        return HStack(spacing: 10) {
            Text(title).font(BN.body3).foregroundColor(BN.textStrong).frame(width: 230, alignment: .leading)
            Picker("", selection: selection) { ForEach(options, id: \.self) { Text($0.label).tag($0) } }
                .labelsHidden().frame(width: 170).accessibilityLabel("Szolgáltató: \(title)")
            Picker("", selection: models) {
                ForEach(list.contains(models.wrappedValue) ? list : list + [models.wrappedValue], id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 220).accessibilityLabel("Modell: \(title)")
            if model.keyStatus[selection.wrappedValue] != true { BNLabel("nincs kulcs", size: 10, color: BN.warning) }
        }
    }

    /// Az OpenAI kártya akadálymentes címkéi változatlanok (önteszt-kompatibilitás).
    private func ax(_ p: AIProvider, _ what: String) -> String { p == .openai ? "API-kulcs \(what)" : "\(p.short) kulcs \(what)" }

    func keyCard(_ p: AIProvider) -> some View {
        let has = model.keyStatus[p] == true
        return BNCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(has ? BN.success : BN.textWeak).frame(width: 8, height: 8)
                    Text(p.label + (has ? " — kulcs mentve" : " — nincs kulcs")).font(BN.sans(14, .medium)).foregroundColor(BN.light)
                    Spacer()
                    Link("Kulcs létrehozása ↗", destination: p.keyPage).font(BN.sans(12)).accessibilityLabel("\(p.label) kulcsoldal megnyitása")
                    if has {
                        Button(testing == p ? "Tesztelés…" : "Kulcs tesztelése") { test(p) }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true)).disabled(testing != nil).accessibilityLabel(ax(p, "tesztelése"))
                        Button("Törlés") { Keychain.delete(p); model.refreshKey(); testResult[p] = nil; message = "\(p.label) kulcs törölve." }
                            .buttonStyle(BNButtonStyle(kind: .danger, compact: true)).accessibilityLabel(ax(p, "törlése"))
                    }
                }
                if let r = testResult[p] { Text(r).font(BN.sans(12)).foregroundColor(BN.textMedium) }
                HStack {
                    SecureField(p.placeholder, text: Binding(get: { pasted[p] ?? "" }, set: { pasted[p] = $0 })).textFieldStyle(BNTextFieldStyle()).accessibilityLabel(ax(p, "beillesztése"))
                    Button("Mentés") {
                        let v = (pasted[p] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        message = Keychain.save(v, for: p) ? "\(p.label) kulcs mentve." : "Nem sikerült menteni."
                        pasted[p] = ""; testResult[p] = nil; model.refreshKey()
                    }.buttonStyle(BNButtonStyle(kind: .primary, compact: true)).disabled((pasted[p] ?? "").count < 20).accessibilityLabel(ax(p, "mentése"))
                }
            }
        }
    }

    func test(_ p: AIProvider) {
        guard let key = Keychain.read(p) else { return }
        testing = p
        Task {
            let r = await router.testKey(p, key: key)
            testing = nil
            switch r {
            case .success: testResult[p] = "✓ A kulcs működik."
            case .failure(let e): testResult[p] = "✗ \(e.message)"
            }
        }
    }

    func pickEnv() {
        if TestMode.isOn {
            guard let u = TestMode.envFile, let s = try? String(contentsOf: u, encoding: .utf8) else { return }
            loadEnv(u, s); return
        }
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.showsHiddenFiles = true
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.message = "Válaszd ki a .env fájlt"
        guard p.runModal() == .OK, let u = p.url, let s = try? String(contentsOf: u, encoding: .utf8) else { return }
        loadEnv(u, s)
    }

    func loadEnv(_ u: URL, _ s: String) {
        envURL = u
        foundKeys = EnvFile.keys(in: s).filter { AIProvider.forEnvName($0) != nil && $0.uppercased().contains("KEY") }
        if foundKeys.isEmpty { message = "Nem találtam OpenAI / Anthropic / Gemini kulcsot ebben a fájlban." } else { keyName = foundKeys.contains("OPENAI_API_KEY") ? "OPENAI_API_KEY" : foundKeys[0]; message = nil }
    }

    func importEnv() {
        guard let u = envURL, let s = try? String(contentsOf: u, encoding: .utf8), let v = EnvFile.value(for: keyName, in: s),
              let p = AIProvider.forEnvName(keyName) else { message = "A kulcs üres vagy nem olvasható."; return }
        message = Keychain.save(v, for: p) ? "\(keyName) importálva (\(p.label))." : "Nem sikerült menteni."
        model.refreshKey()
    }
}

// MARK: Haladó

struct AdvancedSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BNCard {
                VStack(alignment: .leading, spacing: 10) {
                    BNLabel("Modellek (OpenAI)", size: 10)
                    field("Átírás", model.binding(\.transcriptionModel))
                    field("Átírás — tartalék", model.binding(\.fallbackTranscriptionModel))
                    field("Formázás / parancs / polírozás", model.binding(\.chatModel))
                    field("Szövegmodell — tartalék", model.binding(\.fallbackChatModel))
                    Text("Ha az elsődleges modell nem elérhető (400/404), automatikusan a tartalékot használja.").font(BN.sans(12)).foregroundColor(BN.textWeak)
                    BNToggle(title: "Előretöltés szünet alatt", detail: "Kísérleti. A csend alatt elindítja az átírást. Ha újra beszélsz vagy megszakítod, a szolgáltató a már átvett kérést akkor is felszámolhatja. Alapból ki.", isOn: model.binding(\.paidPrefetch))
                }
            }
            BNCard {
                VStack(alignment: .leading, spacing: 10) {
                    BNLabel("Előzmények megőrzése", size: 10)
                    HStack(spacing: 8) {
                        ForEach(HistoryRetention.allCases, id: \.self) { r in
                            Button(r.label) { model.settings.retention = r; model.applyRetention() }.buttonStyle(TabStyle(selected: model.settings.retention == r))
                                .accessibilityLabel("Megőrzés: \(r.label)")
                        }
                    }
                    HStack {
                        Button("Adatmappa megnyitása") { Workspace.open(AppPaths.supportDirectory) }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true))
                        Button("Előzmények törlése") { model.clearHistory() }.buttonStyle(BNButtonStyle(kind: .danger, compact: true))
                    }
                }
            }
        }
    }
    func field(_ label: String, _ b: Binding<String>) -> some View {
        HStack {
            Text(label).font(BN.body3).foregroundColor(BN.textStrong).frame(width: 220, alignment: .leading)
            TextField("", text: b).textFieldStyle(BNTextFieldStyle()).font(BN.mono(12)).accessibilityLabel("Modell: \(label)")
        }
    }
}
