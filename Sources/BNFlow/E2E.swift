import AppKit
import ApplicationServices
import BNFlowCore

/// Élő végponttól-végpontig teszt: `say`-jel szintetizált magyar diktálás → a valódi DictationController
/// (valódi OpenAI átírás + formázás a Kulcskarika-kulccsal) → valódi beillesztés a fókuszban lévő TextEdit dokumentumba
/// → visszaolvasás AX-szel. Indítás: `open -n "Business Flow.app" --args --e2e <kimenet.json>`.
/// A mikrofon helyett a szintetizált hang kerül a felvevőbe; minden más a valódi útvonal. Elkülönített adatmappa,
/// így az előzmények nem szennyeződnek. Titkot nem ír ki.
enum E2E {
    nonisolated(unsafe) static var isOn = false
    nonisolated(unsafe) static var outPath = "/tmp/bf-e2e.json"
    /// A felvevő ezt adja vissza a mikrofon helyett.
    nonisolated(unsafe) static var audio: [Float]?
    /// Mesterséges késleltetés az átírás előtt (elakadás-szimuláció).
    nonisolated(unsafe) static var delayBeforeTranscribe: Double = 0
    nonisolated(unsafe) static var marks: [String: Date] = [:]
    nonisolated(unsafe) static var raw = "", formatted = "", pasted: Bool?
    static func mark(_ k: String) { if isOn { marks[k] = Date() } }

    struct U { let id, say, expect: String }
    static let utterances: [U] = [
        U(id: "rovid", say: "Rendben, holnap hívlak.", expect: "Rendben, holnap hívlak."),
        U(id: "kerdes", say: "Át tudnád küldeni a szerződést még ma délután?", expect: "Át tudnád küldeni a szerződést még ma délután?"),
        U(id: "szamok", say: "Az ajánlat összege 2 450 000 forint, a határidő március 15.", expect: "Az ajánlat összege 2 450 000 forint, a határidő március 15."),
        U(id: "nevek", say: "Kovács Péter és Szabó Anna csütörtökön jönnek Budapestre.", expect: "Kovács Péter és Szabó Anna csütörtökön jönnek Budapestre."),
        U(id: "ceg", say: "A Business Native csapata jövő héten bemutatja az új verziót.", expect: "A Business Native csapata jövő héten bemutatja az új verziót."),
        U(id: "irasjel-szo", say: "Szia Gábor vessző köszönöm a gyors választ pont", expect: "Szia Gábor, köszönöm a gyors választ."),
        U(id: "kerdojel-szo", say: "Mikor érsz rá a héten kérdőjel", expect: "Mikor érsz rá a héten?"),
        U(id: "ujsor", say: "Kedves Ügyfelünk vessző új sor köszönjük a megrendelését pont", expect: "Kedves Ügyfelünk,\nköszönjük a megrendelését."),
        U(id: "javitas", say: "Találkozzunk kedden, nem, inkább szerdán tíz órakor.", expect: "Találkozzunk szerdán tíz órakor."),
        U(id: "javitas2", say: "Küldd el Péternek, bocsánat, Annának a jelentést.", expect: "Küldd el Annának a jelentést."),
        U(id: "szazalek", say: "Az árbevétel 12 százalékkal nőtt az előző negyedévhez képest.", expect: "Az árbevétel 12%-kal nőtt az előző negyedévhez képest."),
        U(id: "ido", say: "A megbeszélés reggel fél kilenckor kezdődik a második emeleten.", expect: "A megbeszélés reggel fél kilenckor kezdődik a második emeleten."),
        U(id: "email", say: "Írj nekem az info kukac pelda pont hu címre.", expect: "Írj nekem az info@pelda.hu címre."),
        U(id: "hosszu", say: "Szeretném összefoglalni a mai megbeszélést. Megállapodtunk, hogy a projekt első fázisa december végéig lezárul, a tesztelést januárban kezdjük, és a végleges átadás február közepén várható. Kérlek, jelezzetek, ha valami kimaradt.", expect: "Szeretném összefoglalni a mai megbeszélést. Megállapodtunk, hogy a projekt első fázisa december végéig lezárul, a tesztelést januárban kezdjük, és a végleges átadás február közepén várható. Kérlek, jelezzetek, ha valami kimaradt."),
        U(id: "felsorolas", say: "Holnapra kell tej, kenyér, tojás és egy kiló alma.", expect: "Holnapra kell tej, kenyér, tojás és egy kiló alma."),
        U(id: "angol-szo", say: "A meetingen átnézzük a dashboardot és a KPI-okat.", expect: "A meetingen átnézzük a dashboardot és a KPI-okat."),
        U(id: "ekezet", say: "Őszintén szólva üdítő volt a tűzijáték a hídon.", expect: "Őszintén szólva üdítő volt a tűzijáték a hídon."),
        U(id: "rovid2", say: "Köszönöm szépen.", expect: "Köszönöm szépen."),
    ]

    static func synth(_ text: String) -> [Float]? {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("bf-e2e-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: f) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Tünde", "-o", f.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0, let d = try? Data(contentsOf: f), let w = WAV.decode(d) else { return nil }
        // Kis csend elöl-hátul, mint egy valódi felvételnél.
        let pad = [Float](repeating: 0, count: 4_000)
        return pad + w.samples + pad
    }

    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    @MainActor static func focusedValue() -> (String?, AXUIElement?) {
        let t = TextInserter.currentTarget()
        return (TextInserter.value(t), t.element)
    }
    @MainActor static func clearField() {
        let (_, el) = focusedValue()
        if let el { AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, "" as CFString) }
    }

    @MainActor static func waitIdle(_ c: DictationController, timeout: Double = 60) async -> Bool {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if !c.isBusy && !c.isRecording { return true }
            await sleep(0.05)
        }
        return false
    }

    static func ms(_ a: String, _ b: String) -> Int? {
        guard let x = marks[a], let y = marks[b] else { return nil }
        return Int(y.timeIntervalSince(x) * 1000)
    }

    @MainActor static func run(_ d: AppDelegate) async -> Int32 {
        var rep: [String: Any] = ["version": AppVersion.current, "date": ISO8601DateFormatter().string(from: Date())]
        let c: DictationController = d.controller!
        let m = AppModel.shared
        rep["accessibility"] = AXIsProcessTrusted()
        rep["microphone"] = Permissions.microphone == .authorized
        rep["frontApp"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        rep["settings"] = ["smartFormatting": m.settings.smartFormatting, "chatModel": m.settings.chatModel, "transcriptionModel": m.settings.transcriptionModel, "sounds": m.settings.sounds]
        func finish(_ code: Int32) -> Int32 {
            if let data = try? JSONSerialization.data(withJSONObject: rep, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: outPath)) }
            return code
        }
        // 1) Valódi beillesztés (Cmd+V a vágólapon át) + visszaolvasás, kulcs nélkül is.
        let (v0, el0) = focusedValue()
        rep["fieldReadable"] = v0 != nil
        guard el0 != nil, v0 != nil else { rep["blocked"] = "nincs olvasható fókuszált szövegmező (TextEdit nincs elöl / képernyő zárolva / nincs AX)"; return finish(3) }
        var ins: [[String: Any]] = []
        let pbBefore = NSPasteboard.general.changeCount
        for u in utterances {
            clearField(); await sleep(0.25)
            let t = TextInserter.currentTarget()
            let t0 = Date()
            let res = await TextInserter.insertVerified(u.expect, into: t)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            await sleep(0.2)
            let got = (focusedValue().0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ins.append(["id": u.id, "pasted": res.pasted, "match": got == u.expect, "ms": ms])
        }
        rep["insertOnly"] = ["n": ins.count, "pasted": ins.filter { $0["pasted"] as? Bool == true }.count,
                             "exactReadback": ins.filter { $0["match"] as? Bool == true }.count,
                             "medianMs": ins.compactMap { $0["ms"] as? Int }.sorted()[ins.count / 2], "cases": ins,
                             "pasteboardChanges": NSPasteboard.general.changeCount - pbBefore]
        clearField()

        guard m.hasAPIKey else { rep["blocked"] = "nincs kulcs a Kulcskarikában"; return finish(2) }
        // A Kulcskarika ACL-je ad-hoc aláírásnál a binárishoz kötött: új build után jóváhagyó ablak jöhet, ami szinkron blokkol.
        final class R: @unchecked Sendable { var done = false; var ok = false }
        let r = R()
        Thread.detachNewThread { r.ok = Keychain.read(interactive: false) != nil; r.done = true }
        let t0 = Date()
        while !r.done && Date().timeIntervalSince(t0) < 8 { await sleep(0.1) }
        if !r.done || !r.ok {
            rep["blocked"] = r.done ? "kulcs nem olvasható" : "Kulcskarika-jóváhagyó ablak jelent meg (8 mp alatt nem jött válasz) – senki nincs a gépnél, kihagyva"
            return finish(2)
        }
        var cases: [[String: Any]] = []
        var werSum = 0.0, rawWerSum = 0.0, ok = 0, exact = 0
        var totals: [Int] = []
        for u in utterances {
            guard let a = synth(u.say) else { cases.append(["id": u.id, "error": "say sikertelen"]); continue }
            clearField(); await sleep(0.3)
            audio = a; marks = [:]; raw = ""; formatted = ""; pasted = nil
            mark("start"); c.start(.dictation, handsFree: true)
            await sleep(0.4)
            mark("stop"); c.stop()
            let idle = await waitIdle(c)
            mark("idle")
            await sleep(0.3)
            let (val, _) = focusedValue()
            let got = (val ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let w = EvalScoring.wer(reference: u.expect, hypothesis: got)
            let rw = EvalScoring.wer(reference: u.expect, hypothesis: raw)
            let isExact = got == u.expect
            werSum += w; rawWerSum += rw; if pasted == true && got == formatted.trimmingCharacters(in: .whitespacesAndNewlines) { ok += 1 }; if isExact { exact += 1 }
            let total = ms("stop", "inserted") ?? -1; if total >= 0 { totals.append(total) }
            cases.append(["id": u.id, "expect": u.expect, "raw": raw, "formatted": formatted, "document": got, "wer": w, "rawWer": rw,
                          "exact": isExact, "pasted": pasted as Any, "idle": idle,
                          "ms_transcribe": ms("stop", "transcribed") ?? -1, "ms_format": ms("transcribed", "formatted") ?? -1,
                          "ms_insert": ms("formatted", "inserted") ?? -1, "ms_total": total, "bar": "\(m.bar)"])
        }
        let n = Double(max(1, cases.count))
        totals.sort()
        rep["summary"] = ["n": cases.count, "meanWER": werSum / n, "meanRawWER": rawWerSum / n, "insertedAndVerified": ok, "exact": exact,
                          "medianTotalMs": totals.isEmpty ? -1 : totals[totals.count / 2], "maxTotalMs": totals.last ?? -1]
        rep["cases"] = cases

        // Elakadás-helyreállítás valódi hanggal: az átírás 6 mp-ig „lóg”, 3,5 mp-nél új nyomás → megszakítás és új felvétel.
        var rec: [String: Any] = [:]
        if let a = synth("Ez a helyreállítási teszt.") {
            clearField(); await sleep(0.3)
            audio = a; delayBeforeTranscribe = 6
            c.start(.dictation, handsFree: true); await sleep(0.4); c.stop()
            await sleep(3.5)
            rec["busyBeforePress"] = c.isBusy
            delayBeforeTranscribe = 0
            c.start(.dictation, handsFree: true)
            rec["recordingAfterPress"] = c.isRecording
            rec["lastFailedKept"] = c.lastFailedAudio != nil
            await sleep(0.4); c.stop()
            rec["idle"] = await waitIdle(c)
            await sleep(7) // a megszakított régi feladat se illesszen be utólag
            let (val, _) = focusedValue()
            let got = (val ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            rec["document"] = got
            rec["ok"] = got == "Ez a helyreállítási teszt."
        }
        rep["stuckRecovery"] = rec

        // Ismételt indítás/leállítás valódi hanggal: 8 teljes diktálás + 8 indítás/megszakítás egymás után.
        var cyc: [String: Any] = [:]
        if let a = synth("Teszt.") {
            clearField(); await sleep(0.3)
            audio = a
            var idleAll = true
            for i in 0..<8 {
                c.start(.dictation, handsFree: true); await sleep(0.25); c.cancel()
                c.start(.dictation, handsFree: true); await sleep(0.25); c.stop()
                if !(await waitIdle(c)) { idleAll = false; cyc["stuckAt"] = i }
                await sleep(0.2)
            }
            await sleep(0.5)
            let (val, _) = focusedValue()
            let got = val ?? ""
            cyc["insertions"] = got.components(separatedBy: "Teszt").count - 1
            cyc["expected"] = 8
            cyc["allIdle"] = idleAll
            cyc["barIdle"] = m.bar == .idle
        }
        rep["cycles"] = cyc
        audio = nil
        clearField()
        return finish(0)
    }
}
