import AppKit
import BNFlowCore

/// A diktálás teljes folyamata: felvétel → átírás → formázás → beillesztés.
@MainActor
final class DictationController {
    let model: AppModel
    let monitor: HotkeyMonitor
    private let recorder = AudioRecorder()
    let muter = MediaMuter()
    private let sounds = SoundPlayer()
    private let client = OpenAIClient(session: TestMode.isOn ? TestMode.session : nil)
    private lazy var router = AIRouter(http: client)

    private var target: TextInserter.Target?
    private var kind: DictationKind = .dictation
    private var handsFree = false
    private var hadSelectionAtStart = false
    private var startCueWork: DispatchWorkItem?
    private var resetWork: DispatchWorkItem?
    private var busy = false
    private var job: Task<Void, Never>?
    /// Az utolsó sikertelen felvétel (csak memóriában), hogy hálózati hiba után újrapróbálható legyen.
    private(set) var lastFailedAudio: (wav: Data, seconds: Double, kind: DictationKind, stats: AudioStats)?
    private var learnWork: Task<Void, Never>?
    /// Őrök: felvétel közbeni ellenőrzés (elveszett felengedés, néma mikrofon) és feldolgozási időkorlát.
    private var recWatch: Timer?
    private var procWatch: DispatchWorkItem?
    private var busySince: Date?
    private var jobID = 0
    private var pendingAudio: (wav: Data, seconds: Double, kind: DictationKind, stats: AudioStats)?
    /// Helyi WAV-cache a felengedéshez. Nem küld kérést.
    private let prep = LocalTurnPrep()
    private var prepLoop: Task<Void, Never>?
    /// Fizetős előretöltés. Alapból zárva: a beállítás kikapcsolt állapotában nem nyit hívást.
    private let prefetch = PrefetchSession()
    private struct SpecJob {
        var id: TranscriptRequestID
        var task: Task<SpecOutcome, Never>
        var started: UInt64
    }
    /// A csend alatt lefutott átírás, és ha a szöveg megérkezett még felengedés előtt, a hozzá tartozó tisztítás.
    private struct SpecOutcome: Sendable {
        var transcript: Result<String, FlowError>
        var polish: FormatResult?
        var polishInput: String?
        var context: DictationContext?
        var settings: AppSettings?
        var transcriptReady: UInt64
        var polishReady: UInt64?
    }
    private var spec: SpecJob?
    /// A teljes feldolgozás (átírás + formázás + beillesztés) felső korlátja.
    static var processingTimeout: Double = 45
    /// Ennyi ideig tartó feldolgozás után egy új gyorsbillentyű-nyomás megszakítja az elakadt feldolgozást.
    static let stuckAfter: Double = 3

    var openHub: ((HubSection) -> Void)?

    init(model: AppModel, monitor: HotkeyMonitor) {
        self.model = model
        self.monitor = monitor
        recorder.onLevel = { [weak self] l in self?.model.pushLevel(l) }
        recorder.onLimit = { [weak self] in self?.stop() }
        recorder.onInterrupted = { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            FlowLog.flow.error("felvétel megszakadt eszközváltás miatt – eddigi hang feldolgozása")
            self.stop()
        }
        if !TestMode.isOn { observeSleepWake() }
    }

    var isRecording: Bool { recorder.isRecording }
    var isBusy: Bool { busy }

    func handle(_ action: HotkeyAction) {
        switch action {
        case .start(let k, let hf): start(k, handsFree: hf)
        case .switchKind(let k): switchKind(k)
        case .lockHandsFree:
            handsFree = true
            if case .recording(let f, _) = model.bar { model.bar = .recording(f, handsFree: true) }
        case .stop: stop()
        case .cancel: cancel()
        case .pasteLast: pasteLast()
        case .polish: polishSelection(preset: nil)
        }
    }

    // MARK: Felvétel

    private func play(_ cue: SoundPlayer.Cue) {
        guard model.settings.sounds else { return }
        sounds.play(cue, volume: model.settings.soundVolume)
    }

    /// Mindig helyreállítható állapotgép: ha a feldolgozás régóta fut, egy új nyomás megszakítja (a hang megmarad újrapróbálásra).
    private func recoverIfStuck() -> Bool {
        guard busy else { return true }
        if let since = busySince, Date().timeIntervalSince(since) >= Self.stuckAfter {
            FlowLog.flow.error("elakadt feldolgozás megszakítva gyorsbillentyűvel")
            abortProcessing(short: "Megszakítva", detail: "Az előző feldolgozás elakadt, ezért megszakítottam.", showErr: false)
            return true
        }
        return false
    }

    private func abortProcessing(short: String, detail: String, showErr: Bool) {
        jobID += 1
        spec?.task.cancel(); spec = nil
        prefetch.close()
        job?.cancel(); job = nil
        procWatch?.cancel(); procWatch = nil
        busy = false; busySince = nil
        monitor.engine.reset()
        if let a = pendingAudio { lastFailedAudio = a }
        pendingAudio = nil
        let tail = lastFailedAudio != nil ? " A felvétel megmaradt: menü → „Utolsó felvétel újrapróbálása”." : ""
        if showErr { showError(short, detail: detail + tail) } else { lastErrorDetail = detail + tail; model.bar = .idle }
    }

    /// Feldolgozás indítása időkorláttal; az elavult feladat nem írhatja felül az új állapotot.
    private func runJob(audio: (wav: Data, seconds: Double, kind: DictationKind, stats: AudioStats), _ work: @escaping @MainActor () async -> Void) {
        jobID += 1
        let id = jobID
        busy = true; busySince = Date()
        pendingAudio = audio
        model.bar = .processing(nil)
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.jobID == id, self.busy else { return }
            FlowLog.flow.error("feldolgozási időkorlát lejárt")
            self.abortProcessing(short: "Időtúllépés", detail: "A feldolgozás nem fejeződött be \(Int(Self.processingTimeout)) mp alatt.", showErr: true)
        }
        procWatch = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.processingTimeout, execute: w)
        job = Task { [weak self] in
            await work()
            guard let self, self.jobID == id else { return }
            self.procWatch?.cancel(); self.procWatch = nil
            self.busy = false; self.busySince = nil; self.pendingAudio = nil
            if self.model.bar == .processing(nil) { self.model.bar = .idle }
        }
    }

    private func startRecWatch() {
        recWatch?.invalidate()
        recWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recTick() }
        }
    }

    private func recTick() {
        guard recorder.isRecording, !TestMode.isOn else { recWatch?.invalidate(); recWatch = nil; return }
        // Nyomva tartásnál: ha a gomb már nincs lent (elveszett felengedés), leállítjuk.
        if !handsFree { monitor.resync() }
        guard recorder.isRecording, let since = model.recordingSince else { return }
        let elapsed = Date().timeIntervalSince(since)
        let last = recorder.lastBufferAt
        if elapsed > 2.0, last == nil || Date().timeIntervalSince(last!) > 1.5 {
            FlowLog.audio.error("a mikrofon nem küld hangot – felvétel leállítva, a hangmotor újraindul")
            cancelSilently()
            showError("Nincs mikrofonjel", detail: "A mikrofon nem küldött hangot (eszközváltás vagy foglalt eszköz). Próbáld újra – a hangmotor újraindul.")
        }
    }

    private func cancelSilently() {
        startCueWork?.cancel()
        stopSpeculation(cancelTask: true)
        recWatch?.invalidate(); recWatch = nil
        recorder.cancel()
        muter.restore()
        monitor.engine.reset()
        model.recordingSince = nil
        model.bar = .idle
    }

    func start(_ k: DictationKind, handsFree hf: Bool) {
        guard recoverIfStuck() else {
            // Rövid ideje fut a feldolgozás: a nyomást elengedjük, de a motor állapota nem csúszhat el.
            monitor.engine.reset()
            FlowLog.flow.info("indítás kihagyva: feldolgozás folyamatban")
            return
        }
        if recorder.isRecording {
            // A motor szerint nem ment felvétel, a felvevő szerint igen: leállítjuk, hogy ne ragadjon be.
            FlowLog.flow.error("állapot-eltérés: indítás felvétel közben → leállítás")
            stop(); return
        }
        guard model.hasAPIKey else {
            monitor.engine.reset()
            showError("Nincs kulcs", detail: FlowError.noAPIKey.message)
            openHub?(.settings)
            model.settingsTab = .apiKey
            return
        }
        switch Permissions.microphone {
        case .authorized: break
        case .notDetermined:
            monitor.engine.reset()
            Permissions.requestMicrophone { _ in AppModel.shared.permissionTick += 1 }
            return
        default:
            monitor.engine.reset()
            showError("Nincs mikrofon", detail: "Engedélyezd a mikrofont: Rendszerbeállítások → Adatvédelem → Mikrofon.")
            return
        }
        resetWork?.cancel()
        target = TextInserter.currentTarget()
        kind = k
        handsFree = hf
        hadSelectionAtStart = target.flatMap(TextInserter.selectedTextAX) != nil
        model.resetLevels()
        model.recordingSince = Date()
        model.bar = .recording(flavor(for: k), handsFree: hf)
        // A mikrofon indítása a háttérben: a fő szál (sáv, billentyűfigyelő) sosem blokkol a hangeszközre várva.
        let uid = model.settings.microphoneUID
        recorder.start(deviceUID: uid) { [weak self] err in
            guard let self, let err else { return }
            FlowLog.audio.error("felvétel indítása sikertelen: \(String(describing: err), privacy: .public) – újrapróbálás")
            guard uid != nil else { self.micFailed(err); return }
            // Egyszeri újrapróbálás alapértelmezett eszközzel (a hangmotor újraépül).
            self.recorder.start(deviceUID: nil) { [weak self] err2 in
                if let self, let err2 { self.micFailed(err2) }
            }
        }
        startRecWatch()
        // A kapcsolat felépítése már beszéd közben (hitelesítés nélkül, ingyenes).
        client.warmUp()
        switch model.settings.cleanupProvider {
        case .anthropic: client.warmUp(host: URL(string: "https://api.anthropic.com")!)
        case .gemini: client.warmUp(host: URL(string: "https://generativelanguage.googleapis.com")!)
        case .openai: break
        }
        spec?.task.cancel(); spec = nil
        prefetch.beginRecording()
        prep.reset()
        recorder.onPCM = { [weak self] chunk in self?.prep.append(chunk) }
        startPrepLoop()
        if model.settings.muteMedia { muter.mute() }
        // Rövid fn-koppintásnál ne szóljon a jelzés.
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            self.play(.start)
        }
        startCueWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (hf ? 0 : 0.2), execute: w)
    }

    private func micFailed(_ error: Error) {
        cancelSilently()
        showError("Mikrofon hiba", detail: "A mikrofon nem indult el: \(error). Ellenőrizd a hangbemenetet.")
    }

    private func flavor(for k: DictationKind) -> RecordingFlavor {
        k == .dictation ? .dictation : (hadSelectionAtStart ? .command : .instruct)
    }

    func switchKind(_ k: DictationKind) {
        guard recorder.isRecording else { return }
        kind = k
        model.bar = .recording(flavor(for: k), handsFree: handsFree)
    }

    /// Alvás/ébredés: alvás előtt a futó felvételt megszakítjuk (különben a sáv „felvétel” állapotban ragadna),
    /// ébredés után a hangmotort újraépítjük (az eszközök újracsatlakoznak).
    private var sleepObservers: [NSObjectProtocol] = []
    func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        })
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
    }
    func handleSleep() { if recorder.isRecording { cancel() } }
    func handleWake() {
        monitor.engine.reset()
        if case .recording = model.bar, !recorder.isRecording { model.bar = .idle; model.recordingSince = nil }
    }

    func cancel() {
        startCueWork?.cancel()
        stopSpeculation(cancelTask: true)
        recWatch?.invalidate(); recWatch = nil
        procWatch?.cancel(); procWatch = nil
        jobID += 1; busySince = nil; pendingAudio = nil
        job?.cancel()
        let wasRecording = recorder.isRecording
        recorder.cancel()
        muter.restore()
        monitor.engine.reset()
        model.recordingSince = nil
        busy = false
        if wasRecording, model.bar != .idle, isLongEnough() { play(.cancel) }
        model.bar = .idle
    }

    private func isLongEnough() -> Bool { true }

    /// Sáv-kattintás vagy STOP gomb.
    func barClicked() {
        guard recoverIfStuck() else { return }
        monitor.engine.barClicked().forEach(handle)
    }

    func stop() {
        guard recorder.isRecording else {
            // Nincs felvétel, de a motor/sáv még felvételt mutat: helyreállítás üresjáratba.
            monitor.engine.reset()
            if case .recording = model.bar { model.bar = .idle; model.recordingSince = nil }
            return
        }
        startCueWork?.cancel()
        recWatch?.invalidate(); recWatch = nil
        prepLoop?.cancel(); prepLoop = nil
        let started = model.recordingSince ?? Date()
        let stopMark = DispatchTime.now().uptimeNanoseconds
        let raw = recorder.takeSamples()
        recorder.onPCM = nil
        let stats = AudioPrep.analyze(raw)
        muter.restore()
        monitor.engine.reset()
        model.recordingSince = nil
        let elapsed = Date().timeIntervalSince(started)
        if AudioPrep.isSilent(stats) {
            stopSpeculation(cancelTask: true)
            model.bar = .idle
            if elapsed > 0.5 { flash(.notice("Nem hallottam semmit")) }
            return
        }
        play(.stop)
        let kind = self.kind
        let target = self.target ?? TextInserter.currentTarget()
        // A kurzor környezete a felvétel végén (jelszómezőben semmi; kikapcsolva csak az app és az ablakcím).
        let ctx = TextInserter.context(target, includeText: model.settings.contextAwareness)
        let cached = prep.ready(count: raw.count)
        runJob(audio: (cached?.wav ?? Data(), stats.seconds, kind, stats)) { [weak self] in
            guard let self else { return }
            let wav: Data
            if let cached {
                wav = cached.wav
            } else {
                wav = await Task.detached(priority: .userInitiated) {
                    WAV.encode(samples: WAV.floatToInt16(AudioPrep.prepare(raw)))
                }.value
            }
            let finalizeMs = Int((DispatchTime.now().uptimeNanoseconds &- stopMark) / 1_000_000)
            self.pendingAudio = (wav, stats.seconds, kind, stats)
            await self.process(wav: wav, seconds: stats.seconds, kind: kind, target: target, context: ctx, stats: stats, finalizeMs: finalizeMs, stopMark: stopMark)
        }
    }

    /// „Utolsó felvétel újrapróbálása” (menü): a memóriában tartott, sikertelen felvétel újraküldése.
    func retryLastFailed() {
        guard !busy, !recorder.isRecording, let f = lastFailedAudio else { return }
        let target = TextInserter.currentTarget()
        let ctx = TextInserter.context(target, includeText: model.settings.contextAwareness)
        runJob(audio: f) { [weak self] in
            await self?.process(wav: f.wav, seconds: f.seconds, kind: f.kind, target: target, context: ctx, stats: f.stats)
        }
    }

    private var terms: [String] { model.settings.dictionary.map(\.term) }

    private func transcriptionIdentity(_ s: AppSettings) -> (model: String, fallback: String) {
        if s.transcriptionProvider == .gemini {
            let fb = s.geminiTranscriptionModel == "gemini-3.5-flash-lite" ? s.geminiTranscriptionModel : "gemini-3.5-flash-lite"
            return (s.geminiTranscriptionModel, fb)
        }
        return (s.transcriptionModel, s.fallbackTranscriptionModel)
    }

    /// Helyi előkészítés a beszéd alatt, hogy a felengedés ne várjon a WAV-ra, ha a cache utolérte a mintákat. Hálózat nincs.
    private func startPrepLoop() {
        guard !TestMode.isOn, !E2E.isOn else { return }
        prepLoop?.cancel()
        prepLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                guard let self, self.recorder.isRecording else { return }
                let box = self.prep
                let prepared = await Task.detached(priority: .utility) { box.prepareLatestIfIdle() }.value
                guard let prepared, self.recorder.isRecording, self.prep.count == prepared.count else { continue }
                await self.maybeSpeculate(prepared.turn)
            }
        }
    }

    private func stopSpeculation(cancelTask: Bool) {
        prepLoop?.cancel(); prepLoop = nil
        recorder.onPCM = nil
        // A generáció lezárása megakadályozza, hogy egy már eldöntött jegy utólag hálózatot nyisson.
        // A Task.cancel csak a helyi URLSession-t szakítja meg; a szolgáltató a már átvett kérést felszámolhatja.
        prefetch.close()
        if cancelTask { spec?.task.cancel(); spec = nil }
        prep.reset()
    }

    /// Csak `paidPrefetch` mellett, és csak ha a jegy a küldés pillanatában is érvényes. A megszakítás után nem nyit hívást.
    private func maybeSpeculate(_ snap: PreparedTurn) async {
        guard recorder.isRecording, !TestMode.isOn, !E2E.isOn else { return }
        // Alapból ki. Kikapcsolt állapotban nincs kontextusolvasás és nincs hívás.
        guard model.settings.paidPrefetch else {
            if spec != nil { spec?.task.cancel(); spec = nil; prefetch.close() }
            return
        }
        let enabled = true
        let last = recorder.lastBufferAt
        let micInactive = last == nil || Date().timeIntervalSince(last!) > 1.5
        let s = model.settings
        let ctx = TextInserter.context(target ?? TextInserter.currentTarget(), includeText: s.contextAwareness)
        let termList = terms + Array(TextRules.contextNames(ctx).prefix(20))
        let ident = transcriptionIdentity(s)
        let id = TranscriptRequestID.make(wav: snap.wav, provider: s.transcriptionProvider.rawValue, model: ident.model, fallback: ident.fallback, language: s.language.rawValue, terms: termList)
        let verdict = prefetch.consider(enabled: enabled, recording: true, micInactive: micInactive, stats: snap.stats, trailingSilence: snap.trailingSilence, candidate: id)
        switch verdict {
        case .ignore:
            return
        case .abandon:
            spec?.task.cancel(); spec = nil
            return
        case .start(let ticket):
            spec?.task.cancel(); spec = nil
            guard prefetch.confirmSend(ticket) else { prefetch.cancelSend(ticket); return }
            launchPrefetch(ticket, snap: snap, settings: s, terms: termList)
        }
    }

    private func launchPrefetch(_ ticket: PrefetchSession.Ticket, snap: PreparedTurn, settings s: AppSettings, terms termList: [String]) {
        let keys = Keychain.all()
        guard keys.canTranscribe else { prefetch.cancelSend(ticket); return }
        client.warmUp()
        let started = DispatchTime.now().uptimeNanoseconds
        let wav = snap.wav
        let peak = snap.stats.peak
        let speech = snap.stats.speechSeconds
        let id = ticket.id
        let task = Task { @MainActor [weak self] () -> SpecOutcome in
            let empty = SpecOutcome(transcript: .failure(.network), polish: nil, polishInput: nil, context: nil, settings: nil, transcriptReady: DispatchTime.now().uptimeNanoseconds, polishReady: nil)
            guard let self, self.prefetch.confirmSend(ticket) else { return empty }
            let (r, _) = await self.router.transcribe(s, keys, wav: wav, terms: termList)
            let ready = DispatchTime.now().uptimeNanoseconds
            guard case .success(let text) = r, self.recorder.isRecording, self.kind == .dictation, self.spec?.id == id, self.prefetch.confirmSend(ticket) else {
                return SpecOutcome(transcript: r, polish: nil, polishInput: nil, context: nil, settings: nil, transcriptReady: ready, polishReady: nil)
            }
            let cleaned = AudioPrep.cleanTranscript(text, peak: peak, speechSeconds: speech)
            let ctx = TextInserter.context(self.target ?? TextInserter.currentTarget(), includeText: s.contextAwareness)
            let settingsNow = self.model.settings
            let chat = settingsNow.smartFormatting ? self.chat(keys) : nil
            let formatted = await DictationFormatter.format(raw: cleaned, settings: settingsNow, context: ctx, chat: chat)
            guard self.recorder.isRecording, self.spec?.id == id, self.prefetch.confirmSend(ticket) else {
                return SpecOutcome(transcript: r, polish: nil, polishInput: nil, context: nil, settings: nil, transcriptReady: ready, polishReady: nil)
            }
            return SpecOutcome(transcript: r, polish: formatted, polishInput: cleaned, context: ctx, settings: settingsNow, transcriptReady: ready, polishReady: DispatchTime.now().uptimeNanoseconds)
        }
        spec = SpecJob(id: id, task: task, started: started)
    }

    private func logTrace(finalizeMs: Int, transcribeWait: Int, overlapped: Int, cleanupMs: Int, pasteMs: Int, stopMark: UInt64, speculated: Bool, bytes: Int) {
        let post = stopMark == 0 ? finalizeMs + transcribeWait + cleanupMs + pasteMs : Int((DispatchTime.now().uptimeNanoseconds &- stopMark) / 1_000_000)
        let trace = DictationTrace(finalizeMs: finalizeMs, transcribeWait: transcribeWait, overlappedMs: overlapped, cleanupMs: cleanupMs, pasteMs: pasteMs, postSpeechMs: post, speculated: speculated, bytes: bytes)
        FlowLog.flow.info("\(trace.logLine, privacy: .public)")
    }

    private func process(wav: Data, seconds: Double, kind: DictationKind, target: TextInserter.Target, context: DictationContext, stats: AudioStats, finalizeMs: Int = 0, stopMark: UInt64 = 0) async {
        // 0.4.0: a kulcsok az alkalmazás saját titkosított fájljában vannak — olvasásuk azonnali, rendszerablak nélküli.
        let keys = Keychain.all()
        guard keys.canTranscribe else { showError("Nincs kulcs", detail: FlowError.noAPIKey.message); return }
        let s = model.settings
        let allTerms = terms + Array(TextRules.contextNames(context).prefix(20))
        if E2E.delayBeforeTranscribe > 0 { try? await Task.sleep(nanoseconds: UInt64(E2E.delayBeforeTranscribe * 1e9)) }
        if Task.isCancelled { return }
        AIRouter.onFailure = { p, e in FlowLog.flow.error("átírás hiba [\(p.rawValue, privacy: .public)]: \(String(String(describing: e).prefix(160)), privacy: .public)") }
        let ident = transcriptionIdentity(s)
        let id = TranscriptRequestID.make(wav: wav, provider: s.transcriptionProvider.rawValue, model: ident.model, fallback: ident.fallback, language: s.language.rawValue, terms: allTerms)
        let mark = stopMark == 0 ? DispatchTime.now().uptimeNanoseconds : stopMark
        let tTr = DispatchTime.now().uptimeNanoseconds
        let resolved = await resolveTranscript(id: id, settings: s, keys: keys, wav: wav, terms: allTerms, stopMark: mark)
        let transcribeEnd = resolved.outcome?.transcriptReady ?? DispatchTime.now().uptimeNanoseconds
        let transcribeWait = Int((max(transcribeEnd, tTr) &- tTr) / 1_000_000)
        if let usedProvider = resolved.provider { FlowLog.flow.info("átírás: \(usedProvider.rawValue, privacy: .public)") }
        if Task.isCancelled { return }
        guard case .success(let rawT) = resolved.result else {
            if case .failure(let e) = resolved.result {
                logTrace(finalizeMs: finalizeMs, transcribeWait: transcribeWait, overlapped: resolved.overlapped, cleanupMs: 0, pasteMs: 0, stopMark: mark, speculated: resolved.speculated, bytes: wav.count)
                FlowLog.flow.error("átírás sikertelen: \(e.short, privacy: .public)")
                if e == .emptyResult { flash(.notice("Nem hallottam semmit")) } else {
                    lastFailedAudio = (wav, seconds, kind, stats)
                    showError(e.short, detail: e.message + " A felvétel megmaradt: menü → „Utolsó felvétel újrapróbálása”.")
                }
            }
            return
        }
        lastFailedAudio = nil
        let raw = AudioPrep.cleanTranscript(rawT, peak: stats.peak, speechSeconds: stats.speechSeconds)
        E2E.mark("transcribed"); if E2E.isOn { E2E.raw = raw }
        guard !raw.isEmpty else { flash(.notice("Nem hallottam semmit")); return }
        let stage = StageClock(finalizeMs: finalizeMs, transcribeWait: transcribeWait, overlapped: resolved.overlapped, stopMark: mark, speculated: resolved.speculated, bytes: wav.count, outcome: resolved.outcome)
        switch kind {
        case .dictation: await finishDictation(raw: raw, seconds: seconds, target: target, keys: keys, context: context, stage: stage)
        case .command:
            let c0 = DispatchTime.now().uptimeNanoseconds
            await finishCommand(instruction: raw, seconds: seconds, target: target, keys: keys, context: context)
            let tail = Int((DispatchTime.now().uptimeNanoseconds &- c0) / 1_000_000)
            logTrace(finalizeMs: stage.finalizeMs, transcribeWait: stage.transcribeWait, overlapped: stage.overlapped, cleanupMs: tail, pasteMs: 0, stopMark: stage.stopMark, speculated: stage.speculated, bytes: stage.bytes)
        }
    }

    private struct StageClock {
        var finalizeMs: Int
        var transcribeWait: Int
        var overlapped: Int
        var stopMark: UInt64
        var speculated: Bool
        var bytes: Int
        var outcome: SpecOutcome?
    }

    private func resolveTranscript(id: TranscriptRequestID, settings s: AppSettings, keys: ProviderKeys, wav: Data, terms allTerms: [String], stopMark: UInt64) async -> (result: Result<String, FlowError>, provider: AIProvider?, overlapped: Int, speculated: Bool, outcome: SpecOutcome?) {
        if let job = spec, TurnSelection.useInflight(job.id, final: id) {
            let overlapped = stopMark > job.started ? Int((stopMark &- job.started) / 1_000_000) : 0
            let early = await job.task.value
            spec = nil
            if Task.isCancelled { return (.failure(.timeout), nil, 0, false, nil) }
            if case .success = early.transcript { return (early.transcript, s.transcriptionProvider, overlapped, true, early) }
            let pair = await router.transcribe(s, keys, wav: wav, terms: allTerms)
            return (pair.0, pair.1, 0, false, nil)
        }
        spec?.task.cancel(); spec = nil
        if Task.isCancelled { return (.failure(.timeout), nil, 0, false, nil) }
        let pair = await router.transcribe(s, keys, wav: wav, terms: allTerms)
        return (pair.0, pair.1, 0, false, nil)
    }

    /// Szövegtisztítás a választott szolgáltatóval, hiba esetén a többi kulcsos szolgáltatóra vált.
    private func chat(_ keys: ProviderKeys) -> ChatProvider {
        router.chatProvider(model.settings, keys) ?? FallbackChat([])
    }

    private func finishDictation(raw: String, seconds: Double, target: TextInserter.Target, keys: ProviderKeys, context ctx: DictationContext, stage: StageClock) async {
        let s = model.settings
        let c0 = DispatchTime.now().uptimeNanoseconds
        let reused = stage.outcome?.polishInput == raw && stage.outcome?.context == ctx && stage.outcome?.settings == s
        let r: FormatResult
        if reused, let done = stage.outcome?.polish {
            r = done
        } else {
            r = await DictationFormatter.format(raw: raw, settings: s, context: ctx, chat: s.smartFormatting ? chat(keys) : nil)
        }
        let cleanupEnd = (reused ? stage.outcome?.polishReady : nil) ?? DispatchTime.now().uptimeNanoseconds
        let cleanupMs = Int((max(cleanupEnd, c0) &- c0) / 1_000_000)
        if Task.isCancelled { return }
        let text = r.text
        E2E.mark("formatted"); if E2E.isOn { E2E.formatted = text }
        guard !text.isEmpty else {
            logTrace(finalizeMs: stage.finalizeMs, transcribeWait: stage.transcribeWait, overlapped: stage.overlapped, cleanupMs: cleanupMs, pasteMs: 0, stopMark: stage.stopMark, speculated: stage.speculated, bytes: stage.bytes)
            model.bar = .idle
            return
        }
        let p0 = DispatchTime.now().uptimeNanoseconds
        let res = await TextInserter.insertVerified(text, into: target)
        let pasteMs = Int((DispatchTime.now().uptimeNanoseconds &- p0) / 1_000_000)
        logTrace(finalizeMs: stage.finalizeMs, transcribeWait: stage.transcribeWait, overlapped: stage.overlapped, cleanupMs: cleanupMs, pasteMs: pasteMs, stopMark: stage.stopMark, speculated: stage.speculated, bytes: stage.bytes)
        E2E.mark("inserted"); if E2E.isOn { E2E.pasted = res.pasted }
        model.addHistory(HistoryItem(text: text, rawText: raw, appName: target.appName, bundleID: target.bundleID ?? "", durationSeconds: seconds, kind: .dictation))
        if res.pasted { model.bar = .idle } else { flash(.notice("Vágólapra másolva – ⌘V"), after: 3.5) }
        if res.pasted, s.autoLearnDictionary, let pasted = res.valueAfter { scheduleLearning(inserted: text, pasted: pasted, target: target) }
    }

    /// Néhány másodperc múlva megnézi, javítottál-e kézzel egy szót a beillesztett szövegben (a mező tartalmát nem tárolja).
    private func scheduleLearning(inserted: String, pasted: String, target: TextInserter.Target) {
        learnWork?.cancel()
        learnWork = Task { [weak self] in
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: TestMode.isOn ? TestMode.learnDelay : 6_000_000_000)
                if Task.isCancelled { return }
                guard let self, let later = TextInserter.value(target) else { return }
                if let c = AutoLearn.correction(inserted: inserted, pasted: pasted, later: later, dictionary: self.model.settings.dictionary) {
                    AutoLearn.learn(c, into: &self.model.settings.dictionary)
                    self.flash(.notice("Szótárba: \(c.term)"), after: 2.5)
                    return
                }
            }
        }
    }

    private func finishCommand(instruction: String, seconds: Double, target: TextInserter.Target, keys: ProviderKeys, context: DictationContext) async {
        let selection = await TextInserter.selectedText(target)
        var ctx = context
        ctx.selected = selection
        let r = await CommandFormatter.run(instruction: instruction, context: ctx, chat: chat(keys))
        if Task.isCancelled { return }
        switch r {
        case .success(let out):
            if selection != nil { await TextInserter.replaceSelection(with: out, in: target) } else { _ = await TextInserter.insert(out, into: target) }
            model.addHistory(HistoryItem(text: out, rawText: instruction, appName: target.appName, bundleID: target.bundleID ?? "", durationSeconds: seconds, kind: .command))
            if let sel = selection { model.lastPolish = (sel, out); flash(.polishDone, after: 5) } else { model.bar = .idle }
        case .failure(let e):
            showError(e.short, detail: e.message)
        }
    }

    // MARK: Polírozás

    func polishSelection(preset: PolishPreset?) {
        guard !busy, !recorder.isRecording else { return }
        let keys = Keychain.all()
        guard !keys.isEmpty else { showError("Nincs kulcs", detail: FlowError.noAPIKey.message); openHub?(.settings); model.settingsTab = .apiKey; return }
        let p = preset ?? model.settings.defaultPolish
        let target = TextInserter.currentTarget()
        busy = true; busySince = Date()
        jobID += 1
        let id = jobID
        job = Task { [weak self] in
            guard let self else { return }
            defer { if self.jobID == id { self.busy = false; self.busySince = nil } }
            guard let sel = await TextInserter.selectedText(target) else {
                self.flash(.notice("Jelölj ki szöveget"))
                return
            }
            self.model.bar = .polishProcessing
            let s = self.model.settings
            _ = s
            let r = await self.chat(keys).complete(system: Prompts.polish(instruction: p.prompt), user: sel)
            if Task.isCancelled { return }
            switch r {
            case .success(let out):
                await TextInserter.replaceSelection(with: out, in: target)
                self.model.lastPolish = (sel, out)
                self.model.addHistory(HistoryItem(text: out, rawText: sel, appName: target.appName, bundleID: target.bundleID ?? "", durationSeconds: 0, kind: .polish))
                self.flash(.polishDone, after: 5)
            case .failure(let e):
                self.showError(e.short, detail: e.message)
            }
        }
    }

    func pasteLast() {
        guard !recorder.isRecording, let t = model.lastText else { return }
        let target = TextInserter.currentTarget()
        Task { _ = await TextInserter.insert(t, into: target) }
    }

    // MARK: Sáv-üzenetek

    private(set) var lastErrorDetail: String?

    func showError(_ short: String, detail: String) {
        lastErrorDetail = detail
        play(.error)
        flash(.error(short), after: 3.5)
        NSLog("Business Flow: %@", detail)
    }

    func flash(_ mode: BarMode, after: Double = 2.2) {
        model.bar = mode
        resetWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.recorder.isRecording, !self.busy || mode == .polishDone else { return }
            if self.model.bar == mode { self.model.bar = .idle }
        }
        resetWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }
}
