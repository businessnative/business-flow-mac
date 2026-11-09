import AppKit
import SwiftUI
import BNFlowCore

/// Fejlesztői ellenőrzések parancssorból (semmilyen titkot nem írnak ki).
enum Diagnostics {
    /// `--check-models`: ingyenes GET /v1/models/<név> hívás a beállított modellekre; csak a HTTP státuszt írja ki.
    static func checkModels() -> Int32 {
        guard let key = Keychain.read(interactive: false) else { print(Keychain.lastReadNeedsApproval ? "a kulcs olvasásához Kulcskarika-jóváhagyás kell (nyisd meg egyszer a Business Flow-t és válaszd: Mindig engedélyez)" : "nincs kulcs a Kulcskarikában"); return 1 }
        let st = JSONFileStore<AppSettings>(url: AppPaths.supportDirectory.appendingPathComponent("settings.json")).load() ?? AppSettings()
        let models = [st.transcriptionModel, st.fallbackTranscriptionModel, st.chatModel, st.fallbackChatModel]
        let session = URLSession(configuration: .ephemeral)
        for m in models {
            var r = URLRequest(url: OpenAIClient.baseURL.appendingPathComponent("models/\(m)"))
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            r.timeoutInterval = 20
            let sem = DispatchSemaphore(value: 0)
            final class Box: @unchecked Sendable { var line = "" }
            let box = Box()
            session.dataTask(with: r) { _, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode
                box.line = "\(m): " + (code.map { "HTTP \($0)" + ($0 == 200 ? " (elérhető)" : "") } ?? "hiba: \(err?.localizedDescription ?? "?")")
                sem.signal()
            }.resume()
            sem.wait()
            print(box.line)
        }
        return 0
    }

    /// `--render-previews DIR`: a Hub és a Flow-sáv képernyőképei PNG-be, ablak megjelenítése nélkül (vizuális ellenőrzéshez).
    @MainActor
    static func renderPreviews(to dir: String) {
        FontLoader.registerBundled()
        TestMode.staticUI = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        func snap<V: View>(_ v: V, _ size: NSSize, _ name: String) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
            host.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("\(dir)/\(name).png")
        }
        for s in HubSection.allCases {
            model.hubSection = s
            snap(HubView(model: model), NSSize(width: 980, height: 660), "hub-\(s.rawValue)")
        }
        model.hubSection = .settings
        for t in SettingsTab.allCases {
            model.settingsTab = t
            snap(HubView(model: model), NSSize(width: 980, height: 660), "settings-\(t.rawValue)")
        }
        snap(AboutView(), NSSize(width: 420, height: 300), "about")
        let mb = MenuBarController(model: model)
        snap(ZStack { BN.depth; PillMenuView(model: PillMenuModel(menu: mb.buildMenu())) }, NSSize(width: 300, height: 520), "bar-menu")
        let modes: [(BarMode, String, Bool)] = [
            (.idle, "idle", false), (.idle, "idle-hover", true),
            (.recording(.dictation, handsFree: false), "ptt", false), (.recording(.dictation, handsFree: true), "handsfree", false),
            (.recording(.command, handsFree: false), "command", false), (.processing(nil), "processing", false),
            (.error("Nincs kulcs"), "error", false), (.polishDone, "polish-done", false),
        ]
        model.levels = [0.2, 0.5, 0.9, 0.6, 0.3, 0.7, 1, 0.4, 0.5, 0.2]
        for (m, name, hover) in modes {
            model.bar = m; model.hovering = hover
            snap(ZStack { BN.depth; FlowBarRoot(model: model, onClick: {}, onStop: {}, onCancel: {}, onMenu: {}, onChanges: {}) },
                 NSSize(width: 360, height: 110), "bar-\(name)")
        }
    }
}
