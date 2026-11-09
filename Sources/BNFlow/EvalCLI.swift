import Foundation
import BNFlowCore

/// `--eval [local|llm|audio|all] [--label NÉV] [--out MAPPA]`
/// - local: csak a helyi lánc (ingyenes, offline)
/// - llm:   okos formázás + parancs mód az OpenAI-val (a Kulcskarikából olvasott kulccsal; néhány cent)
/// - audio: `say`-jel szintetizált magyar/angol hang → átírás → WER (néhány cent)
/// Semmilyen titkot és valódi diktálást nem ír ki; csak a beépített, szintetikus teszteseteket.
enum EvalCLI {
    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    static func blocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<T?>(nil)
        Task.detached { box.value = await body(); sem.signal() }
        sem.wait()
        return box.value!
    }

    static func pct(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }

    static func run(_ args: [String]) -> Int32 {
        var mode = "local", label = "run", out = "eval/results"
        if let i = args.firstIndex(of: "--eval"), i + 1 < args.count, !args[i + 1].hasPrefix("--") { mode = args[i + 1] }
        if let i = args.firstIndex(of: "--label"), i + 1 < args.count { label = args[i + 1] }
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count { out = (args[i + 1] as NSString).expandingTildeInPath }
        let only = args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let settings = JSONFileStore<AppSettings>(url: AppPaths.supportDirectory.appendingPathComponent("settings.json")).load() ?? AppSettings()
        let client = OpenAIClient()
        let needsKey = mode != "local"
        let key = needsKey ? Keychain.read(interactive: false) : nil
        if needsKey && key == nil { print(Keychain.lastReadNeedsApproval ? "a kulcs olvasásához Kulcskarika-jóváhagyás kell — kihagyva" : "nincs kulcs a Kulcskarikában"); return 1 }
        var report: [String: Any] = ["label": label, "mode": mode, "date": ISO8601DateFormatter().string(from: Date()),
                                     "chatModel": settings.chatModel, "transcriptionModel": settings.transcriptionModel]
        let cases = EvalSuite.text.filter { only == nil || $0.id.hasPrefix(only!) || $0.category == only! }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        func json<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with: enc.encode(v))) ?? [:] }

        func textRun(_ name: String, chat: ChatProvider?) {
            print("== \(name) (\(cases.filter { chat != nil || !$0.command }.count) eset) ==")
            let res = blocking { await EvalRunner.runText(cases, chat: chat) { r in
                let mark = r.failedChecks.isEmpty ? "✓" : "✗"
                print("\(mark) \(r.id) [\(String(format: "%.2f", r.score))] \(r.latencyMs) ms\(r.llmRejected ? " (LLM elutasítva)" : "")\(r.failedChecks.isEmpty ? "" : " hiányzik: " + r.failedChecks.joined(separator: ", "))")
            } }
            let sum = EvalSummary(label: label, mode: name, results: res)
            print("→ \(name): pontszám \(pct(sum.meanScore)), ellenőrzések \(pct(sum.checkPassRate)), pontos egyezés \(pct(sum.exactRate)), medián késleltetés \(sum.medianLatencyMs) ms")
            for (k, v) in sum.byCategory.sorted(by: { $0.key < $1.key }) { print("   \(k): \(pct(v))") }
            report[name] = ["summary": json(sum), "cases": json(res)]
        }

        if mode == "local" || mode == "all" { textRun("local", chat: nil) }
        if (mode == "llm" || mode == "all"), let key {
            textRun("llm", chat: OpenAIChat(client: client, apiKey: key, model: settings.chatModel, fallbackModel: settings.fallbackChatModel))
        }
        if (mode == "audio" || mode == "all"), let key {
            report["audio"] = audioRun(client: client, key: key, settings: settings, only: only, json: json)
        }
        let path = (out as NSString).appendingPathComponent("\(label)-\(mode).json")
        if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path)); print("eredmény: \(path)")
        }
        return 0
    }

    static func synthesize(_ c: EvalAudioCase, cacheDir: URL) -> [Float]? {
        if c.variant == .noise { return [] }
        let name = String(format: "%08x", UInt32(truncatingIfNeeded: c.text.hashValueStable ^ c.voice.hashValueStable)) + ".wav"
        let file = cacheDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", c.voice, "-o", file.path, "--file-format=WAVE", "--data-format=LEI16@16000", c.text]
            do { try p.run(); p.waitUntilExit() } catch { return nil }
            guard p.terminationStatus == 0 else { return nil }
        }
        guard let d = try? Data(contentsOf: file), let w = WAV.decode(d), w.sampleRate == 16_000 else { return nil }
        return w.samples
    }

    static func audioRun(client: OpenAIClient, key: String, settings: AppSettings, only: String?, json: (([EvalAudioResult]) -> Any)) -> Any {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Business Flow/eval-tts")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cases = EvalSuite.audio.filter { only == nil || $0.id.hasPrefix(only!) }
        print("== audio (\(cases.count) eset, modell: \(settings.transcriptionModel)) ==")
        var results: [EvalAudioResult] = []
        for c in cases {
            guard let clean = synthesize(c, cacheDir: cache) else { print("✗ \(c.id): a hangszintézis nem sikerült"); continue }
            let samples = EvalRunner.makeVariant(clean, c.variant)
            let stats = AudioPrep.analyze(samples)
            let peak = stats.peak
            let t0 = Date()
            var transcript = "", err: String?
            if AudioPrep.isSilent(stats) {
                transcript = ""
            } else {
                let prepared = AudioPrep.prepare(samples)
                let wav = WAV.encode(samples: WAV.floatToInt16(prepared))
                var s = settings
                if !c.terms.isEmpty { s.dictionary = c.terms.map { DictionaryEntry(term: $0) } }
                let lang: DictationLanguage = .auto
                let terms = s.dictionary.map(\.term)
                let tm = s.transcriptionModel, fm = s.fallbackTranscriptionModel
                switch blocking({ await client.transcribe(apiKey: key, wav: wav, model: tm, fallbackModel: fm, language: lang, terms: terms) }) {
                case .success(let t): transcript = AudioPrep.cleanTranscript(t, peak: peak, speechSeconds: stats.speechSeconds)
                case .failure(let e): if e != .emptyResult { err = "\(e)" }
                }
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let w = EvalScoring.wer(reference: c.text, hypothesis: transcript)
            let r = EvalAudioResult(id: c.id, variant: c.variant.rawValue, reference: c.text, transcript: transcript, wer: w, latencyMs: ms, error: err)
            print("\(w <= 0.1 ? "✓" : "✗") \(c.id) (\(c.variant.rawValue)) WER \(pct(w)) \(ms) ms\(err.map { " hiba: \($0)" } ?? "")")
            if w > 0 { print("   ref: \(c.text)\n   hyp: \(transcript)") }
            results.append(r)
        }
        let speech = results.filter { $0.variant != "noise" }
        let mean = speech.isEmpty ? 0 : speech.map(\.wer).reduce(0, +) / Double(speech.count)
        let hall = results.filter { $0.variant == "noise" && !$0.transcript.isEmpty }.count
        let lat = speech.map(\.latencyMs).sorted()
        print("→ audio: átlagos WER \(pct(mean)), hallucináció zajra: \(hall)/\(results.filter { $0.variant == "noise" }.count), medián \(lat.isEmpty ? 0 : lat[lat.count / 2]) ms")
        return ["meanWER": mean, "hallucinations": hall, "cases": json(results)]
    }
}

extension String {
    /// Futásonként stabil hash (a Swift `hashValue` véletlenített).
    var hashValueStable: UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}
