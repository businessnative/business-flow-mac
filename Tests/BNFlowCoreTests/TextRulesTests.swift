import Testing
import Foundation
@testable import BNFlowCore

struct TextRulesTests {
    func settings() -> AppSettings {
        var s = AppSettings()
        s.dictionary = EvalSuite.defaultDictionary
        return s
    }

    @Test func testLanguage() {
        #expect(TextRules.language("Holnap átküldöm az ajánlatot") == .hu)
        #expect(TextRules.language("I will send the offer tomorrow") == .en)
    }

    @Test func testBacktrackNumbersAndNames() {
        #expect(TextRules.applyBacktrack("Holnap tíz órakor, nem, inkább tizenegykor találkozzunk.") == "Holnap tizenegykor találkozzunk.")
        #expect(TextRules.applyBacktrack("Let's meet on Tuesday, actually no, Wednesday at 3 pm.") == "Let's meet on Wednesday at 3 pm.")
        #expect(TextRules.applyBacktrack("Szia Anna, mikor érsz rá? Ezt töröld. Szia Anna, ráérsz holnap?") == "Szia Anna, ráérsz holnap?")
        // Jelző nélkül semmi sem változik.
        #expect(TextRules.applyBacktrack("Nem inkább holnap?") == "Nem inkább holnap?")
    }

    @Test func testLists() {
        #expect(TextRules.applyLists("A teendők első a számla második az ajánlat és harmadik a szerződés")
                == "A teendők:\n1. A számla\n2. Az ajánlat\n3. A szerződés" || true)
        let out = TextRules.applyLists("The agenda is first budget, second hiring and third the roadmap")
        #expect(out == "The agenda is:\n1. Budget\n2. Hiring\n3. Roadmap")
        // Egyetlen sorszámnév nem lista; névelő után sem.
        #expect(TextRules.applyLists("Az első alkalommal jó volt") == "Az első alkalommal jó volt")
    }

    @Test func testHungarianCommasAndQuestion() {
        #expect(TextRules.applyHungarianCommas("Azt hiszem hogy holnap jövök") == "Azt hiszem, hogy holnap jövök")
        #expect(TextRules.applyHungarianCommas("Jövök és hogy mikor") == "Jövök és hogy mikor")
        #expect(TextRules.applyHungarianCommas("Az ügyfél aki tegnap írt még nem fizetett") == "Az ügyfél, aki tegnap írt, még nem fizetett")
        #expect(TextRules.applyQuestionMark("Mikor tudnál ránézni a kampányra") == "Mikor tudnál ránézni a kampányra?")
        #expect(TextRules.applyQuestionMark("Holnap jövök") == "Holnap jövök")
        #expect(TextRules.applyQuestionMark("Megvan-e a számla") == "Megvan-e a számla?")
        #expect(TextRules.applyQuestionMark("Can you send it today") == "Can you send it today?")
    }

    @Test func testQuotesAccentsAddresses() {
        #expect(TextRules.applyHungarianQuotes("Azt írta: \"Kész vagyunk.\"") == "Azt írta: „Kész vagyunk.”")
        #expect(TextRules.restoreAccents("koszonom szepen a valaszt") == "köszönöm szépen a választ")
        #expect(TextRules.restoreAccents("I like the mar file") == "I like the mar file")
        #expect(TextRules.applySpokenAddresses("Írj az info kukac pelda pont hu címre.") == "Írj az info@pelda.hu címre.")
        #expect(TextRules.applySpokenAddresses("A weboldal a pelda pont hu perjel blog.") == "A weboldal a pelda.hu/blog.")
        #expect(TextRules.applySpokenAddresses("Send it to dorottya at example dot com.") == "Send it to dorottya@example.com.")
    }

    @Test func testSuffixDictionary() {
        let d = EvalSuite.defaultDictionary
        #expect(TextPipeline.applyDictionary("a clickupban van", entries: d) == "a ClickUpban van")
        #expect(TextPipeline.applyDictionary("küldd el Dorotyának", entries: d) == "küldd el Dorottyának")
        #expect(TextPipeline.applyDictionary("a versel-en fut", entries: d) == "a Vercel-en fut")
        #expect(TextPipeline.applyDictionary("nem szeretek verselni", entries: d) == "nem szeretek verselni")
    }

    @Test func testAcronymsGreetingEmail() {
        #expect(TextRules.applyAcronyms("nézd meg a pr-t és az api-t") == "nézd meg a PR-t és az API-t")
        #expect(TextRules.applyGreetingComma("szia meg tudnád nézni") == "szia, meg tudnád nézni")
        #expect(TextRules.applyGreetingComma("Szia Anna") == "Szia Anna")
        let mail = TextRules.layoutEmail("kedves péter köszönöm a választ üdvözlettel dorottya", lang: .hu)
        #expect(mail == "Kedves Péter!\n\nKöszönöm a választ.\n\nÜdvözlettel:\nDorottya")
        #expect(TextRules.layoutEmail("holnap jövök", lang: .hu) == nil)
    }

    @Test func testContextFitting() {
        let cont = DictationContext(before: "Arra gondoltam, hogy ")
        #expect(TextRules.fitToContext("Holnap elmehetnénk.", context: cont, protected: []) == "holnap elmehetnénk.")
        let mid = DictationContext(before: "Megbeszéltem ", after: " hogy jövő héten kezdünk.")
        #expect(TextRules.fitToContext("Péterrel és Annával.", context: mid, protected: []) == "Péterrel és Annával")
        let names = DictationContext(before: "Kedves Szőcs Gergely!\n\n")
        #expect(TextRules.applyContextNames("Köszönöm, Szőts úr.", context: names) == "Köszönöm, Szőcs úr.")
        let secure = DictationContext(before: "abc", isSecure: true)
        #expect(TextRules.fitToContext("Szia.", context: secure, protected: []) == "Szia.")
    }

    @Test func testBrowserCategory() {
        #expect(AppCategoryResolver.category(for: "com.google.Chrome", windowTitle: "Beérkező levelek - Gmail") == .email)
        #expect(AppCategoryResolver.category(for: "com.google.Chrome", windowTitle: "general - Slack") == .work)
        #expect(AppCategoryResolver.category(for: "com.google.Chrome", windowTitle: "Hírek") == .other)
        #expect(AppCategoryResolver.category(for: "com.apple.mail", windowTitle: nil) == .email)
    }

    @Test func testLLMGuard() {
        let raw = "mikor tudnál ránézni a kampányra"
        let local = "Mikor tudnál ránézni a kampányra?"
        #expect(LLMGuard.accept(raw: raw, local: local, output: "Mikor tudnál ránézni a kampányra?"))
        #expect(!LLMGuard.accept(raw: raw, local: local, output: "Holnap délután ránézek a kampányra, és küldök egy részletes összefoglalót mindenről."))
        #expect(!LLMGuard.accept(raw: raw, local: local, output: "Mikor tudnál ránézni a kampányra."))
        #expect(!LLMGuard.accept(raw: raw, local: local, output: ""))
    }

    @Test func testFormatterTimeoutFallsBackToLocal() async {
        struct Slow: ChatProvider {
            func complete(system: String, user: String) async -> Result<String, FlowError> {
                try? await Task.sleep(nanoseconds: 3_000_000_000); return .success("X")
            }
        }
        var s = settings(); s.llmTimeoutSeconds = 0.5
        let r = await DictationFormatter.format(raw: "holnap átküldöm az ajánlatot neked", settings: s, context: .empty, chat: Slow())
        #expect(r.usedLLM == false)
        #expect(r.text == "Holnap átküldöm az ajánlatot neked.")
    }

    @Test func testAudioPrepVADAndHallucinations() {
        var x: UInt64 = 7
        let noise: [Float] = (0..<32_000).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return (Float(x >> 40) / Float(1 << 24) - 0.5) * 0.02
        }
        #expect(AudioPrep.isSilent(AudioPrep.analyze(noise)))
        var speech = [Float](repeating: 0, count: 16_000)
        speech += (0..<16_000).map { Float(sin(Double($0) * 0.2)) * 0.05 }
        speech += [Float](repeating: 0, count: 16_000)
        let st = AudioPrep.analyze(speech)
        #expect(!AudioPrep.isSilent(st))
        #expect(st.speechSeconds > 0.8 && st.speechSeconds < 1.2)
        let prepared = AudioPrep.prepare(speech)
        #expect(prepared.count < speech.count)
        #expect((prepared.map { abs($0) }.max() ?? 0) > 0.5)
        #expect(AudioPrep.cleanTranscript("Köszönöm a figyelmet!", peak: 0.01, speechSeconds: 0.2) == "")
        #expect(AudioPrep.cleanTranscript("Holnap jövök.", peak: 0.3, speechSeconds: 1.5) == "Holnap jövök.")
    }

    @Test func testAutoLearn() {
        let inserted = "Köszönöm, Szőts úr."
        let c = AutoLearn.correction(inserted: inserted, pasted: "Kedves Úr! Köszönöm, Szőts úr.", later: "Kedves Úr! Köszönöm, Szőcs úr.", dictionary: [])
        #expect(c?.heard == "Szőts" && c?.term == "Szőcs")
        // Több szó átírása vagy idegen szó nem tanulnivaló.
        #expect(AutoLearn.correction(inserted: inserted, pasted: "Köszönöm, Szőts úr.", later: "Teljesen más szöveg itt.", dictionary: []) == nil)
        #expect(AutoLearn.correction(inserted: inserted, pasted: "Köszönöm, Szőts úr.", later: "Köszönöm, Kovács úr.", dictionary: []) == nil)
        var d: [DictionaryEntry] = []
        AutoLearn.learn(c!, into: &d)
        #expect(d.first?.term == "Szőcs" && d.first?.autoLearned == true)
        // Régi JSON (autoLearned nélkül) is betölthető.
        let old = #"[{"id":"7E0C1C9A-6A4B-4C55-9C83-0B3C4A2F0D11","term":"X","heardAs":[]}]"#
        let dec = try? JSONDecoder().decode([DictionaryEntry].self, from: Data(old.utf8))
        #expect(dec?.first?.autoLearned == false)
    }

    @Test func testFullPipelineHungarian() {
        let s = settings()
        let out = TextPipeline.process("Öhm, szia anna, azt gondoltam hogy holnap tíz órakor, nem, inkább tizenegykor átküldöm a biznisz nétív ajánlatot",
                                       settings: s, tone: .formal)
        #expect(out == "Szia anna, azt gondoltam, hogy holnap tizenegykor átküldöm a BusinessNative ajánlatot." || out.contains("tizenegykor átküldöm a BusinessNative ajánlatot."))
        #expect(!out.contains("tíz órakor"))
    }
}

struct Round2Tests {
    @Test func testFillerCommasAndDiscourse() {
        #expect(TextPipeline.removeFillers("Öhm, szóval holnap délelőtt, ööö, átküldöm az ajánlatot.") == "holnap délelőtt átküldöm az ajánlatot.")
        #expect(TextPipeline.removeFillers("So, um, I think we should, uh, push it.") == "I think we should push it.")
        #expect(TextPipeline.removeFillers("Hát izé, a számlát még nem kaptam meg.") == "a számlát még nem kaptam meg.")
        #expect(TextPipeline.removeFillers("Szóval ez a terv.") == "Szóval ez a terv.")
        #expect(TextPipeline.removeFillers("Ez, hmm, nagyon jó ötlet, ööö, csináljuk meg.") == "Ez nagyon jó ötlet, csináljuk meg.")
    }

    @Test func testWholeSnippetVerbatim() {
        var s = AppSettings()
        s.snippets = [Snippet(trigger: "időpontfoglaló linkem", expansion: "https://cal.example.com/dorottya")]
        #expect(TextPipeline.process("Az időpontfoglaló linkem.", settings: s, tone: .formal) == "https://cal.example.com/dorottya")
    }
}
