import AVFoundation
import AudioToolbox
import CoreAudio
import BNFlowCore

/// Mikrofon-felvétel AVAudioEngine-nel; 16 kHz mono Int16 mintákat gyűjt (WAV-hoz) és szintet jelez a hullámformához.
final class AudioRecorder {
    /// Felvétel-őr: ennél hosszabb felvétel automatikusan leáll és feldolgozódik.
    static let maxSeconds: Double = 300

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var startedAt: Date?

    /// Szint 0…1, a fő szálon.
    var onLevel: ((Float) -> Void)?
    /// 16 kHz-es minták, a hangszálon, a puffer rögzítésével egy zárolásban (a spekulatív átírás ugyanazt a hangot látja).
    var onPCM: (([Float]) -> Void)?
    /// Elérte a maximális hosszt.
    var onLimit: (() -> Void)?
    /// A hangeszköz megváltozott / a motor leállt felvétel közben (fő szálon).
    var onInterrupted: (() -> Void)?
    private var configObserver: NSObjectProtocol?
    private let bufLock = NSLock()
    private var _lastBuffer: Date?
    /// Utolsó beérkezett hangpuffer ideje (az elakadás-őrhöz).
    var lastBufferAt: Date? { bufLock.lock(); defer { bufLock.unlock() }; return _lastBuffer }

    enum RecError: Error { case noInput, start(String) }

    private var fake = false
    /// A hangmotor minden művelete (létrehozás, inputNode, start/stop) ezen a soron fut, SOHA nem a fő szálon:
    /// a CoreAudio HAL egy lassú/elakadt eszköznél (USB/Bluetooth) másodpercekig vagy tovább blokkolhat,
    /// ami a fő szálon pörgő órát, kikapcsolt billentyűfigyelőt és „lefagyott” appot okozott.
    private var audioQ = DispatchQueue(label: "com.example.businessflow.audio", qos: .userInitiated)
    /// Fő szálon kezelt állapot: felvétel folyamatban (indítás alatt is).
    private var active = false
    private var generation = 0
    static let startTimeout: TimeInterval = 4

    /// Nem blokkoló indítás: a hangmotor a háttérsoron épül fel; a `done` a fő szálon fut (nil = siker).
    func start(deviceUID: String?, done: @escaping (Error?) -> Void) {
        if TestMode.isOn || E2E.isOn {
            do { try start(deviceUID: deviceUID); done(nil) } catch { done(error) }
            return
        }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        active = true; startedAt = Date()
        bufLock.lock(); _lastBuffer = nil; bufLock.unlock()
        generation += 1
        let gen = generation
        var finished = false
        let finish: (Error?) -> Void = { [weak self] err in
            guard let self, !finished else { return }
            finished = true
            guard gen == self.generation else { return }
            if err != nil { self.active = false; self.startedAt = nil }
            done(err)
        }
        // Őr: ha a hangeszköz nem válaszol, a felhasználó hibát lát, az app pedig reagál tovább.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            guard let self, !finished, gen == self.generation else { return }
            FlowLog.audio.error("a hangeszköz nem válaszol (indítási időtúllépés)")
            self.starting = false
            self.audioQ = DispatchQueue(label: "com.example.businessflow.audio", qos: .userInitiated) // az elakadt sor mögé ne álljon a következő
            finish(RecError.start("a mikrofon nem válaszol"))
        }
        starting = true
        let q = audioQ
        q.async { [weak self] in
            guard let self else { return }
            var err: Error?, built: Built?
            do { built = try self.buildEngine(deviceUID: deviceUID) } catch { err = error }
            DispatchQueue.main.async {
                if gen == self.generation { self.starting = false }
                if gen != self.generation || finished {
                    // Közben leállították / időtúllépés: a késve elindult motort lebontjuk.
                    if let b = built { q.async { Self.shutdown(b.engine) } }
                    return
                }
                if let b = built { self.adopt(b) }
                finish(err)
            }
        }
    }

    /// Szinkron indítás (teszt/E2E mód; valódi motorhoz csak háttérsorról).
    func start(deviceUID: String?) throws {
        if TestMode.isOn || E2E.isOn {
            fake = true; startedAt = Date()
            for l in [0.2, 0.6, 0.9, 0.4] as [Float] { DispatchQueue.main.async { [weak self] in self?.onLevel?(l) } }
            return
        }
        throw RecError.start("szinkron indítás csak teszt módban")
    }

    private var starting = false
    private struct Built { let engine: AVAudioEngine; let converter: AVAudioConverter; let rate: Double, channels: UInt32 }

    /// Háttérsoron: felépíti és elindítja a motort (a fő szálat nem érinti).
    private func buildEngine(deviceUID: String?) throws -> Built {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, var dev = AudioDevices.id(forUID: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecError.noInput }
        guard let conv = AVAudioConverter(from: inFormat, to: target) else { throw RecError.noInput }
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in self?.handle(buf, conv) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw RecError.start(error.localizedDescription)
        }
        return Built(engine: engine, converter: conv, rate: inFormat.sampleRate, channels: inFormat.channelCount)
    }

    /// Fő szálon: a kész motor átvétele.
    private func adopt(_ b: Built) {
        engine = b.engine; converter = b.converter
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: b.engine, queue: .main) { [weak self] _ in
            FlowLog.audio.error("AVAudioEngine konfiguráció változott felvétel közben (eszközváltás)")
            self?.onInterrupted?()
        }
        FlowLog.audio.info("felvétel indult: \(b.rate, privacy: .public) Hz, \(b.channels, privacy: .public) csatorna")
    }

    private static func shutdown(_ e: AVAudioEngine) {
        e.inputNode.removeTap(onBus: 0)
        e.stop()
    }

    private func handle(_ buf: AVAudioPCMBuffer, _ converter: AVAudioConverter) {
        bufLock.lock(); _lastBuffer = Date(); bufLock.unlock()
        if let ch = buf.floatChannelData {
            let lvl = WAV.level(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(lvl) }
        }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let d = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: d[0], count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        onPCM?(chunk)
        let over = Double(samples.count) / target.sampleRate >= Self.maxSeconds
        lock.unlock()
        if over { DispatchQueue.main.async { [weak self] in self?.onLimit?() } }
    }


    /// Leállítás; a nyers mintákat adja vissza. Az előkészítés és a WAV a hívó dolga, hogy ne a fő szál kódolja a fájlt.
    func takeSamples() -> [Float] {
        teardown()
        lock.lock(); var s = samples; samples.removeAll(); lock.unlock()
        if fake { fake = false; s = TestMode.isOn ? TestMode.nextAudio : (E2E.audio ?? []) }
        startedAt = nil
        return s
    }

    func cancel() {
        fake = false
        teardown()
        lock.lock(); samples.removeAll(); lock.unlock()
        startedAt = nil
    }

    /// Leállítás a fő szálról: azonnal visszatér, a motort a háttérsor bontja le.
    private func teardown() {
        generation += 1; active = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        let e = engine; engine = nil; converter = nil
        if let e { audioQ.async { Self.shutdown(e) } }
        // Elakadt indítás mögé ne álljon be a következő felvétel.
        if starting { starting = false; audioQ = DispatchQueue(label: "com.example.businessflow.audio", qos: .userInitiated) }
    }

    var isRecording: Bool { active || fake }
}
