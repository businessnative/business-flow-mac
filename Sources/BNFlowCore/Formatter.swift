import Foundation

/// A fókuszban lévő mező környezete egy diktáláskor (csak memóriában, a diktálás végén eldobjuk).
public struct DictationContext: Sendable, Equatable {
    public var appName: String
    public var bundleID: String?
    /// A böngészőablak vagy dokumentum címe (oldalfelismeréshez: Gmail, Slack a böngészőben stb.).
    public var windowTitle: String?
    /// A kurzor előtti szöveg (legfeljebb néhány száz karakter).
    public var before: String
    /// A kurzor utáni szöveg (legfeljebb néhány száz karakter).
    public var after: String
    public var selected: String?
    /// Jelszómező: ilyenkor semmilyen tartalmat nem olvasunk és nem küldünk.
    public var isSecure: Bool

    public init(appName: String = "", bundleID: String? = nil, windowTitle: String? = nil, before: String = "", after: String = "",
                selected: String? = nil, isSecure: Bool = false) {
        self.appName = appName; self.bundleID = bundleID; self.windowTitle = windowTitle
        self.before = before; self.after = after; self.selected = selected; self.isSecure = isSecure
    }
    public static let empty = DictationContext()
}

/// Nyelvi modell absztrakció (tesztelhetőség, értékelés).
public protocol ChatProvider: Sendable {
    func complete(system: String, user: String) async -> Result<String, FlowError>
    /// `prediction` a helyi piszkozat. A szolgáltató figyelmen kívül hagyhatja. A visszaadott szöveg a modell válasza.
    func complete(system: String, user: String, prediction: String?) async -> Result<String, FlowError>
}

public extension ChatProvider {
    func complete(system: String, user: String, prediction: String?) async -> Result<String, FlowError> {
        await complete(system: system, user: user)
    }
}

public struct FormatResult: Sendable, Equatable {
    public var text: String
    public var usedLLM: Bool
    /// Az LLM kimenetét az őr elutasította (pl. válaszolt a szövegre), és a helyi lánc eredménye ment ki.
    public var llmRejected: Bool
    public init(text: String, usedLLM: Bool, llmRejected: Bool = false) { self.text = text; self.usedLLM = usedLLM; self.llmRejected = llmRejected }
}

/// Diktálás → beilleszthető szöveg (helyi lánc + opcionális LLM-formázás őrrel és időkorláttal).
/// Az alkalmazás és az értékelő (`--eval`) is ezt használja.
public enum DictationFormatter {
    public static func category(for context: DictationContext) -> AppCategory {
        AppCategoryResolver.category(for: context.bundleID, windowTitle: context.windowTitle)
    }

    public static func format(raw: String, settings s: AppSettings, context: DictationContext, chat: ChatProvider?) async -> FormatResult {
        let cat = category(for: context)
        let tone = s.tone(for: cat)
        let ctx = s.contextAwareness ? context : DictationContext(appName: context.appName, bundleID: context.bundleID, windowTitle: context.windowTitle)
        let local = TextPipeline.process(raw, settings: s, tone: tone, context: ctx, category: cat)
        // Rövid, egyszerű diktálásnál az LLM nem ad hozzá semmit, csak késleltet.
        guard s.smartFormatting, let chat, FormatPolicy.needsLLM(raw: raw) else { return FormatResult(text: local, usedLLM: false) }
        let terms = s.dictionary.map(\.term) + TextRules.contextNames(ctx)
        let system = Prompts.smartFormatting(tone: tone, terms: terms, category: cat)
        let user = Prompts.smartFormattingUser(raw: raw, context: ctx)
        let result = await withTimeout(seconds: s.llmTimeoutSeconds) { await chat.complete(system: system, user: user, prediction: local) }
        guard case .success(let out)? = result else { return FormatResult(text: local, usedLLM: false) }
        let cleaned = Prompts.cleanOutput(out)
        guard LLMGuard.accept(raw: raw, local: local, output: cleaned) else { return FormatResult(text: local, usedLLM: false, llmRejected: true) }
        // Az LLM-kimenetre is lefut a helyi lánc (szótár, stílus, környezet), hogy a szabályok mindig érvényesüljenek.
        var post = s
        post.removeFillers = false
        let final = TextPipeline.process(cleaned, settings: post, tone: tone, context: ctx, category: cat)
        return FormatResult(text: final, usedLLM: true)
    }

    /// Időkorlát egy aszinkron hívásra: ha lejár, `nil` (a hívó a helyi eredményt használja).
    public static func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await op() }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0.5, seconds) * 1_000_000_000)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }
}

/// Az LLM-kimenet ellenőrzése: nem válaszolhat a diktálásra, nem hagyhat ki/találhat ki tartalmat.
/// Mikor érdemes a nyelvi modellt hívni? A rövid, tiszta mondatoknál a helyi lánc ugyanazt adja, csak gyorsabban
/// (nincs 0,5–1,5 s-os modellhívás). Önjavítás, felsorolás vagy hosszabb szöveg esetén mindig az LLM formáz.
public enum FormatPolicy {
    static let correctionCues = ["vagyis", "mármint", "illetve", "helyesbítek", "bocsánat", "nem is", "várj", "inkább", "jobban mondva",
                                 "i mean", "actually", "scratch that", "sorry", "no wait", "rather"]
    static let listCues = ["először", "másodszor", "harmadszor", "egyrészt", "pontok", "lista", "egyes", "kettes", "first", "second", "third",
                           "bullet", "számozott"]
    // Az „új sor / új bekezdés” hangparancsokat a helyi lánc pontosan kezeli; az LLM-et nem indítják (gyorsabb, determinisztikus).
    public static let shortWordLimit = 12

    public static func needsLLM(raw: String) -> Bool {
        let words = TextStats.wordCount(raw)
        if words <= 3 { return false }
        if words > shortWordLimit { return true }
        let l = " " + raw.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression) + " "
        let padded = l.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if (correctionCues + listCues).contains(where: { padded.contains(" \($0) ") }) { return true }
        // Töltelékszó vagy ismétlés („a a”, „hogy hogy”) → az LLM tisztábban rendezi.
        let toks = padded.split(separator: " ")
        if zip(toks, toks.dropFirst()).contains(where: { $0 == $1 }) { return true }
        if toks.contains(where: { ["öhm", "ömm", "hmm", "izé", "um", "uh", "ö", "öö"].contains(String($0)) }) { return true }
        // Számok, e-mail, URL: a helyi szabályok kezelik; írásjel nélküli hosszabb mondatnál az LLM tagol jobban.
        let hasPunct = raw.range(of: #"[.?!,]"#, options: .regularExpression) != nil
        return !hasPunct && words > 8
    }
}

public enum LLMGuard {
    static func contentStems(_ s: String) -> [String] {
        TextRules.words(s).filter { $0.count >= 4 }.map { String($0.prefix(4)) }
    }

    public static func accept(raw: String, local: String, output: String) -> Bool {
        let out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return false }
        let rw = max(1, TextStats.wordCount(local)), ow = TextStats.wordCount(out)
        let lo = Double(rw) * 0.3 - 2, hi = Double(rw) * 1.8 + 3
        guard Double(ow) >= lo, Double(ow) <= hi else { return false }
        let src = Set(contentStems(raw + " " + local)), dst = contentStems(out)
        if !dst.isEmpty {
            let novel = dst.filter { !src.contains($0) }.count
            if Double(novel) / Double(dst.count) > 0.4 { return false }
        }
        let srcStems = Set(contentStems(local))
        if !srcStems.isEmpty {
            let kept = srcStems.filter { Set(dst).contains($0) }.count
            if Double(kept) / Double(srcStems.count) < 0.6 { return false }
        }
        if local.contains("?") && !out.contains("?") { return false }
        return true
    }
}

/// Parancs mód: kimondott utasítás a kijelölésen (vagy kijelölés nélkül szöveg írása).
public enum CommandFormatter {
    public static func run(instruction: String, context: DictationContext, chat: ChatProvider) async -> Result<String, FlowError> {
        let sel = context.selected
        return await chat.complete(system: Prompts.command(hasSelection: sel != nil),
                                   user: Prompts.commandUser(instruction: instruction, selection: sel,
                                                             before: context.isSecure ? "" : context.before,
                                                             after: context.isSecure ? "" : context.after))
    }
}
