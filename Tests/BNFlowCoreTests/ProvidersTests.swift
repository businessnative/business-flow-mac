import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BNFlowCore

/// Hostnév szerint válaszoló mock (a kulcsok csak teszt-értékek).
final class ProviderStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (URLRequest) -> (Int, Data) = { _ in (404, Data()) }
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()
    static func reset(_ h: @escaping (URLRequest) -> (Int, Data)) { lock.lock(); seen = []; handler = h; lock.unlock() }
    static func hosts() -> [String] { lock.lock(); defer { lock.unlock() }; return seen.compactMap { $0.url?.host } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var req = request
        if req.httpBody == nil, let s = req.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); req.httpBody = d
        }
        Self.lock.lock(); Self.seen.append(req); let h = Self.handler; Self.lock.unlock()
        let (code, body) = h(req)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ProvidersTests {
    func router() -> AIRouter {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ProviderStub.self]
        return AIRouter(http: OpenAIClient(session: URLSession(configuration: c)))
    }
    let geminiOK = Data(#"{"candidates":[{"content":{"parts":[{"text":"szia vilag"}]}}]}"#.utf8)
    let claudeOK = Data(#"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Tisztított."}]}"#.utf8)
    let openaiChatOK = Data(#"{"choices":[{"message":{"content":"OpenAI kész."}}]}"#.utf8)

    @Test func testProviderMetadata() {
        #expect(!(AIProvider.anthropic.canTranscribe))
        #expect(AIProvider.transcribers == [.openai, .gemini])
        #expect(AIProvider.forEnvName("ANTHROPIC_API_KEY") == .anthropic)
        #expect(AIProvider.forEnvName("GEMINI_API_KEY") == .gemini)
        #expect(AIProvider.forEnvName("OPENAI_API_KEY") == .openai)
        for p in AIProvider.allCases { #expect(!(p.chatModels.isEmpty)); #expect(p.keyPage.scheme == "https") }
        let s = AppSettings()
        #expect(s.anthropicChatModel == AIProvider.anthropic.chatModels.first)
        #expect(s.geminiTranscriptionModel == AIProvider.gemini.transcriptionModels.first)
    }

    @Test func testSettingsDecodeOldFileKeepsDefaults() throws {
        let old = Data(#"{"chatModel":"gpt-4.1-mini"}"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(s.cleanupProvider == .openai); #expect(s.transcriptionProvider == .openai); #expect(s.chatModel == "gpt-4.1-mini")
        var n = AppSettings(); n.cleanupProvider = .anthropic; n.transcriptionProvider = .gemini
        let r = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(n))
        #expect(r.cleanupProvider == .anthropic); #expect(r.transcriptionProvider == .gemini)
    }

    @Test func testAnthropicRequestShape() throws {
        let r = AnthropicAPI.makeMessagesRequest(apiKey: "test-key", model: "claude-haiku-5-5", system: "S", user: "U")
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let o = try #require(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        #expect(o["system"] as? String == "S"); #expect(o["model"] as? String == "claude-haiku-5-5")
        #expect(AnthropicAPI.parseMessage(claudeOK) == "Tisztított.")
    }

    @Test func testGeminiTranscriptionRequestShape() throws {
        let r = GeminiAPI.makeTranscriptionRequest(apiKey: "g-key", model: "gemini-3.5-flash-lite", wav: Data([1, 2, 3]), language: .hu, terms: ["Business Flow"])
        #expect(r.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
        #expect(!(r.url!.absoluteString.contains("g-key")))
        let body = String(decoding: r.httpBody!, as: UTF8.self)
        #expect(body.contains(#"audio\/wav"#)); #expect(body.contains("AQID")); #expect(body.contains("Business Flow"))
        #expect(GeminiAPI.parse(geminiOK) == "szia vilag")
        #expect(GeminiAPI.parse(Data(#"{"candidates":[{"content":{"parts":[{"text":"gondol","thought":true},{"text":"válasz"}]}}]}"#.utf8)) == "válasz")
    }

    @Test func testGeminiTranscribeViaRouter() async {
        ProviderStub.reset { _ in (200, self.geminiOK) }
        var s = AppSettings(); s.transcriptionProvider = .gemini
        let (r, p) = await router().transcribe(s, ProviderKeys([.gemini: "g"]), wav: Data([0]), terms: [])
        #expect((try? r.get()) == "szia vilag"); #expect(p == .gemini)
    }

    @Test func testTranscriptionFallsBackToOtherProvider() async {
        ProviderStub.reset { req in
            if req.url?.host == "api.openai.com" { return (500, Data()) }
            return (200, self.geminiOK)
        }
        let (r, p) = await router().transcribe(AppSettings(), ProviderKeys([.openai: "o", .gemini: "g"]), wav: Data([0]), terms: [])
        #expect((try? r.get()) == "szia vilag"); #expect(p == .gemini)
        #expect(ProviderStub.hosts().contains("api.openai.com"))
    }

    @Test func testTranscriptionAnthropicOnlyHasNoKey() async {
        ProviderStub.reset { _ in (200, Data()) }
        var s = AppSettings(); s.transcriptionProvider = .anthropic
        let (r, _) = await router().transcribe(s, ProviderKeys([.anthropic: "a"]), wav: Data([0]), terms: [])
        if case .failure(.noAPIKey) = r {} else { Issue.record("\(r)") }
        #expect(!(ProviderKeys([.anthropic: "a"]).canTranscribe))
    }

    @Test func testCleanupWithClaudeAndFallbackToOpenAI() async {
        var s = AppSettings(); s.cleanupProvider = .anthropic
        ProviderStub.reset { _ in (200, self.claudeOK) }
        let ok = await router().chatProvider(s, ProviderKeys([.anthropic: "a", .openai: "o"]))!.complete(system: "s", user: "u")
        #expect((try? ok.get()) == "Tisztított.")
        ProviderStub.reset { req in req.url?.host == "api.anthropic.com" ? (401, Data()) : (200, self.openaiChatOK) }
        let fb = await router().chatProvider(s, ProviderKeys([.anthropic: "a", .openai: "o"]))!.complete(system: "s", user: "u")
        #expect((try? fb.get()) == "OpenAI kész.")
        #expect(ProviderStub.hosts().first == "api.anthropic.com")
    }

    @Test func testChatOrderAndNoKeys() {
        var s = AppSettings(); s.cleanupProvider = .gemini
        #expect(AIRouter.chatOrder(s, ProviderKeys([.openai: "o", .gemini: "g", .anthropic: "a"])) == [.gemini, .openai, .anthropic])
        #expect(router().chatProvider(s, ProviderKeys()) == nil)
    }

    @Test func testKeyTestRequests() async {
        #expect(AIRouter.makeKeyTestRequest(.openai, key: "k").value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(AIRouter.makeKeyTestRequest(.anthropic, key: "k").url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(AIRouter.makeKeyTestRequest(.gemini, key: "k").value(forHTTPHeaderField: "x-goog-api-key") == "k")
        ProviderStub.reset { _ in (401, Data()) }
        if case .failure(.unauthorized) = await router().testKey(.gemini, key: "bad") {} else { Issue.record("fail") }
        ProviderStub.reset { _ in (200, Data("{}".utf8)) }
        if case .failure = await router().testKey(.anthropic, key: "good") { Issue.record("fail") }
    }

    @Test func testSecretStoreRoundTripEncryptedAndPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("keys.enc")
        let st = SecretStore(url: url, machineSecret: Data("m1".utf8))
        #expect(st.set("openai-api-key", "sk-test-value-123456789"))
        #expect(st.set("gemini-api-key", "AIza-test"))
        #expect(st.get("openai-api-key") == "sk-test-value-123456789")
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("sk-test".utf8)) == nil)
        let perm = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perm?.intValue == 0o600)
        #expect(SecretStore(url: url, machineSecret: Data("m2".utf8)).get("openai-api-key") == nil)
        #expect(SecretStore(url: url, machineSecret: Data("m1".utf8)).get("gemini-api-key") == "AIza-test")
        st.set("openai-api-key", nil); st.set("gemini-api-key", nil)
        #expect(!(FileManager.default.fileExists(atPath: url.path)))
        try? FileManager.default.removeItem(at: dir)
    }
}
