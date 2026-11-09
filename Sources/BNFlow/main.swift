import AppKit
import Foundation
import BNFlowCore

// Parancssori kulcsimport: a kulcs értékét soha nem írja ki.
//   "Business Flow.app/Contents/MacOS/BNFlow" --import-env "<.env útvonal>" [--key OPENAI_API_KEY]
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--import-env") {
    guard i + 1 < args.count else { FileHandle.standardError.write("Használat: --import-env <fájl> [--key NÉV]\n".data(using: .utf8)!); exit(2) }
    let path = (args[i + 1] as NSString).expandingTildeInPath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("Nem olvasható: \(path)"); exit(1) }
    // --key nélkül minden ismert szolgáltató kulcsát importálja (OPENAI/ANTHROPIC/GEMINI…), ami a fájlban van.
    var names: [String] = AIProvider.allCases.flatMap(\.envNames)
    if let k = args.firstIndex(of: "--key"), k + 1 < args.count { names = [args[k + 1]] }
    var done = Set<AIProvider>()
    for name in names {
        guard let p = AIProvider.forEnvName(name), !done.contains(p), let value = EnvFile.value(for: name, in: text), !value.isEmpty else { continue }
        if Keychain.save(value, for: p) { done.insert(p); print("\(name) → \(p.label): elmentve az alkalmazás kulcstárába (\(value.count) karakter).") }
    }
    exit(done.isEmpty ? 1 : 0)
}
if args.contains("--migrate-legacy") { print("régi Kulcskarika-elem: \(Keychain.migrateLegacy())"); exit(0) }
if args.contains("--check-models") { exit(Diagnostics.checkModels()) }
if let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { Diagnostics.renderPreviews(to: (args[i + 1] as NSString).expandingTildeInPath) }
    exit(0)
}
if args.contains("--eval") { exit(EvalCLI.run(args)) }
if let i = args.firstIndex(of: "--probe"), i + 3 < args.count {
    // Diagnosztika: egy teszt-WAV átírása a megadott szolgáltatóval/modellel; csak HTTP-státuszt és (kulcs-mentesített) hibát ír ki.
    let p = AIProvider(rawValue: args[i + 1]) ?? .openai, model = args[i + 2]
    guard let key = Keychain.read(p), let wav = FileManager.default.contents(atPath: args[i + 3]) else { print("nincs kulcs/wav"); exit(2) }
    let req = p == .gemini ? GeminiAPI.makeTranscriptionRequest(apiKey: key, model: model, wav: wav, language: .hu, terms: [])
                           : OpenAIClient().makeTranscriptionRequest(apiKey: key, wav: wav, model: model, language: .hu, terms: [])
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out = ""
    URLSession.shared.dataTask(with: req) { d, r, e in
        let st = (r as? HTTPURLResponse)?.statusCode ?? -1
        var body = String(decoding: (d ?? Data()).prefix(400), as: UTF8.self)
        body = body.replacingOccurrences(of: #"(sk-|AIza)[A-Za-z0-9_*\-]+"#, with: "<kulcs>", options: .regularExpression)
        out = "\(p.short) \(model): HTTP \(st)" + (st == 200 ? " (válasz \(d?.count ?? 0) bájt)" : " \(body)") + (e.map { " hiba: \($0.localizedDescription)" } ?? "")
        sem.signal()
    }.resume()
    sem.wait(); print(out); exit(0)
}
if let i = args.firstIndex(of: "--test-key") {
    // Ingyenes ellenőrzés (modell-lista GET); a kulcsot nem írja ki. Alapból csak OpenAI.
    let p = i + 1 < args.count ? AIProvider(rawValue: args[i + 1]) ?? .openai : .openai
    guard let key = Keychain.read(p) else { print("\(p.short): nincs kulcs"); exit(2) }
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var ok = false
    Task.detached { if case .success = await AIRouter(http: OpenAIClient()).testKey(p, key: key) { ok = true }; sem.signal() }
    sem.wait()
    print("\(p.short) kulcs: \(ok ? "érvényes" : "HIBÁS")")
    exit(ok ? 0 : 1)
}
if args.contains("--has-key") {
    let k = Keychain.all()
    for p in AIProvider.allCases { print("\(p.short): \(k[p] != nil ? "van kulcs (\(k[p]!.count) karakter)" : "nincs kulcs")") }
    exit(0)
}

if let i = args.firstIndex(of: "--self-test") {
    // Önteszt: elkülönített, ideiglenes adatmappa; a valódi beállítások, előzmények, Kulcskarika és engedélyek érintetlenek.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("business-flow-selftest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv("BUSINESS_FLOW_SUPPORT_DIR", dir.path, 1)
    AppPaths.supportDirectory = dir
    MainActor.assumeIsolated {
        TestMode.isOn = true
        TestMode.staticUI = true
        SelfTest.outPath = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? (args[i + 1] as NSString).expandingTildeInPath : nil
        if let k = args.firstIndex(of: "--passes"), k + 1 < args.count, let n = Int(args[k + 1]) { SelfTest.passes = max(1, n) }
        SelfTest.tempDir = dir
    }
}

if let i = args.firstIndex(of: "--e2e") {
    // Élő E2E: elkülönített adatmappa a valódi beállítások másolatával (az előzmények érintetlenek).
    let real = AppPaths.supportDirectory
    Keychain.storeURL = real.appendingPathComponent("keys.enc")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("business-flow-e2e-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: real.appendingPathComponent("settings.json"), to: dir.appendingPathComponent("settings.json"))
    setenv("BUSINESS_FLOW_SUPPORT_DIR", dir.path, 1)
    AppPaths.supportDirectory = dir
    MainActor.assumeIsolated {
        E2E.isOn = true
        if i + 1 < args.count, !args[i + 1].hasPrefix("--") { E2E.outPath = (args[i + 1] as NSString).expandingTildeInPath }
    }
}

// Egyszeri, ablakmentes áthozatal a régi Kulcskarika-elemből (háttérszál, max. 3 mp).
if !MainActor.assumeIsolated({ TestMode.isOn }) && !E2E.isOn && Keychain.legacyExists() {
    let sem = DispatchSemaphore(value: 0)
    Thread.detachNewThread { NSLog("Business Flow: legacy keychain migration: \(Keychain.migrateLegacy())"); sem.signal() }
    _ = sem.wait(timeout: .now() + 3)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
