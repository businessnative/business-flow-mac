import AppKit
import BNFlowCore

/// Menüsor-ikon (BN pontmátrix-nyíl) és a közös menü (a sáv jobb klikkje is ezt használja).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Önteszt módban nincs menüsor-ikon (a felhasználó menüsorát nem érinti).
    private let item: NSStatusItem? = TestMode.isOn ? nil : NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let model: AppModel
    weak var controller: DictationController?
    var openHub: ((HubSection?) -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        item?.button?.image = BrandIcon.menuBarImage(recording: false)
        item?.button?.toolTip = "Business Flow"
        let menu = NSMenu()
        menu.delegate = self
        item?.menu = menu
    }

    func setRecording(_ on: Bool) {
        item?.button?.image = BrandIcon.menuBarImage(recording: on)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        fill(m)
        return m
    }

    private func fill(_ m: NSMenu) {
        m.appearance = NSAppearance(named: .darkAqua)
        m.addItem(action("Business Flow megnyitása", #selector(openHome), key: ","))
        m.addItem(.separator())
        let paste = action("Utolsó átirat beillesztése", #selector(pasteLast))
        paste.isEnabled = model.lastText != nil
        m.addItem(paste)
        let retry = action("Utolsó felvétel újrapróbálása", #selector(retryLast))
        retry.isEnabled = controller?.lastFailedAudio != nil
        m.addItem(retry)
        let polish = NSMenuItem(title: "Polírozás", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in model.settings.allPolishPresets {
            let it = action(p.name, #selector(polishWith(_:)))
            it.representedObject = p.id
            it.state = p.id == model.settings.defaultPolishID ? .on : .off
            sub.addItem(it)
        }
        polish.submenu = sub
        m.addItem(polish)
        let lang = NSMenuItem(title: "Nyelv: \(model.settings.language.label)", action: nil, keyEquivalent: "")
        let ls = NSMenu()
        for l in DictationLanguage.allCases {
            let it = action(l.label, #selector(setLanguage(_:)))
            it.representedObject = l.rawValue
            it.state = l == model.settings.language ? .on : .off
            ls.addItem(it)
        }
        lang.submenu = ls
        m.addItem(lang)
        m.addItem(.separator())
        m.addItem(action("Szótár…", #selector(openDictionary)))
        m.addItem(action("Beállítások…", #selector(openSettings)))
        let hide = action("Sáv elrejtése, ha nem diktálok", #selector(toggleHide))
        hide.state = model.settings.hideBarWhenIdle ? .on : .off
        m.addItem(hide)
        m.addItem(.separator())
        m.addItem(action("Névjegy (Business Flow \(AboutWindowController.version))", #selector(about)))
        m.addItem(action("Kilépés a Business Flow-ból", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func openHome() { openHub?(.home) }
    @objc private func openDictionary() { openHub?(.dictionary) }
    @objc private func openSettings() { openHub?(.settings) }
    @objc private func pasteLast() { controller?.pasteLast() }
    @objc private func retryLast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.controller?.retryLastFailed() }
        }
    }
    @objc private func polishWith(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let p = model.settings.allPolishPresets.first(where: { $0.id == id }) else { return }
        // A menü bezárása után a fókusz visszakerül az eredeti appra.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.controller?.polishSelection(preset: p) }
        }
    }
    @objc private func setLanguage(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let l = DictationLanguage(rawValue: raw) { model.settings.language = l }
    }
    @objc private func toggleHide() { model.settings.hideBarWhenIdle.toggle() }
    @objc private func about() { AboutWindowController.shared.show() }
    var onQuit: (() -> Void)?
    @objc private func quit() { if let onQuit { onQuit() } else { NSApp.terminate(nil) } }
}
