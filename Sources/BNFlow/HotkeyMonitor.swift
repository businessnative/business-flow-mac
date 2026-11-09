import AppKit
import CoreGraphics
import BNFlowCore

/// Globális billentyű- és egérfigyelő CGEventTap-pel (Bemenetfigyelés engedély kell).
/// Az eseményeket a tiszta `HotkeyEngine` értelmezi; mi csak továbbítjuk és szükség esetén elnyeljük őket.
final class HotkeyMonitor {
    static let syntheticMarker: Int64 = 0x424E_464C // "BNFL"

    let engine: HotkeyEngine
    var onAction: ((HotkeyAction) -> Void)?
    /// Rögzítő mód (Billentyűparancsok beállítása): minden eseményt ide küld, és nem hajt végre parancsot.
    var recorder: ((RecordedInput) -> Void)?

    enum RecordedInput { case modifiers(Set<ModifierKey>), key(UInt16, Set<ModifierClass>), mouse(Int) }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pressed: Set<ModifierKey> = []
    private(set) var isRunning = false

    init(shortcuts: ShortcutSettings) { engine = HotkeyEngine(shortcuts: shortcuts) }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let m = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return m.handle(type, event)
        }, userInfo: me) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        isRunning = true
        // Őr: ha a rendszer csendben kikapcsolta a figyelőt (pl. lassú fő szál), visszakapcsoljuk.
        health?.invalidate()
        health = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkHealth() }
        FlowLog.hotkey.info("eseményfigyelő elindult")
        return true
    }

    private var health: Timer?
    private(set) var reenableCount = 0

    private func checkHealth() {
        guard let t = tap else { return }
        if !CGEvent.tapIsEnabled(tap: t) {
            reenableCount += 1
            FlowLog.hotkey.error("eseményfigyelő ki volt kapcsolva – visszakapcsolás (őr)")
            CGEvent.tapEnable(tap: t, enable: true)
            resync()
        }
    }

    /// A tényleges (fizikai) billentyű- és egérállapothoz igazít: ha egy felengedés elveszett
    /// (pl. a figyelő ki volt kapcsolva), a motor megkapja a hiányzó „felengedést” és leállítja a felvételt.
    func resync() {
        let cls = Self.classes(of: CGEventSource.flagsState(.combinedSessionState))
        let now = pressed.filter { cls.contains($0.modifierClass) }
        if now != pressed {
            FlowLog.hotkey.notice("elveszett módosító-felengedés pótlása")
            pressed = now
            emit(engine.modifiersChanged(now, at: self.now()))
        }
        if case .holding(_, _, let mouse?) = engine.state, let btn = CGMouseButton(rawValue: UInt32(mouse)),
           !CGEventSource.buttonState(.combinedSessionState, button: btn) {
            FlowLog.hotkey.notice("elveszett egérgomb-felengedés pótlása")
            emit(engine.mouseUp(mouse, at: self.now()).actions)
        }
    }

    func stop() {
        health?.invalidate(); health = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; isRunning = false
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func emit(_ actions: [HotkeyAction]) {
        guard !actions.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in actions.forEach { self?.onAction?($0) } }
    }

    static func modifierKeys(flags: CGEventFlags, changedKey: UInt16, previous: Set<ModifierKey>) -> Set<ModifierKey> {
        var set = previous
        if let k = ModifierKey.from(keyCode: changedKey) {
            let flag: CGEventFlags
            switch k.modifierClass {
            case .fn: flag = .maskSecondaryFn
            case .control: flag = .maskControl
            case .option: flag = .maskAlternate
            case .shift: flag = .maskShift
            case .command: flag = .maskCommand
            }
            if set.contains(k) { set.remove(k) } else { set.insert(k) }
            // Biztonsági szinkron a flag-ekkel (pl. ha egy felengedés elveszett).
            if !flags.contains(flag) { set = set.filter { $0.modifierClass != k.modifierClass } }
        }
        // Az összes osztály, amelynek a flagje már nincs lent, törlődik.
        let classes: [(ModifierClass, CGEventFlags)] = [(.fn, .maskSecondaryFn), (.control, .maskControl), (.option, .maskAlternate), (.shift, .maskShift), (.command, .maskCommand)]
        for (c, f) in classes where !flags.contains(f) { set = set.filter { $0.modifierClass != c } }
        return set
    }

    static func classes(of flags: CGEventFlags) -> Set<ModifierClass> {
        var s: Set<ModifierClass> = []
        if flags.contains(.maskSecondaryFn) { s.insert(.fn) }
        if flags.contains(.maskControl) { s.insert(.control) }
        if flags.contains(.maskAlternate) { s.insert(.option) }
        if flags.contains(.maskShift) { s.insert(.shift) }
        if flags.contains(.maskCommand) { s.insert(.command) }
        return s
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableCount += 1
            FlowLog.hotkey.error("eseményfigyelő kikapcsolva (\(type == .tapDisabledByTimeout ? "timeout" : "userInput", privacy: .public)) – visszakapcsolás")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            DispatchQueue.main.async { [weak self] in self?.resync() }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }

        switch type {
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            pressed = Self.modifierKeys(flags: event.flags, changedKey: code, previous: pressed)
            if let rec = recorder { let p = pressed; DispatchQueue.main.async { rec(.modifiers(p)) }; return pass }
            emit(engine.modifiersChanged(pressed, at: now()))
            return pass
        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if let rec = recorder {
                let cls = Self.classes(of: event.flags)
                DispatchQueue.main.async { rec(.key(code, cls)) }
                return nil
            }
            let repeatFlag = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // A nyílbillentyűk és F-billentyűk fn-flaggel jönnek; a motor a saját módosító-állapotunkat használja.
            let r = engine.keyDown(code, isRepeat: repeatFlag, at: now())
            emit(r.actions)
            return r.consume ? nil : pass
        case .keyUp:
            if recorder != nil { return nil }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return engine.keyUp(code) ? nil : pass
        case .otherMouseDown:
            let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if let rec = recorder, b >= 2 { DispatchQueue.main.async { rec(.mouse(b)) }; return nil }
            let r = engine.mouseDown(b, at: now())
            emit(r.actions)
            return r.consume ? nil : pass
        case .otherMouseUp:
            let b = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if recorder != nil { return pass }
            let r = engine.mouseUp(b, at: now())
            emit(r.actions)
            return r.consume ? nil : pass
        default:
            return pass
        }
    }
}
