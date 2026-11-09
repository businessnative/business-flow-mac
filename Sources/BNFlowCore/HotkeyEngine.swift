import Foundation

public enum DictationKind: String, Sendable, Equatable { case dictation, command }

public enum HotkeyAction: Equatable, Sendable {
    case start(DictationKind, handsFree: Bool)
    case switchKind(DictationKind)
    case lockHandsFree
    case stop
    case cancel
    case pasteLast
    case polish
}

/// A globális billentyű- és egéresemények tiszta állapotgépe (az eseményfigyelő AppKit-réteg hívja).
/// Teszteléshez az idő kívülről jön.
public final class HotkeyEngine {
    public enum State: Equatable { case idle, holding(DictationKind, since: TimeInterval, viaMouse: Int?), handsFree(DictationKind) }

    public var shortcuts: ShortcutSettings
    public private(set) var state: State = .idle
    /// Rövidebb nyomás nem diktálás (pl. véletlen fn-koppintás).
    public var minimumHold: TimeInterval = 0.18
    /// A külső vezérlő jelzi, ha egy felvétel magától véget ért (pl. hiba), hogy az állapot visszaálljon.
    public func reset() { state = .idle }  // a lenyomott módosítók a fizikai állapotot tükrözik, nem töröljük

    private var pressed: Set<ModifierKey> = []
    private var pendingHandsFreeStop = false

    public init(shortcuts: ShortcutSettings) { self.shortcuts = shortcuts }

    var holdChords: [(DictationKind, Set<ModifierKey>)] {
        var r: [(DictationKind, Set<ModifierKey>)] = []
        for case .hold(let k) in shortcuts.command { r.append((.command, Set(k))) }
        for case .hold(let k) in shortcuts.pushToTalk { r.append((.dictation, Set(k))) }
        return r
    }

    func classes(_ s: Set<ModifierKey>) -> Set<ModifierClass> { Set(s.map(\.modifierClass)) }

    /// Módosítók változása. Visszatérés: a végrehajtandó akciók.
    public func modifiersChanged(_ now: Set<ModifierKey>, at t: TimeInterval) -> [HotkeyAction] {
        let before = pressed
        pressed = now
        switch state {
        case .idle:
            if pendingHandsFreeStop, now.isEmpty { pendingHandsFreeStop = false; return [] }
            if pendingHandsFreeStop { return [] }
            if let (kind, _) = holdChords.first(where: { $0.1 == now }) {
                state = .holding(kind, since: t, viaMouse: nil)
                return [.start(kind, handsFree: false)]
            }
            return []
        case .holding(let kind, let since, let mouse):
            if mouse != nil { return [] }
            // Akkord bővült (pl. fn → fn+⌃): parancs módra váltás, ha még frissen nyomja.
            if let (newKind, _) = holdChords.first(where: { $0.1 == now }), newKind != kind {
                state = .holding(newKind, since: since, viaMouse: nil)
                return [.switchKind(newKind)]
            }
            let chord = holdChords.first { $0.0 == kind }?.1 ?? []
            if !chord.isSubset(of: now) {
                state = .idle
                return t - since < minimumHold ? [.cancel] : [.stop]
            }
            return []
        case .handsFree:
            // Kihangosított módban a diktáló akkord újbóli lenyomása állítja le.
            let newlyPressed = now.subtracting(before)
            if !newlyPressed.isEmpty, holdChords.contains(where: { $0.1 == now }) {
                state = .idle
                pendingHandsFreeStop = true
                return [.stop]
            }
            return []
        }
    }

    /// Billentyűlenyomás. `consume` = elnyeljük-e az eseményt.
    public func keyDown(_ keyCode: UInt16, isRepeat: Bool, at t: TimeInterval) -> (actions: [HotkeyAction], consume: Bool) {
        let cls = classes(pressed)
        func matches(_ list: [ShortcutTrigger]) -> Bool {
            list.contains { if case .combo(let c, let m) = $0 { return c == keyCode && Set(m) == cls } else { return false } }
        }
        if keyCode == 53 { // Esc
            switch state {
            case .idle: return ([], false)
            default: state = .idle; return ([.cancel], true)
            }
        }
        switch state {
        case .holding(let kind, _, let mouse):
            if mouse == nil, matches(shortcuts.handsFree) {
                state = .handsFree(kind)
                return ([.lockHandsFree], true)
            }
            if mouse == nil {
                // Más billentyű a nyomva tartott akkorddal: a felhasználó mást csinál (pl. fn+nyíl) → megszakítás.
                state = .idle
                return ([.cancel], false)
            }
            return ([], false)
        case .handsFree:
            if matches(shortcuts.handsFree) { if isRepeat { return ([], true) }; state = .idle; return ([.stop], true) }
            return ([], false)
        case .idle:
            if isRepeat { return ([], matches(shortcuts.handsFree) || matches(shortcuts.pasteLast) || matches(shortcuts.polish)) }
            // Kihangosítás leállítása fn+Szóközzel: az fn már leállította, a Szóköz ne indítsa újra azonnal.
            if pendingHandsFreeStop, matches(shortcuts.handsFree) { pendingHandsFreeStop = false; return ([], true) }
            if matches(shortcuts.handsFree) { state = .handsFree(.dictation); return ([.start(.dictation, handsFree: true)], true) }
            if matches(shortcuts.pasteLast) { return ([.pasteLast], true) }
            if matches(shortcuts.polish) { return ([.polish], true) }
            return ([], false)
        }
    }

    /// Billentyű felengedése: a kihangosítás-kombináció felengedését elnyeljük, hogy ne gépeljen szóközt.
    public func keyUp(_ keyCode: UInt16) -> Bool {
        if case .handsFree = state { return shortcuts.handsFree.contains { if case .combo(let c, _) = $0 { return c == keyCode } else { return false } } }
        if pendingHandsFreeStop { pendingHandsFreeStop = false }
        return false
    }

    public func mouseDown(_ button: Int, at t: TimeInterval) -> (actions: [HotkeyAction], consume: Bool) {
        let ptt = shortcuts.pushToTalk.contains(.mouse(button: button))
        let hf = shortcuts.handsFree.contains(.mouse(button: button))
        let cmd = shortcuts.command.contains(.mouse(button: button))
        guard ptt || hf || cmd else { return ([], false) }
        switch state {
        case .idle:
            if hf { state = .handsFree(.dictation); return ([.start(.dictation, handsFree: true)], true) }
            let kind: DictationKind = cmd ? .command : .dictation
            state = .holding(kind, since: t, viaMouse: button)
            return ([.start(kind, handsFree: false)], true)
        case .handsFree:
            state = .idle
            return ([.stop], true)
        case .holding:
            return ([], true)
        }
    }

    public func mouseUp(_ button: Int, at t: TimeInterval) -> (actions: [HotkeyAction], consume: Bool) {
        if case .holding(_, let since, let mouse) = state, mouse == button {
            state = .idle
            return (t - since < minimumHold ? [.cancel] : [.stop], true)
        }
        let configured = [shortcuts.pushToTalk, shortcuts.handsFree, shortcuts.command].contains { $0.contains(.mouse(button: button)) }
        return ([], configured)
    }

    /// Kattintás a sávon (hands-free indítás / leállítás).
    public func barClicked() -> [HotkeyAction] {
        switch state {
        case .idle: state = .handsFree(.dictation); return [.start(.dictation, handsFree: true)]
        case .handsFree, .holding: state = .idle; return [.stop]
        }
    }
}
