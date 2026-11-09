import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Az API-kulcsok alkalmazás-saját tárolója: egyetlen 0600-as fájl az Application Support mappában,
/// AES-GCM-mel titkosítva, gépenként származtatott kulccsal (HKDF). Nem használ Kulcskarikát, ezért
/// soha nem jelenít meg rendszer-jóváhagyó ablakot, és újraépítés/újratelepítés után is olvasható.
/// Az értékeket soha nem naplózzuk.
public final class SecretStore: @unchecked Sendable {
    public let url: URL
    private let key: SymmetricKey
    private let lock = NSLock()

    public init(url: URL, machineSecret: Data) {
        self.url = url
        self.key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: machineSecret),
                                          salt: Data("com.example.businessflow/keys/v1".utf8),
                                          info: Data("api-keys".utf8), outputByteCount: 32)
    }

    public func all() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    public func get(_ name: String) -> String? {
        let v = all()[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    @discardableResult
    public func set(_ name: String, _ value: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var d = load()
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v, !v.isEmpty { d[name] = v } else { d.removeValue(forKey: name) }
        return write(d)
    }

    private func load() -> [String: String] {
        guard let blob = try? Data(contentsOf: url), let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: key),
              let d = try? JSONDecoder().decode([String: String].self, from: plain) else { return [:] }
        return d
    }

    private func write(_ d: [String: String]) -> Bool {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if d.isEmpty { try? fm.removeItem(at: url); return true }
            let plain = try JSONEncoder().encode(d)
            guard let blob = try AES.GCM.seal(plain, using: key).combined else { return false }
            let tmp = url.appendingPathExtension("tmp")
            fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try blob.write(to: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            #if os(macOS)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            #else
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: tmp, to: url)
            #endif
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    /// Gépenkénti titok (macOS hardver-UUID); ha nem elérhető, egy állandó tartalék.
    public static func machineSecret() -> Data {
        #if os(macOS)
        var uuid = [UInt8](repeating: 0, count: 16)
        var ts = timespec(tv_sec: 0, tv_nsec: 0)
        if gethostuuid(&uuid, &ts) == 0, uuid.contains(where: { $0 != 0 }) { return Data(uuid) + Data(NSUserName().utf8) }
        #endif
        return Data("bnflow-fallback-\(NSUserName())".utf8)
    }
}
