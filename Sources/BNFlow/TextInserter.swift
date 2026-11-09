import AppKit
import ApplicationServices
import BNFlowCore

/// Szöveg beillesztése a fókuszban lévő mezőbe: vágólap mentése → Cmd+V → vágólap visszaállítása.
enum TextInserter {
    struct Target {
        let app: NSRunningApplication?
        let element: AXUIElement?
        var bundleID: String? { app?.bundleIdentifier }
        var appName: String { app?.localizedName ?? "Ismeretlen" }
    }

    static func currentTarget() -> Target {
        if TestMode.isOn { return Target(app: nil, element: nil) }
        let app = NSWorkspace.shared.frontmostApplication
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let el: AXUIElement?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let f = focused {
            el = (f as! AXUIElement)
        } else { el = nil }
        return Target(app: app, element: el)
    }

    static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// A kijelölt szöveg (AX), ha a mező támogatja.
    static func selectedTextAX(_ t: Target) -> String? {
        if TestMode.isOn { return TestMode.selection }
        guard let el = t.element, let s = stringAttr(el, kAXSelectedTextAttribute as String), !s.isEmpty else { return nil }
        return s
    }

    /// Kijelölés kiolvasása Cmd+C-vel (tartalék, pl. böngészőkben); a vágólapot visszaállítja.
    static func selectedTextViaCopy() async -> String? {
        if TestMode.isOn { return TestMode.selection }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        sendKey(8, flags: .maskCommand) // C
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before { break }
        }
        let s = pb.changeCount != before ? pb.string(forType: .string) : nil
        restore(pb, saved)
        return (s?.isEmpty ?? true) ? nil : s
    }

    static func selectedText(_ t: Target) async -> String? {
        if let s = selectedTextAX(t) { return s }
        return await selectedTextViaCopy()
    }

    /// A kurzor előtti karakter (szóköz-kezeléshez).
    static func characterBeforeCaret(_ t: Target) -> Character? {
        guard let el = t.element else { return nil }
        var rangeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeVal) == .success, let rv = rangeVal else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range), range.location > 0 else { return nil }
        var q = CFRange(location: range.location - 1, length: 1)
        guard let qv = AXValueCreate(.cfRange, &q) else { return nil }
        var out: AnyObject?
        if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, qv, &out) == .success, let s = out as? String {
            return s.last
        }
        if let full = stringAttr(el, kAXValueAttribute as String) {
            let ns = full as NSString
            guard range.location - 1 < ns.length else { return nil }
            return (ns.substring(with: NSRange(location: range.location - 1, length: 1))).first
        }
        return nil
    }

    static func role(_ el: AXUIElement) -> String {
        stringAttr(el, kAXRoleAttribute as String) ?? ""
    }

    static func isSecure(_ t: Target) -> Bool {
        guard let el = t.element else { return false }
        return role(el) == "AXSecureTextField" || stringAttr(el, kAXSubroleAttribute as String) == "AXSecureTextField"
    }

    /// A mező teljes értéke (csak memóriában használjuk: beillesztés-ellenőrzés, szótár-tanulás). Jelszómezőnél nil.
    static func value(_ t: Target) -> String? {
        if TestMode.isOn { return TestMode.fieldValue }
        guard let el = t.element, !isSecure(t) else { return nil }
        guard let v = stringAttr(el, kAXValueAttribute as String), (v as NSString).length < 200_000 else { return nil }
        return v
    }

    static func windowTitle(_ t: Target) -> String? {
        guard let pid = t.app?.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        var w: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &w) == .success, let win = w else { return nil }
        return stringAttr(win as! AXUIElement, kAXTitleAttribute as String)
    }

    /// A kurzor körüli szöveg (legfeljebb 300 karakter előtte/utána) és az ablakcím. Csak memóriában.
    static func context(_ t: Target, includeText: Bool = true) -> DictationContext {
        var ctx = DictationContext(appName: t.appName, bundleID: t.bundleID, windowTitle: windowTitle(t))
        if isSecure(t) { ctx.isSecure = true; return ctx }
        guard includeText, let el = t.element, let full = value(t) else { return ctx }
        var rangeVal: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeVal) == .success, let rv = rangeVal else { return ctx }
        var r = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &r) else { return ctx }
        let ns = full as NSString
        let loc = max(0, min(ns.length, r.location)), end = max(loc, min(ns.length, r.location + r.length))
        let bStart = max(0, loc - 300)
        ctx.before = ns.substring(with: NSRange(location: bStart, length: loc - bStart))
        ctx.after = ns.substring(with: NSRange(location: end, length: min(300, ns.length - end)))
        if r.length > 0 { ctx.selected = ns.substring(with: NSRange(location: loc, length: end - loc)) }
        return ctx
    }

    static var hasEditableFocus: Bool {
        let t = currentTarget()
        guard let el = t.element else { return false }
        var role: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        let r = role as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) { return true }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    struct InsertResult { let pasted: Bool; let valueAfter: String? }

    /// Beillesztés. Ha a mező értéke olvasható, ellenőrizzük, hogy a szöveg tényleg bekerült-e; ha nem, natív mezőben
    /// közvetlen AX-beírással próbálkozunk, végső esetben a szöveg a vágólapon marad (és a sáv ezt jelzi).
    @MainActor
    static func insert(_ text: String, into t: Target, addLeadingSpace: Bool = true) async -> Bool {
        await insertVerified(text, into: t, addLeadingSpace: addLeadingSpace).pasted
    }

    @MainActor
    static func insertVerified(_ text: String, into t: Target, addLeadingSpace: Bool = true) async -> InsertResult {
        var s = text
        if TestMode.isOn {
            if addLeadingSpace, let last = TestMode.fieldValue.last, TextPipeline.needsLeadingSpace(before: last, text: s) { s = " " + s }
            if let sel = TestMode.selection, !addLeadingSpace, let r = TestMode.fieldValue.range(of: sel) {
                TestMode.fieldValue.replaceSubrange(r, with: s); TestMode.selection = nil
            } else { TestMode.fieldValue += s }
            TestMode.inserted.append(s)
            return InsertResult(pasted: true, valueAfter: TestMode.fieldValue)
        }
        if addLeadingSpace, TextPipeline.needsLeadingSpace(before: characterBeforeCaret(t), text: s) { s = " " + s }
        if let app = t.app, app != NSWorkspace.shared.frontmostApplication { app.activate() ; try? await Task.sleep(nanoseconds: 60_000_000) }
        let pb = NSPasteboard.general
        let editable = hasEditableFocus || t.element != nil
        let valueBefore = value(t)
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(s, forType: .string)
        // A vágólap-kezelők (pl. Raycast) jelzése: átmeneti tartalom.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        sendKey(9, flags: .maskCommand) // V
        guard editable else { return InsertResult(pasted: false, valueAfter: nil) }
        // A szöveg a billentyű pillanatában kerül be. Csak addig várunk, amíg a mező értéke tényleg megváltozik.
        try? await Task.sleep(nanoseconds: UInt64(PasteConfirm.firstWaitMs) * 1_000_000)
        var after = value(t)
        var polls = 0
        while PasteConfirm.shouldPoll(pollsDone: polls, valueChanged: valueBefore != nil && after != valueBefore, canRead: valueBefore != nil) {
            try? await Task.sleep(nanoseconds: UInt64(PasteConfirm.pollMs) * 1_000_000)
            polls += 1
            after = value(t)
        }
        if let vb = valueBefore, after == vb {
            // Lassabb appoknak még egy esély.
            try? await Task.sleep(nanoseconds: UInt64(PasteConfirm.slowExtraMs) * 1_000_000)
            after = value(t)
            if after == vb, let el = t.element, !AppCategoryResolver.browsers.contains(t.bundleID ?? ""), ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role(el)) {
                AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFString)
                try? await Task.sleep(nanoseconds: 80_000_000)
                after = value(t)
            }
            if after == vb {
                // Nem került be: a szöveg a vágólapon marad, Cmd+V-vel kézzel beilleszthető.
                return InsertResult(pasted: false, valueAfter: nil)
            }
        }
        if pb.string(forType: .string) == s { restore(pb, saved) }
        return InsertResult(pasted: true, valueAfter: after)
    }

    /// Kijelölés cseréje (polírozás / parancs mód).
    @MainActor
    static func replaceSelection(with text: String, in t: Target) async {
        _ = await insert(text, into: t, addLeadingSpace: false)
    }

    // MARK: Vágólap

    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }

    static func restore(_ pb: NSPasteboard, _ snap: Snapshot) {
        pb.clearContents()
        guard !snap.isEmpty else { return }
        let items: [NSPasteboardItem] = snap.map { dict in
            let it = NSPasteboardItem()
            for (t, v) in dict { it.setData(v, forType: t) }
            return it
        }
        pb.writeObjects(items)
    }

    // MARK: Billentyű-szimuláció (saját eseményforrással, hogy a figyelőnk ne vegye diktálásnak)
    static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = HotkeyMonitor.syntheticMarker
        return s
    }()

    static func sendKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
