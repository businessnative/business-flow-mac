import Foundation
import SwiftUI
import BNFlowCore

/// Meeting-jegyzetelő ütemező: iCal-figyelés → vendégként csatlakozás (Node/Playwright segéd) → átirat → összefoglaló.
/// Az MCP-szerver és a `bflow` CLI ugyanebbe a mappába ír/olvas (lásd docs/MEETINGS.md); kulcsot sosem kapnak.
@MainActor
final class MeetingService: ObservableObject {
    static let shared = MeetingService()
    static let icsSecretName = "google_calendar_ics"

    @Published private(set) var upcoming: [MeetingEvent] = []
    @Published private(set) var status: String = "Kikapcsolva"
    @Published private(set) var activeID: String? = nil
    @Published var hasCalendar = false

    private weak var model: AppModel?
    private var timer: Timer?
    private var lastFetch: Date = .distantPast
    private var handled = Set<String>()
    private var helper: Process?
    private let router = AIRouter()

    var notesFolder: URL { MeetingNotes.defaultFolder }
    var queueFolder: URL { notesFolder.appendingPathComponent(".queue", isDirectory: true) }

    func start(model: AppModel) {
        guard !TestMode.isOn else { return }
        self.model = model
        hasCalendar = Keychain.store.get(Self.icsSecretName) != nil
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in await MeetingService.shared.tick() } }
        Task { await tick() }
    }

    func setCalendarURL(_ s: String) {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.store.set(Self.icsSecretName, v.isEmpty ? nil : v)
        hasCalendar = !v.isEmpty; lastFetch = .distantPast
        Task { await tick() }
    }

    func toggleSkip(_ e: MeetingEvent) {
        guard let m = model else { return }
        if let i = m.settings.skippedMeetings.firstIndex(of: e.id) { m.settings.skippedMeetings.remove(at: i) }
        else { m.settings.skippedMeetings.append(e.id) }
    }
    func isSkipped(_ e: MeetingEvent) -> Bool { model?.settings.skippedMeetings.contains(e.id) ?? false }

    func tick() async {
        guard let m = model else { return }
        guard m.settings.meetingsEnabled else { status = "Kikapcsolva"; return }
        try? FileManager.default.createDirectory(at: queueFolder, withIntermediateDirectories: true)
        if Date().timeIntervalSince(lastFetch) > 300 { await refresh() }
        guard activeID == nil else { return }
        // 1) Kézi kérés (MCP / CLI): .queue/*.json
        if let req = nextQueued() { await run(req); return }
        // 2) Naptár: kezdés előtt 1 perccel, a vége előtt
        let now = Date()
        if let e = upcoming.first(where: { $0.platform.joinSupported && !isSkipped($0) && !handled.contains($0.id)
            && $0.start.addingTimeInterval(-60) <= now && now < $0.end.addingTimeInterval(-60) }) {
            handled.insert(e.id); await run(e)
        }
    }

    func refresh() async {
        lastFetch = Date()
        guard let s = Keychain.store.get(Self.icsSecretName), let url = URL(string: s), url.scheme == "https" else {
            status = hasCalendar ? "Érvénytelen naptár-cím" : "Nincs naptár beállítva"; upcoming = []; return
        }
        var r = URLRequest(url: url); r.timeoutInterval = 20
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let text = String(data: d, encoding: .utf8) else { status = "Naptár nem elérhető"; return }
            let now = Date()
            upcoming = ICS.meetings(text, from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(7 * 86_400)).filter { $0.end > now }
            status = "Figyelés: \(upcoming.count) online meeting a következő 7 napban"
        } catch { status = "Naptár nem elérhető" }   // a cím (titok) soha nem kerül naplóba
    }

    private func nextQueued() -> MeetingEvent? {
        let files = (try? FileManager.default.contentsOfDirectory(at: queueFolder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path } ?? []
        for f in files {
            defer { try? FileManager.default.removeItem(at: f) }
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let us = o["url"] as? String, let u = URL(string: us), let p = MeetingLinks.platform(of: u), p.joinSupported else { continue }
            let now = Date(), mins = (o["maxMinutes"] as? Double) ?? 120
            return MeetingEvent(uid: "manual-\(Int(now.timeIntervalSince1970))", title: (o["title"] as? String) ?? "Kézi meeting", start: now, end: now.addingTimeInterval(mins * 60), url: u, platform: p)
        }
        return nil
    }

    // MARK: Futtatás

    static func helperDir() -> URL? {
        var c: [URL] = []
        if let e = ProcessInfo.processInfo.environment["BNFLOW_MEETINGS_DIR"] { c.append(URL(fileURLWithPath: e)) }
        c.append(AppPaths.supportDirectory.appendingPathComponent("meetings"))
        c.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/bn-flow-mac/meetings"))
        return c.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("node_modules/playwright-core").path) }
    }
    static func nodePath() -> String? { ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    private func run(_ e: MeetingEvent) async {
        guard let m = model else { return }
        let dir = notesFolder.appendingPathComponent(MeetingNotes.slug(e), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let box = MetaBox(MeetingNotes.Meta(event: e), dir: dir)
        func save() { box.save() }
        guard let hd = Self.helperDir(), let node = Self.nodePath() else { box.meta.status = "error: helper not installed"; save(); status = "A csatlakozó segéd nincs telepítve (lásd docs/MEETINGS.md)"; return }
        activeID = e.id; status = "Csatlakozás: \(e.title)"; box.meta.status = "joining"; save()
        let pcm = dir.appendingPathComponent("audio.pcm")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [hd.appendingPathComponent("helper/join.mjs").path, "--url", e.url.absoluteString, "--name", m.settings.meetingBotName,
                       "--out", pcm.path, "--until", String(Int(e.end.addingTimeInterval(15 * 60).timeIntervalSince1970))]
        p.currentDirectoryURL = hd
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") where line.hasPrefix("STATUS ") {
                let st = String(line.dropFirst(7))
                Task { @MainActor in
                    box.meta.status = st; if st == "in-meeting" { box.meta.joinedAt = Date() }; box.save()
                    MeetingService.shared.status = "\(e.title): \(Self.label(st))"
                }
            }
        }
        helper = p
        let exited = AsyncStream<Void> { c in p.terminationHandler = { _ in c.yield(); c.finish() } }
        do { try p.run() } catch { box.meta.status = "error: node"; save(); activeID = nil; helper = nil; return }
        for await _ in exited { break }
        out.fileHandleForReading.readabilityHandler = nil
        helper = nil
        box.meta.leftAt = Date()
        await process(dir: dir, pcm: pcm, box: box)
        activeID = nil
    }

    static func label(_ s: String) -> String {
        switch s {
        case "joining": return "csatlakozás…"
        case "lobby": return "várakozás a beengedésre"
        case "in-meeting": return "jegyzetel"
        case "denied": return "nem engedték be"
        case "ended": return "véget ért"
        default: return s
        }
    }

    func stopActive() { helper?.interrupt() }   // SIGINT → a segéd lezárja a felvételt és kilép

    private func process(dir: URL, pcm: URL, box: MetaBox) async {
        func save() { box.save() }
        let capText = (try? String(contentsOf: dir.appendingPathComponent("captions.jsonl"), encoding: .utf8)) ?? ""
        let caps = MeetingCaptions.parse(capText)
        let people = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: dir.appendingPathComponent("participants.json")))) ?? []
        guard let m = model, let data = try? Data(contentsOf: pcm), data.count > MeetingAudio.sampleRate * 2 * 5 else {
            // Tartalék: ha nincs hang, de van Meet-felirat, abból lesz átirat és összefoglaló.
            if !caps.isEmpty, let m = model {
                try? MeetingNotes.transcriptMarkdown(box.meta, segments: [], captions: caps, participants: people).write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
                await summarize(dir: dir, box: box, settings: m.settings, transcript: MeetingCaptions.markdown(caps), captions: [])
                return
            }
            if !box.meta.status.hasPrefix("error") && box.meta.status != "denied" { box.meta.status = "no-audio" }; save(); status = "Nem készült hangfelvétel"; return
        }
        box.meta.audioSeconds = Double(data.count) / Double(MeetingAudio.sampleRate * 2)
        let parts = MeetingAudio.chunks(pcm: data); box.meta.chunks = parts.count; box.meta.status = "transcribing"; save()
        let keys = Keychain.all(), s = m.settings
        let terms = s.dictionary.map(\.term)
        var segs: [String] = [], failed = 0
        for (i, part) in parts.enumerated() {
            status = "Átírás \(i + 1)/\(parts.count)…"
            if MeetingAudio.isSilent(part) { segs.append(""); continue }
            let (r, _) = await router.transcribe(s, keys, wav: MeetingAudio.wav(part), terms: terms)
            if case .success(let t) = r { segs.append(t) } else { segs.append(""); failed += 1 }
        }
        let md = MeetingNotes.transcriptMarkdown(box.meta, segments: segs, captions: caps, participants: people)
        try? md.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let full = segs.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if failed > 0 { box.meta.status = "partial"; save(); status = "Átírás részben sikertelen – a hang megmaradt"; return }
        try? FileManager.default.removeItem(at: pcm)   // sikeres átirat után a nyers hang törlődik
        guard !full.isEmpty || !caps.isEmpty else { box.meta.status = "done"; save(); status = "Kész (nem hangzott el beszéd)"; return }
        await summarize(dir: dir, box: box, settings: s, transcript: full.isEmpty ? MeetingCaptions.markdown(caps) : full, captions: full.isEmpty ? [] : caps)
    }

    private func summarize(dir: URL, box: MetaBox, settings s: AppSettings, transcript: String, captions: [MeetingCaption]) async {
        box.meta.status = "summarizing"; box.save()
        if let chat = router.chatProvider(s, Keychain.all()), case .success(let sum) = await chat.complete(system: MeetingNotes.summarySystem, user: MeetingNotes.summaryInput(box.meta.title, transcript: transcript, captions: captions)) {
            try? "# \(box.meta.title) – összefoglaló\n\n\(sum)\n".write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        }
        box.meta.status = "done"; box.save(); status = "Kész: \(box.meta.title)"
    }
}

@MainActor final class MetaBox {
    var meta: MeetingNotes.Meta; let dir: URL
    init(_ m: MeetingNotes.Meta, dir: URL) { meta = m; self.dir = dir }
    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }
}

struct MeetingSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var svc: MeetingService
    @State private var ics = ""
    private let tf: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "hu_HU"); f.dateFormat = "MMM d., EEE HH:mm"; return f }()
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            BNCard { VStack(alignment: .leading, spacing: 10) {
                BNLabel("Meeting-jegyzetelő", size: 10)
                Toggle("Automatikus csatlakozás a Google Meet meetingekhez", isOn: model.binding(\.meetingsEnabled)).accessibilityLabel("Meeting-jegyzetelő bekapcsolása")
                HStack { Text("Név a meetingben").font(BN.sans(13)); TextField("", text: model.binding(\.meetingBotName)).textFieldStyle(BNTextFieldStyle()) }
                Text("Vendégként lép be (a szervezőnek be kell engednie), csak a résztvevők hangját rögzíti, a mikrofonodat nem. A Mac legyen bekapcsolva. Szólj a résztvevőknek, hogy jegyzetelés folyik.").font(BN.sans(12)).foregroundColor(BN.textWeak)
                Text(svc.status).font(BN.sans(12)).foregroundColor(BN.textMedium)
                if svc.activeID != nil { Button("Jegyzetelő leállítása") { svc.stopActive() }.buttonStyle(BNButtonStyle(kind: .danger, compact: true)) }
            } }
            BNCard { VStack(alignment: .leading, spacing: 10) {
                BNLabel("Google Naptár – titkos iCal-cím", size: 10)
                Text(svc.hasCalendar ? "Beállítva (titkosítva tárolva)." : "Google Naptár → Beállítások → a naptárad → „Titkos cím iCal formátumban”.").font(BN.sans(12)).foregroundColor(BN.textWeak)
                HStack {
                    SecureField("https://calendar.google.com/calendar/ical/…/basic.ics", text: $ics).textFieldStyle(BNTextFieldStyle()).accessibilityLabel("iCal-cím")
                    Button("Mentés") { svc.setCalendarURL(ics); ics = "" }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true)).disabled(ics.isEmpty)
                    if svc.hasCalendar { Button("Törlés") { svc.setCalendarURL("") }.buttonStyle(BNButtonStyle(kind: .danger, compact: true)) }
                }
            } }
            BNCard { VStack(alignment: .leading, spacing: 8) {
                HStack { BNLabel("Közelgő meetingek", size: 10); Spacer()
                    Button("Frissítés") { Task { await svc.refresh() } }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true))
                    Button("Jegyzetek mappa") { try? FileManager.default.createDirectory(at: svc.notesFolder, withIntermediateDirectories: true); Workspace.open(svc.notesFolder) }.buttonStyle(BNButtonStyle(kind: .secondary, compact: true)) }
                if svc.upcoming.isEmpty { Text("Nincs Meet/Teams linkes esemény.").font(BN.sans(12)).foregroundColor(BN.textWeak) }
                ForEach(svc.upcoming.prefix(15)) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(BN.sans(13)).foregroundColor(svc.isSkipped(e) ? BN.textWeak : BN.light).lineLimit(1)
                            Text("\(tf.string(from: e.start)) · \(e.platform.title)\(e.platform.joinSupported ? "" : " (2. szakasz)")").font(BN.sans(11)).foregroundColor(BN.textWeak)
                        }
                        Spacer()
                        if e.platform.joinSupported {
                            Button(svc.isSkipped(e) ? "Visszavesz" : "Kihagy") { svc.toggleSkip(e) }.buttonStyle(TabStyle(selected: svc.isSkipped(e)))
                        }
                    }
                }
            } }
        } }
    }
}
