import AppKit
import os
import AVFoundation
import ApplicationServices
import CoreAudio
import Security
import BNFlowCore
import ServiceManagement

// MARK: Keychain — az API-kulcs csak itt tárolódik, soha nem kerül fájlba vagy naplóba.
/// API-kulcsok szolgáltatónként. 0.4.0-tól NEM a Kulcskarikában vannak (annak ACL-je új buildnél jóváhagyást kért),
/// hanem az alkalmazás saját, titkosított 0600-as fájljában (`SecretStore`) — így soha nem jelenik meg rendszerablak.
/// A régi Kulcskarika-elemet egyszer, felugró ablak nélkül próbáljuk áthozni (`migrateLegacy`).
enum Keychain {
    /// Minden mentés/törlés növeli – a diktálásvezérlő ebből tudja, hogy a memóriában tartott kulcs elavult.
    nonisolated(unsafe) static var generation = 0
    static let service = "com.example.businessflow"
    static let account = "openai-api-key"
    static var lastReadNeedsApproval: Bool { false }

    /// Felülírható (az E2E a valódi kulcsfájlt használja, miközben az adatmappa ideiglenes).
    nonisolated(unsafe) static var storeURL: URL?
    static var store: SecretStore {
        SecretStore(url: storeURL ?? AppPaths.supportDirectory.appendingPathComponent("keys.enc"), machineSecret: SecretStore.machineSecret())
    }

    static func exists(_ p: AIProvider = .openai) -> Bool { read(p) != nil }

    static func read(_ p: AIProvider = .openai, interactive: Bool = true) -> String? {
        if TestMode.isOn { return p == .openai ? TestMode.keychain : (TestMode.otherKeys[p] ?? nil) }
        return store.get(p.storeName)
    }

    static func all() -> ProviderKeys {
        if TestMode.isOn {
            var d = TestMode.otherKeys; d[.openai] = TestMode.keychain
            return ProviderKeys(d.compactMapValues { $0 })
        }
        let raw = store.all()
        var d: [AIProvider: String] = [:]
        for p in AIProvider.allCases { if let v = raw[p.storeName] { d[p] = v } }
        return ProviderKeys(d)
    }

    @discardableResult
    static func save(_ value: String, for p: AIProvider = .openai) -> Bool {
        generation += 1
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if TestMode.isOn { if p == .openai { TestMode.keychain = v } else { TestMode.otherKeys[p] = v }; return true }
        return store.set(p.storeName, v)
    }

    static func delete(_ p: AIProvider = .openai) {
        generation += 1
        if TestMode.isOn { if p == .openai { TestMode.keychain = nil } else { TestMode.otherKeys[p] = nil }; return }
        store.set(p.storeName, nil)
    }

    // MARK: Régi Kulcskarika-elem (≤ 0.3.3) — egyszeri, ablakmentes áthozatal

    private static var legacyBase: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func legacyExists() -> Bool {
        var q = legacyBase
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    /// Háttérszálon fut. A felhasználói interakciót a folyamatra letiltjuk, így a Kulcskarika nem kérdez:
    /// ha jóváhagyás kellene, egyszerűen hibát kapunk. Eredmény: "none" | "migrated" | "needs-import" | "kept".
    @discardableResult
    static func migrateLegacy() -> String {
        if TestMode.isOn { return "none" }
        guard legacyExists() else { return "none" }
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        var moved = store.get(AIProvider.openai.storeName) != nil
        if !moved {
            var q = legacyBase
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
                let v = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty, store.set(AIProvider.openai.storeName, v) { moved = true; generation += 1 }
            }
        }
        guard moved else { return "needs-import" }
        return SecItemDelete(legacyBase as CFDictionary) == errSecSuccess ? "migrated" : "kept"
    }
}

// MARK: Engedélyek
enum Permissions {
    static var microphone: AVAuthorizationStatus {
        if TestMode.isOn { return TestMode.permissionsGranted ? .authorized : .denied }
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }
    static var accessibility: Bool { TestMode.isOn ? TestMode.permissionsGranted : AXIsProcessTrusted() }
    static var inputMonitoring: Bool { TestMode.isOn ? TestMode.permissionsGranted : CGPreflightListenEventAccess() }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        if TestMode.isOn { TestMode.log("perm:request-mic"); done(TestMode.permissionsGranted); return }
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }
    static func promptAccessibility() {
        if TestMode.isOn { TestMode.log("perm:prompt-ax"); return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    static func requestInputMonitoring() {
        if TestMode.isOn { TestMode.log("perm:request-input"); return }
        _ = CGRequestListenEventAccess()
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone", accessibility = "Privacy_Accessibility", input = "Privacy_ListenEvent"
    }
    static func open(_ pane: Pane) {
        if TestMode.isOn { TestMode.log("open:\(pane.rawValue)"); return }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") { NSWorkspace.shared.open(u) }
    }
    static func openKeyboardSettings() {
        if TestMode.isOn { TestMode.log("open:keyboard"); return }
        if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(u) }
    }
}

// MARK: Indítás bejelentkezéskor
enum LoginItem {
    static var testEnabled = false
    static var enabled: Bool { TestMode.isOn ? testEnabled : SMAppService.mainApp.status == .enabled }
    @discardableResult
    static func set(_ on: Bool) -> String? {
        if TestMode.isOn { testEnabled = on; TestMode.log("login:\(on)"); return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: Mikrofonok
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        return st == noErr ? value : nil
    }

    static func cfString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func allIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    static func inputs() -> [AudioInputDevice] {
        allIDs().filter(hasInput).compactMap { id in
            guard let uid = cfString(id, kAudioDevicePropertyDeviceUID), let name = cfString(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultInput() -> AudioDeviceID? {
        prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioDeviceID(0))
    }
    static func defaultOutput() -> AudioDeviceID? {
        prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
    }
    static func id(forUID uid: String) -> AudioDeviceID? { inputs().first { $0.uid == uid }?.id }
}

// MARK: Média némítása diktálás közben (a kimeneti eszköz némítása, majd visszaállítása)
final class MediaMuter {
    private var mutedDevice: AudioDeviceID?

    private func muteAddr() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private var testMuted = false
    var isMuted: Bool { mutedDevice != nil || testMuted }

    func mute() {
        if TestMode.isOn { if !testMuted { testMuted = true; TestMode.log("mute") }; return }
        guard mutedDevice == nil, let dev = AudioDevices.defaultOutput() else { return }
        var addr = muteAddr()
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return }
        var cur: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cur) == noErr, cur == 0 else { return }
        var one: UInt32 = 1
        if AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &one) == noErr { mutedDevice = dev }
    }

    func restore() {
        if TestMode.isOn { if testMuted { testMuted = false; TestMode.log("unmute") }; return }
        guard let dev = mutedDevice else { return }
        mutedDevice = nil
        var addr = muteAddr()
        var zero: UInt32 = 0
        _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &zero)
    }
}

// MARK: Saját, szintetizált hangjelzések (nincs külső hangfájl)
/// Halk, lágy szinuszjelek. Minden munka egy háttérsoron fut (a fő szál soha nem vár a hangkártyára),
/// és a motor eszközváltáskor (AVAudioEngineConfigurationChange) vagy hibánál újraépül.
final class SoundPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.example.businessflow.sound")
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?
    private var generation = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    enum Cue { case start, stop, cancel, error }

    private static let shared = SoundPlayer()
    /// Előhallgatás a hangerő-csúszkához.
    static func preview(volume: Double) { shared.play(.start, volume: volume) }

    private func teardown() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        node?.stop(); engine?.stop()
        engine = nil; node = nil
    }

    private func setup() -> (AVAudioEngine, AVAudioPlayerNode) {
        if let e = engine, let n = node { return (e, n) }
        let e = AVAudioEngine(), n = AVAudioPlayerNode()
        e.attach(n)
        e.connect(n, to: e.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            self?.queue.async { self?.teardown() }
        }
        engine = e; node = n
        return (e, n)
    }

    static func buffer(_ notes: [(Double, Double)], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let total = notes.reduce(0) { $0 + $1.1 }
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total * sr)) else { return nil }
        b.frameLength = b.frameCapacity
        let p = b.floatChannelData![0]
        var i = 0
        for (freq, dur) in notes {
            let n = Int(dur * sr)
            for k in 0..<n where i < Int(b.frameLength) {
                let t = Double(k) / sr
                // Lágy felfutás és lecsengés (nincs kattanás), tiszta szinusz felhang nélkül.
                let attack = min(1, t / 0.018), release = min(1, max(0, (dur - t) / 0.07))
                let env = attack * attack * release
                p[i] = Float(sin(2 * .pi * freq * t) * env * 0.35)
                i += 1
            }
        }
        return b
    }

    static func notes(_ cue: Cue) -> [(Double, Double)] {
        switch cue {
        case .start: return [(523, 0.09), (659, 0.11)]
        case .stop: return [(659, 0.09), (523, 0.11)]
        case .cancel: return [(440, 0.12)]
        case .error: return [(392, 0.12), (330, 0.14)]
        }
    }

    func play(_ cue: Cue, volume: Double) {
        if TestMode.isOn { TestMode.log("sound:\(cue)"); return }
        let vol = Float(min(1, max(0, volume)))
        guard vol > 0.001 else { return }
        queue.async { [self] in
            guard let b = Self.buffer(Self.notes(cue), format: format) else { return }
            for attempt in 0..<2 {
                let (e, n) = setup()
                e.mainMixerNode.outputVolume = vol * 0.5
                do {
                    if !e.isRunning { try e.start() }
                    n.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
                    if !n.isPlaying { n.play() }
                    break
                } catch {
                    FlowLog.audio.error("hangjelzés hiba (\(attempt)): \(error.localizedDescription, privacy: .public)")
                    teardown()
                }
            }
            generation += 1
            let g = generation
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, g == self.generation else { return }
                self.teardown()
            }
        }
    }
}

/// Diagnosztikai napló (Konzol.app / `log show --predicate 'subsystem == "com.example.businessflow"'`).
/// Soha nem ír ki átiratot, kulcsot vagy szöveget – csak állapotokat és hibakódokat.
enum FlowLog {
    static let hotkey = Logger(subsystem: "com.example.businessflow", category: "hotkey")
    static let audio = Logger(subsystem: "com.example.businessflow", category: "audio")
    static let flow = Logger(subsystem: "com.example.businessflow", category: "flow")
}
