import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A támogatott szolgáltatók (saját kulccsal — BYOK).
public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case openai, anthropic, gemini

    public var label: String {
        switch self { case .openai: return "OpenAI"; case .anthropic: return "Anthropic Claude"; case .gemini: return "Google Gemini" }
    }
    public var short: String {
        switch self { case .openai: return "OpenAI"; case .anthropic: return "Anthropic"; case .gemini: return "Gemini" }
    }
    /// A tároló bejegyzésneve és a .env-ben szokásos változónév.
    public var storeName: String { rawValue + "-api-key" }
    public var envNames: [String] {
        switch self {
        case .openai: return ["OPENAI_API_KEY"]
        case .anthropic: return ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"]
        }
    }
    public static func forEnvName(_ n: String) -> AIProvider? {
        let u = n.uppercased()
        if u.contains("OPENAI") { return .openai }
        if u.contains("ANTHROPIC") || u.contains("CLAUDE") { return .anthropic }
        if u.contains("GEMINI") || u.contains("GOOGLE") { return .gemini }
        return nil
    }
    public var keyPage: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        }
    }
    public var placeholder: String {
        switch self { case .openai: return "sk-…"; case .anthropic: return "sk-ant-…"; case .gemini: return "AIza…" }
    }
    /// A Claude-nak nincs beszéd→szöveg API-ja, ezért átírásra nem választható.
    public var canTranscribe: Bool { self != .anthropic }
    /// Modellek, az első a takarékos alapértelmezés (2026-11 állapot a szolgáltatói dokumentáció alapján).
    public var transcriptionModels: [String] {
        switch self {
        case .openai: return ["gpt-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"]
        case .gemini: return ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-2.5-flash"]
        case .anthropic: return []
        }
    }
    public var chatModels: [String] {
        switch self {
        case .openai: return ["gpt-5.6-luna", "gpt-4.1-mini", "gpt-4.1-nano"]
        case .anthropic: return ["claude-haiku-5-5", "claude-sonnet-5-5"]
        case .gemini: return ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-2.5-flash-lite"]
        }
    }
    public static var transcribers: [AIProvider] { allCases.filter(\.canTranscribe) }
}

/// Átírási keret/kvóta üzenet. Egy szolgáltató nevét kiírja; ha mindkettő elhasalt, mindkettőt.
public enum TranscriptionLimitCopy {
    public static func message(providers: [AIProvider]) -> String {
        var names: [String] = []
        for p in providers where p.canTranscribe && !names.contains(p.short) { names.append(p.short) }
        let whereTo: String
        if names.isEmpty || (names.contains("OpenAI") && names.contains("Gemini")) {
            whereTo = "az OpenAI vagy a Gemini"
        } else if names == ["Gemini"] {
            whereTo = "a Gemini"
        } else if names.count == 1 {
            whereTo = "az \(names[0])"
        } else {
            whereTo = names.map { $0 == "Gemini" ? "a \($0)" : "az \($0)" }.joined(separator: " vagy ")
        }
        return "Elfogyott az átírás kerete. Nézd meg \(whereTo) számlázását."
    }
}

/// A szolgáltatónkénti kulcsok egy hívás idejére (soha nem naplózzuk).
public struct ProviderKeys: Sendable, Equatable {
    public var values: [AIProvider: String]
    public init(_ values: [AIProvider: String] = [:]) { self.values = values.filter { !$0.value.isEmpty } }
    public subscript(_ p: AIProvider) -> String? { values[p] }
    public var canTranscribe: Bool { AIProvider.transcribers.contains { values[$0] != nil } }
    public var isEmpty: Bool { values.isEmpty }
}

// MARK: Anthropic (csak szöveg)

public enum AnthropicAPI {
    public static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    public static let version = "2023-06-01"

    static func headers(_ r: inout URLRequest, key: String) {
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue(version, forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    public static func makeMessagesRequest(apiKey: String, model: String, system: String, user: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent("messages"))
        r.httpMethod = "POST"; r.timeoutInterval = 45
        headers(&r, key: apiKey)
        let body: [String: Any] = [
            "model": model, "max_tokens": 4096, "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": "low"],
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    public static func parseMessage(_ d: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let c = o["content"] as? [[String: Any]] else { return nil }
        let t = c.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

// MARK: Gemini (hang és szöveg)

public enum GeminiAPI {
    public static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    static func post(_ model: String, key: String, body: [String: Any], timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent("models/\(model):generateContent"))
        r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    public static func makeChatRequest(apiKey: String, model: String, system: String, user: String) -> URLRequest {
        post(model, key: apiKey, body: [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["temperature": 0.2],
        ], timeout: 45)
    }

    public static func transcriptionInstruction(language: DictationLanguage, terms: [String]) -> String {
        var s = "Írd le szó szerint a hangfelvételen elhangzó beszédet. Csak az elhangzott szöveget add vissza, magyarázat, idézőjel és időbélyeg nélkül. Ha nincs beszéd, adj vissza üres választ."
        s += language == .auto ? " A beszéd magyar vagy angol (vegyesen is lehet); az angol szavakat angolul írd." : " A beszéd nyelve: \(language.codes.joined())."
        let t = terms.prefix(80)
        if !t.isEmpty { s += " Helyes írásmód ezekre a kifejezésekre: \(t.joined(separator: ", "))." }
        return s
    }

    public static func makeTranscriptionRequest(apiKey: String, model: String, wav: Data, language: DictationLanguage, terms: [String]) -> URLRequest {
        post(model, key: apiKey, body: [
            "contents": [["role": "user", "parts": [
                ["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]],
                ["text": transcriptionInstruction(language: language, terms: terms)],
            ]]],
            "generationConfig": ["temperature": 0],
        ], timeout: 60)
    }

    public static func parse(_ d: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = (o["candidates"] as? [[String: Any]])?.first,
              let parts = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { return nil }
        let s = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

// MARK: Útválasztó tartalékkal

/// Egy szolgáltatóhoz kötött szövegmodell.
public struct ProviderChat: ChatProvider {
    let router: AIRouter; let provider: AIProvider; let key: String; let model: String; let fallbackModel: String
    public func complete(system: String, user: String) async -> Result<String, FlowError> {
        await complete(system: system, user: user, prediction: nil)
    }
    public func complete(system: String, user: String, prediction: String?) async -> Result<String, FlowError> {
        let pred = provider == .openai ? prediction : nil
        return await router.chat(provider, key: key, model: model, fallbackModel: fallbackModel, system: system, user: user, prediction: pred)
    }
}

/// Sorban próbálja a szolgáltatókat; a következőre lép, ha az előző hibázik (érvénytelen kulcs, keret, szerverhiba…).
public struct FallbackChat: ChatProvider {
    public let chain: [ChatProvider]
    public init(_ chain: [ChatProvider]) { self.chain = chain }
    public func complete(system: String, user: String) async -> Result<String, FlowError> {
        await complete(system: system, user: user, prediction: nil)
    }
    public func complete(system: String, user: String, prediction: String?) async -> Result<String, FlowError> {
        var last: FlowError = .noAPIKey
        for c in chain {
            if Task.isCancelled { return .failure(.timeout) }
            switch await c.complete(system: system, user: user, prediction: prediction) {
            case .success(let s): return .success(s)
            case .failure(let e): last = e
            }
        }
        return .failure(last)
    }
}

public final class AIRouter: @unchecked Sendable {
    public let http: OpenAIClient
    public init(http: OpenAIClient = OpenAIClient()) { self.http = http }

    /// A kiválasztott szolgáltató modellje(i) a beállításokból.
    public static func chatModels(_ p: AIProvider, _ s: AppSettings) -> (String, String) {
        switch p {
        case .openai: return (s.chatModel, s.fallbackChatModel)
        case .anthropic: return (s.anthropicChatModel, p.chatModels.first { $0 != s.anthropicChatModel } ?? s.anthropicChatModel)
        case .gemini: return (s.geminiChatModel, p.chatModels.first { $0 != s.geminiChatModel } ?? s.geminiChatModel)
        }
    }

    /// Szöveg-szolgáltatók sorrendje: a választott, majd a többi, amihez van kulcs.
    public static func chatOrder(_ s: AppSettings, _ keys: ProviderKeys) -> [AIProvider] {
        ([s.cleanupProvider] + AIProvider.allCases.filter { $0 != s.cleanupProvider }).filter { keys[$0] != nil }
    }
    public static func transcriptionOrder(_ s: AppSettings, _ keys: ProviderKeys) -> [AIProvider] {
        let first = s.transcriptionProvider.canTranscribe ? s.transcriptionProvider : .openai
        return ([first] + AIProvider.transcribers.filter { $0 != first }).filter { keys[$0] != nil }
    }

    public func chatProvider(_ s: AppSettings, _ keys: ProviderKeys) -> ChatProvider? {
        let chain: [ChatProvider] = Self.chatOrder(s, keys).map { p in
            let (m, f) = Self.chatModels(p, s)
            return ProviderChat(router: self, provider: p, key: keys[p]!, model: m, fallbackModel: f)
        }
        return chain.isEmpty ? nil : FallbackChat(chain)
    }

    public func chat(_ p: AIProvider, key: String, model: String, fallbackModel: String, system: String, user: String, prediction: String? = nil) async -> Result<String, FlowError> {
        if p == .openai { return await http.chat(apiKey: key, model: model, fallbackModel: fallbackModel, system: system, user: user, prediction: prediction) }
        var last: FlowError = .emptyResult
        for m in model == fallbackModel ? [model] : [model, fallbackModel] {
            let r = p == .anthropic ? AnthropicAPI.makeMessagesRequest(apiKey: key, model: m, system: system, user: user)
                                    : GeminiAPI.makeChatRequest(apiKey: key, model: m, system: system, user: user)
            switch await http.send(r) {
            case .success(let d):
                if let s = (p == .anthropic ? AnthropicAPI.parseMessage(d) : GeminiAPI.parse(d)) { return .success(s) }
                return .failure(.emptyResult)
            case .failure(let e):
                last = e
                if case .badRequest = e { continue }
                return .failure(e)
            }
        }
        return .failure(last)
    }

    /// Átírás a választott szolgáltatóval; hiba esetén (a csendet kivéve) a következő kulcsos szolgáltatóra vált.
    /// Diagnosztika: szolgáltatónkénti hiba (csak a hiba típusa; kulcs/szöveg soha).
    nonisolated(unsafe) public static var onFailure: ((AIProvider, FlowError) -> Void)?

    public func transcribe(_ s: AppSettings, _ keys: ProviderKeys, wav: Data, terms: [String]) async -> (Result<String, FlowError>, AIProvider?) {
        let order = Self.transcriptionOrder(s, keys)
        guard !order.isEmpty else { return (.failure(.noAPIKey), nil) }
        var last: (Result<String, FlowError>, AIProvider?) = (.failure(.noAPIKey), nil)
        for p in order {
            if Task.isCancelled { break }
            let key = keys[p]!
            let r: Result<String, FlowError>
            if p == .openai {
                r = await http.transcribe(apiKey: key, wav: wav, model: s.transcriptionModel, fallbackModel: s.fallbackTranscriptionModel, language: s.language, terms: terms)
            } else {
                r = await geminiTranscribe(key: key, model: s.geminiTranscriptionModel, wav: wav, language: s.language, terms: terms)
            }
            switch r {
            case .success: return (r, p)
            case .failure(.emptyResult): return (r, p)
            case .failure(let e): last = (r, p); Self.onFailure?(p, e)
            }
        }
        return last
    }

    func geminiTranscribe(key: String, model: String, wav: Data, language: DictationLanguage, terms: [String]) async -> Result<String, FlowError> {
        var last: FlowError = .emptyResult
        let models = model == "gemini-3.5-flash-lite" ? [model] : [model, "gemini-3.5-flash-lite"]
        for m in models {
            switch await http.send(GeminiAPI.makeTranscriptionRequest(apiKey: key, model: m, wav: wav, language: language, terms: terms)) {
            case .success(let d): return GeminiAPI.parse(d).map { .success($0) } ?? .failure(.emptyResult)
            case .failure(let e):
                last = e
                if case .badRequest = e { continue }
                return .failure(e)
            }
        }
        return .failure(last)
    }

    /// „Kulcs tesztelése”: ingyenes modell-lista lekérés; semmit nem számláz.
    public static func makeKeyTestRequest(_ p: AIProvider, key: String) -> URLRequest {
        var r: URLRequest
        switch p {
        case .openai:
            r = URLRequest(url: OpenAIClient.baseURL.appendingPathComponent("models"))
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            r = URLRequest(url: AnthropicAPI.baseURL.appendingPathComponent("models"))
            AnthropicAPI.headers(&r, key: key)
        case .gemini:
            r = URLRequest(url: GeminiAPI.baseURL.appendingPathComponent("models"))
            r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        r.timeoutInterval = 20
        return r
    }

    public func testKey(_ p: AIProvider, key: String) async -> Result<Void, FlowError> {
        switch await http.send(Self.makeKeyTestRequest(p, key: key)) {
        case .success: return .success(())
        case .failure(let e): return .failure(e)
        }
    }
}
