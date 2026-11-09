import Testing
import Foundation
@testable import BNFlowCore

struct MockChat: ChatProvider {
    let reply: @Sendable (String, String) -> String
    func complete(system: String, user: String) async -> Result<String, FlowError> { .success(reply(system, user)) }
}

@Suite struct EvalTests {
    @Test func testWER() {
        #expect(EvalScoring.wer(reference: "Holnap megyek, és veszek tejet.", hypothesis: "holnap megyek és veszek tejet") == 0)
        #expect(EvalScoring.wer(reference: "a b c d", hypothesis: "a x c") == 0.5)
        #expect(EvalScoring.wer(reference: "", hypothesis: "") == 0)
        #expect(EvalScoring.wer(reference: "", hypothesis: "Köszönöm.") == 1)
    }
    @Test func testSimilarityAndChecks() {
        #expect(EvalScoring.similarity("abc", "abc") == 1)
        let c = EvalCase("t", "x", "hu", raw: "", expected: "Tizenegykor találkozzunk.", contain: ["tizenegykor|11-kor"], notContain: ["tíz"])
        let good = EvalScoring.score(c, output: "Holnap 11-kor találkozzunk.")
        #expect(good.failedChecks.isEmpty)
        // „tíz” egész szóként tiltott, a „tizenegy” nem bukik rajta
        let bad = EvalScoring.score(c, output: "Tíz órakor találkozzunk.")
        #expect(bad.failedChecks.count == 2)
        #expect(EvalScoring.score(c, output: "Tizenegykor találkozzunk.").exact)
    }
    @Test func testWAVRoundTrip() {
        let s: [Float] = [0, 0.5, -0.5, 0.25]
        let d = WAV.encode(samples: WAV.floatToInt16(s))
        let back = WAV.decode(d)
        #expect(back?.sampleRate == 16_000)
        #expect(back?.samples.count == 4)
        #expect(abs((back?.samples[1] ?? 0) - 0.5) < 0.001)
    }
    @Test func testVariants() {
        let s = [Float](repeating: 0.5, count: 1600)
        #expect(EvalRunner.makeVariant(s, .quiet).max()! < 0.02)
        #expect(EvalRunner.makeVariant(s, .padded).count == 1600 + 48_000)
        #expect(EvalRunner.makeVariant(s, .noise).count == 32_000)
    }
    @Test func testRunnerLocalAndMock() async {
        let local = await EvalRunner.runText(chat: nil)
        #expect(!local.isEmpty)
        #expect(!local.contains { $0.category == "command" })
        let echo = MockChat { _, user in user }
        let llm = await EvalRunner.runText(Array(EvalSuite.text.prefix(3)), chat: echo)
        #expect(llm.count == 3)
        #expect(llm.allSatisfy { $0.usedLLM })
    }
}
