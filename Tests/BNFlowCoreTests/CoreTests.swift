import Testing
import Foundation
@testable import BNFlowCore

@Suite struct TextPipelineTests {
    @Test func testFillersRemoved() {
        #expect(TextPipeline.removeFillers("Öö, szóval holnap hmm megyek.") == "holnap megyek.")
        #expect(TextPipeline.removeFillers("I think, um, we should go.") == "I think we should go.")
        #expect(TextPipeline.removeFillers("Ügyfél és önkormányzat") == "Ügyfél és önkormányzat")
    }
    @Test func testVoiceCommands() {
        #expect(TextPipeline.applyVoiceCommands("Első pont új sor második pont") == "Első pont\nMásodik pont")
        #expect(TextPipeline.applyVoiceCommands("Hello. New paragraph thanks") == "Hello.\n\nThanks")
    }
    @Test func testDictionary() {
        let e = [DictionaryEntry(term: "BusinessNative", heardAs: ["biznisz nétív"]), DictionaryEntry(term: "ClickUp")]
        #expect(TextPipeline.applyDictionary("A biznisz nétív és a clickup.", entries: e) == "A BusinessNative és a ClickUp.")
    }
    @Test func testSnippets() {
        let s = [Snippet(trigger: "my calendly", expansion: "https://calendly.com/dorottya")]
        #expect(TextPipeline.applySnippets("My Calendly.", snippets: s) == "https://calendly.com/dorottya")
        #expect(TextPipeline.applySnippets("Itt a my calendly linkem", snippets: s) == "Itt a https://calendly.com/dorottya linkem")
    }
    @Test func testTones() {
        #expect(TextPipeline.applyTone("szia holnap jövök", tone: .formal) == "Szia holnap jövök.")
        #expect(TextPipeline.applyTone("Szia, holnap jövök.", tone: .casual) == "Szia, holnap jövök")
        #expect(TextPipeline.applyTone("Szia, holnap jövök. Jó lesz?", tone: .veryCasual) == "szia holnap jövök jó lesz?")
        #expect(TextPipeline.applyTone("Az API kész.", tone: .veryCasual) == "az API kész")
        #expect(TextPipeline.applyTone("Dorottya jön.", tone: .veryCasual, protectedTerms: ["Dorottya"]) == "Dorottya jön")
    }
    @Test func testLeadingSpace() {
        #expect(TextPipeline.needsLeadingSpace(before: "a", text: "szia"))
        #expect(!(TextPipeline.needsLeadingSpace(before: " ", text: "szia")))
        #expect(!(TextPipeline.needsLeadingSpace(before: "a", text: ", szia")))
        #expect(!(TextPipeline.needsLeadingSpace(before: nil, text: "szia")))
    }
    @Test func testCategory() {
        #expect(AppCategoryResolver.category(for: "com.tinyspeck.slackmacgap") == .work)
        #expect(AppCategoryResolver.category(for: "com.apple.mail") == .email)
        #expect(AppCategoryResolver.category(for: "x.y") == .other)
    }
}

@Suite struct FormatTests {
    @Test func testWAVHeader() {
        let d = WAV.encode(samples: [0, 1, -1], sampleRate: 16000)
        #expect(d.count == 44 + 6)
        #expect(String(data: d[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: d[8..<12], encoding: .ascii) == "WAVE")
    }
    @Test func testEnvParse() {
        let env = "# c\nexport OPENAI_API_KEY=\"sk-abc\"\nOTHER=1 # x\nEMPTY=\n"
        #expect(EnvFile.value(for: "OPENAI_API_KEY", in: env) == "sk-abc")
        #expect(EnvFile.value(for: "OTHER", in: env) == "1")
        #expect(EnvFile.value(for: "EMPTY", in: env) == nil)
        #expect(EnvFile.keys(in: env) == ["OPENAI_API_KEY", "OTHER", "EMPTY"])
    }
    @Test func testDiff() {
        let ops = WordDiff.diff("a b c", "a x c")
        #expect(ops == [.same("a"), .removed("b"), .added("x"), .same("c")])
    }
    @Test func testCleanOutput() {
        #expect(Prompts.cleanOutput("„Szia!”") == "Szia!")
        #expect(Prompts.cleanOutput("```\nhello\n```") == "hello")
    }
    @Test func testSettingsDecodeTolerant() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{\"sounds\":false}".utf8))
        #expect(!(s.sounds))
        #expect(s.language == .auto)
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
    }
}

@Suite struct OpenAIRequestTests {
    @Test func testTranscriptionRequestMultiLanguage() throws {
        let r = OpenAIClient().makeTranscriptionRequest(apiKey: "k", wav: Data([1]), model: "gpt-transcribe", language: .auto, terms: ["ClickUp"])
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        let body = String(decoding: try #require(r.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"languages[]\"\r\n\r\nhu"))
        #expect(body.contains("name=\"languages[]\"\r\n\r\nen"))
        #expect(body.contains("name=\"keywords[]\"\r\n\r\nClickUp"))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }
    @Test func testTranscriptionRequestLegacy() throws {
        let r = OpenAIClient().makeTranscriptionRequest(apiKey: "k", wav: Data([1]), model: "gpt-4o-transcribe", language: .hu, terms: [])
        let body = String(decoding: try #require(r.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"language\"\r\n\r\nhu"))
        #expect(!(body.contains("languages[]")))
    }
    @Test func testErrorMapping() {
        #expect(OpenAIClient.mapError(status: 401, body: nil) == .unauthorized)
        #expect(OpenAIClient.mapError(status: 429, body: Data("{\"error\":{\"code\":\"insufficient_quota\"}}".utf8)) == .quota)
        #expect(OpenAIClient.mapError(status: 429, body: nil) == .rateLimit)
        #expect(OpenAIClient.mapError(status: 503, body: nil) == .server)
        let billing = Data(#"{"error":{"code":"billing_hard_limit_reached","type":"billing","message":"billing sk-live-secret-do-not-log"}}"#.utf8)
        let mapped = OpenAIClient.mapError(status: 429, body: billing)
        #expect(mapped == .quota)
        #expect(!String(describing: mapped).contains("sk-live-secret"))
        let gemini = Data(#"{"error":{"code":429,"message":"Quota exceeded sk-gemini-secret","status":"RESOURCE_EXHAUSTED"}}"#.utf8)
        let g = OpenAIClient.mapError(status: 429, body: gemini)
        #expect(g == .quota)
        #expect(!String(describing: g).contains("sk-gemini-secret"))
        #expect(OpenAIClient.mapError(status: 429, body: Data(#"{"error":{"status":"RESOURCE_EXHAUSTED","code":429}}"#.utf8)) == .quota)
        #expect(TranscriptionLimitCopy.message(providers: [.openai, .gemini]) == "Elfogyott az átírás kerete. Nézd meg az OpenAI vagy a Gemini számlázását.")
        #expect(TranscriptionLimitCopy.message(providers: [.openai]) == "Elfogyott az átírás kerete. Nézd meg az OpenAI számlázását.")
        #expect(TranscriptionLimitCopy.message(providers: [.gemini]) == "Elfogyott az átírás kerete. Nézd meg a Gemini számlázását.")
        #expect(!TranscriptionLimitCopy.message(providers: [.openai, .gemini]).contains("sk-"))
    }
    @Test func testParseChat() {
        let d = Data("{\"choices\":[{\"message\":{\"content\":\" Kész \"}}]}".utf8)
        #expect(OpenAIClient.parseChat(d) == " Kész ")
    }
}

@Suite struct HotkeyEngineTests {
    func engine() -> HotkeyEngine { HotkeyEngine(shortcuts: .default) }

    @Test func testPushToTalk() {
        let e = engine()
        #expect(e.modifiersChanged([.fn], at: 0) == [.start(.dictation, handsFree: false)])
        #expect(e.modifiersChanged([], at: 1) == [.stop])
    }
    @Test func testShortTapCancels() {
        let e = engine()
        _ = e.modifiersChanged([.fn], at: 0)
        #expect(e.modifiersChanged([], at: 0.05) == [.cancel])
    }
    @Test func testFnSpaceLocksHandsFree() {
        let e = engine()
        _ = e.modifiersChanged([.fn], at: 0)
        let r = e.keyDown(49, isRepeat: false, at: 0.1)
        #expect(r.actions == [.lockHandsFree]); #expect(r.consume)
        #expect(e.keyUp(49))
        #expect(e.modifiersChanged([], at: 0.3) == [])
        #expect(e.modifiersChanged([.fn], at: 5) == [.stop])
        #expect(e.state == .idle)
    }
    @Test func testCommandChord() {
        let e = engine()
        _ = e.modifiersChanged([.fn], at: 0)
        #expect(e.modifiersChanged([.fn, .leftControl], at: 0.05) == [.switchKind(.command)])
        #expect(e.modifiersChanged([], at: 1) == [.stop])
    }
    @Test func testOtherKeyCancels() {
        let e = engine()
        _ = e.modifiersChanged([.fn], at: 0)
        let r = e.keyDown(123, isRepeat: false, at: 0.1)
        #expect(r.actions == [.cancel]); #expect(!(r.consume))
    }
    @Test func testEscape() {
        let e = engine()
        #expect(!(e.keyDown(53, isRepeat: false, at: 0).consume))
        _ = e.modifiersChanged([.fn], at: 0); _ = e.keyDown(49, isRepeat: false, at: 0.1)
        #expect(e.keyDown(53, isRepeat: false, at: 1).actions == [.cancel])
    }
    @Test func testPasteLastCombo() {
        let e = engine()
        _ = e.modifiersChanged([.leftControl, .leftCommand], at: 0)
        let r = e.keyDown(9, isRepeat: false, at: 0.1)
        #expect(r.actions == [.pasteLast]); #expect(r.consume)
    }
    @Test func testMouseButton5() {
        var s = ShortcutSettings.default
        s.pushToTalk.append(.mouse(button: 4))
        let e = HotkeyEngine(shortcuts: s)
        #expect(e.mouseDown(4, at: 0).actions == [.start(.dictation, handsFree: false)])
        #expect(e.mouseUp(4, at: 2).actions == [.stop])
        #expect(!(e.mouseDown(3, at: 3).consume))
    }
    @Test func testBarClick() {
        let e = engine()
        #expect(e.barClicked() == [.start(.dictation, handsFree: true)])
        #expect(e.barClicked() == [.stop])
    }
}

@Suite struct HistoryTests {
    @Test func testStatsAndPrune() {
        let now = Date()
        let items = [
            HistoryItem(date: now, text: "egy kettő három", rawText: "egy kettő három", appName: "A", bundleID: "a", durationSeconds: 3, kind: .dictation),
            HistoryItem(date: now.addingTimeInterval(-86400), text: "négy öt", rawText: "négy öt", appName: "A", bundleID: "a", durationSeconds: 2, kind: .dictation),
            HistoryItem(date: now.addingTimeInterval(-40 * 86400), text: "régi", rawText: "régi", appName: "A", bundleID: "a", durationSeconds: 0, kind: .dictation),
        ]
        let st = HistoryLogic.stats(items, now: now)
        #expect(st.totalWords == 6); #expect(st.weekWords == 5); #expect(st.streakDays == 2)
        #expect(st.averageWPM == 60)
        #expect(HistoryLogic.prune(items, retention: .days30, now: now).count == 2)
        #expect(HistoryLogic.prune(items, retention: .never, now: now).count == 0)
    }
}
