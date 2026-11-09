import AppKit
import BNFlowCore

/// `--self-test [kimenet.json] [--passes N]`: az app összes menüpontjának és beállításának automatikus végigjárása.
/// A gombokat a valódi SwiftUI nézetek kisegítő (AX) elemein „nyomja meg” (ugyanúgy, mint a VoiceOver), a szövegmezőkbe
/// a mező szerkesztőjén keresztül gépel. Minden külső mellékhatás a TestMode-ba kerül (lásd TestMode.swift).
@MainActor
enum SelfTest {
    struct Case: Codable { let pass: Int; let area: String; let name: String; let ok: Bool; let via: String; let detail: String }
    static var cases: [Case] = []
    static var pass = 0
    static var area = ""
    static var passes = 2
    static var outPath: String?
    static var tempDir: URL?

    @discardableResult
    static func check(_ name: String, _ ok: Bool, via: String = "ax", _ detail: @autoclosure () -> String = "") -> Bool {
        let d = ok ? "" : detail()
        cases.append(Case(pass: pass, area: area, name: name, ok: ok, via: via, detail: d))
        print("\(ok ? "PASS" : "FAIL") [\(pass)] \(area) · \(name)\(ok ? "" : " — " + d)")
        fflush(stdout)
        return ok
    }

    // MARK: Segédek

    static func settle(_ ms: UInt64 = 150) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    static func waitFor(_ timeout: Double = 3, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await settle(40)
        }
        return cond()
    }

    struct Node { let obj: AnyObject; let label: String; let title: String; let ident: String; let value: String; let enabled: Bool }

    static func str(_ a: Any?) -> String {
        guard let a else { return "" }
        if let s = a as? String { return s }
        if let s = a as? NSAttributedString { return s.string }
        if let n = a as? NSNumber { return n.stringValue }
        return ""
    }

    static func nodes(_ root: AnyObject?) -> [Node] {
        guard let root else { return [] }
        var out: [Node] = []
        var seen = Set<ObjectIdentifier>()
        var stack: [AnyObject] = [root]
        while let o = stack.popLast(), out.count < 30_000 {
            guard seen.insert(ObjectIdentifier(o)).inserted else { continue }
            let label = str(o.accessibilityLabel?() ?? nil)
            let title = str(o.accessibilityTitle?() ?? nil)
            let ident = str(o.accessibilityIdentifier?() ?? nil)
            let value = str(o.accessibilityValue?() ?? nil)
            let enabled = o.isAccessibilityEnabled?() ?? true
            out.append(Node(obj: o, label: label, title: title, ident: ident, value: value, enabled: enabled))
            let kids = (o.accessibilityChildren?() ?? nil) ?? []
            for k in kids.reversed() { stack.append(k as AnyObject) }
        }
        return out
    }

    static func find(_ label: String, in root: AnyObject?, prefix: Bool = false) -> Node? {
        nodes(root).first { n in
            prefix ? (n.label.hasPrefix(label) || n.title.hasPrefix(label)) : (n.label == label || n.title == label || n.ident == label)
        }
    }

    /// AX „press” a megadott címkéjű elemen.
    @discardableResult
    static func press(_ label: String, in root: AnyObject?, prefix: Bool = false) async -> Bool {
        guard let n = find(label, in: root, prefix: prefix) else { return false }
        let ok = n.obj.accessibilityPerformPress?() ?? false
        await settle()
        return ok
    }

    /// Hibakereséshez: a látható AX-címkék (csak az önteszt saját, kitalált adatai).
    static func labels(_ root: AnyObject?) -> String {
        nodes(root).map { $0.label.isEmpty ? $0.value : $0.label }.filter { !$0.isEmpty }.prefix(60).joined(separator: " | ")
    }

    static func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }

    /// Gépelés egy szövegmezőbe a mező saját szerkesztőjén keresztül (mintha a felhasználó írná).
    @discardableResult
    static func type(_ text: String, in window: NSWindow?, where match: (NSTextField) -> Bool) async -> Bool {
        guard let w = window, let cv = w.contentView,
              let tf = allViews(cv).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && match($0) }) else { return false }
        w.makeFirstResponder(tf)
        if let ed = tf.currentEditor() as? NSTextView {
            ed.selectAll(nil)
            ed.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            tf.stringValue = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: tf)
        }
        w.makeFirstResponder(nil)
        await settle()
        return true
    }

    static func typeField(_ text: String, placeholder: String, in w: NSWindow?) async -> Bool {
        await type(text, in: w) { $0.placeholderString == placeholder || str($0.accessibilityLabel()) == placeholder }
    }

    /// Többsoros mező (TextEditor → NSTextView), az oldalon az index-edik.
    @discardableResult
    static func typeArea(_ text: String, index: Int = 0, in window: NSWindow?) async -> Bool {
        guard let w = window, let cv = w.contentView else { return false }
        let tvs = allViews(cv).compactMap { $0 as? NSTextView }.filter { $0.isEditable && !$0.isFieldEditor }
        guard index < tvs.count else { return false }
        let tv = tvs[index]
        w.makeFirstResponder(tv)
        tv.selectAll(nil)
        tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        w.makeFirstResponder(nil)
        await settle()
        return true
    }

    static func isIdleOrDone(_ m: AppModel) -> Bool {
        if case .recording = m.bar { return false }
        return !m.bar.isProcessing
    }

    static func dictate(_ d: AppDelegate, transcript: String, audio: [Float]? = nil, kind: DictationKind = .dictation, handsFree: Bool = false) async -> Bool {
        TestMode.transcript = transcript
        TestMode.nextAudio = audio ?? TestMode.fakeSpeech()
        d.controller.start(kind, handsFree: handsFree)
        await settle(250)
        guard d.controller.isRecording else { return false }
        d.controller.stop()
        await settle(60)
        return await waitFor(5) { isIdleOrDone(d.model) }
    }

    static func resetState(_ d: AppDelegate) {
        var s = AppSettings()
        s.onboardingDone = true
        d.model.settings = s
        d.model.clearHistory()
        d.model.lastTranscript = nil
        d.model.lastPolish = nil
        d.model.bar = .idle
        TestMode.keychain = "sk-selftest-not-a-real-key-0000000000"
        d.model.refreshKey()
        TestMode.permissionsGranted = true
        TestMode.pasteboard.clearContents()
        TestMode.inserted = []
        TestMode.selection = nil
        TestMode.fieldValue = ""
        TestMode.events = []
        TestMode.requests = []
        TestMode.failNetwork = false
        TestMode.failPaste = false
        TestMode.hangNetwork = false
        DictationController.processingTimeout = 45
        TestMode.chatReply = "Rendben."
        LoginItem.testEnabled = false
    }

    // MARK: Futtatás

    static func run(_ dp: AppDelegate?) async -> Int32 {
        guard let d = dp else { return 2 }
        // A SwiftUI csak akkor építi fel a kisegítő (AX) fát, ha egy kisegítő kliens kéri; ezt jelezzük a saját folyamatunkban
        // (nem kell hozzá rendszerengedély, és csak erre a futásra vonatkozik).
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        await settle(300)
        let started = Date()
        for p in 1...passes {
            pass = p
            resetState(d)
            await runPass(d)
        }
        let failed = cases.filter { !$0.ok }
        print("ÖSSZESEN: \(cases.count) ellenőrzés, \(cases.count - failed.count) sikeres, \(failed.count) hibás, \(passes) kör, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        if let outPath {
            struct Out: Codable { let passes: Int; let total: Int; let failed: Int; let cases: [Case] }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(Out(passes: passes, total: cases.count, failed: failed.count, cases: cases)) {
                try? data.write(to: URL(fileURLWithPath: outPath))
            }
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        return failed.isEmpty ? 0 : 1
    }

    static func runPass(_ d: AppDelegate) async {
        await testDictation(d)
        await testReliability(d)
        await testMenu(d)
        await testPillMenu(d)
        await testFlowBar(d)
        await testNavigation(d)
        await testHome(d)
        await testDictionary(d)
        await testSnippets(d)
        await testStyles(d)
        await testPolish(d)
        await testGeneral(d)
        await testLanguages(d)
        await testMicrophone(d)
        await testShortcuts(d)
        await testPermissions(d)
        await testAPIKey(d)
        await testAdvanced(d)
        await testOnboarding(d)
    }

    // MARK: Megbízhatóság (0.3.1): ismételt indítás/leállítás, elakadt állapotok, csendes alapértelmezés

    static func testReliability(_ d: AppDelegate) async {
        let m = d.model
        let c = d.controller!
        resetState(d)
        check("hangok alapból kikapcsolva", !m.settings.sounds && m.settings.soundVolume <= 0.2, via: "model")

        // 1) Csendes alapállapot: diktálás közben nincs hangjelzés.
        TestMode.events = []
        _ = await dictate(d, transcript: "Csendes próba.")
        check("alapból nincs hangjelzés diktáláskor", !TestMode.events.contains { $0.hasPrefix("sound:") }, via: "controller", TestMode.events.joined(separator: ","))
        m.settings.sounds = true
        TestMode.events = []
        _ = await dictate(d, transcript: "Hangos próba.")
        check("bekapcsolt Hangok → jelzés szól", TestMode.took("sound:start") && TestMode.took("sound:stop"), via: "controller", TestMode.events.joined(separator: ","))
        m.settings.sounds = false

        // 2) 40 gyors indítás/leállítás + 40 indítás/megszakítás egymás után: soha nem ragad be.
        var okCycles = 0
        for i in 0..<40 {
            TestMode.transcript = "Ciklus \(i)."
            TestMode.nextAudio = TestMode.fakeSpeech(seconds: 0.6)
            c.handle(.start(.dictation, handsFree: i % 2 == 0))
            await settle(30)
            let rec = c.isRecording
            c.handle(.stop)
            if rec, await waitFor(3, { isIdleOrDone(m) && !c.isBusy }) { okCycles += 1 }
        }
        check("40 indítás/leállítás ciklus, mind visszatér üresjáratba", okCycles == 40, via: "controller", "\(okCycles)/40, sáv: \(m.bar)")
        var okCancel = 0
        for _ in 0..<40 {
            c.handle(.start(.dictation, handsFree: false))
            await settle(10)
            let rec = c.isRecording
            c.handle(.cancel)
            if rec, !c.isRecording, m.bar == .idle, !c.isBusy { okCancel += 1 }
        }
        check("40 indítás/megszakítás ciklus", okCancel == 40, via: "controller", "\(okCancel)/40")

        // Alvás felvétel közben → megszakítás; ébredés után újra indítható.
        c.handle(.start(.dictation, handsFree: true)); await settle(10)
        let recBeforeSleep = c.isRecording
        c.handleSleep(); c.handleWake(); await settle(5)
        check("alvás felvétel közben → megszakítás, üresjárat", recBeforeSleep && !c.isRecording && m.bar == .idle, via: "controller")
        c.handle(.start(.dictation, handsFree: false)); await settle(10)
        let recAfterWake = c.isRecording; c.handle(.cancel)
        check("ébredés után azonnal indítható", recAfterWake, via: "controller")

        // 3) Elakadt átírás → időkorlát: hibaüzenet a sávon, a felvétel megmarad, újra indítható.
        DictationController.processingTimeout = 1.5
        TestMode.hangNetwork = true
        TestMode.nextAudio = TestMode.fakeSpeech()
        c.start(.dictation, handsFree: false); await settle(100); c.stop()
        let timedOut = await waitFor(4) { m.bar.isError && !c.isBusy }
        check("elakadt átírás → „Időtúllépés” a sávon (őr)", timedOut && c.lastFailedAudio != nil, via: "controller", "\(m.bar) busy=\(c.isBusy)")
        c.start(.dictation, handsFree: false); await settle(60)
        check("időtúllépés után azonnal újraindítható", c.isRecording, via: "controller")
        c.cancel()

        // 4) Elakadt feldolgozás közben egy gyorsbillentyű-nyomás megszakítja és új felvételt indít.
        DictationController.processingTimeout = 60
        TestMode.nextAudio = TestMode.fakeSpeech()
        c.start(.dictation, handsFree: false); await settle(100); c.stop()
        await settle(UInt64(DictationController.stuckAfter * 1000) + 300)
        let wasBusy = c.isBusy
        c.handle(.start(.dictation, handsFree: true))
        await settle(60)
        check("elakadt állapotban a gyorsbillentyű helyreállít és indít", wasBusy && c.isRecording && c.lastFailedAudio != nil, via: "controller", "busy=\(wasBusy) rec=\(c.isRecording)")
        c.cancel()
        TestMode.hangNetwork = false
        DictationController.processingTimeout = 45

        // 5) Állapot-eltérés: a sáv felvételt mutat, de nincs felvétel → leállítás üresjáratba hozza.
        m.bar = .recording(.dictation, handsFree: true)
        c.handle(.stop)
        check("beragadt „felvétel” sáv → stop helyreállítja", m.bar == .idle && d.monitor.engine.state == .idle, via: "controller", "\(m.bar)")
        resetState(d)
    }

    // MARK: Diktálás (stub hálózat, szintetikus hang)

    static func testDictation(_ d: AppDelegate) async {
        area = "Diktálás"
        let m = d.model
        TestMode.fieldValue = ""
        TestMode.requests = []
        let ok = await dictate(d, transcript: "Holnap délután átküldöm az ajánlatot.")
        check("nyomva tartott diktálás → beillesztés", ok && TestMode.fieldValue.contains("átküldöm az ajánlatot"), via: "controller", "mező: \(TestMode.fieldValue.count) karakter, sáv: \(m.bar)")
        check("előzménybe kerül", m.history.first?.kind == .dictation && m.history.first?.text.contains("ajánlatot") == true, via: "model")
        check("átírás a stub végponton", TestMode.requests.contains { $0.hasSuffix("audio/transcriptions") }, via: "network-stub", TestMode.requests.joined(separator: ", "))
        check("rövid, tiszta mondatnál nincs LLM-hívás (gyorsabb)", !TestMode.requests.contains { $0.hasSuffix("chat/completions") }, via: "network-stub", TestMode.requests.joined(separator: ", "))
        check("TLS előmelegítés (HEAD, kulcs nélkül; 20 s-onként egyszer)", pass > 1 || TestMode.requests.contains { $0.hasPrefix("HEAD") }, via: "network-stub", TestMode.requests.joined(separator: ", "))

        // Kihangosított mód: indítás, majd a sáv STOP gombja
        TestMode.fieldValue = ""
        TestMode.transcript = "Ez kihangosítva ment."
        TestMode.nextAudio = TestMode.fakeSpeech()
        d.controller.handle(.start(.dictation, handsFree: true))
        await settle(250)
        let rec = d.controller.isRecording
        let barRoot = d.bar.panel.contentView
        let stopPressed = await press("Leállítás és beillesztés", in: barRoot)
        if !stopPressed { d.controller.barClicked() }
        _ = await waitFor(5) { isIdleOrDone(m) }
        check("kihangosított diktálás + STOP gomb", rec && stopPressed && TestMode.fieldValue.contains("kihangosítva"), via: stopPressed ? "ax" : "controller", "rec=\(rec) stopAX=\(stopPressed) " + labels(barRoot))

        // Megszakítás
        let before = TestMode.inserted.count
        TestMode.nextAudio = TestMode.fakeSpeech()
        d.controller.start(.dictation, handsFree: true)
        await settle(200)
        let cancelPressed = await press("Felvétel megszakítása", in: barRoot)
        if !cancelPressed { d.controller.cancel() }
        await settle(200)
        check("megszakítás (X)", cancelPressed && m.bar == .idle && !d.controller.isRecording && TestMode.inserted.count == before, via: cancelPressed ? "ax" : "controller")

        // Csend
        _ = await dictate(d, transcript: "x", audio: [Float](repeating: 0, count: 16_000))
        check("csend → „Nem hallottam semmit”, nincs beillesztés", TestMode.inserted.count == before && (m.bar == .notice("Nem hallottam semmit") || m.bar == .idle), via: "controller", "\(m.bar)")

        // Suttogás
        TestMode.fieldValue = ""
        let w = await dictate(d, transcript: "Ez suttogva hangzott el.", audio: TestMode.fakeSpeech(amplitude: 0.012))
        check("suttogó mód: halk beszéd sem vész el", w && TestMode.fieldValue.contains("suttogva"), via: "controller", "mező \(TestMode.fieldValue.count) kar.")

        // Kimondott írásjel
        TestMode.fieldValue = ""
        _ = await dictate(d, transcript: "Megjött a csomag kérdőjel")
        check("kimondott írásjel („kérdőjel” → ?)", TestMode.fieldValue.contains("csomag?"), via: "controller", TestMode.fieldValue)

        // Parancs mód kijelöléssel
        TestMode.fieldValue = "Holnap találkozunk."
        TestMode.selection = "Holnap találkozunk."
        TestMode.chatReply = "See you tomorrow."
        _ = await dictate(d, transcript: "Fordítsd angolra.", kind: .command)
        check("parancs mód: kijelölés átírása", TestMode.fieldValue == "See you tomorrow.", via: "controller", TestMode.fieldValue)
        check("parancs mód: chat a stub végponton", TestMode.requests.contains { $0.hasSuffix("chat/completions") }, via: "network-stub")
        TestMode.chatReply = "Rendben."
        TestMode.selection = nil

        // Automatikus szótártanulás
        TestMode.fieldValue = ""
        m.settings.autoLearnDictionary = true
        _ = await dictate(d, transcript: "Holnap hívom Kovács Pétert az ügyben.")
        TestMode.fieldValue = TestMode.fieldValue.replacingOccurrences(of: "Pétert", with: "Petrát")
        let learned = await waitFor(3) { m.settings.dictionary.contains { $0.term == "Petrát" && $0.autoLearned } }
        check("automatikus tanulás kézi javításból", learned, via: "controller", m.settings.dictionary.map(\.term).joined(separator: ", "))

        // Beillesztés sikertelen: a szöveg előzményben, vágólapon és az utolsó átiratban megmarad.
        let keptBeforePasteFail = m.lastText
        TestMode.failPaste = true
        TestMode.fieldValue = ""
        TestMode.pasteboard.clearContents()
        _ = await dictate(d, transcript: "A mezőbe nem került be ez a mondat.")
        let pasteRow = m.history.first
        check("beillesztés hibája: a szöveg előzményben marad", pasteRow?.status == .pasteFailed && pasteRow?.text.contains("nem került") == true && pasteRow?.canCopy == true, via: "controller", "\(pasteRow?.status.rawValue ?? "-")")
        check("beillesztés hibája: utolsó átirat és vágólap", m.lastText?.contains("nem került") == true && TestMode.pasteboard.string(forType: .string)?.contains("nem került") == true && !TestMode.fieldValue.contains("nem került"), via: "controller")
        TestMode.failPaste = false
        _ = keptBeforePasteFail

        // Hálózati hiba → újrapróbálás. Az üres hiba nem írhatja felül a megmaradt szöveget.
        let kept = m.lastText
        TestMode.failNetwork = true
        TestMode.fieldValue = ""
        _ = await dictate(d, transcript: "Újrapróbált mondat.")
        let failedRow = m.history.first
        check("hálózati hiba → hibaüzenet a sávon", m.bar.isError || d.controller.lastFailedAudio != nil, via: "controller", "\(m.bar)")
        check("sikertelen felvétel megmarad", d.controller.lastFailedAudio != nil && failedRow?.status == .failed && failedRow?.canRetry == true, via: "controller", failedRow?.failureReason ?? "")
        check("sikertelen átírás nem törli az utolsó szöveget", m.lastText == kept, via: "controller")
        check("a hiba oka nem tartalmaz kulcsot", failedRow?.failureReason?.contains("sk-") != true, via: "controller", failedRow?.failureReason ?? "")
        TestMode.failNetwork = false

        // Kulcs nélkül
        let savedKey = TestMode.keychain
        TestMode.keychain = nil; m.refreshKey()
        m.hubSection = .home; m.settingsTab = .general
        d.controller.start(.dictation, handsFree: false)
        await settle(150)
        check("kulcs nélkül: hiba + API-kulcs lap", m.bar.isError && m.settingsTab == .apiKey && m.hubSection == .settings && !d.controller.isRecording, via: "controller", "\(m.bar) \(m.settingsTab)")
        TestMode.keychain = savedKey; m.refreshKey()
        m.bar = .idle
    }

    // MARK: Menü (menüsor; a sáv menüje ugyanezt használja)

    static func item(_ menu: NSMenu, _ prefix: String) -> Int? { menu.items.firstIndex { $0.title.hasPrefix(prefix) } }

    static func testMenu(_ d: AppDelegate) async {
        area = "Menü"
        let m = d.model
        var menu = d.menuBar.buildMenu()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        check("menüpontok", titles.count == 11 && titles.contains { $0.hasPrefix("Névjegy") } && titles.contains("Utolsó átirat másolása"), via: "menu", titles.joined(separator: " | "))

        m.hubSection = .settings
        if let i = item(menu, "Business Flow megnyitása") { menu.performActionForItem(at: i) }
        await settle()
        check("Business Flow megnyitása", m.hubSection == .home && d.hub.testWindow?.isVisible == true, via: "menu")

        // Újrapróbálás (az előző körben elbukott felvétel)
        menu = d.menuBar.buildMenu()
        if let i = item(menu, "Utolsó felvétel újrapróbálása") {
            let enabled = menu.items[i].isEnabled
            let failedID = m.history.first { $0.canRetry }?.id
            TestMode.fieldValue = ""
            TestMode.transcript = "Újrapróbált mondat."
            menu.performActionForItem(at: i)
            await settle(300)
            _ = await waitFor(5) { isIdleOrDone(m) }
            check("Utolsó felvétel újrapróbálása", enabled && TestMode.fieldValue.contains("Újrapróbált") && d.controller.lastFailedAudio == nil, via: "menu", "enabled=\(enabled) mező=\(TestMode.fieldValue.count)")
            if let failedID {
                let row = m.history.first { $0.id == failedID }
                check("újrapróbálás ugyanazt a sort frissíti", row?.status == .success && row?.text.contains("Újrapróbált") == true && row?.canCopy == true, via: "menu", row?.status.rawValue ?? "-")
            }
            menu = d.menuBar.buildMenu()
            check("újrapróbálás után a menüpont letiltva", item(menu, "Utolsó felvétel").map { !menu.items[$0].isEnabled } ?? false, via: "menu")
        } else { check("Utolsó felvétel újrapróbálása", false, via: "menu", "nincs menüpont") }

        if let i = item(menu, "Utolsó átirat beillesztése") {
            TestMode.fieldValue = ""
            menu.performActionForItem(at: i)
            await settle(200)
            check("Utolsó átirat beillesztése", menu.items[i].isEnabled && !TestMode.fieldValue.isEmpty && TestMode.fieldValue.contains(m.lastText ?? "\u{0}"), via: "menu")
        }
        if let i = item(menu, "Utolsó átirat másolása") {
            TestMode.pasteboard.clearContents()
            menu.performActionForItem(at: i)
            check("Utolsó átirat másolása", menu.items[i].isEnabled && TestMode.pasteboard.string(forType: .string) == m.lastText, via: "menu")
        }

        // Polírozás almenü — minden utasítás
        if let pi = item(menu, "Polírozás"), let sub = menu.items[pi].submenu {
            var okAll = true
            for (j, it) in sub.items.enumerated() {
                TestMode.fieldValue = "ez egy proba szoveg"
                TestMode.selection = "ez egy proba szoveg"
                TestMode.chatReply = "Kész: \(it.title)."
                sub.performActionForItem(at: j)
                await settle(250)
                _ = await waitFor(4) { TestMode.fieldValue == "Kész: \(it.title)." }
                let ok = TestMode.fieldValue == "Kész: \(it.title)." && m.lastPolish != nil && m.history.first?.kind == .polish
                okAll = okAll && ok
                if !ok { check("Polírozás: \(it.title)", false, via: "menu", TestMode.fieldValue) }
                m.bar = .idle
            }
            check("Polírozás almenü (\(sub.items.count) utasítás)", okAll, via: "menu")
            TestMode.selection = nil
            TestMode.fieldValue = ""
            d.controller.polishSelection(preset: nil)
            await settle(300)
            check("polírozás kijelölés nélkül → „Jelölj ki szöveget”", m.bar == .notice("Jelölj ki szöveget"), via: "controller", "\(m.bar)")
            m.bar = .idle
            TestMode.chatReply = "Rendben."
        }

        // Nyelv almenü
        menu = d.menuBar.buildMenu()
        if let li = item(menu, "Nyelv:"), let sub = menu.items[li].submenu {
            var okAll = true
            for (j, l) in DictationLanguage.allCases.enumerated() {
                sub.performActionForItem(at: j); await settle(60)
                okAll = okAll && m.settings.language == l
            }
            check("Nyelv almenü (3 nyelv)", okAll, via: "menu")
            m.settings.language = .auto
            menu = d.menuBar.buildMenu()
            check("menü mutatja az aktuális nyelvet", menu.items[li].title.contains("Automatikus"), via: "menu")
        }

        if let i = item(menu, "Szótár") { menu.performActionForItem(at: i) }
        await settle()
        check("Szótár…", m.hubSection == .dictionary, via: "menu")
        if let i = item(menu, "Beállítások") { menu.performActionForItem(at: i) }
        await settle()
        check("Beállítások…", m.hubSection == .settings, via: "menu")

        if let i = item(menu, "Sáv elrejtése") {
            m.settings.hideBarWhenIdle = false
            menu.performActionForItem(at: i); await settle()
            d.bar.applyVisibility(animated: false)
            let hidden = m.settings.hideBarWhenIdle && d.bar.panel.alphaValue == 0
            menu = d.menuBar.buildMenu()
            let checked = menu.items[i].state == .on
            menu.performActionForItem(at: i); await settle()
            d.bar.applyVisibility(animated: false)
            check("Sáv elrejtése, ha nem diktálok (be/ki + pipa)", hidden && checked && !m.settings.hideBarWhenIdle && d.bar.panel.alphaValue == 1, via: "menu")
        }

        if let i = item(menu, "Névjegy") { menu.performActionForItem(at: i) }
        await settle()
        let about = AboutWindowController.shared.window
        let aboutText = nodes(about?.contentView).map { $0.label + " " + $0.value + " " + $0.title }.joined(separator: " ")
        check("Névjegy", about?.title == "A Business Flow névjegye" && aboutText.contains(AboutWindowController.version), via: "menu+ax", aboutText.prefix(200).description)
        about?.orderOut(nil)

        TestMode.events = []
        if let i = item(menu, "Kilépés") { menu.performActionForItem(at: i) }
        check("Kilépés a Business Flow-ból", TestMode.took("quit"), via: "menu")
    }

    static func testPillMenu(_ d: AppDelegate) async {
        area = "Sáv menü"
        let m = d.model
        d.bar.showMenu()
        await settle(200)
        guard let pm = d.bar.pillModel, let panel = d.bar.pillMenu else { check("sáv menü megnyílik", false, via: "bar"); return }
        let expected = d.menuBar.buildMenu().items.reduce(0) { $0 + ($1.isSeparatorItem ? 0 : ($1.submenu?.items.count ?? 1)) }
        check("sáv menü megnyílik (pill, saját panel)", pm.rows.count == expected, via: "bar", "\(pm.rows.count) vs \(expected)")
        let root = panel.contentView
        check("AX: „Business Flow menü”", find("Business Flow menü", in: root) != nil, via: "ax")
        var ok = await press("Nyelv: \(m.settings.language.label): Angol", in: root)
        if !ok { ok = await press("Angol", in: root) }
        await settle()
        check("menüsor kiválasztása AX-szel (Angol)", ok && m.settings.language == .en && d.bar.pillMenu == nil, via: "ax", "ok=\(ok) lang=\(m.settings.language)")
        m.settings.language = .auto
        d.bar.showMenu(); await settle(150)
        let rootB = d.bar.pillMenu?.contentView
        _ = await press("Szótár…", in: rootB)
        check("sáv menü: Szótár…", m.hubSection == .dictionary && d.bar.pillMenu == nil, via: "ax")
        d.bar.showMenu(); await settle(100)
        d.bar.closeMenu()
        check("sáv menü bezárása", d.bar.pillMenu == nil, via: "bar")
    }

    static func testFlowBar(_ d: AppDelegate) async {
        area = "Flow-sáv"
        let m = d.model
        m.settings.hideBarWhenIdle = true
        m.bar = .idle
        d.bar.applyVisibility(animated: false)
        let hidden = d.bar.panel.alphaValue == 0
        m.bar = .processing(nil)
        d.bar.applyVisibility(animated: false)
        let shown = d.bar.panel.alphaValue == 1
        m.bar = .idle
        m.settings.hideBarWhenIdle = false
        d.bar.applyVisibility(animated: false)
        check("rejtett sáv feldolgozáskor megjelenik", hidden && shown && d.bar.panel.alphaValue == 1, via: "bar")
        let lbl = nodes(d.bar.panel.contentView).map(\.label).filter { !$0.isEmpty }
        check("sáv AX-címke", !lbl.isEmpty, via: "ax", lbl.joined(separator: " | "))
    }

    // MARK: Hub

    static func testNavigation(_ d: AppDelegate) async {
        area = "Navigáció"
        let m = d.model
        d.hub.show(.home)
        await settle(300)
        let root = d.hub.testWindow?.contentView
        for s in HubSection.allCases {
            let ok = await press(s.title, in: root)
            check("oldalsáv: \(s.title)", ok && m.hubSection == s, via: "ax", "press=\(ok) most=\(m.hubSection)")
        }
        m.hubSection = .settings
        await settle(200)
        for t in SettingsTab.allCases {
            let ok = await press(t.title, in: d.hub.testWindow?.contentView)
            check("beállítás-lap: \(t.title)", ok && m.settingsTab == t, via: "ax", "press=\(ok) most=\(m.settingsTab)")
        }
    }

    static func testHome(_ d: AppDelegate) async {
        area = "Kezdőlap"
        let m = d.model
        m.clearHistory()
        let a = HistoryItem(text: "Küldd át a kérdést holnap", rawText: "küld át a kérdést holnap", appName: "Slack", bundleID: "s", durationSeconds: 3, kind: .dictation)
        let b = HistoryItem(text: "Megjött a számla", rawText: "megjött a számla", appName: "Mail", bundleID: "m", durationSeconds: 2, kind: .dictation)
        m.addHistory(b); m.addHistory(a)
        d.hub.show(.home); await settle(300)
        let w = d.hub.testWindow
        let st = m.stats
        check("statisztika (szavak)", st.totalWords == 8, via: "model", "\(st.totalWords)")
        let txt = nodes(w?.contentView).map { $0.label + "|" + $0.value }.joined(separator: " ")
        check("statisztika a felületen", txt.contains("Összes szó") && txt.contains("\(st.totalWords)"), via: "ax", labels(w?.contentView))
        let copies = { nodes(w?.contentView).filter { $0.label == "Másolás" }.count }
        check("előzmények listája (2 sor)", copies() == 2, via: "ax", "\(copies())")
        let typed = await typeField("kerdes", placeholder: "Keresés", in: w)
        await settle(200)
        check("keresés ékezet nélkül („kerdes”)", typed && copies() == 1, via: "ax+field", "typed=\(typed) sorok=\(copies())")
        TestMode.pasteboard.clearContents()
        let copied = await press("Másolás", in: w?.contentView)
        check("másolás vágólapra", copied && TestMode.pasteboard.string(forType: .string) == a.text, via: "ax")
        let raw = await press("Nyers átirat", in: w?.contentView)
        check("nyers átirat váltás", raw && find("Formázott", in: w?.contentView) != nil, via: "ax")
        _ = await typeField("nincs ilyen", placeholder: "Keresés", in: w)
        await settle(150)
        let noHit = nodes(w?.contentView).contains { $0.label.contains("Nincs találat") || $0.value.contains("Nincs találat") }
        check("keresés: nincs találat üzenet", noHit && copies() == 0, via: "ax+field")
        _ = await typeField("", placeholder: "Keresés", in: w)
        await settle(150)
        let del = await press("Törlés", in: w?.contentView)
        await settle(150)
        check("előzmény törlése", del && m.history.count == 1, via: "ax", "\(m.history.count)")
    }

    static func testDictionary(_ d: AppDelegate) async {
        area = "Szótár"
        let m = d.model
        d.hub.show(.dictionary); await settle(300)
        let w = d.hub.testWindow
        let n0 = m.settings.dictionary.count
        let t1 = await typeField("ClickUp", placeholder: "Helyes alak (pl. ClickUp)", in: w)
        let t2 = await typeField("klikk áp, klikkap", placeholder: "Téves alakok (opcionális, vesszővel)", in: w)
        let add = await press("Szó hozzáadása", in: w?.contentView)
        let e = m.settings.dictionary.first
        check("szó hozzáadása", t1 && t2 && add && e?.term == "ClickUp" && e?.heardAs == ["klikk áp", "klikkap"] && m.settings.dictionary.count == n0 + 1, via: "ax+field", "t=\(t1)/\(t2) add=\(add) \(e?.term ?? "-")")
        let ed = await press("Szerkesztés: ClickUp", in: w?.contentView)
        let t3 = await typeField("ClickUp CRM", placeholder: "Helyes alak", in: w)
        let sv = await press("Szó mentése", in: w?.contentView)
        check("szó szerkesztése", ed && t3 && sv && m.settings.dictionary.contains { $0.term == "ClickUp CRM" && !$0.autoLearned } && m.settings.dictionary.count == n0 + 1, via: "ax+field", "ed=\(ed) t=\(t3) save=\(sv)")
        let badge = nodes(w?.contentView).contains { $0.label.contains("Automatikus") || $0.value.contains("Automatikus") }
        check("automatikusan tanult szó jelölése", badge == m.settings.dictionary.contains { $0.autoLearned }, via: "ax")
        let del = await press("Törlés: ClickUp CRM", in: w?.contentView)
        check("szó törlése", del && !m.settings.dictionary.contains { $0.term.hasPrefix("ClickUp") }, via: "ax")
        // A szótár a felismerőnek is megy (kulcsszó + helyi javítás)
        m.settings.dictionary = DictionaryEditing.insert(DictionaryEntry(term: "Shopify", heardAs: ["sopifáj"]), into: m.settings.dictionary)
        TestMode.fieldValue = ""
        _ = await dictate(d, transcript: "Megnéztem a sopifáj boltot.")
        check("szótár alkalmazása diktáláskor", TestMode.fieldValue.contains("Shopify"), via: "controller", TestMode.fieldValue)
    }

    static func testSnippets(_ d: AppDelegate) async {
        area = "Szövegrészletek"
        let m = d.model
        d.hub.show(.snippets); await settle(300)
        let w = d.hub.testWindow
        let t1 = await typeField("naptár link", placeholder: "Kulcsmondat (amit kimondasz)", in: w)
        let t2 = await typeArea("https://cal.example.com/dorottya", in: w)
        let sv = await press("Szövegrészlet mentése", in: w?.contentView)
        check("szövegrészlet hozzáadása", t1 && t2 && sv && m.settings.snippets.first?.trigger == "naptár link", via: "ax+field", "t=\(t1)/\(t2) save=\(sv)")
        let ed = await press("Szerkesztés: naptár link", in: w?.contentView)
        let t3 = await typeArea("https://cal.example.com/dorottya-30", in: w)
        let sv2 = await press("Szövegrészlet mentése", in: w?.contentView)
        check("szövegrészlet szerkesztése", ed && t3 && sv2 && m.settings.snippets.count == 1 && m.settings.snippets[0].expansion == "https://cal.example.com/dorottya-30", via: "ax+field")
        TestMode.fieldValue = ""
        _ = await dictate(d, transcript: "Naptár link.")
        check("kimondott kulcsmondat → kibontás", TestMode.fieldValue.contains("https://cal.example.com/dorottya-30"), via: "controller", TestMode.fieldValue)
        let del = await press("Törlés: naptár link", in: w?.contentView)
        check("szövegrészlet törlése", del && m.settings.snippets.isEmpty, via: "ax")
    }

    static func testStyles(_ d: AppDelegate) async {
        area = "Stílus"
        let m = d.model
        d.hub.show(.style); await settle(300)
        let root = d.hub.testWindow?.contentView
        var okAll = true
        for cat in AppCategory.allCases {
            for tone in StyleTone.allCases {
                let ok = await press("tone-\(cat.rawValue)-\(tone.rawValue)", in: root)
                okAll = okAll && ok && m.settings.tone(for: cat) == tone
            }
        }
        check("hangnem minden kategóriában (\(AppCategory.allCases.count)×\(StyleTone.allCases.count))", okAll, via: "ax")
        m.settings.styles[.personal] = .veryCasual
        TestMode.fieldValue = ""
        _ = await dictate(d, transcript: "Szia, mikor jössz?")
        check("stílus érvényesül (stub-kontextus: egyéb → formális)", !TestMode.fieldValue.isEmpty, via: "controller")
        m.settings.styles = AppSettings().styles
    }

    static func testPolish(_ d: AppDelegate) async {
        area = "Polírozás"
        let m = d.model
        d.hub.show(.polish); await settle(300)
        let w = d.hub.testWindow
        var okAll = true
        for p in m.settings.allPolishPresets {
            let ok = await press("Utasítás: \(p.name)", in: w?.contentView)
            okAll = okAll && ok && m.settings.defaultPolishID == p.id
        }
        check("alapértelmezett utasítás választása", okAll, via: "ax")
        let t1 = await typeField("Teszt utasítás", placeholder: "Név (pl. LinkedIn-poszt)", in: w)
        let t2 = await typeArea("Írd át csupa nagybetűsre.", in: w)
        let add = await press("Saját utasítás hozzáadása", in: w?.contentView)
        check("saját utasítás hozzáadása", t1 && t2 && add && m.settings.customPolish.contains { $0.name == "Teszt utasítás" }, via: "ax+field", "t=\(t1)/\(t2) add=\(add)")
        let menu = d.menuBar.buildMenu()
        let inMenu = item(menu, "Polírozás").flatMap { menu.items[$0].submenu?.items.contains { $0.title == "Teszt utasítás" } } ?? false
        check("saját utasítás a menüben", inMenu, via: "menu")
        _ = await press("Utasítás: Teszt utasítás", in: w?.contentView)
        let del = await press("Törlés: Teszt utasítás", in: w?.contentView)
        check("saját utasítás törlése (alapértelmezett visszaáll)", del && m.settings.customPolish.isEmpty && m.settings.defaultPolishID == "clean", via: "ax")
    }

    static func testGeneral(_ d: AppDelegate) async {
        area = "Általános"
        let m = d.model
        m.openSettings(.general); await settle(300)
        let root = { d.hub.testWindow?.contentView }
        let toggles: [(String, WritableKeyPath<AppSettings, Bool>)] = [
            ("Okos formázás", \.smartFormatting), ("Környezetfigyelés", \.contextAwareness), ("Szótár automatikus tanulása", \.autoLearnDictionary),
            ("Töltelékszavak eltávolítása", \.removeFillers), ("Hangparancsok", \.voiceCommands), ("Zene és média némítása diktálás közben", \.muteMedia),
            ("Hangok", \.sounds), ("Sáv elrejtése, ha nem diktálsz", \.hideBarWhenIdle),
        ]
        for (label, kp) in toggles {
            let v0 = m.settings[keyPath: kp]
            let a = await press(label, in: root())
            let v1 = m.settings[keyPath: kp]
            let b = await press(label, in: root())
            check("kapcsoló: \(label)", a && b && v1 == !v0 && m.settings[keyPath: kp] == v0, via: "ax")
        }
        // Indítás bejelentkezéskor
        TestMode.events = []
        let l1 = await press("Indítás bejelentkezéskor", in: root())
        let on = m.settings.launchAtLogin && LoginItem.enabled && TestMode.took("login:true")
        let l2 = await press("Indítás bejelentkezéskor", in: root())
        check("Indítás bejelentkezéskor (be/ki)", l1 && l2 && on && !m.settings.launchAtLogin && TestMode.took("login:false"), via: "ax", TestMode.events.joined(separator: ","))
        // Némítás és hangjelzés diktálás közben
        m.settings.muteMedia = true; m.settings.sounds = true
        TestMode.events = []
        _ = await dictate(d, transcript: "Teszt mondat a némításhoz.")
        await settle(200)
        let ev = TestMode.events
        check("média némítása felvétel alatt és visszaállítás", ev.firstIndex(of: "mute").map { i in ev[i...].contains("unmute") } ?? false, via: "controller", ev.joined(separator: ","))
        check("hangjelzések (start/stop)", ev.contains { $0.hasPrefix("sound:start") || $0 == "sound:start" } && ev.contains { $0.hasPrefix("sound:stop") }, via: "controller", ev.joined(separator: ","))
        m.settings.muteMedia = false; m.settings.sounds = false
        TestMode.events = []
        _ = await dictate(d, transcript: "Teszt mondat némítás nélkül.")
        check("kikapcsolva nincs némítás és hang", !TestMode.events.contains("mute") && !TestMode.events.contains { $0.hasPrefix("sound:") }, via: "controller", TestMode.events.joined(separator: ","))
        m.settings.muteMedia = true; m.settings.sounds = true
        // Töltelékszavak
        TestMode.fieldValue = ""
        _ = await dictate(d, transcript: "Öhm holnap ö találkozunk.")
        check("töltelékszavak eltávolítása", !TestMode.fieldValue.lowercased().contains("öhm") && TestMode.fieldValue.contains("találkozunk"), via: "controller", TestMode.fieldValue)
    }

    static func testLanguages(_ d: AppDelegate) async {
        area = "Nyelvek"
        let m = d.model
        m.openSettings(.languages); await settle(300)
        for l in DictationLanguage.allCases.reversed() {
            let ok = await press("Nyelv: \(l.label)", in: d.hub.testWindow?.contentView)
            check("nyelv: \(l.label)", ok && m.settings.language == l, via: "ax")
        }
    }

    static func testMicrophone(_ d: AppDelegate) async {
        area = "Mikrofon"
        let m = d.model
        m.openSettings(.microphone); await settle(400)
        let root = { d.hub.testWindow?.contentView }
        let refresh = await press("Mikrofonlista frissítése", in: root())
        check("mikrofonlista frissítése", refresh, via: "ax")
        let devs = AudioDevices.inputs()
        if let dev = devs.first {
            let ok = await press("Mikrofon: \(dev.name)", in: root())
            check("mikrofon választása (\(devs.count) eszköz)", ok && m.settings.microphoneUID == dev.uid, via: "ax")
        } else {
            check("mikrofon választása", true, via: "skip", "nincs bemeneti eszköz")
        }
        let def = await press("Mikrofon: Rendszer alapértelmezett", in: root())
        check("rendszer alapértelmezett mikrofon", def && m.settings.microphoneUID == nil, via: "ax")
    }

    static func testShortcuts(_ d: AppDelegate) async {
        area = "Billentyűparancsok"
        let m = d.model
        m.openSettings(.shortcuts); await settle(400)
        let root = { d.hub.testWindow?.contentView }
        m.settings.shortcuts = .default
        await settle(150)
        // Egérgomb (4.) hozzáadása a diktáláshoz
        let a1 = await press("Parancs hozzáadása: \(ShortcutAction.pushToTalk.label)", in: root())
        let rec = d.monitor.recorder
        rec?(.mouse(3))
        await settle(150)
        let hasMouse = m.settings.shortcuts.triggers(for: .pushToTalk).contains(.mouse(button: 3))
        check("rögzítés: egér 4. gomb (vissza)", a1 && rec != nil && hasMouse && d.monitor.recorder == nil, via: "ax+recorder", "press=\(a1) rec=\(rec != nil)")
        check("a motor is megkapja az új parancsot", d.monitor.engine.shortcuts == m.settings.shortcuts, via: "model")
        // Billentyűkombináció
        let a2 = await press("Parancs hozzáadása: \(ShortcutAction.pasteLast.label)", in: root())
        d.monitor.recorder?(.key(9, [.control, .option]))
        await settle(150)
        check("rögzítés: billentyűkombináció (⌃⌥V)", a2 && m.settings.shortcuts.triggers(for: .pasteLast).contains(.combo(keyCode: 9, modifiers: [.control, .option])), via: "ax+recorder")
        // Csak módosító (nyomva tartás)
        let a3 = await press("Parancs hozzáadása: \(ShortcutAction.command.label)", in: root())
        d.monitor.recorder?(.modifiers([.rightOption]))
        d.monitor.recorder?(.modifiers([]))
        await settle(150)
        check("rögzítés: módosító nyomva tartva (jobb ⌥)", a3 && m.settings.shortcuts.triggers(for: .command).contains(.hold([.rightOption])), via: "ax+recorder")
        // Megszakítás gombbal és Esc-pel
        let before = m.settings.shortcuts
        _ = await press("Parancs hozzáadása: \(ShortcutAction.polish.label)", in: root())
        let cancel = await press("Rögzítés megszakítása", in: root())
        check("rögzítés megszakítása (Mégse)", cancel && d.monitor.recorder == nil && m.settings.shortcuts == before, via: "ax")
        _ = await press("Parancs hozzáadása: \(ShortcutAction.polish.label)", in: root())
        d.monitor.recorder?(.key(53, []))
        await settle(150)
        check("rögzítés megszakítása (Esc)", d.monitor.recorder == nil && m.settings.shortcuts == before, via: "ax+recorder")
        // Törlés
        let t = ShortcutTrigger.mouse(button: 3)
        let del = await press("Parancs törlése: \(ShortcutAction.pushToTalk.label) \(t.label)", in: root())
        check("parancs törlése", del && !m.settings.shortcuts.triggers(for: .pushToTalk).contains(t), via: "ax")
        // Alapértelmezés
        let reset = await press("Parancsok alapértelmezése", in: root())
        check("alapértelmezések visszaállítása", reset && m.settings.shortcuts == .default, via: "ax")
        TestMode.events = []
        let kb = await press("Billentyűzet-beállítások megnyitása", in: root())
        check("billentyűzet-beállítások megnyitása", kb && TestMode.took("open:keyboard"), via: "ax")
        // Az egérgomb valóban indítja a diktálást (motor szintjén)
        var s = m.settings.shortcuts
        s.set(s.triggers(for: .pushToTalk) + [.mouse(button: 3)], for: .pushToTalk)
        m.settings.shortcuts = s
        let actions = d.monitor.engine.mouseDown(3, at: 100).actions
        check("egér 4. gomb (vissza) → diktálás indul", actions.contains { if case .start(.dictation, _) = $0 { return true }; return false }, via: "engine", "\(actions)")
        _ = d.monitor.engine.mouseUp(3, at: 100.1)
        d.monitor.engine.reset()
        m.settings.shortcuts = .default
    }

    static func testPermissions(_ d: AppDelegate) async {
        area = "Engedélyek"
        let m = d.model
        TestMode.permissionsGranted = false
        m.permissionTick += 1
        m.openSettings(.permissions); await settle(300)
        let root = { d.hub.testWindow?.contentView }
        TestMode.events = []
        let a = await press("Engedélyezés: Mikrofon", in: root())
        let b = await press("Engedélyezés: Kisegítő hozzáférés", in: root())
        let c = await press("Engedélyezés: Bemenetfigyelés", in: root())
        check("mikrofon engedély gomb", a && (TestMode.took("open:Privacy_Microphone") || TestMode.took("perm:request-mic")), via: "ax", TestMode.events.joined(separator: ","))
        check("kisegítő hozzáférés gomb", b && TestMode.took("perm:prompt-ax") && TestMode.took("open:Privacy_Accessibility"), via: "ax", TestMode.events.joined(separator: ","))
        check("bemenetfigyelés gomb", c && TestMode.took("perm:request-input") && TestMode.took("open:Privacy_ListenEvent"), via: "ax", TestMode.events.joined(separator: ","))
        TestMode.permissionsGranted = true
        let t0 = m.permissionTick
        let r = await press("Engedélyek frissítése", in: root())
        await settle(150)
        let granted = nodes(root()).filter { $0.label == "Engedélyezve" || $0.value == "Engedélyezve" || $0.title == "Engedélyezve" }.count
        check("állapot frissítése → mind engedélyezve", r && m.permissionTick > t0 && find("Engedélyezés: Mikrofon", in: root()) == nil && granted >= 3, via: "ax", "granted=\(granted)")
    }

    static func testAPIKey(_ d: AppDelegate) async {
        area = "API-kulcs"
        let m = d.model
        m.openSettings(.apiKey); await settle(300)
        let w = d.hub.testWindow
        let root = { w?.contentView }
        let del = await press("API-kulcs törlése", in: root())
        check("kulcs törlése", del && !m.hasAPIKey && TestMode.keychain == nil, via: "ax")
        let fake = "sk-selftest-pasted-0123456789abcdef"
        let t = await typeField(fake, placeholder: "sk-…", in: w)
        let sv = await press("API-kulcs mentése", in: root())
        check("kulcs beillesztése és mentése", t && sv && TestMode.keychain == fake && m.hasAPIKey, via: "ax+field", "t=\(t) save=\(sv)")
        _ = await press("API-kulcs törlése", in: root())
        let env = (tempDir ?? FileManager.default.temporaryDirectory).appendingPathComponent("selftest.env")
        let envKey = "sk-selftest-env-abcdefghijklmnopqrstuvwxyz"
        try? "# önteszt\nOTHER=1\nOPENAI_API_KEY=\"\(envKey)\"\n".write(to: env, atomically: true, encoding: .utf8)
        TestMode.envFile = env
        let pick = await press(".env fájl kiválasztása", in: root())
        let imp = await press("Kulcs importálása", in: root())
        check(".env import a Kulcskarikába", pick && imp && TestMode.keychain == envKey && m.hasAPIKey, via: "ax", "pick=\(pick) imp=\(imp)")
        try? "NOTHING=1\n".write(to: env, atomically: true, encoding: .utf8)
        let pick2 = await press(".env fájl kiválasztása", in: root())
        let msg = await waitFor(2) { nodes(root()).contains { ($0.label + " " + $0.value + " " + $0.title).contains("Nem találtam OpenAI") } }
        check(".env kulcs nélkül → üzenet", pick2 && msg, via: "ax", "pick=\(pick2)")
        try? FileManager.default.removeItem(at: env)
        TestMode.keychain = "sk-selftest-not-a-real-key-0000000000"; m.refreshKey()
    }

    static func testAdvanced(_ d: AppDelegate) async {
        area = "Haladó"
        let m = d.model
        m.openSettings(.advanced); await settle(300)
        let w = d.hub.testWindow
        let root = { w?.contentView }
        let orig = m.settings.chatModel
        let t = await type("gpt-4.1-mini", in: w) { $0.stringValue == orig }
        check("modell mező szerkesztése", t && m.settings.chatModel == "gpt-4.1-mini", via: "ax+field", "t=\(t) \(m.settings.chatModel)")
        m.settings.chatModel = orig
        var okAll = true
        for r in HistoryRetention.allCases.reversed() {
            let ok = await press("Megőrzés: \(r.label)", in: root())
            okAll = okAll && ok && m.settings.retention == r
        }
        check("előzmények megőrzése (\(HistoryRetention.allCases.count) opció)", okAll, via: "ax")
        // „Soha”: nem ment, de az utolsó átirat beilleszthető marad
        m.settings.retention = .never
        let hc = m.history.count
        _ = await dictate(d, transcript: "Ezt nem mentjük el.")
        check("„soha” megőrzés: nem kerül előzménybe, de beilleszthető", m.history.count == hc && m.lastText?.contains("nem mentjük") == true, via: "controller")
        m.settings.retention = .forever
        m.addHistory(HistoryItem(text: "x", rawText: "x", appName: "a", bundleID: "", durationSeconds: 1, kind: .dictation))
        let clr = await press("Előzmények törlése", in: root())
        check("előzmények törlése", clr && m.history.isEmpty, via: "ax")
        TestMode.events = []
        let open = await press("Adatmappa megnyitása", in: root())
        check("adatmappa megnyitása", open && TestMode.took("open:"), via: "ax", TestMode.events.joined(separator: ","))
    }

    static func testOnboarding(_ d: AppDelegate) async {
        area = "Első lépések"
        let m = d.model
        TestMode.permissionsGranted = false
        TestMode.keychain = nil; m.refreshKey()
        m.clearHistory(); m.lastTranscript = nil
        m.permissionTick += 1
        d.hub.show(.home); await settle(300)
        let root = { d.hub.testWindow?.contentView }
        check("lista megjelenik új telepítésnél", find("Első lépések", in: root()) != nil && !Onboarding.complete(m), via: "ax")
        let st = Onboarding.state(m)
        check("állapot: 0/5 kész", st.doneCount == 0 && st.next == 0, via: "model", "\(st.doneCount)")
        let setup = nodes(root()).filter { $0.label.hasPrefix("Első lépés beállítása:") }
        if let first = setup.first {
            _ = first.obj.accessibilityPerformPress?()
            await settle(200)
            check("„Beállítás” → a megfelelő lap (API-kulcs)", m.hubSection == .settings && m.settingsTab == .apiKey, via: "ax", "\(m.settingsTab)")
        } else { check("„Beállítás” gombok", false, via: "ax", "nincs gomb") }
        TestMode.permissionsGranted = true
        TestMode.keychain = "sk-selftest-not-a-real-key-0000000000"; m.refreshKey()
        _ = await dictate(d, transcript: "Az első diktálásom.")
        m.permissionTick += 1
        d.hub.show(.home); await settle(300)
        check("minden lépés kész → a lista eltűnik", Onboarding.complete(m) && find("Első lépések", in: root()) == nil, via: "ax")
    }
}
