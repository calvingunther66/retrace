import XCTest
@testable import Search

final class AITimeResolverTests: XCTestCase {
    private let tz = TimeZone(identifier: "America/Los_Angeles")!
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(timeZone: tz, year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func testClaudeUsagePanelResolvesSessionAndWeeklyResetsIndependently() {
        // The real panel text; captured Mon Oct 5 11:34 AM, asked on Wed Oct 7 at 5 PM.
        let text = "Plan usage limits Session limit Resets in 4 hr 26 min 10% Weekly all models Resets Sat 12:00 PM 21%"
        let out = AITimeResolver.annotate(text, capturedAt: date(10, 5, 11, 34), now: date(10, 7, 17, 0), calendar: cal, timeZone: tz)

        XCTAssertTrue(out.contains("Resets in 4 hr 26 min [= Mon Oct 5, 4:00 PM (already passed)]"), out)
        XCTAssertTrue(out.contains("Resets Sat 12:00 PM [= Sat Oct 10, 12:00 PM (still upcoming"), out)
    }

    func testClockOnlyResetIsPlacedOnTheNextOccurrenceAfterCapture() {
        let out = AITimeResolver.annotate("Session limit Resets at 4:00 PM 70%", capturedAt: date(10, 5, 14, 25), now: date(10, 5, 15, 0), calendar: cal, timeZone: tz)
        XCTAssertTrue(out.contains("[= Mon Oct 5, 4:00 PM (still upcoming, in 1 hr 0 min)]"), out)

        // "resets 1pm" seen at 12:40 PM on Thu Oct 1; asked a week later.
        let compact = AITimeResolver.annotate("You've hit your session limit • resets 1pm (America/Los_Angeles)", capturedAt: date(10, 1, 12, 40), now: date(10, 7, 12, 0), calendar: cal, timeZone: tz)
        XCTAssertTrue(compact.contains("resets 1pm [= Thu Oct 1, 1:00 PM (already passed)]"), compact)
    }

    func testAgoIsResolvedAgainstCaptureTime() {
        let out = AITimeResolver.annotate("Last synced 12 min ago", capturedAt: date(10, 5, 11, 34), now: date(10, 7, 0, 0), calendar: cal, timeZone: tz)
        XCTAssertTrue(out.contains("12 min ago [= Mon Oct 5, 11:22 AM]"), out)
    }

    func testTextWithoutResetPhrasesAndMenuBarClocksIsUntouched() {
        let text = "HTHM Weekly Newsletter Week 8, 10/05  Claude File Edit View  Mon Oct 5 11:34 AM  94°F"
        XCTAssertEqual(AITimeResolver.annotate(text, capturedAt: date(10, 5, 11, 34), now: date(10, 7, 0, 0), calendar: cal, timeZone: tz), text)
    }
}
