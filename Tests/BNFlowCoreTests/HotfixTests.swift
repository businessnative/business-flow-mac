import Testing
import Foundation
@testable import BNFlowCore

/// 0.3.1: csendes alapértelmezés + hangok migrációja, helyreállítható gyorsbillentyű-állapotgép.
struct HotfixTests {
    @Test func soundsOffByDefault() {
        let s = AppSettings()
        #expect(s.sounds == false)
        #expect(s.soundVolume <= 0.2)
        #expect(s.settingsVersion == AppSettings.currentVersion)
    }

    @Test func oldInstallMigratesToSilent() throws {
        // 0.3.0-s settings.json: sounds=true, nincs settingsVersion.
        let old = #"{"sounds":true,"muteMedia":true,"transcriptionModel":"gpt-transcribe"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(s.sounds == false)
        #expect(s.muteMedia == true)
        #expect(s.transcriptionModel == "gpt-transcribe")
        #expect(s.settingsVersion == 2)
    }

    @Test func userChoiceSurvivesAfterMigration() throws {
        var s = AppSettings()
        s.sounds = true; s.soundVolume = 0.4
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.sounds == true)
        #expect(abs(back.soundVolume - 0.4) < 0.0001)
    }

    @Test func volumeClamped() throws {
        let j = #"{"settingsVersion":2,"sounds":true,"soundVolume":7}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(AppSettings.self, from: j).soundVolume == 1)
    }

    func mouseEngine() -> HotkeyEngine {
        var sc = ShortcutSettings.default
        sc.handsFree.append(.mouse(button: 4))
        return HotkeyEngine(shortcuts: sc)
    }

    @Test func handsFreeMouseToggleCycles() {
        let e = mouseEngine()
        for i in 0..<50 {
            let t = Double(i)
            #expect(e.mouseDown(4, at: t).actions == [.start(.dictation, handsFree: true)])
            _ = e.mouseUp(4, at: t + 0.05)
            #expect(e.mouseDown(4, at: t + 0.5).actions == [.stop])
            _ = e.mouseUp(4, at: t + 0.55)
            #expect(e.state == .idle)
        }
    }

    @Test func resetRecoversFromDesync() {
        // A vezérlő elutasította az indítást (pl. feldolgozás fut) és reset()-et hív: a következő nyomás újra indít.
        let e = mouseEngine()
        _ = e.mouseDown(4, at: 0)
        e.reset()
        #expect(e.mouseDown(4, at: 1).actions == [.start(.dictation, handsFree: true)])
    }

    @Test func lostFnReleaseIsRecoveredByResync() {
        // A figyelő kikapcsolt állapotában elveszett az fn felengedése; a resync üres módosító-halmazt küld → stop.
        let e = HotkeyEngine(shortcuts: .default)
        #expect(e.modifiersChanged([.fn], at: 0) == [.start(.dictation, handsFree: false)])
        #expect(e.modifiersChanged([], at: 5) == [.stop])
        #expect(e.state == .idle)
        #expect(e.modifiersChanged([.fn], at: 6) == [.start(.dictation, handsFree: false)])
    }

    @Test func fnSpaceHandsFreeCycles() {
        // fn lenyomva → PTT indul; Szóköz → kihangosított; fn+Szóköz újra → leáll, és a Szóköz NEM indítja újra.
        let e = HotkeyEngine(shortcuts: .default)
        for i in 0..<30 {
            let t = Double(i) * 10
            #expect(e.modifiersChanged([.fn], at: t) == [.start(.dictation, handsFree: false)])
            #expect(e.keyDown(49, isRepeat: false, at: t + 0.1).actions == [.lockHandsFree])
            _ = e.keyUp(49); _ = e.modifiersChanged([], at: t + 0.3)
            #expect(e.state == .handsFree(.dictation))
            #expect(e.modifiersChanged([.fn], at: t + 2) == [.stop])
            e.reset() // a vezérlő stop() közben ezt hívja
            let r = e.keyDown(49, isRepeat: false, at: t + 2.1)
            #expect(r.actions.isEmpty && r.consume)
            #expect(e.state == .idle)
            _ = e.keyUp(49); _ = e.modifiersChanged([], at: t + 2.3)
            #expect(e.state == .idle)
        }
    }
}
