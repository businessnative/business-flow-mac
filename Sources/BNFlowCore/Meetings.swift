import Foundation

// MARK: - Meeting-jegyzetelő: naptár (iCal), link-felismerés, darabolás, jegyzetfájlok
// Csak tiszta logika (tesztelhető); a böngésző-segéd és az ütemező az appban van.

public enum MeetingPlatform: String, Codable, Sendable { case googleMeet, teams
    public var title: String { self == .googleMeet ? "Google Meet" : "Microsoft Teams" }
    /// 1. szakasz: csak a Google Meet csatlakozás aktív.
    public var joinSupported: Bool { self == .googleMeet }
}

public struct MeetingEvent: Codable, Equatable, Sendable, Identifiable {
    public var uid: String
    public var title: String
    public var start: Date
    public var end: Date
    public var url: URL
    public var platform: MeetingPlatform
    /// Ismétlődő eseménynél alkalmanként egyedi azonosító (uid + kezdés).
    public var id: String { "\(uid)@\(Int(start.timeIntervalSince1970))" }
    public init(uid: String, title: String, start: Date, end: Date, url: URL, platform: MeetingPlatform) {
        self.uid = uid; self.title = title; self.start = start; self.end = end; self.url = url; self.platform = platform
    }
}

public enum MeetingLinks {
    /// Az első Meet vagy Teams link a szövegben (leírás, helyszín, URL mező).
    public static func find(in text: String) -> (URL, MeetingPlatform)? {
        let t = text.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\,", with: ",")
        let patterns: [(String, MeetingPlatform)] = [
            (#"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, .googleMeet),
            (#"https://teams\.(microsoft|live)\.com/(l/meetup-join|meet)/[^\s"<>]+"#, .teams),
        ]
        var best: (Range<String.Index>, URL, MeetingPlatform)?
        for (p, plat) in patterns {
            if let r = t.range(of: p, options: .regularExpression), let u = URL(string: String(t[r])),
               best == nil || r.lowerBound < best!.0.lowerBound { best = (r, u, plat) }
        }
        return best.map { ($0.1, $0.2) }
    }
    public static func platform(of url: URL) -> MeetingPlatform? { find(in: url.absoluteString)?.1 }
}

// MARK: iCal (Google Naptár „titkos iCal-cím”)

public enum ICS {
    struct Prop { let name: String; let params: [String: String]; let value: String }

    /// Sorok kibontása (RFC 5545 folding) és tulajdonságokra bontás.
    static func props(_ text: String) -> [Prop] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += String(raw.dropFirst()) }
            else { lines.append(raw) }
        }
        return lines.compactMap { l in
            guard let colon = Self.valueColon(l) else { return nil }
            let head = l[..<colon], value = String(l[l.index(after: colon)...])
            let parts = head.split(separator: ";").map(String.init)
            var params: [String: String] = [:]
            for p in parts.dropFirst() { let kv = p.split(separator: "=", maxSplits: 1); if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
            return Prop(name: parts.first?.uppercased() ?? "", params: params, value: value)
        }
    }
    /// Az első kettőspont, ami nem idézőjeles paraméterben van.
    static func valueColon(_ l: String) -> String.Index? {
        var q = false
        for i in l.indices { if l[i] == "\"" { q.toggle() } else if l[i] == ":" && !q { return i } }
        return nil
    }

    static func date(_ v: String, tzid: String?, defaultTZ: TimeZone) -> (Date, allDay: Bool)? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        if v.count == 8 { f.dateFormat = "yyyyMMdd"; f.timeZone = defaultTZ; return f.date(from: v).map { ($0, true) } }
        if v.hasSuffix("Z") { f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC"); return f.date(from: v).map { ($0, false) } }
        f.dateFormat = "yyyyMMdd'T'HHmmss"; f.timeZone = tzid.flatMap(TimeZone.init(identifier:)) ?? defaultTZ
        return f.date(from: v).map { ($0, false) }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Meet/Teams linkes események a [from, to) ablakban; ismétlődés (DAILY/WEEKLY/MONTHLY, INTERVAL, COUNT, UNTIL, BYDAY, EXDATE)
    /// és áthelyezett alkalmak (RECURRENCE-ID) kezelésével. Lemondott (STATUS:CANCELLED) és egész napos események kimaradnak.
    public static func meetings(_ text: String, from: Date, to: Date, defaultTZ: TimeZone = .current) -> [MeetingEvent] {
        struct Raw { var p: [String: [Prop]] = [:] ; func v(_ n: String) -> Prop? { p[n]?.first } }
        var raws: [Raw] = [], cur: Raw?, depth = 0
        for pr in props(text) {
            if pr.name == "BEGIN" && pr.value == "VEVENT" { cur = Raw(); depth = 0; continue }
            if pr.name == "BEGIN", cur != nil { depth += 1; continue }        // VALARM stb.
            if pr.name == "END", cur != nil, depth > 0 { depth -= 1; continue }
            if pr.name == "END" && pr.value == "VEVENT" { if let c = cur { raws.append(c) }; cur = nil; continue }
            if cur != nil, depth == 0 { cur!.p[pr.name, default: []].append(pr) }
        }
        // Áthelyezett / lemondott alkalmak: uid + eredeti kezdés.
        var overridden = Set<String>()
        for r in raws { if let uid = r.v("UID")?.value, let rid = r.v("RECURRENCE-ID"), let d = date(rid.value, tzid: rid.params["TZID"], defaultTZ: defaultTZ) {
            overridden.insert("\(uid)@\(Int(d.0.timeIntervalSince1970))") } }
        var out: [MeetingEvent] = []
        for r in raws {
            guard let uid = r.v("UID")?.value, let ds = r.v("DTSTART"), let sd = date(ds.value, tzid: ds.params["TZID"], defaultTZ: defaultTZ), !sd.allDay else { continue }
            let start = sd.0
            if r.v("STATUS")?.value.uppercased() == "CANCELLED" { continue }
            var end = start.addingTimeInterval(3600)
            if let de = r.v("DTEND"), let e = date(de.value, tzid: de.params["TZID"], defaultTZ: defaultTZ) { end = e.0 }
            let blob = [r.v("X-GOOGLE-CONFERENCE")?.value, r.v("URL")?.value, r.v("LOCATION")?.value, r.v("DESCRIPTION")?.value].compactMap { $0 }.map(unescape).joined(separator: " ")
            guard let link = MeetingLinks.find(in: blob) else { continue }
            let (url, plat) = link
            let title = unescape(r.v("SUMMARY")?.value ?? "Meeting")
            let dur = end.timeIntervalSince(start)
            var starts: [Date] = [start]
            if let rr = r.v("RRULE")?.value, r.v("RECURRENCE-ID") == nil {
                let ex = Set((r.p["EXDATE"] ?? []).flatMap { p in p.value.split(separator: ",").compactMap { date(String($0), tzid: p.params["TZID"], defaultTZ: defaultTZ)?.0 } }.map { Int($0.timeIntervalSince1970) })
                let tz = ds.params["TZID"].flatMap(TimeZone.init(identifier:)) ?? defaultTZ
                starts = expand(rule: rr, start: start, until: to, tz: tz).filter { !ex.contains(Int($0.timeIntervalSince1970)) }
                    .filter { !overridden.contains("\(uid)@\(Int($0.timeIntervalSince1970))") }
            }
            for s in starts where s < to && s.addingTimeInterval(dur) > from {
                out.append(MeetingEvent(uid: uid, title: title, start: s, end: s.addingTimeInterval(dur), url: url, platform: plat))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func expand(rule: String, start: Date, until horizon: Date, tz: TimeZone) -> [Date] {
        var kv: [String: String] = [:]
        for part in rule.split(separator: ";") { let a = part.split(separator: "=", maxSplits: 1); if a.count == 2 { kv[String(a[0]).uppercased()] = String(a[1]) } }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let interval = max(1, Int(kv["INTERVAL"] ?? "1") ?? 1)
        let count = kv["COUNT"].flatMap { Int($0) }
        var until = horizon
        if let u = kv["UNTIL"], let d = date(u, tzid: nil, defaultTZ: tz) { until = min(horizon, d.allDay ? d.0.addingTimeInterval(86_399) : d.0) }
        let dayMap = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let byDay = (kv["BYDAY"] ?? "").split(separator: ",").compactMap { dayMap[String($0.suffix(2))] }
        var out: [Date] = [], n = 0
        func emit(_ d: Date) -> Bool { // false = vége
            if d > until { return false }
            if let c = count, n >= c { return false }
            if d >= start { out.append(d); n += 1 }
            return true
        }
        switch kv["FREQ"] {
        case "DAILY":
            var d = start
            while emit(d) { guard let nd = cal.date(byAdding: .day, value: interval, to: d) else { break }; d = nd; if out.count > 2000 { break } }
        case "WEEKLY":
            let days = byDay.isEmpty ? [cal.component(.weekday, from: start)] : byDay.sorted()
            var weekStart = cal.date(byAdding: .day, value: -(cal.component(.weekday, from: start) - 1), to: start)!
            outer: while true {
                for wd in days {
                    let d = cal.date(byAdding: .day, value: wd - 1, to: weekStart)!
                    if d < start { continue }
                    if !emit(d) { break outer }
                }
                weekStart = cal.date(byAdding: .day, value: 7 * interval, to: weekStart)!
                if out.count > 2000 || weekStart > until { break }
            }
        case "MONTHLY":
            var i = 0
            while let d = cal.date(byAdding: .month, value: i * interval, to: start), emit(d) { i += 1; if i > 600 { break } }
        default:
            out = [start]
        }
        return out
    }
}

// MARK: Jegyzetek

public enum MeetingNotes {
    public static let folderName = "Meeting-jegyzetek"
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Business Flow/\(folderName)", isDirectory: true)
    }
    /// Mappanév: „2026-11-04 1000 – Heti egyeztetés” (fájlrendszer-biztos).
    public static func slug(_ e: MeetingEvent, tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HHmm"
        let safe = e.title.replacingOccurrences(of: #"[/\\:*?"<>|\n\r\t]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(60)
        return "\(f.string(from: e.start)) – \(safe.isEmpty ? "Meeting" : String(safe))"
    }

    public struct Meta: Codable, Equatable, Sendable {
        public var id: String, title: String, platform: MeetingPlatform, url: String
        public var start: Date, end: Date, joinedAt: Date?, leftAt: Date?
        public var audioSeconds: Double, status: String, chunks: Int
        public init(event e: MeetingEvent) { id = e.id; title = e.title; platform = e.platform; url = e.url.absoluteString; start = e.start; end = e.end; joinedAt = nil; leftAt = nil; audioSeconds = 0; status = "scheduled"; chunks = 0 }
    }

    public static func transcriptMarkdown(_ m: Meta, segments: [String], captions: [MeetingCaption] = [], participants: [String] = [], tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "hu_HU"); f.timeZone = tz; f.dateFormat = "yyyy. MMMM d. HH:mm"
        var s = "# \(m.title) – átirat\n\n- Időpont: \(f.string(from: m.start))\n- Platform: \(m.platform.title)\n- Felvett hang: \(Int(m.audioSeconds / 60)) perc\n\n"
        if !participants.isEmpty { s += "- Résztvevők: \(participants.joined(separator: ", "))\n\n" }
        if !captions.isEmpty {
            let tt = MeetingCaptions.talkTime(captions).prefix(10).map { "\($0.0) \(Int(($0.1 / 60).rounded())) p" }
            s += "## Beszélőnként (Meet-felirat)\n\n- Beszédidő: \(tt.joined(separator: ", "))\n\n\(MeetingCaptions.markdown(captions))\n\n"
        }
        if segments.contains(where: { !$0.isEmpty }) { s += "## Teljes átirat (hangból)\n\n" }
        for (i, seg) in segments.enumerated() where !seg.isEmpty {
            let mm = i * Int(MeetingAudio.chunkSeconds) / 60
            s += "**[\(String(format: "%02d:%02d", mm / 60, mm % 60))]** \(seg)\n\n"
        }
        return s
    }

    public static let summarySystem = """
    Meeting-jegyzetelő vagy. A felhasználó egy meeting gépi átiratát adja meg (több résztvevő, beszélőnév nélkül, lehetnek félrehallások).
    Írj tömör, pontos magyar összefoglalót Markdownban, csak az átiratban ténylegesen elhangzottak alapján; ne találj ki neveket, számokat vagy döntéseket.
    Szerkezet:
    ## Összefoglaló
    (3–6 mondat)
    ## Fő témák
    - …
    ## Döntések
    - … (ha nincs: „Nem hangzott el egyértelmű döntés.”)
    ## Teendők
    - [ ] Ki – mit – határidő (a felelős neve a feliratból, ha van) (ami elhangzott; ha nincs felelős: „(nincs megnevezve)”)
    ## Nyitott kérdések
    - …
    Ha az átirat angol vagy más nyelvű, az összefoglaló akkor is magyar legyen, a szakkifejezéseket hagyd eredetiben.
    """

    /// Nagyon hosszú átiratnál a modell-kontextus védelme: elejét és végét tartjuk meg, a közepét rövidítjük.
    public static func summaryInput(_ title: String, transcript: String, captions: [MeetingCaption] = [], limit: Int = 120_000) -> String {
        if !captions.isEmpty {
            // A felirat ad beszélőneveket (felelősök a teendőkhöz), a hangalapú átirat a pontosabb szöveget.
            let cap = MeetingCaptions.markdown(captions)
            let half = limit / 2
            return summaryInput(title, transcript: transcript, limit: half) + "\n\nBeszélőnevekkel ellátott élő felirat (pontatlanabb, de megmutatja, ki mit mondott):\n" + String(cap.prefix(half))
        }
        let body = transcript.count <= limit ? transcript
            : String(transcript.prefix(limit * 2 / 3)) + "\n\n[…az átirat közepe a hossz miatt kimaradt…]\n\n" + String(transcript.suffix(limit / 3))
        return "Meeting címe: \(title)\n\nÁtirat:\n\(body)"
    }
}

// MARK: Hang: nyers 16 kHz mono s16le PCM → WAV darabok

public enum MeetingAudio {
    public static let sampleRate = 16_000
    /// 10 perces darab ≈ 19 MB WAV (< 25 MB API-korlát), ugyanaz a minőség, mint a diktálásnál.
    public static let chunkSeconds: Double = 600

    public static func chunks(pcm: Data, seconds: Double = chunkSeconds) -> [Data] {
        let bytesPer = Int(seconds) * sampleRate * 2
        var out: [Data] = [], i = 0
        while i < pcm.count {
            let end = min(pcm.count, i + bytesPer)
            out.append(pcm.subdata(in: i..<(end - (end - i) % 2)))
            i = end
        }
        return out
    }

    public static func wav(_ pcm: Data) -> Data {
        let s: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return WAV.encode(samples: s, sampleRate: sampleRate)
    }
    /// Csendes darab (senki nem beszélt) – nem küldjük el, így nincs „hallucinált” szöveg és költség.
    public static func isSilent(_ pcm: Data) -> Bool {
        let st = AudioPrep.analyze(samples(pcm), sampleRate: sampleRate)
        return st.peak < 0.01 || st.speechSeconds < 1.0
    }
    public static func samples(_ pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
    }
}

// MARK: Feliratok (Meet élő felirat, beszélőnévvel) – beszélő-címkék és tartalék átirat

public struct MeetingCaption: Codable, Equatable, Sendable {
    public var speaker: String; public var text: String; public var t: Double; public var tEnd: Double?
    public init(speaker: String, text: String, t: Double, tEnd: Double? = nil) { self.speaker = speaker; self.text = text; self.t = t; self.tEnd = tEnd }
}

public enum MeetingCaptions {
    /// JSONL beolvasás; az egymást követő, azonos beszélős blokkokat összevonja, a szó szerint ismétlődőket elhagyja.
    public static func parse(_ jsonl: String) -> [MeetingCaption] {
        let dec = JSONDecoder()
        var out: [MeetingCaption] = []
        for line in jsonl.split(separator: "\n") {
            guard let c = try? dec.decode(MeetingCaption.self, from: Data(line.utf8)) else { continue }
            let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !c.speaker.isEmpty else { continue }
            if var last = out.last, last.speaker == c.speaker, c.t - (last.tEnd ?? last.t) < 20 {
                if text.hasPrefix(last.text) { last.text = text } else if !last.text.hasSuffix(text) { last.text += " " + text }
                last.tEnd = c.tEnd ?? c.t; out[out.count - 1] = last
            } else { out.append(MeetingCaption(speaker: c.speaker, text: text, t: c.t, tEnd: c.tEnd)) }
        }
        return out.sorted { $0.t < $1.t }
    }

    public static func stamp(_ t: Double) -> String { let s = Int(t); return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }

    public static func markdown(_ caps: [MeetingCaption]) -> String {
        caps.map { "**\($0.speaker)** [\(stamp($0.t))]: \($0.text)" }.joined(separator: "\n\n")
    }

    /// Beszélőnként felszólalási idő (másodperc), csökkenő sorrendben – a Fireflies „talk-time” mintájára.
    public static func talkTime(_ caps: [MeetingCaption]) -> [(String, Double)] {
        var d: [String: Double] = [:]
        for c in caps { d[c.speaker, default: 0] += max(1, (c.tEnd ?? c.t) - c.t) }
        return d.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}
