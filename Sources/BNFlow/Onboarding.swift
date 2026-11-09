import AppKit
import SwiftUI
import BNFlowCore

/// „Első lépések”: API-kulcs, három engedély, első diktálás — mindegyikhez egy gomb a megfelelő beállításhoz.
@MainActor
enum Onboarding {
    static func state(_ model: AppModel) -> OnboardingState {
        let _ = model.permissionTick
        return OnboardingState(hasKey: model.hasAPIKey,
                               microphone: Permissions.microphone == .authorized,
                               accessibility: Permissions.accessibility,
                               inputMonitoring: Permissions.inputMonitoring,
                               hasDictated: !model.history.isEmpty || model.lastTranscript != nil)
    }
    static func complete(_ model: AppModel) -> Bool { state(model).complete }
}

struct OnboardingChecklist: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let st = Onboarding.state(model)
        let shortcut = model.settings.shortcuts.pushToTalk.first?.label ?? "fn"
        let rows: [(String, String, SettingsTab?)] = [
            ("OpenAI API-kulcs", "A kulcs a macOS Kulcskarikában marad, a lemezen nincs.", .apiKey),
            ("Mikrofon", "Csak felvétel közben használjuk.", .permissions),
            ("Kisegítő hozzáférés", "A szöveg beillesztéséhez és a kijelölés olvasásához.", .permissions),
            ("Bemenetfigyelés", "A(z) \(shortcut) billentyű figyeléséhez bármelyik appban.", .permissions),
            ("Első diktálás", "Tartsd lenyomva a(z) \(shortcut) billentyűt egy szövegmezőben, mondj egy mondatot, engedd el.", nil),
        ]
        BNCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        BNLabel("Első lépések", size: 10)
                        Text("\(st.doneCount) / \(st.steps.count) kész").font(BN.sans(16, .medium)).foregroundColor(BN.light)
                    }
                    Spacer()
                    ProgressTrack(value: Double(st.doneCount) / Double(st.steps.count)).frame(width: 160)
                }
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 12) {
                            LucideIcon(st.steps[i] ? "check" : (st.next == i ? "circle-dot" : "circle"), size: 16,
                                       color: st.steps[i] ? BN.success : (st.next == i ? BN.accent : BN.textWeak))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.0).font(BN.sans(14, .medium)).foregroundColor(st.steps[i] ? BN.textMedium : BN.light)
                                Text(r.1).font(BN.sans(12)).foregroundColor(BN.textMedium).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if !st.steps[i], let tab = r.2 {
                                Button("Beállítás") { model.openSettings(tab) }
                                    .buttonStyle(BNButtonStyle(kind: st.next == i ? .primary : .secondary, compact: true))
                                    .accessibilityLabel("Első lépés beállítása: \(r.0)")
                            }
                        }
                        .padding(.vertical, 8)
                        if i < rows.count - 1 { BNDivider() }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Első lépések")
    }
}

struct ProgressTrack: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(BN.light(0.08))
                RoundedRectangle(cornerRadius: 2).fill(BN.accent).frame(width: max(4, g.size.width * value))
            }
        }
        .frame(height: 4)
        .animation(BN.ease, value: value)
    }
}

/// Vágólap: önteszt módban saját (privát) vágólapra ír, így nem írja felül a felhasználóét.
@MainActor
enum Clipboard {
    static var pasteboard: NSPasteboard { TestMode.isOn ? TestMode.pasteboard : .general }
    static func copy(_ s: String) {
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
    }
}

// MARK: - Névjegy

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private(set) var window: NSWindow?

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.current }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "A Business Flow névjegye"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.backgroundColor = BN.ns(0x0a0a0b)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: AboutView())
            w.center()
            window = w
        }
        if TestMode.isOn {
            window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window?.orderBack(nil); return
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Wordmark()
            Text("Business Flow").font(BN.h6).foregroundColor(BN.light)
            Text("Diktálás bármelyik appba, magyarul és angolul. Okos formázás, parancs mód, polírozás.")
                .font(BN.body3).foregroundColor(BN.textMedium).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                BNBadge("Verzió \(AboutWindowController.version)")
                BNBadge("Build \(AboutWindowController.build)", color: BN.textMedium)
            }
            Spacer()
            Text("© Business Native — személyes használatra. Betűk: Geist (OFL). Ikonok: Lucide (ISC).")
                .font(BN.sans(11)).foregroundColor(BN.textWeak)
        }
        .padding(32)
        .frame(width: 420, height: 300, alignment: .topLeading)
        .background(BN.base)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Névjegy")
    }
}
