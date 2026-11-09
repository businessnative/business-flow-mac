import AppKit
import Combine
import BNFlowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.shared
    var monitor: HotkeyMonitor!
    var controller: DictationController!
    var bar: FlowBarController!
    var menuBar: MenuBarController!
    var hub: HubWindowController!
    private var cancellables: Set<AnyCancellable> = []
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.registerBundled()
        monitor = HotkeyMonitor(shortcuts: model.settings.shortcuts)
        controller = DictationController(model: model, monitor: monitor)
        hub = HubWindowController(model: model)
        bar = FlowBarController(model: model)
        bar.attach(controller)
        MeetingService.shared.start(model: model)
        menuBar = MenuBarController(model: model)
        menuBar.controller = controller
        bar.menuBuilder = { [weak self] in self?.menuBar.buildMenu() ?? NSMenu() }

        let open: (HubSection?) -> Void = { [weak self] s in self?.hub.show(s) }
        menuBar.openHub = open
        model.showHub = open
        controller.openHub = { s in open(s) }

        Services.shared.monitor = monitor
        Services.shared.controller = controller
        Services.shared.restartMonitor = { [weak self] in self?.startMonitor(prompt: false) }

        monitor.onAction = { [weak self] a in MainActor.assumeIsolated { self?.controller.handle(a) } }

        model.onSettingsChanged = { [weak self] old, new in
            guard let self else { return }
            if old.shortcuts != new.shortcuts { self.monitor.engine.shortcuts = new.shortcuts; self.monitor.engine.reset() }
            if old.retention != new.retention { self.model.applyRetention() }
        }

        model.$bar.receive(on: RunLoop.main).sink { [weak self] mode in
            if case .recording = mode { self?.menuBar.setRecording(true) } else { self?.menuBar.setRecording(false) }
        }.store(in: &cancellables)

        if TestMode.isOn {
            // Önteszt: nincs valódi event tap, engedélykérés vagy bejelentkezési elem; a teszt végén kilép.
            menuBar.onQuit = { TestMode.log("quit") }
            bar.menuBuilder = { [weak self] in self?.menuBar.buildMenu() ?? NSMenu() }
            Task { @MainActor in
                let code = await SelfTest.run(self)
                exit(code)
            }
            return
        }

        if E2E.isOn {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let code = await E2E.run(self)
                exit(code)
            }
            return
        }

        startMonitor(prompt: true)

        // Engedélyek állapota (a Hub ezt mutatja) — olcsó lekérdezés.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.permissionTick &+= 1
                if !self.monitor.isRunning && Permissions.inputMonitoring { self.startMonitor(prompt: false) }
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            NSLog("Business Flow smoke test: launched, monitor=\(monitor.isRunning), key=\(model.hasAPIKey)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            return
        }

        // Átnevezés / új helyre telepítés után a bejelentkezési elem a régi appra mutathat: ha be volt kapcsolva, újraregisztráljuk.
        if model.settings.launchAtLogin && !LoginItem.enabled {
            if let err = LoginItem.set(true) { NSLog("Business Flow: bejelentkezési elem újraregisztrálása sikertelen: %@", err) }
        }

        if !model.settings.onboardingDone || !model.hasAPIKey {
            model.settings.onboardingDone = true
            // Az „Első lépések” lista a Kezdőlapon van; kulcs nélkül a beállítások API-kulcs lapja nyílik.
            if model.hasAPIKey { hub.show(.home) } else { model.openSettings(.apiKey) }
        }
    }

    func startMonitor(prompt: Bool) {
        if monitor.start() { return }
        NSLog("Business Flow: event tap nem indult (Bemenetfigyelés engedély kell)")
        if prompt && !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            Permissions.requestInputMonitoring()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        hub.show(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}
