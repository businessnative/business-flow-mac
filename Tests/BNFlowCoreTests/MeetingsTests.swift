import Testing
import Foundation
@testable import BNFlowCore

@Suite struct MeetingsTests {
    let utc = TimeZone(identifier: "UTC")!
    func d(_ s: String) -> Date { let f = ISO8601DateFormatter(); return f.date(from: s)! }

    @Test func testLinks() {
        #expect(MeetingLinks.find(in: "Join: https://meet.google.com/abc-defg-hij ok")?.1 == .googleMeet)
        #expect(MeetingLinks.find(in: "x https://teams.microsoft.com/l/meetup-join/19%3ameeting_X/0?context=1 y")?.1 == .teams)
        #expect(MeetingLinks.find(in: "https://meet.google.com/landing") == nil)
        #expect(MeetingLinks.find(in: "nincs link") == nil)
    }

    let ics = """
    BEGIN:VCALENDAR\r
    BEGIN:VEVENT\r
    UID:one\r
    DTSTART;TZID=Europe/Budapest:20261104T100000\r
    DTEND;TZID=Europe/Budapest:20261104T110000\r
    SUMMARY:Heti egyeztetés\\, csapat\r
    DESCRIPTION:Csatlakozás: https://meet.google.com/abc-de\r
     fg-hij\\nKöszi\r
    BEGIN:VALARM\r
    DESCRIPTION:riasztás\r
    END:VALARM\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:rec\r
    DTSTART:20261102T080000Z\r
    DTEND:20261102T083000Z\r
    RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4\r
    EXDATE:20261104T080000Z\r
    LOCATION:https://meet.google.com/xyz-wxyz-xyz\r
    SUMMARY:Standup\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:rec\r
    RECURRENCE-ID:20261109T080000Z\r
    DTSTART:20261109T090000Z\r
    DTEND:20261109T093000Z\r
    LOCATION:https://meet.google.com/xyz-wxyz-xyz\r
    SUMMARY:Standup (áthelyezve)\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:nolink\r
    DTSTART:20261104T120000Z\r
    SUMMARY:Ebéd\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:allday\r
    DTSTART;VALUE=DATE:20261105\r
    DESCRIPTION:https://meet.google.com/aaa-bbbb-ccc\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:cancel\r
    STATUS:CANCELLED\r
    DTSTART:20261104T130000Z\r
    DESCRIPTION:https://meet.google.com/aaa-bbbb-ccc\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    @Test func testICSParse() {
        let ev = ICS.meetings(ics, from: d("2026-11-01T00:00:00Z"), to: d("2026-11-20T00:00:00Z"), defaultTZ: utc)
        let one = ev.first { $0.uid == "one" }!
        #expect(one.title == "Heti egyeztetés, csapat")
        #expect(one.start == d("2026-11-04T09:00:00Z"))      // Budapest UTC+1
        #expect(one.url.absoluteString == "https://meet.google.com/abc-defg-hij")
        let stand = ev.filter { $0.uid == "rec" }.map(\.start)
        // COUNT=4: nov 2, (4 kizárva), 9 (áthelyezve 9:00-ra), 11 ; az áthelyezett külön esemény
        #expect(stand == [d("2026-11-02T08:00:00Z"), d("2026-11-09T09:00:00Z"), d("2026-11-11T08:00:00Z")])
        #expect(!ev.contains { ["nolink", "allday", "cancel"].contains($0.uid) })
    }

    @Test func testWindowAndSlug() {
        let ev = ICS.meetings(ics, from: d("2026-11-10T00:00:00Z"), to: d("2026-11-12T00:00:00Z"), defaultTZ: utc)
        #expect(ev.map(\.uid) == ["rec"])
        let e = MeetingEvent(uid: "u", title: "A/B: teszt?", start: d("2026-11-04T09:00:00Z"), end: d("2026-11-04T10:00:00Z"), url: URL(string: "https://meet.google.com/abc-defg-hij")!, platform: .googleMeet)
        #expect(MeetingNotes.slug(e, tz: utc) == "2026-11-04 0900 – A B  teszt")
    }

    @Test func testChunksAndSilence() {
        let pcm = Data(count: 16_000 * 2 * 25)  // 25 s csend
        let c = MeetingAudio.chunks(pcm: pcm, seconds: 10)
        #expect(c.map(\.count) == [320_000, 320_000, 160_000])
        #expect(MeetingAudio.isSilent(c[0]))
        #expect(MeetingAudio.wav(c[2]).count == 160_044)
        #expect(MeetingAudio.chunks(pcm: Data(count: 16_000 * 2 * 600 * 2)).count == 2)
    }

    @Test func testSummaryInputTruncates() {
        let s = MeetingNotes.summaryInput("T", transcript: String(repeating: "a", count: 300), limit: 90)
        #expect(s.contains("kimaradt") && s.count < 250)
    }

    @Test func testCaptionsMergeAndTalkTime() {
        let j = """
        {"speaker":"Anna","text":"Szia, kezdjük","t":1,"tEnd":3}
        {"speaker":"Anna","text":"Szia, kezdjük a költségvetéssel","t":2,"tEnd":6}
        {"speaker":"Béla","text":"Rendben, péntekig küldöm","t":8,"tEnd":20}
        rossz sor
        {"speaker":"","text":"x","t":9}
        """
        let c = MeetingCaptions.parse(j)
        #expect(c.count == 2)
        #expect(c[0].text == "Szia, kezdjük a költségvetéssel")
        #expect(MeetingCaptions.talkTime(c).first?.0 == "Béla")
        #expect(MeetingCaptions.markdown(c).contains("**Béla** [00:00:08]: Rendben"))
        let e = MeetingEvent(uid: "u", title: "T", start: Date(), end: Date(), url: URL(string: "https://meet.google.com/abc-defg-hij")!, platform: .googleMeet)
        let md = MeetingNotes.transcriptMarkdown(.init(event: e), segments: [], captions: c, participants: ["Anna", "Béla"])
        #expect(md.contains("Résztvevők: Anna, Béla") && md.contains("Beszélőnként"))
        #expect(MeetingNotes.summaryInput("T", transcript: "hang", captions: c).contains("**Anna**"))
    }
}
