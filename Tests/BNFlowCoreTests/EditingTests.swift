import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BNFlowCore

/// Szótár / kódrészlet szerkesztés, előzmény-keresés, első lépések, kapcsolat-előmelegítés.
struct EditingTests {
    @Test func testDictionaryAddMergesCaseInsensitive() {
        var list: [DictionaryEntry] = []
        list = DictionaryEditing.insert(DictionaryEditing.make(term: " BusinessNative ", heard: "biznisz nétív, Biznisz Nétív,  ")!, into: list)
        #expect(list.count == 1)
        #expect(list[0].term == "BusinessNative")
        #expect(list[0].heardAs == ["biznisz nétív"])
        list = DictionaryEditing.insert(DictionaryEditing.make(term: "Kubernetes", heard: "")!, into: list)
        list = DictionaryEditing.insert(DictionaryEditing.make(term: "businessnative", heard: "business native, businessnative")!, into: list)
        #expect(list.count == 2)
        #expect(list[0].term == "businessnative")
        #expect(list[0].heardAs == ["biznisz nétív", "business native"])
        #expect(DictionaryEditing.make(term: "   ", heard: "x") == nil)
    }

    @Test func testDictionaryAutoLearnFlagMerge() {
        let auto = DictionaryEntry(term: "Shopify", heardAs: ["sopifáj"], autoLearned: true)
        var list = DictionaryEditing.insert(auto, into: [])
        #expect(list[0].autoLearned)
        list = DictionaryEditing.insert(DictionaryEntry(term: "Shopify", heardAs: [], autoLearned: false), into: list)
        #expect(!list[0].autoLearned)
    }

    @Test func testDictionaryUpdate() {
        let e = DictionaryEntry(term: "Exprt", heardAs: ["a"], autoLearned: true)
        let other = DictionaryEntry(term: "Más")
        let out = DictionaryEditing.update(id: e.id, term: "Expert", heard: "expört, Expert", in: [other, e])
        #expect(out[1].term == "Expert")
        #expect(out[1].heardAs == ["expört"])
        #expect(!out[1].autoLearned)
        #expect(out[0] == other)
        #expect(DictionaryEditing.update(id: e.id, term: " ", heard: "", in: [e]) == [e])
        #expect(DictionaryEditing.update(id: UUID(), term: "X", heard: "", in: [e]) == [e])
    }

    @Test func testSnippetSave() {
        var list = SnippetEditing.save(id: nil, trigger: " címem ", expansion: "Budapest, Fő u. 1.", in: [])
        #expect(list.count == 1 && list[0].trigger == "címem")
        list = SnippetEditing.save(id: nil, trigger: "Címem", expansion: "Új cím", in: list)
        #expect(list.count == 1 && list[0].expansion == "Új cím")
        list = SnippetEditing.save(id: nil, trigger: "aláírás", expansion: "Üdv, Dorottya", in: list)
        let id = list[1].id
        list = SnippetEditing.save(id: id, trigger: "aláírás", expansion: "x", in: list)
        #expect(list.count == 1 && list[0].trigger == "aláírás" && list[0].expansion == "x")
        #expect(SnippetEditing.save(id: nil, trigger: "", expansion: "x", in: list) == list)
        #expect(SnippetEditing.save(id: nil, trigger: "a", expansion: "", in: list) == list)
    }

    @Test func testHistorySearchFoldsAccents() {
        let a = HistoryItem(text: "Küldd át a kérdést", rawText: "küld át a kérdést", appName: "Slack", bundleID: "s", durationSeconds: 1, kind: .dictation)
        let b = HistoryItem(text: "Holnap találkozunk", rawText: "holnap", appName: "Mail", bundleID: "m", durationSeconds: 1, kind: .dictation)
        #expect(HistorySearch.filter([a, b], query: "kerdes") == [a])
        #expect(HistorySearch.filter([a, b], query: "KÉRDÉS slack") == [a])
        #expect(HistorySearch.filter([a, b], query: "mail") == [b])
        #expect(HistorySearch.filter([a, b], query: "kerdes mail").isEmpty)
        #expect(HistorySearch.filter([a, b], query: "  ") == [a, b])
    }

    @Test func testOnboardingState() {
        var s = OnboardingState(hasKey: false, microphone: true, accessibility: false, inputMonitoring: false, hasDictated: false)
        #expect(s.doneCount == 1 && s.next == 0 && !s.complete)
        s.hasKey = true; s.accessibility = true; s.inputMonitoring = true
        #expect(s.next == 4)
        s.hasDictated = true
        #expect(s.complete && s.next == nil && s.doneCount == 5)
    }

    @Test func testWarmUpIsUnauthenticatedHeadAndThrottled() async throws {
        WarmStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [WarmStub.self]
        let client = OpenAIClient(session: URLSession(configuration: cfg))
        client.warmUp()
        client.warmUp()
        try await Task.sleep(nanoseconds: 400_000_000)
        let reqs = WarmStub.seen()
        #expect(reqs.count == 1)
        #expect(reqs.first?.httpMethod == "HEAD")
        #expect(reqs.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(reqs.first?.httpBody == nil)
    }
}

final class WarmStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()
    static func reset() { lock.lock(); requests = []; lock.unlock() }
    static func seen() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let r = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func reasoningEffortOnlyForReasoningModels() {
    #expect(OpenAIClient.isReasoningModel("gpt-5.6-luna"))
    #expect(OpenAIClient.isReasoningModel("o4-mini"))
    #expect(!OpenAIClient.isReasoningModel("gpt-4.1-mini"))
}

@Test func offlineAndQuotaErrors() {
    #expect(OpenAIClient.mapURLError(.notConnectedToInternet) == .network)
    #expect(OpenAIClient.mapURLError(.cannotFindHost) == .network)
    #expect(OpenAIClient.mapURLError(.timedOut) == .timeout)
    #expect(FlowError.quota.message.contains("kredit"))
    #expect(OpenAIClient.mapError(status: 402, body: nil) == .quota)
}

@Test func reasoningEffortCanBeDisabled() throws {
    let c = OpenAIClient()
    let r = c.makeChatRequest(apiKey: "x", model: "gpt-5.6-luna", system: "s", user: "u", effort: false)
    let j = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
    #expect(j["reasoning_effort"] == nil)
    let r2 = c.makeChatRequest(apiKey: "x", model: "gpt-4.1-mini", system: "s", user: "u")
    #expect((try JSONSerialization.jsonObject(with: r2.httpBody!) as! [String: Any])["reasoning_effort"] == nil)
}

@Test func settingsPersistAcrossRestart() throws {
    var s = AppSettings()
    #expect(s.sounds == false) // csendes alapértelmezés
    s.sounds = true; s.soundVolume = 0.6; s.cleanupProvider = .anthropic; s.transcriptionProvider = .gemini
    let d = try JSONEncoder().encode(s)
    let r = try JSONDecoder().decode(AppSettings.self, from: d)
    #expect(r.sounds && r.soundVolume == 0.6 && r.cleanupProvider == .anthropic && r.transcriptionProvider == .gemini)
    s.soundVolume = 7
    let clamped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
    #expect(clamped.soundVolume <= 1)
}

@Test func accentsSurviveTextPipeline() {
    let t = "Árvíztűrő tükörfúrógép — „idézet” – 100 € / 50 % őű ŐŰ"
    #expect(TextPipeline.needsLeadingSpace(before: "a", text: t))
    #expect(Prompts.cleanOutput(t) == t)
}
