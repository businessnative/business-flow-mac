import Foundation
import Testing
@testable import BNFlowCore

@Suite struct RecoveryTests {
    private func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bf-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func accidentalTapIsNotKept() {
        #expect(!DictationRecovery.shouldRecord(elapsed: 0.2, speechSeconds: 0))
        #expect(!DictationRecovery.shouldRecord(elapsed: 0.49, speechSeconds: 0.05))
        // A tesztmód hosszú mintája rövid koppintásnál nem számít valódi beszédnek.
        #expect(!DictationRecovery.shouldRecord(elapsed: 0.05, speechSeconds: 1.6))
        #expect(DictationRecovery.shouldRecord(elapsed: 0.4, speechSeconds: 0.3))
        #expect(DictationRecovery.shouldRecord(elapsed: 0.8, speechSeconds: 0))
    }

    @Test func failedTranscriptionIsSaved() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RecordingArchive(directory: dir)
        let id = UUID()
        let wav = WAV.encode(samples: [0, 1200, -800, 400])
        let name = try #require(archive.save(wav: wav, id: id))
        let quota = TranscriptionLimitCopy.message(providers: [.openai])
        let network = HistoryAttempt.failed(appName: "Mail", bundleID: "com.apple.mail", seconds: 2.4, kind: .dictation, reason: HistoryCopy.reason(for: .network), audioFile: name)
        let limited = HistoryAttempt.failed(id: id, appName: "Mail", bundleID: "com.apple.mail", seconds: 3, kind: .dictation, reason: HistoryCopy.reason(for: .quota, quotaMessage: quota), audioFile: name)
        var ledger = HistoryLedger()
        ledger.add(network)
        ledger.add(limited)
        #expect(ledger.items.count == 2)
        #expect(ledger.items[0].status == .failed)
        #expect(ledger.items[0].failureReason == quota)
        #expect(ledger.items[0].failureReason?.hasPrefix("Elfogyott az átírás kerete") == true)
        #expect(ledger.items[0].canRetry)
        #expect(!ledger.items[0].canCopy)
        #expect(ledger.items[1].failureReason == "Nincs hálózati kapcsolat.")
        let empty = HistoryAttempt.empty(appName: "Mail", bundleID: "m", seconds: 1.2, kind: .dictation)
        ledger.add(empty)
        #expect(ledger.items[0].status == .empty)
        #expect(ledger.items[0].failureReason == HistoryCopy.silence)
        #expect(!ledger.items[0].canRetry)
        let data = try encoder().encode(ledger.items)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("Sikertelen") == false)
        #expect(text.contains("\"failed\""))
        #expect(!HistoryPrivacy.containsSecret(text))
    }

    @Test func pasteFailureStaysRecoverable() {
        var ledger = HistoryLedger()
        ledger.add(HistoryAttempt.succeeded(text: "régi mondat", raw: "régi", appName: "Slack", bundleID: "s", seconds: 1.2, kind: .dictation))
        let missed = HistoryAttempt.pasteFailed(text: "Holnap küldöm az ajánlatot.", raw: "holnap küldöm az ajánlatot", appName: "Mail", bundleID: "m", seconds: 2, kind: .dictation)
        ledger.add(missed)
        ledger.add(HistoryAttempt.failed(appName: "Mail", bundleID: "m", seconds: 1, kind: .dictation, reason: HistoryCopy.reason(for: .network), audioFile: nil))
        #expect(ledger.lastText == "Holnap küldöm az ajánlatot.")
        #expect(ledger.items[1].status == .pasteFailed)
        #expect(ledger.items[1].canCopy)
        #expect(!ledger.items[1].canRetry)
        #expect(ledger.items[1].failureReason == HistoryCopy.pasteFailed)
        // A későbbi üres hiba nem írja felül a beilleszthető szöveget.
        #expect(ledger.lastText == "Holnap küldöm az ajánlatot.")
        var forgotten = HistoryLedger(retention: .never)
        forgotten.add(missed)
        #expect(forgotten.items.isEmpty)
        #expect(forgotten.lastText == missed.text)
    }

    @Test func retryUsesSavedAudioAndUpdatesSameRow() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RecordingArchive(directory: dir)
        let id = UUID()
        let wav = Data("RIFF-local-audio-only".utf8)
        let name = try #require(archive.save(wav: wav, id: id))
        let item = HistoryAttempt.failed(id: id, appName: "Notes", bundleID: "n", seconds: 2, kind: .dictation, reason: HistoryCopy.reason(for: .server), audioFile: name)
        let sent = HistoryAttempt.audioForRetry(item: item) { archive.load($0) }
        #expect(sent == wav)
        #expect(archive.load("../\(name)") == nil)
        #expect(archive.load("/tmp/\(name)") == nil)
        #expect(!RecordingArchive.isSafeName("../../secrets.wav"))

        var ledger = HistoryLedger()
        ledger.add(item)
        let pasted = HistoryAttempt.applyRetry(item, outcome: .success(text: "Szia Dorottya", raw: "szia dorottya", pasted: false))
        #expect(pasted.id == id)
        #expect(pasted.status == .pasteFailed)
        #expect(pasted.canCopy)
        #expect(!pasted.canRetry)
        let removed = ledger.update(pasted)
        #expect(removed == [name])
        #expect(ledger.items.count == 1)
        #expect(ledger.items[0].id == id)
        #expect(ledger.lastText == "Szia Dorottya")
        archive.delete(name)
        #expect(archive.load(name) == nil)

        let again = HistoryAttempt.applyRetry(item, outcome: .failure(.network, quotaMessage: nil))
        #expect(again.id == id)
        #expect(again.status == .failed)
        #expect(again.audioFile == name)
        #expect(again.canRetry)
        #expect(again.failureReason == "Nincs hálózati kapcsolat.")
    }

    @Test func interruptedKeepsAudioUntilRetrySucceeds() throws {
        let id = UUID()
        let name = RecordingArchive.fileName(for: id)
        let item = HistoryAttempt.interrupted(id: id, appName: "Mail", bundleID: "m", seconds: 4, kind: .dictation, reason: HistoryCopy.timeout, audioFile: name)
        #expect(item.status == .interrupted)
        #expect(item.canRetry)
        #expect(item.failureReason == HistoryCopy.timeout)
        let done = HistoryAttempt.applyRetry(item, outcome: .success(text: "Megjött.", raw: "megjött", pasted: true))
        #expect(done.status == .success)
        #expect(done.audioFile == nil)
        #expect(done.canCopy)
        #expect(!done.canRetry)
        #expect(done.failureReason == nil)
    }

    @Test func successPathStillWorks() {
        var ledger = HistoryLedger()
        let item = HistoryAttempt.succeeded(text: "Holnap délután átküldöm az ajánlatot.", raw: "holnap délután átküldöm az ajánlatot", appName: "Slack", bundleID: "s", seconds: 3, kind: .dictation)
        ledger.add(item)
        #expect(item.status == .success)
        #expect(item.canCopy)
        #expect(!item.canRetry)
        #expect(item.audioFile == nil)
        #expect(ledger.lastText == item.text)
        #expect(ledger.items.count == 1)
        let st = HistoryLogic.stats(ledger.items)
        #expect(st.totalWords == 5)
        // A sikertelen sor nem rontja a beszédtempót.
        ledger.add(HistoryAttempt.failed(appName: "Slack", bundleID: "s", seconds: 30, kind: .dictation, reason: HistoryCopy.reason(for: .network), audioFile: nil))
        #expect(HistoryLogic.stats(ledger.items).averageWPM == st.averageWPM)
    }

    @Test func retentionDropsAudioWithTheRow() {
        let now = Date()
        let oldName = RecordingArchive.fileName(for: UUID())
        var ledger = HistoryLedger(retention: .days7)
        ledger.add(HistoryItem(date: now.addingTimeInterval(-10 * 86400), text: "", rawText: "", appName: "A", bundleID: "a", durationSeconds: 2, kind: .dictation, status: .failed, failureReason: HistoryCopy.reason(for: .network), audioFile: oldName))
        ledger.add(HistoryAttempt.succeeded(date: now, text: "friss", raw: "friss", appName: "A", bundleID: "a", seconds: 1, kind: .dictation))
        let drop = ledger.prune(now: now)
        #expect(drop == [oldName])
        #expect(ledger.items.count == 1)
        #expect(ledger.items[0].text == "friss")
    }

    @Test func oldHistoryDecodesAsSuccess() throws {
        let id = UUID()
        let old = """
        {"appName":"Mail","bundleID":"com.apple.mail","date":"2026-01-02T15:04:05Z","durationSeconds":1.5,"id":"\(id.uuidString)","kind":"dictation","rawText":"szia","text":"Szia."}
        """
        let item = try decoder().decode(HistoryItem.self, from: Data(old.utf8))
        #expect(item.id == id)
        #expect(item.status == .success)
        #expect(item.text == "Szia.")
        #expect(item.failureReason == nil)
        #expect(item.audioFile == nil)
        #expect(item.canCopy)
        let back = try decoder().decode(HistoryItem.self, from: encoder().encode(item))
        #expect(back == item)
    }

    @Test func secretsNeverLandInHistoryOrLogs() throws {
        let poisoned = "Bearer sk-live-secret-key Authorization: token=abc {\"error\":{\"message\":\"sk-body\"}}"
        let item = HistoryItem(text: "szia", rawText: "szia", appName: "Mail", bundleID: "m", durationSeconds: 1, kind: .dictation, status: .failed, failureReason: poisoned, audioFile: "../sk-live.wav")
        #expect(item.failureReason == HistoryCopy.generic)
        #expect(item.audioFile == nil)
        let reason = HistoryCopy.reason(for: .badRequest(poisoned))
        #expect(reason == "A szolgáltatás elutasította a kérést.")
        #expect(!reason.contains("sk-"))
        #expect(FlowError.badRequest(poisoned).logName == "badRequest")
        #expect(!FlowError.badRequest(poisoned).logName.contains("sk-"))
        #expect(!FlowError.quota.logName.contains("sk-"))
        let encoded = try encoder().encode([item])
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!HistoryPrivacy.containsSecret(text))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("sk-live"))
        #expect(!text.contains("../"))
        let found = HistorySearch.filter([item], query: "atiras")
        #expect(found.count == 1)
    }
}
