import Foundation

public enum TextStats {
    public static func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}

/// Helyi, determinisztikus szövegfeldolgozás az átirat után (hálózat nélkül, tesztelhető).
public enum TextPipeline {

    // MARK: Töltelékszavak

    static let fillerPattern = #"(?i)(?<![\p{L}\p{N}])(ö+h*m*|e+h*m+|hm+|mhm|u+h*m*|u+m+|e+r+m+|ööö+|izé|izéé+)(?![\p{L}\p{N}])[,.…]*\s*"#

    /// Mondatkezdő „töltelék-kötőszó” (szóval, hát, so, well), ha töltelékszó áll mellette.
    static let discourse = #"(?:szóval|hát|nos|na|so|well|okay|oké|like)"#

    public static func removeFillers(_ text: String) -> String {
        let mark = "\u{1}"
        var s = TextRules.replace(text, TextRules.regex(fillerPattern)) { m, ns in
            ns.substring(with: m.range).contains(",") ? mark + "," : mark
        }
        guard s.contains(mark) else { return tidy(s) }
        s = s.replacingOccurrences(of: #"(?i)^("# + mark + #"[,\s]*)*"# + discourse + #"[,\s]*"# + mark, with: mark, options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)^"# + mark + #"[,\s]*"# + discourse + #"(?:[,\s]+|$)"#, with: mark, options: .regularExpression)
        // A töltelékszó körüli vessző is megy: „Ez, hmm, nagyon” → „Ez nagyon”.
        s = TextRules.replace(s, TextRules.regex(#"(,?)\s*"# + mark + #"([,.…\s\x{01}]*)"#)) { m, ns in
            let before = ns.substring(to: m.range.location)
            let hadBoth = !TextRules.group(m, 1, ns).isEmpty && TextRules.group(m, 2, ns).contains(",")
            let chunk = before.components(separatedBy: CharacterSet(charactersIn: ",.;:!?\n")).last ?? ""
            let ws = TextRules.words(chunk)
            let prev = ws.last?.lowercased() ?? ""
            // „Ez nagyon jó ötlet, ööö, csináljuk meg.” → a tagmondathatár vessző marad.
            if hadBoth, ws.count >= 3, !noCommaAfter.contains(prev) { return ", " }
            return " "
        }
        return tidy(s)
    }

    static let noCommaAfter: Set<String> = ["should", "would", "could", "can", "will", "must", "to", "the", "a", "an", "of", "and", "is", "are",
                                            "kell", "fog", "fogok", "fogom", "akarok", "az", "egy", "és", "hogy", "meg", "el", "nem"]

    static func tidy(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[,;:\s]+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Hangparancsok

    static let commandRules: [(String, String)] = [
        (#"(?i),?\s*\b(új bekezdés|new paragraph)\b[,.]?\s*"#, "\n\n"),
        (#"(?i),?\s*\b(új sor|new line)\b[,.]?\s*"#, "\n"),
    ]

    /// Kimondott írásjelek (csak az egyértelmű szavak; a „pont” szándékosan nincs benne, mert gyakori köznév).
    static let punctuationRules: [(String, String)] = [
        (#"(?i)\s*[,.]?\s*\b(kérdőjel|question mark)\b[,.]?"#, "?"),
        (#"(?i)\s*[,.]?\s*\b(felkiáltójel|exclamation (?:mark|point))\b[,.]?"#, "!"),
        (#"(?i)\s*[,.]?\s*\b(pontosvessző|semicolon)\b[,.]?"#, ";"),
        (#"(?i)\s*[,.]?\s*\b(kettőspont)\b[,.]?"#, ":"),
        (#"(?i)\s*,?\s*\b(vessző|comma)\b,?"#, ","),
    ]

    /// „…kérdőjel” → „…?”, utána nagybetű és szóköz.
    public static func applySpokenPunctuation(_ text: String) -> String {
        var s = text
        var hit = false
        for (p, r) in punctuationRules where s.range(of: p, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
            hit = true
        }
        guard hit else { return text }
        s = s.replacingOccurrences(of: #"([?!:;,])(?=\p{L})"#, with: "$1 ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s?!:;,]+"#, with: "", options: .regularExpression)
        // Mondatvégi jel után nagybetű.
        var out = ""; var cap = false
        for ch in s {
            if cap, ch.isLetter { out += ch.uppercased(); cap = false; continue }
            if ch == "?" || ch == "!" { cap = true } else if !ch.isWhitespace { cap = false }
            out.append(ch)
        }
        return out.replacingOccurrences(of: #"([?!:;,])\1+"#, with: "$1", options: .regularExpression)
    }

    public static func applyVoiceCommands(_ text: String) -> String {
        var s = text
        for (p, r) in commandRules { s = s.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        s = applySpokenPunctuation(s)
        // A sortörés utáni első betű nagy legyen.
        s = capitalizeAfterNewlines(s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func capitalizeAfterNewlines(_ s: String) -> String {
        var out = ""; var cap = false
        for ch in s {
            if ch == "\n" { cap = true; out.append(ch); continue }
            if cap, ch.isLetter { out += ch.uppercased(); cap = false; continue }
            if cap, !ch.isWhitespace { cap = false }
            out.append(ch)
        }
        return out
    }

    // MARK: Szótár

    /// Magyar toldalékok (leghosszabb elöl), hogy a „klikkapban” → „ClickUpban”, „Dorotyának” → „Dorottyának” is működjön.
    static let huSuffixes = ["jából", "jéből", "jának", "jének", "ként", "ból", "ből", "ról", "ről", "tól", "től", "nak", "nek", "val", "vel",
                             "hoz", "hez", "höz", "nál", "nél", "ban", "ben", "ért", "ig", "ba", "be", "ra", "re", "on", "en", "ön", "ot", "et",
                             "öt", "at", "ék", "os", "es", "ös", "ja", "je", "é", "t", "n", "s"]
    static let suffixGroup = "(-\\p{Ll}{1,12}|" + huSuffixes.joined(separator: "|") + ")?"

    public static func applyDictionary(_ text: String, entries: [DictionaryEntry]) -> String {
        var s = text
        for e in entries {
            let term = e.term.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            var variants = e.heardAs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // A helyes alak kis/nagybetűs eltéréseit is javítjuk (pl. „businessnative” → „BusinessNative”).
            variants.append(term)
            let suffixOK = term.count >= 4 && term.last.map { $0.isLetter } == true
            let termT = NSRegularExpression.escapedTemplate(for: term)
            for v in variants {
                let ev = NSRegularExpression.escapedPattern(for: v)
                if suffixOK {
                    // Tővéghangzó-nyúlás: Dorottya + nak → Dorottyának.
                    if let lv = v.last, "aeAE".contains(lv), let lt = term.last, "aeAE".contains(lt) {
                        let stemV = NSRegularExpression.escapedPattern(for: String(v.dropLast()))
                        let stemT = String(term.dropLast())
                        let p = #"(?i)(?<![\p{L}\p{N}])"# + stemV + "([áé])" + suffixGroup + #"(?![\p{L}\p{N}])"#
                        s = replaceCasePreserving(s, pattern: p) { g in stemT + g[0].lowercased() + g[1] }
                    }
                    let p = #"(?i)(?<![\p{L}\p{N}])"# + ev + suffixGroup + #"(?![\p{L}\p{N}])"#
                    s = replaceCasePreserving(s, pattern: p) { g in term + g[0] }
                } else {
                    let p = #"(?i)(?<![\p{L}\p{N}])"# + ev + #"(?![\p{L}\p{N}])"#
                    s = s.replacingOccurrences(of: p, with: termT, options: .regularExpression)
                }
            }
        }
        return s
    }

    static func replaceCasePreserving(_ s: String, pattern: String, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return TextRules.replace(s, re) { m, ns in
            let groups = (1..<m.numberOfRanges).map { TextRules.group(m, $0, ns) }
            return f(groups)
        }
    }

    // MARK: Szövegrészletek

    /// Ha a kimondott kulcsmondat elhangzik, helyére a kibontás kerül. Ha a teljes diktálás csak a kulcs, csak a kibontás marad.
    public static func applySnippets(_ text: String, snippets: [Snippet]) -> String {
        var s = text
        for sn in snippets {
            let trig = sn.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trig.isEmpty else { continue }
            var bare = s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            bare = bare.replacingOccurrences(of: #"(?i)^(az én|a|az|the|my|egy)\s+"#, with: "", options: .regularExpression)
            if bare.compare(trig, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return sn.expansion }
            let words = trig.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let p = #"(?i)(?<![\p{L}\p{N}])"# + words.joined(separator: #"[\s,-]*"#) + #"(?![\p{L}\p{N}])[.,!?]?"#
            s = s.replacingOccurrences(of: p, with: NSRegularExpression.escapedTemplate(for: sn.expansion), options: .regularExpression)
        }
        return s
    }

    // MARK: Stílus

    public static func applyTone(_ text: String, tone: StyleTone, protectedTerms: [String] = []) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        switch tone {
        case .formal:
            s = uppercaseFirst(s)
            if let last = s.last, last.isLetter || last.isNumber { s.append(".") }
        case .casual:
            s = uppercaseFirst(s)
            if s.hasSuffix("."), !s.hasSuffix("...") { s.removeLast() }
        case .veryCasual:
            s = lowercaseSentenceStarts(s, protected: protectedTerms)
            if s.hasSuffix("."), !s.hasSuffix("...") { s.removeLast() }
            s = s.replacingOccurrences(of: #"(?<=[\p{L}\p{N}]),(?=\s)"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\.(\s+)"#, with: "$1", options: .regularExpression)
        }
        return s
    }

    static func uppercaseFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: { $0.isLetter }) else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    static func lowercaseSentenceStarts(_ s: String, protected: [String]) -> String {
        let words = s.components(separatedBy: " ")
        var out: [String] = []
        var start = true
        for w in words {
            var word = w
            if start, let f = word.first, f.isUppercase {
                let core = word.trimmingCharacters(in: .punctuationCharacters)
                let isAcronym = core.count > 1 && core == core.uppercased()
                let isProtected = protected.contains { $0.compare(core, options: .caseInsensitive) == .orderedSame }
                if !isAcronym && !isProtected { word = f.lowercased() + word.dropFirst() }
            }
            if !word.isEmpty { start = word.last.map { ".!?\n".contains($0) } ?? false }
            out.append(word)
        }
        return out.joined(separator: " ")
    }

    // MARK: Illesztés a kurzor előtti szöveghez

    public static func needsLeadingSpace(before previous: Character?, text: String) -> Bool {
        guard let p = previous, let first = text.first else { return false }
        if p.isWhitespace || p.isNewline { return false }
        if "([{\"'„«/-".contains(p) { return false }
        if ".,!?;:)]}…".contains(first) { return false }
        return true
    }

    /// A teljes helyi lánc egy diktáláshoz (LLM-formázás nélkül).
    public static func process(_ raw: String, settings: AppSettings, tone: StyleTone) -> String {
        process(raw, settings: settings, tone: tone, context: .empty, category: .other)
    }

    public static func process(_ raw: String, settings: AppSettings, tone: StyleTone, context: DictationContext, category: AppCategory) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        let protected = settings.dictionary.map(\.term)
        if settings.removeFillers { s = removeFillers(s) }
        if settings.voiceCommands { s = applyVoiceCommands(s) }
        s = TextRules.applyBacktrack(s)
        s = applyDictionary(s, entries: settings.dictionary)
        s = applySnippets(s, snippets: settings.snippets)
        // Ha a teljes diktálás egy kódszó volt, a kibontást betű szerint illesztjük be.
        if settings.snippets.contains(where: { $0.expansion == s }) { return s }
        s = TextRules.applySpokenAddresses(s)
        s = TextRules.restoreAccents(s)
        let lang = TextRules.language(s)
        if lang == .hu || (lang == .unknown && settings.language == .hu) {
            s = TextRules.applyHungarianCommas(s)
            s = TextRules.applyHungarianQuotes(s)
        }
        s = TextRules.applyAcronyms(s)
        if settings.voiceCommands { s = TextRules.applyLists(s) }
        if category == .email, let mail = TextRules.layoutEmail(s, lang: lang) {
            s = mail
        } else {
            s = TextRules.applyGreetingComma(s)
            if tone != .veryCasual { s = TextRules.applyQuestionMark(s) }
            if TextRules.isList(s), tone != .veryCasual {
                s = uppercaseFirst(s.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                s = applyTone(s, tone: tone, protectedTerms: protected)
            }
        }
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #",{2,}"#, with: ",", options: .regularExpression)
        s = TextRules.applyContextNames(s, context: context)
        s = TextRules.fitToContext(s, context: context, protected: protected)
        return s
    }
}

public enum AppCategoryResolver {
    static let map: [String: AppCategory] = [
        "com.apple.MobileSMS": .personal, "net.whatsapp.WhatsApp": .personal, "desktop.WhatsApp": .personal,
        "ru.keepcoder.Telegram": .personal, "org.telegram.desktop": .personal, "com.facebook.archon": .personal,
        "com.facebook.archon.developerID": .personal, "org.whispersystems.signal-desktop": .personal, "com.viber.osx": .personal,
        "com.tinyspeck.slackmacgap": .work, "com.microsoft.teams": .work, "com.microsoft.teams2": .work,
        "com.hnc.Discord": .work, "com.linear": .work, "notion.id": .work, "com.figma.Desktop": .work, "com.clickup.desktop-app": .work,
        "com.apple.mail": .email, "com.microsoft.Outlook": .email, "com.readdle.smartemail-Mac": .email,
        "com.superhuman.electron": .email, "com.airmail.Airmail5": .email, "it.bloop.airmail2": .email,
    ]
    public static func category(for bundleID: String?) -> AppCategory {
        guard let id = bundleID else { return .other }
        return map[id] ?? .other
    }
}
