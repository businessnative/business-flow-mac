import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FlowError: Error, Equatable, Sendable {
    case noAPIKey, unauthorized, quota, rateLimit, tooLarge, badRequest(String), server, network, emptyResult, timeout

    public var message: String {
        switch self {
        case .noAPIKey: return "Nincs beállítva API-kulcs (OpenAI vagy Gemini kell az átíráshoz)."
        case .unauthorized: return "Az API-kulcs érvénytelen."
        case .quota: return "Elfogyott a kredit a szolgáltatónál — tölts fel, vagy válts szolgáltatót a Beállításokban."
        case .rateLimit: return "Túl sok kérés, próbáld újra pár másodperc múlva."
        case .tooLarge: return "A felvétel túl hosszú."
        case .badRequest: return "A szolgáltatás elutasította a kérést."
        case .server: return "Az átírási szolgáltatás most nem elérhető."
        case .network: return "Nincs hálózati kapcsolat."
        case .emptyResult: return "Nem érkezett szöveg."
        case .timeout: return "Időtúllépés."
        }
    }
    public var short: String {
        switch self {
        case .noAPIKey: return "Nincs kulcs"
        case .network: return "Nincs net"
        case .emptyResult: return "Csend"
        default: return "Hiba"
        }
    }
    var retryable: Bool { [.rateLimit, .server, .network, .timeout].contains(self) }
}

public struct Multipart {
    public let boundary: String
    public private(set) var body = Data()
    public init(boundary: String = "bnflow-\(UUID().uuidString)") { self.boundary = boundary }
    public mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    public mutating func file(_ name: String, filename: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data); body.append(Data("\r\n".utf8))
    }
    public func finished() -> Data { var b = body; b.append(Data("--\(boundary)--\r\n".utf8)); return b }
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
}

/// Közvetlen OpenAI-hívások — saját kulccsal, köztes szerver nélkül
/// (api/_lib/dictation/provider.js: /v1/audio/transcriptions, gpt-transcribe, languages[]=hu,en, prompt, keywords[]).
public final class OpenAIClient: @unchecked Sendable {
    public static let baseURL = URL(string: "https://api.openai.com/v1/")!
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30
            c.timeoutIntervalForResource = 40
            c.urlCache = nil
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.httpMaximumConnectionsPerHost = 6
            #if os(macOS)
            c.waitsForConnectivity = false
            #endif
            c.httpShouldUsePipelining = true
            self.session = URLSession(configuration: c)
        }
    }

    /// Kapcsolat előmelegítése a felvétel indításakor: hitelesítés nélküli, költségmentes HEAD kérés, hogy a TLS/HTTP2
    /// kapcsolat a felvétel végére már nyitva legyen (a feltöltés így 100–300 ms-mal hamarabb indul). Kulcsot nem küld.
    public func warmUp() {
        let now = Date()
        lock.lock()
        let recent = lastWarm.map { now.timeIntervalSince($0) < 12 } ?? false
        if !recent { lastWarm = now }
        lock.unlock()
        guard !recent else { return }
        var r = URLRequest(url: Self.baseURL)
        r.httpMethod = "HEAD"
        r.timeoutInterval = 5
        session.dataTask(with: r) { _, _, _ in }.resume()
    }
    private let lock = NSLock()
    private var lastWarm: Date?

    /// A gpt-transcribe család a többnyelvű `languages[]` és `keywords[]` mezőket fogadja (a BN backend így hívja);
    /// a régebbi modellek (gpt-4o-transcribe, whisper-1) egyetlen `language` mezőt.
    public static func usesMultiLanguageFields(_ model: String) -> Bool { model.hasPrefix("gpt-transcribe") }

    public func makeTranscriptionRequest(apiKey: String, wav: Data, model: String, language: DictationLanguage, terms: [String]) -> URLRequest {
        var r = URLRequest(url: Self.baseURL.appendingPathComponent("audio/transcriptions"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var m = Multipart()
        m.file("file", filename: "dictation.wav", mime: "audio/wav", data: wav)
        m.field("model", model)
        m.field("prompt", Prompts.transcription(language: language, terms: terms))
        if Self.usesMultiLanguageFields(model) {
            for l in language.codes { m.field("languages[]", l) }
            for t in terms.prefix(32) where !t.isEmpty { m.field("keywords[]", t) }
        } else if language != .auto {
            m.field("language", language.rawValue)
        }
        m.field("response_format", "json")
        r.setValue(m.contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = m.finished()
        r.timeoutInterval = 30
        return r
    }

    /// Érvelési szint a gpt-5/o modelleknél; a BF_REASONING_EFFORT környezeti változó felülírja (eval: "off" = nem küldjük).
    public static var reasoningEffort: String? = {
        let v = ProcessInfo.processInfo.environment["BF_REASONING_EFFORT"] ?? "low"
        return v == "off" ? nil : v
    }()

    public func makeChatRequest(apiKey: String, model: String, system: String, user: String, effort: Bool = true, prediction: String? = nil) -> URLRequest {
        var r = URLRequest(url: Self.baseURL.appendingPathComponent("chat/completions"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        // Gyorsítás: a gpt-5 / o-sorozat érvelő modelljeinél alacsony érvelési szint (szövegtisztításhoz elég, 2-4x gyorsabb).
        if effort, Self.isReasoningModel(model), let e = Self.reasoningEffort { body["reasoning_effort"] = e }
        // Predicted Output: ha a helyi piszkozat közel van a kész szöveghez, az egyező tokenek gyorsabban jönnek.
        // A beillesztett szöveg mindig a modell válasza, nem a piszkozat.
        if let prediction, !prediction.isEmpty {
            body["prediction"] = ["type": "content", "content": prediction]
        }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 20
        return r
    }

    public static func isReasoningModel(_ m: String) -> Bool {
        m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    /// Tetszőleges szolgáltató (pl. Anthropic, Gemini) kapcsolatának előmelegítése kulcs nélkül.
    public func warmUp(host: URL) {
        var r = URLRequest(url: host); r.httpMethod = "HEAD"; r.timeoutInterval = 5
        session.dataTask(with: r) { _, _, _ in }.resume()
    }

    public static func mapURLError(_ c: URLError.Code) -> FlowError {
        switch c {
        case .cancelled, .timedOut: return .timeout
        default: return .network // offline, DNS, kapcsolat megszakadt, TLS
        }
    }

    public static func mapError(status: Int, body: Data?) -> FlowError {
        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let err = json["error"] as? [String: Any]
        let code = (err?["code"] as? String) ?? (err?["type"] as? String) ?? ""
        let param = (err?["param"] as? String) ?? ""
        if status == 400 || status == 404 || status == 422 {
            let token = param.isEmpty ? code : "\(code) \(param)"
            return .badRequest(token)
        }
        switch status {
        case 401, 403: return .unauthorized
        case 402: return .quota
        case 429: return (code.contains("insufficient_quota") || code.contains("credit_balance")) ? .quota : .rateLimit
        case 413: return .tooLarge
        default: return .server
        }
    }

    public static func parseTranscription(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String
    }

    public static func parseChat(_ data: Data) -> String? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = j["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        if let parts = msg["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        return nil
    }

    func send(_ r: URLRequest) async -> Result<Data, FlowError> {
        do {
            let (data, resp) = try await session.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status) ? .success(data) : .failure(Self.mapError(status: status, body: data))
        } catch is CancellationError {
            return .failure(.timeout)
        } catch let e as URLError where e.code == .cancelled {
            return .failure(.timeout)
        } catch let e as URLError where e.code == .timedOut {
            return .failure(.timeout)
        } catch let e as URLError {
            return .failure(Self.mapURLError(e.code))
        } catch {
            return .failure(.network)
        }
    }

    /// Átírás; ha az elsődleges modell 400/404-et ad (pl. nem elérhető), a tartalék modellel újrapróbál.
    public func transcribe(apiKey: String, wav: Data, model: String, fallbackModel: String, language: DictationLanguage, terms: [String]) async -> Result<String, FlowError> {
        var models = [model]
        if !fallbackModel.isEmpty, fallbackModel != model { models.append(fallbackModel) }
        var last: FlowError = .server
        for (i, m) in models.enumerated() {
            var attempt = 0
            retry: while true {
                switch await send(makeTranscriptionRequest(apiKey: apiKey, wav: wav, model: m, language: language, terms: terms)) {
                case .success(let d):
                    guard let t = Self.parseTranscription(d) else { last = .server; break retry }
                    let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    return clean.isEmpty ? .failure(.emptyResult) : .success(clean)
                case .failure(let e):
                    last = e
                    if e.retryable && attempt == 0 {
                        attempt += 1
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        continue retry
                    }
                    break retry
                }
            }
            if case .badRequest = last, i < models.count - 1 { continue }
            return .failure(last)
        }
        return .failure(last)
    }

    public func chat(apiKey: String, model: String, fallbackModel: String, system: String, user: String, prediction: String? = nil) async -> Result<String, FlowError> {
        var models = [model]
        if !fallbackModel.isEmpty, fallbackModel != model { models.append(fallbackModel) }
        var last: FlowError = .server
        for m in models {
            let wantPrediction = !(prediction ?? "").isEmpty && PredictionSupport.allows(m)
            var pred: String? = wantPrediction ? prediction : nil
            var res = await send(makeChatRequest(apiKey: apiKey, model: m, system: system, user: user, effort: true, prediction: pred))
            if case .failure(.badRequest(let c)) = res, pred != nil, !c.contains("reasoning") {
                pred = nil
                res = await send(makeChatRequest(apiKey: apiKey, model: m, system: system, user: user, effort: true, prediction: nil))
                if case .success = res, c.contains("prediction") || c.contains("unknown") || c.isEmpty {
                    PredictionSupport.reject(m)
                }
            }
            if case .failure(.badRequest(let c)) = res, Self.isReasoningModel(m), c.contains("reasoning") {
                res = await send(makeChatRequest(apiKey: apiKey, model: m, system: system, user: user, effort: false, prediction: nil))
            }
            switch res {
            case .success(let d):
                guard let t = Self.parseChat(d) else { last = .server; continue }
                let clean = Prompts.cleanOutput(t)
                return clean.isEmpty ? .failure(.emptyResult) : .success(clean)
            case .failure(let e):
                last = e
                if case .badRequest = e { continue }
                if e.retryable { continue }
                return .failure(e)
            }
        }
        return .failure(last)
    }
}

/// Modellnévenként megjegyzi, ha a szolgáltató elutasította a `prediction` mezőt, hogy a következő diktálás ne fizessen egy üres 400-at.
enum PredictionSupport {
    private static let lock = NSLock()
    private static var rejected: Set<String> = []
    static func allows(_ model: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !rejected.contains(model) }
    static func reject(_ model: String) { lock.lock(); rejected.insert(model); lock.unlock() }
    static func reset() { lock.lock(); rejected.removeAll(); lock.unlock() }
}

/// Az OpenAI chat-hívás `ChatProvider`-ként (formázás, parancs mód, értékelés).
public struct OpenAIChat: ChatProvider {
    public let client: OpenAIClient
    public let apiKey: String
    public let model: String
    public let fallbackModel: String
    public init(client: OpenAIClient, apiKey: String, model: String, fallbackModel: String) {
        self.client = client; self.apiKey = apiKey; self.model = model; self.fallbackModel = fallbackModel
    }
    public func complete(system: String, user: String) async -> Result<String, FlowError> {
        await complete(system: system, user: user, prediction: nil)
    }
    public func complete(system: String, user: String, prediction: String?) async -> Result<String, FlowError> {
        await client.chat(apiKey: apiKey, model: model, fallbackModel: fallbackModel, system: system, user: user, prediction: prediction)
    }
}
