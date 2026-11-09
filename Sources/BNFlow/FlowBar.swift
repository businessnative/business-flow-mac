import AppKit
import SwiftUI
import BNFlowCore

/// Lebegő, nem aktiváló panel: nem veszi el a fókuszt a gépelt alkalmazástól.
final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick() } else { super.rightMouseDown(with: event) }
    }
}

@MainActor
final class FlowBarController {
    static let panelSize = NSSize(width: 360, height: 110)
    let model: AppModel
    let panel: FlowBarPanel
    weak var controller: DictationController?
    private var timer: Timer?
    private var hoverStart: Date?

    init(model: AppModel) {
        self.model = model
        panel = FlowBarPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    func attach(_ c: DictationController) {
        controller = c
        let root = FlowBarRoot(model: model,
                               onClick: { [weak c] in c?.barClicked() },
                               onStop: { [weak c] in c?.stop() },
                               onCancel: { [weak c] in c?.cancel() },
                               onMenu: { [weak self] in self?.showMenu() },
                               onChanges: { [weak self] in self?.showChanges() })
        let host = ClickThroughHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.onRightClick = { [weak self] in self?.showMenu() }
        panel.contentView = host
        reposition()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// A képernyő, amelyen az egér van (külső monitorokon is ott jelenik meg a sáv).
    private func activeScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    private var currentScreen: NSScreen?
    func reposition() {
        guard let s = activeScreen() else { return }
        currentScreen = s
        let vf = s.visibleFrame
        let origin = NSPoint(x: vf.midX - Self.panelSize.width / 2, y: vf.minY + 6)
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }

    /// A sáv téglalapja panel-koordinátában (alul középen).
    private func barRect() -> NSRect {
        let size = FlowBarView.size(for: model.bar, hovering: model.hovering)
        let hit = NSSize(width: max(size.width, 60) + 16, height: max(size.height, 14) + 16)
        return NSRect(x: (Self.panelSize.width - hit.width) / 2, y: 0, width: hit.width, height: hit.height)
    }

    /// Elrejtés tétlenül: 220 ms-os áttűnés (a design rendszer „ease” görbéjével), nem hirtelen eltűnés.
    private(set) var targetAlpha: CGFloat = 1
    var shouldHide: Bool { model.settings.hideBarWhenIdle && model.bar == .idle && !model.hovering && pillMenu == nil }

    func applyVisibility(animated: Bool = true) {
        let want: CGFloat = shouldHide ? 0 : 1
        guard want != targetAlpha else { return }
        targetAlpha = want
        if !animated || BN.reduceMotion || TestMode.isOn { panel.alphaValue = want; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().alphaValue = want
        }
    }

    private func tick() {
        applyVisibility()
        if model.bar == .idle, let s = activeScreen(), s != currentScreen { reposition() }

        let p = NSEvent.mouseLocation
        let f = panel.frame
        let local = NSPoint(x: p.x - f.minX, y: p.y - f.minY)
        let inside = NSMouseInRect(local, barRect(), false) && (targetAlpha > 0 || model.settings.hideBarWhenIdle)
        panel.ignoresMouseEvents = !inside
        if inside != model.hovering {
            if inside {
                if hoverStart == nil { hoverStart = Date() }
                if Date().timeIntervalSince(hoverStart!) > 0.08 { withAnimation(BN.ease) { model.hovering = true } }
            } else {
                hoverStart = nil
                withAnimation(BN.ease) { model.hovering = false }
            }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: Menü (jobb klikk vagy „…” gomb)
    var menuBuilder: (() -> NSMenu)?

    /// A sáv menüje a design rendszer „pill menu” elemeként (saját panel); a menüpontok ugyanazok, mint a menüsoron.
    private(set) var pillMenu: NSPanel?
    private var pillMonitors: [Any] = []
    private(set) var pillModel: PillMenuModel?

    func showMenu() {
        guard let menu = menuBuilder?() else { return }
        closeMenu()
        let pm = PillMenuModel(menu: menu)
        pm.onDone = { [weak self] in self?.closeMenu() }
        let view = ClickThroughHostingView(rootView: PillMenuView(model: pm))
        let size = view.fittingSize
        let p = FlowBarPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = view
        let f = panel.frame, r = barRect()
        var origin = NSPoint(x: f.minX + r.midX - size.width / 2, y: f.minY + r.maxY + 4)
        if let vf = (panel.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - size.width - 8)
            origin.y = min(origin.y, vf.maxY - size.height - 8)
        }
        p.setFrameOrigin(origin)
        if TestMode.isOn { p.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)) }
        p.orderFrontRegardless()
        pillMenu = p
        pillModel = pm
        // Bezárás kattintásra a menün kívül vagy Esc-re.
        if !TestMode.isOn {
            if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.closeMenu() }
            }) { pillMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self, let pm = self.pillMenu else { return e }
                    if e.type == .keyDown { if e.keyCode == 53 { self.closeMenu(); return nil }; return e }
                    if e.window !== pm { self.closeMenu() }
                    return e
                }
            }) { pillMonitors.append(l) }
        }
    }

    func closeMenu() {
        pillMonitors.forEach(NSEvent.removeMonitor)
        pillMonitors = []
        pillMenu?.orderOut(nil)
        pillMenu = nil
        pillModel = nil
    }

    private var changesPanel: NSPanel?

    /// „Kész · Változások”: a polírozás előtti/utáni szöveg szódiffje.
    func showChanges() {
        guard let lp = model.lastPolish else { return }
        changesPanel?.close()
        let p = FlowBarPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = ClickThroughHostingView(rootView: ChangesView(before: lp.before, after: lp.after, onClose: { [weak self] in
            self?.changesPanel?.close(); self?.changesPanel = nil
        }))
        let f = panel.frame
        p.setFrameOrigin(NSPoint(x: f.midX - 220, y: f.minY + 50))
        p.orderFrontRegardless()
        changesPanel = p
    }
}

// MARK: - SwiftUI

struct FlowBarRoot: View {
    @ObservedObject var model: AppModel
    var onClick: () -> Void
    var onStop: () -> Void
    var onCancel: () -> Void
    var onMenu: () -> Void
    var onChanges: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.hovering && model.bar == .idle {
                Tooltip(shortcut: model.settings.shortcuts.pushToTalk.first?.label ?? "fn",
                        handsFree: model.settings.shortcuts.handsFree.first?.label ?? "fn + Space")
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            FlowBarView(model: model, onClick: onClick, onStop: onStop, onCancel: onCancel, onMenu: onMenu, onChanges: onChanges)
        }
        .padding(.bottom, 8)
        .frame(width: FlowBarController.panelSize.width, height: FlowBarController.panelSize.height, alignment: .bottom)
    }
}

struct Tooltip: View {
    let shortcut: String
    let handsFree: String
    var body: some View {
        HStack(spacing: 6) {
            Text("Diktálás:").font(BN.body3).foregroundColor(BN.textStrong)
            Key(shortcut)
            Text("nyomva tartva ·").font(BN.body3).foregroundColor(BN.textStrong)
            Key(handsFree)
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: BN.radius).fill(BN.lift))
        .overlay(RoundedRectangle(cornerRadius: BN.radius).strokeBorder(BN.border, lineWidth: 1))
        .overlay(alignment: .top) { Rectangle().fill(BN.light(0.16)).frame(height: 1).padding(.horizontal, 6) }
        .fixedSize()
    }
    struct Key: View {
        let t: String
        init(_ t: String) { self.t = t }
        var body: some View {
            Text(t.uppercased()).font(BN.label1).tracking(0.75).foregroundColor(BN.textMedium)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: BN.radiusSmall).fill(BN.inputBg))
        }
    }
}

struct FlowBarView: View {
    @ObservedObject var model: AppModel
    var onClick: () -> Void
    var onStop: () -> Void
    var onCancel: () -> Void
    var onMenu: () -> Void
    var onChanges: () -> Void

    static func size(for mode: BarMode, hovering: Bool) -> CGSize {
        switch mode {
        case .idle: return hovering ? CGSize(width: 50, height: 30) : CGSize(width: 40, height: 8)
        case .recording(_, let hf): return hf ? CGSize(width: 102.5, height: 30) : CGSize(width: 73, height: 30)
        case .processing: return CGSize(width: 98, height: 30)
        case .error(let s): return CGSize(width: max(91, CGFloat(s.count) * 7 + 44), height: 30)
        case .notice(let s): return CGSize(width: max(91, CGFloat(s.count) * 7 + 28), height: 30)
        case .polishProcessing: return CGSize(width: 136, height: 30)
        case .polishDone: return CGSize(width: 152, height: 30)
        }
    }

    var size: CGSize { Self.size(for: model.bar, hovering: model.hovering) }

    var borderColor: Color {
        switch model.bar {
        case .idle: return model.hovering ? BN.light(0.32) : BN.light(0.16)
        case .recording(let f, let hf):
            switch f {
            case .dictation: return hf ? BN.accent : BN.light(0.16)
            case .command: return BN.tools
            case .instruct: return BN.warning
            }
        case .error: return BN.error
        default: return BN.light(0.16)
        }
    }

    var barColor: Color {
        switch model.bar {
        case .recording(let f, _):
            switch f { case .dictation: return BN.accent; case .command: return BN.tools; case .instruct: return BN.warning }
        default: return BN.light(0.48)
        }
    }

    var background: Color {
        if model.bar == .idle { return model.hovering ? BN.depth : BN.dark(0.64) }
        return BN.lift80
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BN.radius).fill(.ultraThinMaterial).opacity(0.6)
            RoundedRectangle(cornerRadius: BN.radius).fill(background)
            RoundedRectangle(cornerRadius: BN.radius).strokeBorder(borderColor, lineWidth: model.bar.isError ? 1.5 : 1)
            if model.bar.isProcessing { SpinningRing() }
            content
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            // BN bevel: felül light-16, alul light-8 belső él.
            if model.bar != .idle || model.hovering {
                RoundedRectangle(cornerRadius: BN.radius).inset(by: 0.5).stroke(BN.light(0.16), lineWidth: 1)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)).padding(.horizontal, 1).opacity(0.6)
                RoundedRectangle(cornerRadius: BN.radius).inset(by: 0.5).stroke(BN.light(0.08), lineWidth: 1)
                    .mask(LinearGradient(colors: [.clear, .white], startPoint: .center, endPoint: .bottom)).padding(.horizontal, 1)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(model.bar == .idle && !model.hovering ? 0 : 0.34), radius: 18, y: 8)
        .animation(BN.ease, value: model.bar)
        .animation(BN.ease, value: model.hovering)
        .contentShape(Rectangle())
        .onTapGesture { if model.bar == .polishDone { onChanges() } else { onClick() } }
        // .contain: a STOP/X gomb külön is elérhető VoiceOverrel és billentyűzettel (a .combine összevonta őket).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction { if model.bar == .polishDone { onChanges() } else { onClick() } }
    }

    var accessibilityText: String {
        switch model.bar {
        case .idle: return "Business Flow — diktálásra kész"
        case .recording: return "Felvétel folyamatban"
        case .processing: return "Feldolgozás"
        case .error(let s): return "Hiba: \(s)"
        case .notice(let s): return s
        case .polishProcessing: return "Polírozás"
        case .polishDone: return "Kész, változások megtekintése"
        }
    }

    @ViewBuilder var content: some View {
        switch model.bar {
        case .idle:
            if model.hovering {
                HStack(spacing: 2) { Waveform(levels: Array(repeating: 0, count: 10), color: barColor, idle: true) }
                    .transition(.opacity)
            }
        case .recording(_, let hf):
            HStack(spacing: 8) {
                if hf {
                    BarIconButton(kind: .cancel, action: onCancel).help("Megszakítás (Esc)")
                }
                Waveform(levels: model.levels, color: barColor, idle: false)
                if hf {
                    BarIconButton(kind: .stop, action: onStop).help("Leállítás és beillesztés")
                }
            }
        case .processing:
            Waveform(levels: Array(repeating: 0.15, count: 10), color: BN.light(0.48), idle: true).opacity(0.6)
        case .error(let s):
            HStack(spacing: 6) {
                LucideIcon("circle-alert", size: 14, color: BN.error)
                Text(s).font(BN.button2).foregroundColor(BN.light).lineLimit(1)
            }
        case .notice(let s):
            Text(s).font(BN.button2).foregroundColor(BN.light).lineLimit(1)
        case .polishProcessing:
            BNLabel("Polírozás…", size: 10)
        case .polishDone:
            HStack(spacing: 6) {
                LucideIcon("check", size: 12, color: BN.success, lineWidth: 2)
                Text("Kész · Változások").font(BN.button2).foregroundColor(BN.light)
            }
        }
    }
}

extension BarMode {
    var isError: Bool { if case .error = self { return true }; return false }
    var isProcessing: Bool {
        switch self { case .processing, .polishProcessing: return true; default: return false }
    }
}

struct Waveform: View {
    let levels: [CGFloat]
    let color: Color
    let idle: Bool
    static let shape: [CGFloat] = [0.45, 0.7, 0.9, 1.0, 0.85, 0.95, 1.0, 0.8, 0.6, 0.4]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                let l = i < levels.count ? levels[i] : 0
                let h: CGFloat = idle ? 3 : max(3, min(16, 3 + l * 16 * Self.shape[i]))
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: h)
            }
        }
        .frame(height: 16)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.12), value: levels)
    }
}

/// Feldolgozás: körbefutó lavender fénycsík a sáv szélén (1,6 s, lineáris).
struct SpinningRing: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = BN.reduceMotion ? 0 : (t.truncatingRemainder(dividingBy: 1.6) / 1.6) * 360
            RoundedRectangle(cornerRadius: BN.radius)
                .strokeBorder(AngularGradient(gradient: Gradient(colors: [BN.accent, BN.light(0), BN.light(0), BN.accent]),
                                              center: .center, angle: .degrees(angle)), lineWidth: 1)
        }
    }
}

struct ChangesView: View {
    let before: String
    let after: String
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BNLabel("Változások")
                Spacer()
                Button(action: onClose) { LucideIcon("x", size: 16, color: BN.textMedium) }.buttonStyle(.plain).accessibilityLabel("Bezárás")
            }
            ScrollView {
                diffText.font(BN.body3).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Eredeti másolása") { Clipboard.copy(before) }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true))
                Button("Bezárás", action: onClose).buttonStyle(BNButtonStyle(kind: .primary, compact: true))
            }
        }
        .padding(14)
        .frame(width: 440, height: 280)
        .background(RoundedRectangle(cornerRadius: BN.radius).fill(BN.rgb(0x121212, 0.96)))
        .overlay(RoundedRectangle(cornerRadius: BN.radius).strokeBorder(BN.menuBorder, lineWidth: 1))
    }

    var diffText: Text {
        WordDiff.diff(before, after).reduce(Text("")) { acc, op in
            switch op {
            case .same(let w): return acc + Text(w + " ").foregroundColor(BN.textStrong)
            case .added(let w): return acc + Text(w + " ").foregroundColor(BN.success)
            case .removed(let w): return acc + Text(w + " ").foregroundColor(BN.error).strikethrough()
            }
        }
    }
}

/// Sáv-gombok (Megszakítás / Leállítás): hover-állapot és 2 px-es lavender fókuszgyűrű a design rendszer szerint.
struct BarIconButton: View {
    enum Kind { case cancel, stop }
    let kind: Kind
    let action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: BN.radiusSmall)
                    .fill(kind == .stop ? (hover ? BN.rgb(0xf6f3ec, 0xe0 / 255) : BN.light) : (hover ? BN.light(0.16) : BN.inputBg))
                if kind == .stop {
                    RoundedRectangle(cornerRadius: 1.5).fill(BN.base).frame(width: 8, height: 8)
                } else {
                    LucideIcon("x", size: 12, color: hover ? BN.light : BN.textMedium, lineWidth: 2)
                }
            }
            .frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: BN.radiusSmall + 2).strokeBorder(BN.accent, lineWidth: 2).padding(-2).opacity(focused ? 1 : 0))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { h in withAnimation(BN.ease) { hover = h } }
        .accessibilityLabel(kind == .stop ? "Leállítás és beillesztés" : "Felvétel megszakítása")
    }
}

// MARK: - Pill menu (a sáv jobb klikkes menüje)

@MainActor
final class PillMenuModel: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        let title: String
        let section: String?
        let checked: Bool
        let enabled: Bool
        let icon: String?
        let menu: NSMenu
        let index: Int
        let separatorBefore: Bool
    }
    let rows: [Row]
    var onDone: (() -> Void)?

    init(menu: NSMenu) {
        var out: [Row] = []
        var sep = false
        func icon(_ t: String) -> String? {
            switch t {
            case let x where x.hasSuffix("megnyitása"): return "house"
            case let x where x.hasPrefix("Utolsó átirat"): return "clipboard-paste"
            case let x where x.hasPrefix("Utolsó felvétel"): return "refresh-cw"
            case "Szótár…": return "book-open"
            case "Beállítások…": return "settings"
            case let x where x.hasPrefix("Sáv elrejtése"): return "eye-off"
            case let x where x.hasPrefix("Névjegy"): return "info"
            case let x where x.hasPrefix("Kilépés"): return "log-out"
            default: return nil
            }
        }
        for (i, it) in menu.items.enumerated() {
            if it.isSeparatorItem { sep = true; continue }
            if let sub = it.submenu {
                // Almenü → beágyazott szakasz (a pill menu nem nyit második szintet).
                let header = it.title
                for (j, s) in sub.items.enumerated() where !s.isSeparatorItem {
                    out.append(Row(id: out.count, title: s.title, section: header, checked: s.state == .on, enabled: s.isEnabled,
                                   icon: nil, menu: sub, index: j, separatorBefore: sep && j == 0))
                }
                sep = true
                continue
            }
            out.append(Row(id: out.count, title: it.title, section: nil, checked: it.state == .on, enabled: it.isEnabled,
                           icon: icon(it.title), menu: menu, index: i, separatorBefore: sep && !out.isEmpty))
            sep = false
        }
        rows = out
    }

    func perform(_ r: Row) {
        guard r.enabled else { return }
        onDone?()
        r.menu.performActionForItem(at: r.index)
    }
}

struct PillMenuView: View {
    @ObservedObject var model: PillMenuModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { r in
                if r.separatorBefore { Rectangle().fill(BN.light(0.08)).frame(height: 1).padding(.vertical, 4) }
                if let sec = r.section, model.rows.first(where: { $0.section == sec })?.id == r.id {
                    Text(sec.uppercased()).font(BN.label1).tracking(0.75).foregroundColor(BN.textWeak)
                        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
                }
                PillMenuRow(row: r) { model.perform(r) }
            }
        }
        .padding(4)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: BN.radius).fill(BN.rgb(0x121212, 0.96)))
        .overlay(RoundedRectangle(cornerRadius: BN.radius).strokeBorder(BN.menuBorder, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Business Flow menü")
    }
}

struct PillMenuRow: View {
    let row: PillMenuModel.Row
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if row.section != nil {
                    LucideIcon(row.checked ? "check" : "circle", size: 14, color: row.checked ? BN.accent : BN.light(0))
                } else if let i = row.icon {
                    LucideIcon(i, size: 16, color: BN.light(0.64))
                }
                Text(row.title).font(BN.body3).foregroundColor(row.enabled ? BN.light : BN.textWeak).lineLimit(1)
                Spacer(minLength: 8)
                if row.section == nil && row.checked { LucideIcon("check", size: 14, color: BN.accent) }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BN.radiusSmall).fill(hover && row.enabled ? BN.light(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .onHover { hover = $0 }
        .accessibilityLabel(row.section.map { "\($0): \(row.title)" } ?? row.title)
        .accessibilityValue(row.checked ? "kijelölve" : "")
    }
}
