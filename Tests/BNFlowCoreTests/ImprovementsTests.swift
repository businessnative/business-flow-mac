import Testing
import Foundation
@testable import BNFlowCore

/// 0.3.0: átnevezés-migráció, kimondott írásjelek, gyorsabb formázás, suttogó mód.
struct ImprovementsTests {
    // MARK: Adatmappa-migráció („BN Flow” → „Business Flow”)

    func tempBase() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bf-mig-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func testSupportDirMigratesLegacyFolder() throws {
        let base = tempBase()
        let old = base.appendingPathComponent("BN Flow", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old.appendingPathComponent("settings.json"))
        let dir = AppPaths.resolveSupportDirectory(base: base)
        #expect(dir.lastPathComponent == "Business Flow")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func testSupportDirKeepsExistingNewFolder() throws {
        let base = tempBase()
        let old = base.appendingPathComponent("BN Flow", isDirectory: true)
        let new = base.appendingPathComponent("Business Flow", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let dir = AppPaths.resolveSupportDirectory(base: base)
        #expect(dir == new)
        #expect(FileManager.default.fileExists(atPath: old.path)) // nem írjuk felül, nem töröljük
    }

    @Test func testSupportDirFreshInstall() {
        let base = tempBase()
        #expect(AppPaths.resolveSupportDirectory(base: base).lastPathComponent == "Business Flow")
        #expect(AppPaths.appName == "Business Flow")
    }

    // MARK: Kimondott írásjelek (magyar + angol)

    @Test func testSpokenPunctuationHungarian() {
        #expect(TextPipeline.applySpokenPunctuation("mikor jössz kérdőjel holnap várlak") == "mikor jössz? Holnap várlak")
        #expect(TextPipeline.applySpokenPunctuation("szia vessző hogy vagy") == "szia, hogy vagy")
        #expect(TextPipeline.applySpokenPunctuation("ez nagyszerű felkiáltójel") == "ez nagyszerű!")
        #expect(TextPipeline.applySpokenPunctuation("a lista kettőspont alma") == "a lista: alma")
        #expect(TextPipeline.applySpokenPunctuation("kész pontosvessző jöhet") == "kész; jöhet")
    }

    @Test func testSpokenPunctuationEnglishAndNoFalsePositives() {
        #expect(TextPipeline.applySpokenPunctuation("are you coming question mark") == "are you coming?")
        #expect(TextPipeline.applySpokenPunctuation("great exclamation point") == "great!")
        // Összetett szavakat és a „pont” köznevet nem bántjuk.
        #expect(TextPipeline.applySpokenPunctuation("a kérdőjeles mondat pont jó") == "a kérdőjeles mondat pont jó")
        #expect(TextPipeline.applySpokenPunctuation("Holnap jövök.") == "Holnap jövök.")
    }

    @Test func testSpokenPunctuationInPipeline() {
        var s = AppSettings(); s.voiceCommands = true
        let out = TextPipeline.process("mikor érsz ide kérdőjel", settings: s, tone: .formal)
        #expect(out.hasSuffix("?"))
        #expect(!out.lowercased().contains("kérdőjel"))
        s.voiceCommands = false
        #expect(TextPipeline.process("mikor érsz ide kérdőjel", settings: s, tone: .formal).lowercased().contains("kérdőjel"))
    }

    // MARK: Gyorsabb formázás: rövid, tiszta mondatnál nincs LLM-hívás

    @Test func testFormatPolicy() {
        #expect(!FormatPolicy.needsLLM(raw: "Holnap jövök."))
        #expect(!FormatPolicy.needsLLM(raw: "Holnap délután átküldöm az ajánlatot neked."))
        #expect(!FormatPolicy.needsLLM(raw: "I will send the deck tomorrow morning."))
        #expect(FormatPolicy.needsLLM(raw: "Holnap kettőkor, vagyis háromkor találkozunk."))
        #expect(FormatPolicy.needsLLM(raw: "Let's meet at two, actually three."))
        #expect(FormatPolicy.needsLLM(raw: "Öhm holnap átküldöm az ajánlatot."))
        #expect(FormatPolicy.needsLLM(raw: "hogy hogy nem jött el senki tegnap este"))
        #expect(FormatPolicy.needsLLM(raw: String(repeating: "szó ", count: 20)))
        #expect(FormatPolicy.needsLLM(raw: "holnap délután háromkor átküldöm neked az ajánlatot és a szerződést"))
    }

    actor CountingChat: ChatProvider {
        var calls = 0
        func complete(system: String, user: String) async -> Result<String, FlowError> { calls += 1; return .success(user) }
        func count() -> Int { calls }
    }

    @Test func testShortCleanDictationSkipsLLM() async {
        let chat = CountingChat()
        var s = AppSettings(); s.smartFormatting = true
        let r = await DictationFormatter.format(raw: "Holnap délután átküldöm az ajánlatot.", settings: s, context: .empty, chat: chat)
        #expect(r.usedLLM == false)
        #expect(await chat.count() == 0)
        #expect(r.text == "Holnap délután átküldöm az ajánlatot.")
    }

    // MARK: Suttogó mód

    func whisper(amplitude: Float, noise: Float, rumble: Float = 0) -> [Float] {
        var x: UInt64 = 11
        func rnd() -> Float { x = x &* 6364136223846793005 &+ 1442695040888963407; return Float(x >> 40) / Float(1 << 24) - 0.5 }
        var out: [Float] = []
        for i in 0..<48_000 {
            let t = Double(i) / 16_000
            var v = rnd() * noise + Float(sin(2 * .pi * 50 * t)) * rumble
            // Szótagszerű, 4 Hz-es burkolójú, zajos (suttogásszerű) jel a középső 2 másodpercben.
            if i > 8_000 && i < 40_000 {
                let env = Float(max(0, sin(2 * .pi * 4 * t)))
                v += (rnd() * 0.6 + Float(sin(2 * .pi * 1800 * t)) * 0.4) * amplitude * env
            }
            out.append(v)
        }
        return out
    }

    @Test func testWhisperIsDetectedNotSilent() {
        let w = whisper(amplitude: 0.006, noise: 0.0002)
        let st = AudioPrep.analyze(w)
        #expect(st.peak < 0.01)
        #expect(AudioPrep.isWhisper(st))
        #expect(!AudioPrep.isSilent(st))
    }

    @Test func testWhisperGainAndGate() {
        let w = whisper(amplitude: 0.006, noise: 0.0002)
        let p = AudioPrep.prepare(w)
        let peak = p.map { abs($0) }.max() ?? 0
        #expect(peak > 0.15) // 40×-es plafon: ~0,17 (a régi 20×-ossal ~0,08 lett volna)
        // A beszédszünetek zaja halk marad.
        let st = AudioPrep.analyze(p)
        #expect(st.noiseFloor < 0.03)
    }

    @Test func testGainCappedByNoise() {
        #expect(AudioPrep.gain(peak: 0.01, noiseFloor: 0) == 40)
        #expect(abs(AudioPrep.gain(peak: 0.01, noiseFloor: 0.002) - 10) < 0.001)
        #expect(AudioPrep.gain(peak: 0.5, noiseFloor: 0) == 1)
    }

    @Test func testHighPassRemovesRumble() {
        let hum = (0..<16_000).map { Float(sin(2 * Double.pi * 20 * Double($0) / 16_000)) * 0.2 + 0.1 }
        let f = AudioPrep.highPass(hum)
        let tail = f.suffix(8_000).map { abs($0) }.max() ?? 1
        #expect(tail < 0.06)
        let voice = (0..<16_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 16_000)) * 0.2 }
        #expect((AudioPrep.highPass(voice).suffix(8_000).map { abs($0) }.max() ?? 0) > 0.18)
    }

    @Test func testSteadyNoiseStillSilent() {
        let n = whisper(amplitude: 0, noise: 0.004)
        #expect(AudioPrep.isSilent(AudioPrep.analyze(n)))
    }
}
