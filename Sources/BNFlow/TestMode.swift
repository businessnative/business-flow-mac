import AppKit
import Foundation
import BNFlowCore

/// Önteszt mód (`--self-test`): minden külső mellékhatás (Kulcskarika, mikrofon, hálózat, vágólap, beillesztés, hang,
/// némítás, bejelentkezési elem, Finder/Rendszerbeállítások megnyitása) memóriába kerül, így az app összes funkciója
/// automatikusan végigjárható a felhasználó gépének és adatainak érintése nélkül.
enum TestMode {
    static var isOn = false
    /// Animációk nélküli, azonnal kész nézetek (önteszt és képernyőkép-render).
    static var staticUI = false

    // Kulcskarika helyett
    static var keychain: String?
    static var otherKeys: [AIProvider: String?] = [:]
    // Engedélyek (önteszt: megadottnak tekintjük; a valódi engedélyeket nem kérjük)
    static var permissionsGranted = true

    // Vágólap és beillesztés
    static let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.example.businessflow.selftest"))
    static var inserted: [String] = []
    static var selection: String?
    static var fieldValue = ""

    // Mellékhatás-napló (hang, némítás, login, megnyitás)
    static var events: [String] = []
    static func log(_ e: String) { events.append(e) }
    static func took(_ prefix: String) -> Bool { events.contains { $0.hasPrefix(prefix) } }

    /// Az „.env kiválasztása” panel helyett ezt a fájlt adjuk vissza.
    static var envFile: URL?
    /// Gyorsított automatikus tanulás (6 s helyett).
    static var learnDelay: UInt64 = 300_000_000

    // Hálózat: helyi csonk (soha nem megy ki kérés)
    static var transcript = "Holnap délután átküldöm az ajánlatot."
    static var chatReply = "Rendben."
    static var failNetwork = false
    /// A beillesztés sikertelen: a szöveg nem kerül a mezőbe (vágólap / előzmény marad).
    static var failPaste = false
    /// Elakadt hálózat szimulálása: a csonk nem válaszol (az őröknek kell megszakítaniuk).
    static var hangNetwork = false
    static var requests: [String] = []
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }()

    /// Szintetikus, beszédszerű jel (szótag-burkolóval), hogy a hangaktivitás-felismerés beszédnek lássa.
    static func fakeSpeech(seconds: Double = 1.6, amplitude: Float = 0.3) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { i in
            let t = Double(i) / 16_000
            let env = Float(max(0, sin(2 * .pi * 3 * t)))
            return Float(sin(2 * .pi * 220 * t) * 0.7 + sin(2 * .pi * 1100 * t) * 0.3) * amplitude * env
        }
    }
    static var nextAudio: [Float] = fakeSpeech()
}

/// URLProtocol-csonk az OpenAI-végpontokra (átírás → `{"text": …}`, chat → `choices[0].message.content`).
final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body): (Int, Any)
        let fail = DispatchQueue.main.sync { TestMode.requests.append((request.httpMethod ?? "GET") + " " + path); return TestMode.failNetwork }
        if DispatchQueue.main.sync(execute: { TestMode.hangNetwork }) && path.hasSuffix("audio/transcriptions") { return }
        if fail {
            (status, body) = (500, ["error": ["message": "stub"]])
        } else if path.hasSuffix("audio/transcriptions") {
            (status, body) = (200, ["text": DispatchQueue.main.sync { TestMode.transcript }])
        } else if path.hasSuffix("chat/completions") {
            (status, body) = (200, ["choices": [["message": ["role": "assistant", "content": DispatchQueue.main.sync { TestMode.chatReply }]]]])
        } else {
            (status, body) = (404, [:] as [String: Any])
        }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// NSWorkspace-megnyitás, önteszt alatt csak naplóz.
enum Workspace {
    static func open(_ u: URL) {
        if TestMode.isOn { TestMode.log("open:\(u.lastPathComponent)"); return }
        NSWorkspace.shared.open(u)
    }
}
