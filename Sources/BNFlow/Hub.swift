import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import BNFlowCore

/// Hivatkozások az AppKit-szolgáltatásokra a nézetekből.
@MainActor
final class Services {
    static let shared = Services()
    weak var monitor: HotkeyMonitor?
    weak var controller: DictationController?
    var restartMonitor: (() -> Void)?
}

@MainActor
final class HubWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model: AppModel
    init(model: AppModel) { self.model = model }

    var testWindow: NSWindow? { window }

    func show(_ section: HubSection? = nil) {
        if let section { model.hubSection = section }
        let isNew = window == nil
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Business Flow"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.backgroundColor = BN.ns(0x0a0a0b)
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 820, height: 560)
            w.contentView = NSHostingView(rootView: HubView(model: model))
            w.center()
            w.delegate = self
            if !TestMode.isOn { w.setFrameAutosaveName("BNFlowHub") }
            window = w
        }
        if TestMode.isOn {
            // Önteszt: a képernyőn kívül, aktiválás nélkül (nem veszi el a fókuszt és nem látszik).
            window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window?.orderBack(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Ablak megjelenése: fade 220 ms (tokens).
        if isNew && !BN.reduceMotion, let w = window {
            w.alphaValue = 0
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.22; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut); w.animator().alphaValue = 1 }
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Csak menüsor-app marad (nincs Dock-ikon), ha a Hub zárva.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct HubView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 220)
                .background(BN.lift)
            Rectangle().fill(BN.light(0.16)).frame(width: 1)
            ScrollView {
                Group {
                    switch model.hubSection {
                    case .home: HomeView(model: model)
                    case .dictionary: DictionaryView(model: model)
                    case .snippets: SnippetsView(model: model)
                    case .style: StyleView(model: model)
                    case .polish: PolishView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .id(model.hubSection)
                .modifier(BNRise())
                .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 32)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bnScroller()
            }
            .background(BN.base)
        }
        .background(BN.base)
        .preferredColorScheme(.dark)
        .environment(\.font, BN.body3)
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Wordmark().padding(.horizontal, 16).padding(.top, 44).padding(.bottom, 4)
            BNLabel("Business Flow", size: 10).padding(.horizontal, 16).padding(.bottom, 20)
            ForEach(HubSection.allCases) { s in
                SidebarItem(section: s, selected: model.hubSection == s) { model.hubSection = s }
            }
            Spacer()
            if !model.hasAPIKey {
                Button { model.openSettings(.apiKey) } label: {
                    HStack(spacing: 6) { LucideIcon("key-round", size: 14, color: BN.base); Text("API-kulcs beállítása") }
                }.buttonStyle(BNButtonStyle(kind: .primary, compact: true)).padding(16)
            }
            PermissionSummary(model: model).padding(.horizontal, 16).padding(.bottom, 16)
        }
    }
}

struct SidebarItem: View {
    let section: HubSection
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LucideIcon(section.icon, size: 16, color: selected ? BN.light : BN.textMedium).frame(width: 18)
                Text(section.title).font(BN.sans(14, selected ? .medium : .regular)).foregroundColor(selected || hover ? BN.light : BN.textMedium)
                Spacer()
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: BN.radius).fill(selected ? BN.light(0.08) : (hover ? BN.light(0.04) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .padding(.horizontal, 8)
        .onHover { h in withAnimation(BN.colorEase) { hover = h } }
    }
}

struct PermissionSummary: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let _ = model.permissionTick
        let ok = Permissions.microphone == .authorized && Permissions.accessibility && Permissions.inputMonitoring
        Button { model.openSettings(.permissions) } label: {
            HStack(spacing: 6) {
                Circle().fill(ok ? BN.success : BN.warning).frame(width: 6, height: 6)
                Text(ok ? "Minden engedély megvan" : "Engedélyek hiányoznak").font(BN.sans(12)).foregroundColor(BN.textMedium)
            }
        }.buttonStyle(.plain)
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BN.h5).tracking(-0.25).foregroundColor(BN.light)
            if let subtitle { Text(subtitle).font(BN.body3).foregroundColor(BN.textMedium) }
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Kezdőlap

struct HomeView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    var body: some View {
        let st = model.stats
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Üdv újra!", subtitle: "Tartsd lenyomva a(z) \(model.settings.shortcuts.pushToTalk.first?.label ?? "fn") billentyűt bármelyik szövegmezőben, és beszélj.")
            if !Onboarding.complete(model) { OnboardingChecklist(model: model).bnRise(0) }
            HStack(spacing: 12) {
                Stat(label: "Összes szó", value: "\(st.totalWords)")
                Stat(label: "Ezen a héten", value: "\(st.weekWords)")
                Stat(label: "Átlag szó/perc", value: st.averageWPM > 0 ? "\(st.averageWPM)" : "–")
                Stat(label: "Napi sorozat", value: "\(st.streakDays) nap")
            }
            HStack {
                BNLabel("Előzmények")
                Spacer()
                TextField("Keresés", text: $query).textFieldStyle(BNTextFieldStyle()).frame(width: 220).accessibilityLabel("Előzmények keresése")
            }
            let items = HistorySearch.filter(model.history, query: query)
            if items.isEmpty {
                BNCard { Text(model.history.isEmpty ? "Még nincs diktálás. Próbáld ki: tartsd lenyomva az fn-t, mondj egy mondatot, engedd el." : "Nincs találat.").foregroundColor(BN.textMedium) }
            } else {
                VStack(spacing: 0) {
                    ForEach(groups(items), id: \.0) { g in
                        BNLabel(g.0, size: 10).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 16)
                        ForEach(g.1) { HistoryRow(item: $0, model: model) }
                    }
                }
                .bnList()
            }
        }
    }

    func groups(_ items: [HistoryItem]) -> [(String, [HistoryItem])] {
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "hu_HU"); f.dateFormat = "yyyy. MMMM d., EEEE"
        var out: [(String, [HistoryItem])] = []
        for it in items.prefix(300) {
            let key = cal.isDateInToday(it.date) ? "Ma" : cal.isDateInYesterday(it.date) ? "Tegnap" : f.string(from: it.date)
            if out.last?.0 == key { out[out.count - 1].1.append(it) } else { out.append((key, [it])) }
        }
        return out
    }
}

struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        BNCard {
            VStack(alignment: .leading, spacing: 8) {
                BNLabel(label, size: 10)
                Text(value).font(BN.h6).foregroundColor(BN.light)
            }
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    @ObservedObject var model: AppModel
    @State private var hover = false
    @State private var showRaw = false
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(item.date, style: .time).font(BN.mono(12, .light)).foregroundColor(BN.textWeak).frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(bodyText).font(BN.body3).foregroundColor(hasTranscript ? BN.textStrong : BN.textMedium).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if hasTranscript, let reason = item.failureReason, item.status != .success {
                    Text(reason).font(BN.sans(12)).foregroundColor(BN.textMedium).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    BNLabel(kindLabel, size: 10, color: BN.textWeak)
                    if item.status != .success { BNBadge(item.status.label, color: item.status == .pasteFailed ? BN.warning : BN.error) }
                    Text("· \(item.appName)").font(BN.sans(11)).foregroundColor(BN.textWeak)
                }
            }
            Spacer()
            // A gombok mindig a nézetfában vannak (billentyűzet, VoiceOver, önteszt), csak hoverkor látszanak.
            HStack(spacing: 4) {
                if item.canCopy {
                    iconButton(copied ? "check" : "copy", "Másolás") {
                        Clipboard.copy(item.text)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                }
                if item.canRetry {
                    iconButton("refresh-cw", "Újra") { Services.shared.controller?.retryHistory(item.id) }
                }
                if hasTranscript, item.rawText != item.text, !item.rawText.isEmpty {
                    iconButton(showRaw ? "type" : "audio-lines", showRaw ? "Formázott" : "Nyers átirat") { showRaw.toggle() }
                }
                iconButton("trash-2", "Törlés") { model.deleteHistory(item.id) }
            }
            // 0 helyett 0,001: a teljesen átlátszó nézetet a SwiftUI kiveszi a kisegítő fából (VoiceOver nem érné el a gombokat).
            .opacity(hover || copied ? 1 : 0.001)
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
        .background(hover ? BN.light(0.04) : .clear)
        .onHover { h in withAnimation(BN.colorEase) { hover = h } }
    }
    var kindLabel: String {
        switch item.kind { case .dictation: return "Diktálás"; case .command: return "Parancs"; case .polish: return "Polírozás" }
    }
    var transcript: String { showRaw ? item.rawText : item.text }
    var hasTranscript: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var bodyText: String {
        if hasTranscript { return transcript }
        return item.failureReason ?? "Nem sikerült a diktálás."
    }
    func iconButton(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(name, size: 14, color: name == "check" ? BN.success : BN.textMedium).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: BN.radiusSmall).fill(BN.inputBg))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

// MARK: - Szótár

struct DictionaryView: View {
    @ObservedObject var model: AppModel
    @State private var term = ""
    @State private var heard = ""
    @State private var editing: UUID?
    @State private var editTerm = ""
    @State private var editHeard = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Szótár", subtitle: "Nevek, márkák, szakszavak pontos írásmódja. A felismerő kulcsszóként kapja meg, és a téves alakokat helyben javítjuk. Az automatikusan tanult szavakat jelöljük.")
            BNCard {
                HStack(spacing: 8) {
                    TextField("Helyes alak (pl. ClickUp)", text: $term).textFieldStyle(BNTextFieldStyle()).accessibilityLabel("Új szó helyes alakja")
                        .onSubmit(add)
                    TextField("Téves alakok (opcionális, vesszővel)", text: $heard).textFieldStyle(BNTextFieldStyle()).accessibilityLabel("Új szó téves alakjai")
                        .onSubmit(add)
                    Button(action: add) { HStack(spacing: 6) { LucideIcon("plus", size: 14, color: BN.base); Text("Hozzáadás") } }
                        .buttonStyle(BNButtonStyle(kind: .primary, compact: true)).disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Szó hozzáadása")
                }
            }
            if model.settings.dictionary.isEmpty {
                BNCard { Text("Még üres a szótár.").foregroundColor(BN.textMedium) }
            } else {
                VStack(spacing: 0) {
                    ForEach(model.settings.dictionary) { e in
                        if editing == e.id {
                            HStack(spacing: 8) {
                                TextField("Helyes alak", text: $editTerm).textFieldStyle(BNTextFieldStyle()).accessibilityLabel("Szerkesztett helyes alak").onSubmit(saveEdit)
                                TextField("Téves alakok", text: $editHeard).textFieldStyle(BNTextFieldStyle()).accessibilityLabel("Szerkesztett téves alakok").onSubmit(saveEdit)
                                Button("Mentés", action: saveEdit).buttonStyle(BNButtonStyle(kind: .primary, compact: true)).accessibilityLabel("Szó mentése")
                                    .disabled(editTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Mégse") { editing = nil }.buttonStyle(BNButtonStyle(kind: .tertiary, compact: true)).accessibilityLabel("Szerkesztés elvetése")
                            }
                            .padding(.vertical, 8).padding(.horizontal, 16)
                        } else {
                            HStack(spacing: 10) {
                                Text(e.term).font(BN.sans(14, .medium)).foregroundColor(BN.light)
                                if e.autoLearned { BNBadge("Automatikus") }
                                if !e.heardAs.isEmpty { Text("← " + e.heardAs.joined(separator: ", ")).font(BN.body3).foregroundColor(BN.textMedium).lineLimit(1) }
                                Spacer()
                                RowIconButton(icon: "settings", help: "Szerkesztés: \(e.term)") { startEdit(e) }
                                RowIconButton(icon: "trash-2", help: "Törlés: \(e.term)") { model.settings.dictionary.removeAll { $0.id == e.id } }
                            }
                            .padding(.vertical, 8).padding(.horizontal, 16)
                        }
                        if e.id != model.settings.dictionary.last?.id { BNDivider() }
                    }
                }
                .bnList()
            }
        }
    }
    func add() {
        guard let e = DictionaryEditing.make(term: term, heard: heard) else { return }
        model.settings.dictionary = DictionaryEditing.insert(e, into: model.settings.dictionary)
        term = ""; heard = ""
    }
    func startEdit(_ e: DictionaryEntry) { editing = e.id; editTerm = e.term; editHeard = e.heardAs.joined(separator: ", ") }
    func saveEdit() {
        guard let id = editing else { return }
        model.settings.dictionary = DictionaryEditing.update(id: id, term: editTerm, heard: editHeard, in: model.settings.dictionary)
        editing = nil
    }
}

/// Kis, nagybetűs mono jelvény (Label-2, light-8 háttér, radius 4).
struct BNBadge: View {
    let text: String
    var color: Color = BN.accent
    init(_ text: String, color: Color = BN.accent) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(BN.mono(10, .light)).tracking(0.75).foregroundColor(color)
            .accessibilityLabel(text)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: BN.radiusSmall).fill(BN.light(0.08)))
    }
}

/// Lista sorainak ikon-gombja (Lucide, 14 px, light-64, hoverkor light-8 háttér).
struct RowIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            LucideIcon(icon, size: 14, color: hover ? BN.light : BN.textMedium).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: BN.radiusSmall).fill(hover ? BN.light(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
        .onHover { h in withAnimation(BN.colorEase) { hover = h } }
    }
}

extension View {
    /// Listakonténer a kártya-tokenekkel (radius 16, #121212, light-16 keret, bevel).
    func bnList() -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: BN.radiusLarge))
            .background(RoundedRectangle(cornerRadius: BN.radiusLarge).fill(BN.lift))
            .overlay(RoundedRectangle(cornerRadius: BN.radiusLarge).strokeBorder(BN.border, lineWidth: 1))
            .bnBevel(radius: BN.radiusLarge)
    }
}

/// Többsoros szövegmező az input-tokenekkel (fókuszban light-16 háttér, light-48 keret).
struct BNTextArea: View {
    @Binding var text: String
    let placeholder: String
    var height: CGFloat = 80
    var axLabel: String
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text).font(BN.body3).foregroundColor(focused ? BN.light : BN.textStrong)
            .scrollContentBackground(.hidden).frame(height: height)
            .focused($focused)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: BN.radius).fill(focused ? BN.light(0.16) : BN.inputBg))
            .overlay(RoundedRectangle(cornerRadius: BN.radius).strokeBorder(focused ? BN.light(0.48) : BN.light(0.08), lineWidth: 1))
            .overlay(alignment: .topLeading) { if text.isEmpty { Text(placeholder).foregroundColor(BN.textWeak).padding(12).allowsHitTesting(false) } }
            .animation(BN.colorEase, value: focused)
            .accessibilityLabel(axLabel)
    }
}

// MARK: - Szövegrészletek

struct SnippetsView: View {
    @ObservedObject var model: AppModel
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var editing: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Szövegrészletek", subtitle: "Mondd ki a kulcsmondatot, és a teljes szöveg kerül a helyére (pl. „naptár link” → a foglalási linked).")
            BNCard {
                VStack(alignment: .leading, spacing: 8) {
                    BNLabel(editing == nil ? "Új szövegrészlet" : "Szövegrészlet szerkesztése", size: 10)
                    TextField("Kulcsmondat (amit kimondasz)", text: $trigger).textFieldStyle(BNTextFieldStyle()).accessibilityLabel("Kulcsmondat")
                    BNTextArea(text: $expansion, placeholder: "Kibontott szöveg", axLabel: "Kibontott szöveg")
                    HStack {
                        Spacer()
                        if editing != nil {
                            Button("Mégse") { editing = nil; trigger = ""; expansion = "" }.buttonStyle(BNButtonStyle(kind: .tertiary, compact: true)).accessibilityLabel("Szerkesztés elvetése")
                        }
                        Button("Mentés", action: save).buttonStyle(BNButtonStyle(kind: .primary, compact: true))
                            .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
                            .accessibilityLabel("Szövegrészlet mentése")
                    }
                }
            }
            ForEach(model.settings.snippets) { sn in
                BNCard {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("„\(sn.trigger)”").font(BN.sans(14, .medium)).foregroundColor(BN.light)
                            Text(sn.expansion).font(BN.body3).foregroundColor(BN.textMedium).lineLimit(4)
                        }
                        Spacer()
                        RowIconButton(icon: "settings", help: "Szerkesztés: \(sn.trigger)") { editing = sn.id; trigger = sn.trigger; expansion = sn.expansion }
                        RowIconButton(icon: "trash-2", help: "Törlés: \(sn.trigger)") {
                            model.settings.snippets.removeAll { $0.id == sn.id }
                            if editing == sn.id { editing = nil; trigger = ""; expansion = "" }
                        }
                    }
                }
            }
        }
    }
    func save() {
        model.settings.snippets = SnippetEditing.save(id: editing, trigger: trigger, expansion: expansion, in: model.settings.snippets)
        editing = nil; trigger = ""; expansion = ""
    }
}

// MARK: - Stílus

struct StyleView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Stílus", subtitle: "Alkalmazás-típusonként más hangnem. A formális nagybetűvel és teljes írásjelezéssel ír, a laza elhagyja a mondatvégi pontot, a nagyon laza chat-stílusú.")
            ForEach(AppCategory.allCases, id: \.self) { cat in
                BNCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.label).font(BN.sans(16, .medium)).foregroundColor(BN.light)
                                Text(cat.detail).font(BN.sans(12)).foregroundColor(BN.textMedium)
                            }
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            ForEach(StyleTone.allCases, id: \.self) { tone in
                                ToneOption(tone: tone, selected: model.settings.tone(for: cat) == tone) { model.settings.styles[cat] = tone }.accessibilityIdentifier("tone-\(cat.rawValue)-\(tone.rawValue)")
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ToneOption: View {
    let tone: StyleTone
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                BNLabel(tone.label, size: 10, color: selected ? BN.accent : BN.textMedium)
                Text(tone.example).font(BN.sans(13)).foregroundColor(BN.textStrong).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: BN.radius).fill(selected ? BN.light(0.08) : BN.base))
            .overlay(RoundedRectangle(cornerRadius: BN.radius).strokeBorder(selected ? BN.accent : BN.light(0.16), lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel("Hangnem: \(tone.label)")
        .accessibilityValue(selected ? "kiválasztva" : "")
    }
}

// MARK: - Polírozás

struct PolishView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var prompt = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Polírozás", subtitle: "Jelölj ki szöveget bármelyik appban, és nyomd meg a(z) \(model.settings.shortcuts.polish.first?.label ?? "⌃⌘P") parancsot: az alapértelmezett utasítás szerint átírja a helyén. Utána a sávon a „Kész · Változások” mutatja a különbséget.")
            BNLabel("Utasítások")
            VStack(spacing: 0) {
                ForEach(model.settings.allPolishPresets) { p in
                    HStack(alignment: .top, spacing: 12) {
                        LucideIcon(model.settings.defaultPolishID == p.id ? "circle-dot" : "circle", size: 16,
                                   color: model.settings.defaultPolishID == p.id ? BN.accent : BN.textMedium)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(BN.sans(14, .medium)).foregroundColor(BN.light)
                            Text(p.prompt).font(BN.sans(12)).foregroundColor(BN.textMedium).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.settings.defaultPolishID == p.id { BNBadge("Alapértelmezett") }
                        if !p.builtIn {
                            RowIconButton(icon: "trash-2", help: "Törlés: \(p.name)") {
                                model.settings.customPolish.removeAll { $0.id == p.id }
                                if model.settings.defaultPolishID == p.id { model.settings.defaultPolishID = "clean" }
                            }
                        }
                    }
                    .padding(.vertical, 10).padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture { model.settings.defaultPolishID = p.id }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Utasítás: \(p.name)")
                    .accessibilityAction { model.settings.defaultPolishID = p.id }
                    if p.id != model.settings.allPolishPresets.last?.id { BNDivider() }
                }
            }
            .bnList()
            BNLabel("Saját utasítás")
            BNCard {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Név (pl. LinkedIn-poszt)", text: $name).textFieldStyle(BNTextFieldStyle()).accessibilityLabel("Saját utasítás neve")
                    BNTextArea(text: $prompt, placeholder: "Mit csináljon a kijelölt szöveggel?", height: 70, axLabel: "Saját utasítás szövege")
                    HStack {
                        Spacer()
                        Button("Hozzáadás") {
                            let p = PolishPreset(name: name, prompt: prompt)
                            model.settings.customPolish.append(p)
                            name = ""; prompt = ""
                        }.buttonStyle(BNButtonStyle(kind: .primary, compact: true)).disabled(name.isEmpty || prompt.isEmpty)
                        .accessibilityLabel("Saját utasítás hozzáadása")
                    }
                }
            }
        }
    }
}
