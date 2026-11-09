import Foundation

/// Helyi, determinisztikus nyelvi szabályok (magyar elsőként): önjavítás, listák, vesszők, kérdőjel, idézőjelek,
/// ékezetek, kimondott címek, rövidítések, levélforma, kurzor-környezet. Hálózat nélkül futnak, és az LLM után is.
public enum TextRules {
    public enum Lang: Sendable { case hu, en, unknown }

    // MARK: Segédek

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }).map(String.init)
    }

    static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    /// Regex-csere closure-rel (a találatok hátulról előre cserélve).
    static func replace(_ s: String, _ re: NSRegularExpression, _ f: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = s as NSString
        let ms = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return s }
        let out = NSMutableString(string: s)
        for m in ms.reversed() { if let r = f(m, ns) { out.replaceCharacters(in: m.range, with: r) } }
        return out as String
    }

    static func group(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }

    static func lev(_ a: String, _ b: String) -> Int { EvalScoring.lev(Array(a), Array(b)) }

    static func capFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: { $0.isLetter }) else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    // MARK: Nyelv

    static let huWords: Set<String> = ["az", "egy", "és", "es", "hogy", "nem", "is", "meg", "de", "ha", "már", "még", "csak", "ez", "ezt", "azt",
                                       "van", "lesz", "kell", "holnap", "ma", "szia", "kérlek", "köszönöm", "mert", "vagy", "mi", "ki", "mikor",
                                       "hol", "igen", "itt", "ott", "majd", "akkor", "nagyon", "jó", "nekem", "neked", "kedves", "aki", "ami"]
    static let enWords: Set<String> = ["the", "and", "to", "of", "is", "i", "you", "it", "for", "we", "that", "this", "with", "on", "are", "be",
                                       "will", "can", "please", "thanks", "let's", "my", "your", "so", "just", "what", "when", "have", "our"]

    public static func language(_ s: String) -> Lang {
        let lower = s.lowercased()
        var hu = 0, en = 0
        if lower.contains(where: { "őű".contains($0) }) { hu += 3 }
        if lower.contains(where: { "áéíóöúü".contains($0) }) { hu += 2 }
        for w in words(lower) { if huWords.contains(w) { hu += 1 }; if enWords.contains(w) { en += 1 } }
        if hu > en { return .hu }
        if en > hu { return .en }
        return .unknown
    }

    // MARK: Önjavítás („…, nem, inkább …”, „Ezt töröld.”)

    static let backtrackRE = regex(#"(?i)\s*,\s*(?:nem\s*,?\s*inkább|nem\s*,?\s*hanem|bocsánat|bocsi|bocs|pardon|javítok|helyesbítek|akarom mondani|actually\s*,?\s*no|no\s*,?\s*wait|sorry\s*,?\s*i mean|or rather)\s*[,:]?\s+"#)
    static let scratchSentences: Set<String> = ["ezt töröld", "töröld ezt", "töröld az előzőt", "az előzőt töröld", "scratch that", "delete that", "delete the last sentence"]

    static let numberStems = ["tíz", "tizen", "húsz", "huszon", "harminc", "negyven", "ötven", "hatvan", "hetven", "nyolcvan", "kilencven", "száz",
                              "ezer", "millió", "kettő", "három", "négy", "nyolc", "kilenc", "eleven", "twelve", "twenty", "thirty", "forty",
                              "fifty", "hundred", "thousand", "million"]
    static let numberExact: Set<String> = ["két", "öt", "hat", "hét", "ötkor", "hatkor", "hétkor", "egykor", "kettőkor", "one", "two", "three",
                                           "four", "five", "six", "seven", "eight", "nine", "ten"]

    static func isNumberWord(_ w: String) -> Bool {
        let l = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if l.isEmpty { return false }
        if l.first!.isNumber { return true }
        if numberExact.contains(l) { return true }
        return numberStems.contains { l.hasPrefix($0) }
    }

    static func isCapitalized(_ w: String) -> Bool { w.first?.isUppercase ?? false }

    public static func applyBacktrack(_ text: String) -> String {
        var s = removeScratchedSentences(text)
        for _ in 0..<5 {
            let ns = s as NSString
            guard let m = backtrackRE.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { break }
            let head = ns.substring(to: m.range.location)
            let tail = ns.substring(from: m.range.location + m.range.length)
            // A javított mondatrész a mondat elejétől a jelzőig tart.
            var boundary = head.startIndex
            if let r = head.range(of: #"[.!?\n]\s*"#, options: [.regularExpression, .backwards]) { boundary = r.upperBound }
            let prior = String(head[..<boundary])
            var sentence = String(head[boundary...]).components(separatedBy: " ").filter { !$0.isEmpty }
            let y0 = tail.split(separator: " ").first.map(String.init) ?? ""
            guard !sentence.isEmpty, !y0.isEmpty else { break }
            var drop = sentence.count - 1
            let idx = Array(sentence.indices)
            if isNumberWord(y0), let r = idx.last(where: { isNumberWord(sentence[$0]) }) {
                var k = r
                while k > 0 && isNumberWord(sentence[k - 1]) { k -= 1 }
                drop = k
            } else if isCapitalized(y0), let r = idx.last(where: { $0 > 0 && isCapitalized(sentence[$0]) }) {
                drop = r
            } else {
                let suf = String(y0.lowercased().trimmingCharacters(in: .punctuationCharacters).suffix(3))
                if suf.count == 3, let r = idx.last(where: { $0 > 0 && sentence[$0].lowercased().hasSuffix(suf) }) { drop = r }
            }
            if drop == 0 && sentence.count > 1 { drop = sentence.count - 1 }
            sentence.removeSubrange(drop...)
            var fixedTail = tail
            if sentence.isEmpty { fixedTail = capFirst(tail) }
            let rebuilt = (sentence + [fixedTail]).joined(separator: " ")
            s = prior + rebuilt
        }
        return s
    }

    static func sentences(_ s: String) -> [String] {
        let re = regex(#"[^.!?\n]+[.!?]*\s*|\n+\s*|[.!?]+\s*"#)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func removeScratchedSentences(_ s: String) -> String {
        var parts = sentences(s)
        var changed = false
        var i = 0
        while i < parts.count {
            let core = parts[i].lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            if scratchSentences.contains(core) {
                parts.remove(at: i); changed = true
                if i > 0 { parts.remove(at: i - 1); i -= 1 }
                continue
            }
            i += 1
        }
        return changed ? parts.joined().trimmingCharacters(in: .whitespaces) : s
    }

    // MARK: Listák („első…, második…, harmadik…”)

    static let ordinals: [[String]] = [
        ["első", "elsőként", "egyrészt", "first", "firstly"], ["második", "másodszor", "másodikként", "second", "secondly"],
        ["harmadik", "harmadszor", "harmadikként", "third", "thirdly"], ["negyedik", "negyedszer", "fourth"], ["ötödik", "ötödször", "fifth"],
        ["hatodik", "sixth"], ["hetedik", "seventh"],
    ]
    static let ordinalRE: NSRegularExpression = {
        let all = ordinals.flatMap { $0 }.sorted { $0.count > $1.count }.joined(separator: "|")
        return regex(#"(?i)(?<![\p{L}\p{N}])("# + all + #")(?![\p{L}\p{N}])[,:]?"#)
    }()
    static let articles: Set<String> = ["a", "az", "the", "my", "our", "your", "egy", "minden", "every"]

    static func ordinalIndex(_ w: String) -> Int? {
        let l = w.lowercased()
        return ordinals.firstIndex { $0.contains(l) }
    }

    public static func applyLists(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let ns = text as NSString
        let ms = ordinalRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seq: [NSTextCheckingResult] = []
        for m in ms {
            guard let k = ordinalIndex(ns.substring(with: m.range(at: 1))) else { continue }
            if k == seq.count {
                if k == 0 {
                    let prev = words(ns.substring(to: m.range.location)).last ?? ""
                    if articles.contains(prev) { continue }
                }
                seq.append(m)
            } else if k == 0 { seq = [m] }
        }
        guard seq.count >= 2 else { return text }
        var intro = ns.substring(to: seq[0].range.location).trimmingCharacters(in: .whitespaces)
        intro = intro.replacingOccurrences(of: #"[,;:\s]+$"#, with: "", options: .regularExpression)
        var items: [String] = []
        for (i, m) in seq.enumerated() {
            let start = m.range.location + m.range.length
            let end = i + 1 < seq.count ? seq[i + 1].range.location : ns.length
            var it = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            it = it.replacingOccurrences(of: #"(?i)[\s,;]+(és|and|meg|valamint|and then|aztán)$"#, with: "", options: .regularExpression)
            it = it.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.").union(.whitespaces))
            it = it.replacingOccurrences(of: #"(?i)^(the|a|an|az|a)\s+(?=\p{L})"#, with: "", options: .regularExpression)
            guard !it.isEmpty else { return text }
            items.append(capFirst(it))
        }
        let body = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return intro.isEmpty ? body : intro + ":\n" + body
    }

    public static func isList(_ s: String) -> Bool {
        s.range(of: #"(?m)^\d+\. "#, options: .regularExpression) != nil && s.contains("\n")
    }

    // MARK: Magyar vesszők, kérdőjel, idézőjelek

    static let huConjunctions = ["hogy", "hogyha", "mert", "mivel", "ha", "de", "hanem", "aki", "akit", "akinek", "akivel", "akik", "akiket",
                                 "ami", "amit", "aminek", "amivel", "amik", "amiket", "amely", "amelyet", "amelyek", "amelynek", "amikor", "ahol",
                                 "ahova", "ahová", "ahonnan", "ahogy", "amíg", "amennyiben", "miközben", "mielőtt", "miután", "mintha"]
    static let huNoCommaBefore: Set<String> = ["és", "s", "vagy", "még", "csak", "de", "hogy", "mert", "mint", "akár", "ha", "meg", "illetve",
                                              "sőt", "hanem", "hát", "nem", "persze", "vagyis", "azaz", "mégpedig", "kivéve", "főleg", "különösen"]
    static let huConjRE = regex(#"(?<=[\p{L}\p{N}])(\s+)("# + huConjunctions.joined(separator: "|") + #")(?![\p{L}\p{N}])"#)

    static let relativeStarts: Set<String> = ["aki", "akit", "akinek", "akivel", "akik", "akiket", "ami", "amit", "aminek", "amivel", "amik",
                                              "amiket", "amely", "amelyet", "amelyek", "amelynek"]
    static let mainClauseResumers: Set<String> = ["még", "már", "viszont", "azonban", "szintén", "mindig", "továbbra", "sajnos", "végül", "most"]

    public static func applyHungarianCommas(_ text: String) -> String {
        var s = replace(text, huConjRE) { m, ns in
            let before = ns.substring(to: m.range.location)
            if before.last.map({ ",;:".contains($0) }) == true { return nil }
            let prev = words(before).last ?? ""
            if huNoCommaBefore.contains(prev) { return nil }
            return "," + group(m, 1, ns) + group(m, 2, ns)
        }
        // Mondat eleji alanyhoz kapcsolt vonatkozó mellékmondat zárása: „Az ügyfél, aki tegnap írt, még nem fizetett.”
        s = replace(s, regex(#"(?:^|(?<=[.!?]\s))((?:\p{L}+\s){1,2}\p{L}+, (?:"# + relativeStarts.joined(separator: "|") + #")(?:\s[\p{L}\p{N}]+){2,5}?)\s("# + mainClauseResumers.joined(separator: "|") + #")(?![\p{L}])"#)) { m, ns in
            let clause = group(m, 1, ns)
            if clause.contains(",") && clause.components(separatedBy: ",").count > 2 { return nil }
            return clause + ", " + group(m, 2, ns)
        }
        return s
    }

    static let huQuestionStarts: Set<String> = ["mikor", "hol", "hogyan", "miért", "mi", "mit", "mivel", "minek", "ki", "kit", "kinek", "kivel",
                                               "melyik", "hány", "hányan", "hánykor", "mennyi", "mennyiért", "milyen", "hová", "hova", "honnan",
                                               "meddig", "mióta", "merre", "miben", "kié", "tudnál", "tudnád", "tudnátok", "megtennéd",
                                               "megnéznéd", "ráérsz", "ráértek", "van", "nincs", "jössz", "jöttök"]
    static let huPoliteQuestion: Set<String> = ["tudnál", "tudnád", "tudnátok", "tudnának", "megtennéd", "megnéznéd", "elküldenéd", "ráérsz", "ráértek"]
    static let enQuestionStarts: Set<String> = ["what", "when", "where", "why", "how", "who", "whom", "which", "whose", "can", "could", "would",
                                               "will", "do", "does", "did", "is", "are", "should", "shall", "may", "have", "has", "am", "was", "were"]
    static let greetings: Set<String> = ["szia", "sziasztok", "helló", "hello", "hi", "hey", "szervusz", "szevasz", "csá", "jó", "napot", "kedves"]

    public static func isQuestion(_ sentence: String) -> Bool {
        var w = words(sentence)
        while let f = w.first, greetings.contains(f) { w.removeFirst() }
        guard let first = w.first else { return false }
        if w.count >= 1 && (sentence.range(of: #"(?<=\p{L})-e(?![\p{L}])"#, options: .regularExpression) != nil) { return true }
        if w.last == "ugye" { return true }
        if huQuestionStarts.contains(first) && !(first == "van" || first == "nincs") { return true }
        if (first == "van" || first == "nincs"), w.count <= 6, sentence.lowercased().contains("valami") { return true }
        if w.prefix(3).contains(where: { huPoliteQuestion.contains($0) }) { return true }
        if enQuestionStarts.contains(first) && language(sentence) != .hu { return true }
        return false
    }

    /// Kérdőjel a lezáratlan utolsó mondat végére, ha kérdés.
    public static func applyQuestionMark(_ text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        let tailSentence = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).last ?? text
        return isQuestion(tailSentence) ? text + "?" : text
    }

    public static func applyHungarianQuotes(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #""([^"\n]+)""#, with: "„$1”", options: .regularExpression)
        s = s.replacingOccurrences(of: #"“([^”\n]+)”"#, with: "„$1”", options: .regularExpression)
        return s
    }

    // MARK: Ékezetek (csak teljesen ékezet nélküli magyar szövegben)

    static let accentTable: [String: String] = [
        "koszonom": "köszönöm", "koszonjuk": "köszönjük", "koszi": "köszi", "szepen": "szépen", "valasz": "válasz", "valaszt": "választ",
        "valaszod": "válaszod", "valaszodat": "válaszodat", "es": "és", "kerlek": "kérlek", "kerem": "kérem", "udvozlettel": "üdvözlettel",
        "udv": "üdv", "igy": "így", "ugy": "úgy", "jo": "jó", "kesz": "kész", "keszen": "készen", "szamla": "számla", "szamlat": "számlát",
        "szamlát": "számlát", "ajanlat": "ajánlat", "ajanlatot": "ajánlatot", "hetfo": "hétfő", "hetfon": "hétfőn", "csutortok": "csütörtök",
        "csutortokon": "csütörtökön", "pentek": "péntek", "penteken": "pénteken", "talalkozo": "találkozó", "megbeszeles": "megbeszélés",
        "holnaputan": "holnapután", "kosz": "kösz", "tobb": "több", "lehetoseg": "lehetőség", "ertekeles": "értékelés", "ugyfel": "ügyfél",
        "ugyfelnek": "ügyfélnek", "szerzodes": "szerződés", "szerzodest": "szerződést", "feladat": "feladat", "hataridő": "határidő",
        "hatarido": "határidő", "fontos": "fontos", "kerdes": "kérdés", "kerdesem": "kérdésem", "tegnap": "tegnap", "mar": "már",
    ]

    public static func restoreAccents(_ text: String) -> String {
        guard !text.contains(where: { "áéíóöőúüűÁÉÍÓÖŐÚÜŰ".contains($0) }) else { return text }
        let ws = words(text)
        let hits = ws.filter { accentTable[$0] != nil && accentTable[$0] != $0 }.count
        let lang = language(text)
        guard hits >= 2 || (hits >= 1 && lang == .hu) else { return text }
        guard lang != .en else { return text }
        return replace(text, regex(#"(?<![\p{L}\p{N}])[\p{L}]+(?![\p{L}\p{N}])"#)) { m, ns in
            let w = ns.substring(with: m.range)
            guard let rep = accentTable[w.lowercased()], rep != w.lowercased() else { return nil }
            if w == "mar" { return nil } // angolul is szó
            return w.first!.isUppercase ? capFirst(rep) : rep
        }
    }

    // MARK: Kimondott e-mail-cím és webcím

    static let tlds = "hu|com|net|org|io|eu|ai|dev|app|co|uk|us|me|info|biz|xyz|studio|tech|shop|online"
    static let emailRE = regex(#"(?i)(?<![\p{L}\p{N}@.])([\p{L}\p{N}._-]+)\s+(?:kukac|at)\s+((?:[\p{L}\p{N}-]+\s*(?:pont|dot|\.)\s*)+(?:"# + tlds + #"))(?![\p{L}\p{N}])"#)
    static let domainRE = regex(#"(?i)(?<![\p{L}\p{N}@.])((?:[\p{L}\p{N}-]+\s+(?:pont|dot)\s+)+(?:"# + tlds + #"))(?![\p{L}\p{N}])((?:\s+(?:perjel|per|slash)\s+[\p{L}\p{N}-]+)*)"#)

    static func collapseDomain(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?i)\s*(?:pont|dot|\.)\s*"#, with: ".", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "").lowercased()
    }

    public static func applySpokenAddresses(_ text: String) -> String {
        var s = replace(text, emailRE) { m, ns in
            group(m, 1, ns).lowercased() + "@" + collapseDomain(group(m, 2, ns))
        }
        s = replace(s, domainRE) { m, ns in
            let path = group(m, 2, ns).replacingOccurrences(of: #"(?i)\s+(?:perjel|per|slash)\s+"#, with: "/", options: .regularExpression)
            return collapseDomain(group(m, 1, ns)) + path.lowercased()
        }
        return s
    }

    // MARK: Rövidítések

    static let acronyms = ["pr", "api", "ui", "ux", "crm", "seo", "sem", "kpi", "okr", "ceo", "cto", "cfo", "coo", "hr", "pdf", "url", "mvp", "roi",
                           "b2b", "b2c", "saas", "qa", "sql", "ai", "sms", "faq", "erp", "vpn", "cv", "gdpr", "ppc", "cta", "sdk", "llm"]
    static let acronymRE = regex(#"(?<![\p{L}\p{N}])("# + acronyms.joined(separator: "|") + #"|Pr|Api|Ui|Ux|Crm|Seo|Kpi|Ceo|Cto|Hr|Pdf|Url|Mvp|Roi|Saas|Sql|Ai|Gdpr|Llm)(?=-|(?![\p{L}\p{N}]))"#)

    public static func applyAcronyms(_ text: String) -> String {
        replace(text, acronymRE) { m, ns in ns.substring(with: m.range).uppercased() }
    }

    // MARK: Köszönés utáni vessző („szia meg tudnád…” → „Szia, meg tudnád…”)

    static let greetingCommaRE = regex(#"^((?i:szia|sziasztok|helló|hello|hi|hey|szervusz|szevasz))\s+(?=\p{Ll})"#)

    public static func applyGreetingComma(_ text: String) -> String {
        replace(text, greetingCommaRE) { m, ns in group(m, 1, ns) + ", " }
    }

    // MARK: E-mail forma (megszólítás, törzs, elköszönés + név)

    static let mailGreetingRE = regex(#"^((?i:kedves|tisztelt|szia|sziasztok|szervusz|helló|hello|jó napot|dear|hi))\s+([\p{L}.-]+)(\s+\p{Lu}[\p{L}.-]+)?\s*[,!:.]?\s+"#)
    static let strongSignoffs = ["baráti üdvözlettel", "üdvözlettel", "tisztelettel", "köszönettel", "üdv", "best regards", "kind regards", "regards", "best wishes"]
    static let weakSignoffs = ["köszönöm", "köszi", "thanks", "thank you", "best", "cheers", "szép napot"]

    static func signoffRE(_ list: [String], capitalizedName: Bool) -> NSRegularExpression {
        let name = capitalizedName ? #"(\p{Lu}[\p{L}.-]*(?:\s+\p{Lu}[\p{L}.-]*)?)"# : #"([\p{L}.-]+(?:\s+\p{Lu}[\p{L}.-]*)?)"#
        return regex(#"[,.;]?\s+((?i:"# + list.joined(separator: "|") + #"))[,:.!]?\s+"# + name + #"[.!]?\s*$"#)
    }
    static let strongSignoffRE = signoffRE(strongSignoffs, capitalizedName: false)
    static let weakSignoffRE: NSRegularExpression = {
        let name = #"(\p{Lu}[\p{L}.-]*(?:\s+\p{Lu}[\p{L}.-]*)?)"#
        return regex(#"[,.;]?\s+((?i:"# + weakSignoffs.joined(separator: "|") + #"))[,:.!]?\s+"# + name + #"[.!]?\s*$"#)
    }()
    static let commonNonNames: Set<String> = ["köszönöm", "köszi", "holnap", "ma", "minden", "mindenkinek", "küldöm", "csak", "még", "már", "itt",
                                              "most", "thanks", "thank", "please", "just", "the", "a", "az", "egy", "és", "is", "nem", "jó"]

    public static func layoutEmail(_ text: String, lang: Lang) -> String? {
        guard !text.contains("\n") else { return nil }
        var body = text.trimmingCharacters(in: .whitespaces)
        var greeting: String?
        let ns = body as NSString
        if let m = mailGreetingRE.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
            let g = group(m, 1, ns), n1 = group(m, 2, ns), n2 = group(m, 3, ns).trimmingCharacters(in: .whitespaces)
            let strong = ["kedves", "tisztelt", "dear"].contains(g.lowercased())
            if isCapitalized(n1) || (strong && !commonNonNames.contains(n1.lowercased())) || !commonNonNames.contains(n1.lowercased()) && !huWords.contains(n1.lowercased()) {
                let name = ([capFirst(n1)] + (n2.isEmpty ? [] : [n2])).joined(separator: " ")
                let isEN = ["dear", "hi", "hello"].contains(g.lowercased()) && lang == .en
                greeting = capFirst(g.lowercased()) + " " + name + (isEN ? "," : "!")
                body = ns.substring(from: m.range.location + m.range.length)
            }
        }
        var signoff: String?
        let bns = body as NSString
        let full = NSRange(location: 0, length: bns.length)
        if let m = strongSignoffRE.firstMatch(in: body, range: full) ?? weakSignoffRE.firstMatch(in: body, range: full) {
            let so = group(m, 1, bns), name = group(m, 2, bns)
            if !commonNonNames.contains(name.lowercased()) {
                signoff = capFirst(so.lowercased()) + (lang == .en ? "," : ":") + "\n" + name.split(separator: " ").map { capFirst(String($0)) }.joined(separator: " ")
                body = bns.substring(to: m.range.location)
            }
        }
        guard greeting != nil || signoff != nil else { return nil }
        body = capFirst(body.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))))
        if let l = body.last, l.isLetter || l.isNumber { body += isQuestion(body.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? body) ? "?" : "." }
        return [greeting, body.isEmpty ? nil : body, signoff].compactMap { $0 }.joined(separator: "\n\n")
    }

    // MARK: Kurzor-környezet

    /// Kis/nagybetű és mondatvégi írásjel a kurzor körüli szöveghez igazítva.
    public static func fitToContext(_ text: String, context: DictationContext, protected: [String]) -> String {
        guard !context.isSecure, !text.isEmpty else { return text }
        var s = text
        let before = context.before.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        if let c = before.last {
            let firstWord = String(s.prefix { $0.isLetter || $0.isNumber || $0 == "-" })
            let protectedWord = firstWord.count > 1 && firstWord == firstWord.uppercased()
                || protected.contains { $0.compare(firstWord, options: .caseInsensitive) == .orderedSame }
                || firstWord == "I" || contextNames(context).contains(firstWord) || looksLikeName(firstWord)
            if ".!?\n".contains(c) || before.hasSuffix(":\n") {
                s = capFirst(s)
            } else if c.isLetter || c.isNumber || ",;(–-".contains(c), !protectedWord, !s.contains("\n") {
                if let i = s.firstIndex(where: { $0.isLetter }), s[i].isUppercase, s.distance(from: s.startIndex, to: i) == 0 {
                    s = s.replacingCharacters(in: i...i, with: s[i].lowercased())
                }
            }
        }
        let after = context.after.drop { $0 == " " || $0 == "\t" }
        if let a = after.first, a.isLowercase || ",;:".contains(a) {
            while let l = s.last, ".!?".contains(l), !s.hasSuffix("...") { s.removeLast() }
        }
        return s
    }

    static let firstNames: Set<String> = ["anna", "péter", "attila", "dorottya", "gábor", "lászló", "istván", "zoltán", "józsef", "jános", "ferenc", "sándor",
        "tamás", "zsolt", "tibor", "andrás", "csaba", "imre", "balázs", "gergely", "dávid", "dániel", "ádám", "bence", "máté", "levente",
        "márk", "krisztián", "norbert", "róbert", "richárd", "viktor", "szabolcs", "ákos", "gyula", "miklós", "károly", "béla", "mihály",
        "mária", "erzsébet", "katalin", "éva", "ilona", "zsuzsanna", "judit", "ágnes", "andrea", "erika", "krisztina", "eszter", "edit",
        "anita", "mónika", "tímea", "nóra", "réka", "zsófia", "viktória", "dóra", "petra", "kitti", "lilla", "fanni", "boglárka", "orsolya",
        "beáta", "szilvia", "melinda", "barbara", "noémi", "vivien", "rita", "ildikó", "gabriella", "csilla", "emese", "eniko", "enikő",
        "john", "michael", "david", "james", "robert", "mary", "sarah", "emma", "peter", "paul", "mark", "anne", "laura", "tom", "alex"]

    /// Ismert keresztnév (toldalékkal is: „Péterrel”, „Annának”).
    static func looksLikeName(_ w: String) -> Bool {
        guard let f = w.first, f.isUppercase, w.count >= 3 else { return false }
        let l = w.lowercased()
        if firstNames.contains(l) { return true }
        return firstNames.contains { n in
            l.hasPrefix(n) && l.count - n.count <= 6
                || (n.last.map { "ae".contains($0) } == true && l.hasPrefix(String(n.dropLast())) && l.dropFirst(n.count - 1).first.map { "áé".contains($0) } == true)
        }
    }

    /// A környezetben (nem mondatkezdő helyen) nagybetűvel írt szavak: valószínű nevek.
    public static func contextNames(_ ctx: DictationContext) -> [String] {
        guard !ctx.isSecure else { return [] }
        let text = ctx.before + " " + ctx.after
        let re = regex(#"(?<=[\p{L}\p{N},;]\s)(\p{Lu}[\p{Ll}]{2,})"#)
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range)
            if !out.contains(w) { out.append(w) }
        }
        return out
    }

    /// Ha egy kimondott név egy betűben tér el a környezetben látható névtől (pl. „Szőts” ↔ „Szőcs”), a környezet írásmódja nyer.
    public static func applyContextNames(_ text: String, context: DictationContext) -> String {
        let names = contextNames(context).filter { $0.count >= 4 }
        guard !names.isEmpty else { return text }
        return replace(text, regex(#"(?<![\p{L}\p{N}])\p{Lu}[\p{Ll}]{3,}"#)) { m, ns in
            let w = ns.substring(with: m.range)
            if names.contains(w) { return nil }
            for n in names {
                guard w.count >= n.count, w.first == n.first else { continue }
                let stem = String(w.prefix(n.count)), rest = String(w.dropFirst(n.count))
                if stem != n, lev(stem, n) == 1, rest.count <= 6 { return n + rest }
            }
            return nil
        }
    }
}

extension AppCategoryResolver {
    public static let browsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
                                        "company.thebrowser.Browser", "company.thebrowser.dia", "org.mozilla.firefox", "com.microsoft.edgemac",
                                        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "ai.perplexity.comet", "app.zen-browser.zen"]
    static let siteRules: [(AppCategory, [String])] = [
        (.email, ["gmail", "outlook", "proton mail", "yahoo mail", "superhuman", "fastmail", "icloud mail", "freemail", "citromail"]),
        (.work, ["slack", "microsoft teams", "discord", "notion", "linear", "jira", "clickup", "github", "asana", "trello", "google docs",
                 "google dokumentumok", "figma", "confluence", "monday.com", "airtable"]),
        (.personal, ["whatsapp", "messenger", "telegram", "instagram", "facebook", "signal"]),
    ]

    /// Alkalmazás + (böngészőben) az ablak címe alapján: Gmail a Chrome-ban = e-mail, Slack a böngészőben = munka.
    public static func category(for bundleID: String?, windowTitle: String?) -> AppCategory {
        let base = category(for: bundleID)
        guard base == .other, let id = bundleID, browsers.contains(id), let t = windowTitle?.lowercased(), !t.isEmpty else { return base }
        for (cat, keys) in siteRules where keys.contains(where: { t.contains($0) }) { return cat }
        return base
    }
}
