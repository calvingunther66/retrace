import XCTest
@testable import Processing

/// Table tests for near-duplicate grouping and failure backoff. The OCR fixtures are shaped like what the live
/// backlog actually contains: a settings screen whose only change between captures is a ticking value (the case
/// that makes 40–80% of pending frames redundant), a document that scrolls, and a text-light canvas.
final class SemanticFrameGrouperTests: XCTestCase {
    private let grouper = SemanticFrameGrouper()

    private let settingsScreen = """
        General Settings Enable Components Player Camera Timer Notes Bookmarks Calendar Component Order Space Management \
        Drag to reorder enabled components Launch at login Show in menu bar Appearance Notch width Animation speed \
        Keyboard shortcuts Advanced Quit
        """

    private func frame(_ id: Int64, atSec: Int64, text: String?, segment: Int64 = 1, context: String = "app|General|") -> SemanticFrameGrouper.Frame {
        SemanticFrameGrouper.Frame(
            frameID: id, segmentID: segment, contextKey: context, createdAtMs: atSec * 1000,
            tokens: text.map(SemanticFrameGrouper.tokens(from:))
        )
    }

    func testTokensKeepWordsOfThreeOrMoreAlphanumericCharacters() {
        XCTAssertEqual(SemanticFrameGrouper.tokens(from: "A to Be, Safari—v2.3 57% done!"), ["safari", "done"])
    }

    func testUnchangedScreenWithTickingValueCollapsesToOneGroupRepresentedByMiddleFrame() {
        let frames = (0..<5).map { frame(Int64($0 + 1), atSec: Int64($0 * 2), text: settingsScreen + " \($0 * 7) seconds") }
        let groups = grouper.group(frames)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].representative.frameID, 3)
        XCTAssertEqual(groups[0].siblings.map(\.frameID), [1, 2, 4, 5])
        XCTAssertEqual(groups[0].captureCount, 5)
        XCTAssertEqual(groups[0].spanMs, 8000)
    }

    func testSlowScrollDoesNotChainIntoOneGroup() {
        // Each step swaps ~12% of the words, so neighbours match (≥0.9) but the anchor drifts away.
        let words = (0..<100).map { "word\($0)alpha" }
        func page(_ step: Int) -> String { words[(step * 5)..<(step * 5 + 60)].joined(separator: " ") }
        let frames = (0..<6).map { frame(Int64($0 + 1), atSec: Int64($0 * 2), text: page($0)) }
        let groups = grouper.group(frames)
        XCTAssertGreaterThan(groups.count, 1, "anchor comparison must stop a scrolling document from chaining")
        XCTAssertEqual(groups.map(\.captureCount).reduce(0, +), 6)
    }

    func testStaticSidebarCannotHideAChangedMainPane() {
        // Jaccard is still ≥0.9 (large shared chrome), but ~30 new words appeared: a different pane, not a tick.
        let chrome = (0..<400).map { "sidebar\($0)item" }.joined(separator: " ")
        let paneA = (0..<15).map { "alpha\($0)topic" }.joined(separator: " ")
        let paneB = (0..<15).map { "bravo\($0)topic" }.joined(separator: " ")
        let frames = [frame(1, atSec: 0, text: chrome + " " + paneA), frame(2, atSec: 4, text: chrome + " " + paneB)]
        XCTAssertGreaterThanOrEqual(SemanticFrameGrouper.jaccard(frames[0].tokens!, frames[1].tokens!), 0.9)
        XCTAssertEqual(grouper.group(frames).count, 2)
    }

    func testTextLightFramesAreNeverGrouped() {
        let frames = (0..<4).map { frame(Int64($0 + 1), atSec: Int64($0 * 2), text: "Preview Untitled") }
        XCTAssertEqual(grouper.group(frames).count, 4)
    }

    func testFramesWithoutOCRRowAreNeverGrouped() {
        let frames = (0..<3).map { frame(Int64($0 + 1), atSec: Int64($0 * 2), text: nil) }
        XCTAssertEqual(grouper.group(frames).count, 3)
    }

    func testContextChangeSplitsGroupsButSameContextReopenedAsNewSegmentStillJoins() {
        let other = frame(2, atSec: 2, text: settingsScreen, segment: 2, context: "other|Window|")
        XCTAssertEqual(grouper.group([frame(1, atSec: 0, text: settingsScreen), other]).count, 2)

        let reopened = frame(2, atSec: 2, text: settingsScreen, segment: 9, context: "app|General|")
        XCTAssertEqual(grouper.group([frame(1, atSec: 0, text: settingsScreen), reopened]).count, 1)
    }

    func testGapSpanAndSizeCapsSplitRuns() {
        let gap = [frame(1, atSec: 0, text: settingsScreen), frame(2, atSec: 91, text: settingsScreen)]
        XCTAssertEqual(grouper.group(gap).count, 2, "a >90s gap ends the run")

        // 9 captures every 80s: every gap is fine, but the run is cut whenever it would pass the 5-minute span cap.
        let span = (0..<9).map { frame(Int64($0 + 1), atSec: Int64($0 * 80), text: settingsScreen) }
        XCTAssertEqual(grouper.group(span).map(\.captureCount).sorted(), [1, 4, 4])

        var small = SemanticFrameGrouper()
        small.config.maxGroupSize = 3
        let many = (0..<7).map { frame(Int64($0 + 1), atSec: Int64($0), text: settingsScreen) }
        XCTAssertEqual(small.group(many).map(\.captureCount), [3, 3, 1])
    }

    func testGroupsKeepSelectionPriorityOrderNewestFirst() {
        // Input is newest-first (as selectPending returns it): a settings run, then a distinct page, then an older run.
        let other = "Quarterly revenue dashboard filters region product channel export download share schedule report refresh"
        let input = [
            frame(10, atSec: 1000, text: settingsScreen), frame(9, atSec: 998, text: settingsScreen),
            frame(8, atSec: 900, text: other),
            frame(7, atSec: 100, text: settingsScreen), frame(6, atSec: 98, text: settingsScreen),
        ]
        let groups = grouper.group(input)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(Set(groups[0].siblings.map(\.frameID) + [groups[0].representative.frameID]), [9, 10])
        XCTAssertEqual(groups[1].representative.frameID, 8)
        XCTAssertEqual(Set(groups[2].siblings.map(\.frameID) + [groups[2].representative.frameID]), [6, 7])
    }

    func testEveryInputFrameLandsInExactlyOneGroup() {
        var frames: [SemanticFrameGrouper.Frame] = []
        for i in 0..<30 {
            let text: String = i % 7 == 0
                ? "unique page number \(i) with plenty of distinct body words to pass the token floor"
                : settingsScreen
            frames.append(frame(Int64(i + 1), atSec: Int64(i * 30), text: text))
        }
        var ids: [Int64] = []
        for group in grouper.group(frames) {
            ids.append(group.representative.frameID)
            ids.append(contentsOf: group.siblings.map { $0.frameID })
        }
        XCTAssertEqual(ids.sorted(), frames.map { $0.frameID }.sorted())
    }

    // MARK: - Failure backoff

    func testBackoffStaysAtNormalCadenceForTheFirstTwoFailuresThenClimbsAndCaps() {
        var backoff = SemanticFailureBackoff()
        XCTAssertNil(backoff.delaySeconds)
        var delays: [Int?] = []
        for _ in 0..<7 {
            backoff.recordAvailabilityFailure()
            delays.append(backoff.delaySeconds)
        }
        XCTAssertEqual(delays, [nil, nil, 120, 300, 600, 1200, 1200])
    }

    func testOneSuccessClearsTheBackoff() {
        var backoff = SemanticFailureBackoff()
        (0..<6).forEach { _ in backoff.recordAvailabilityFailure() }
        XCTAssertNotNil(backoff.delaySeconds)
        backoff.recordSuccess()
        XCTAssertNil(backoff.delaySeconds)
        XCTAssertEqual(backoff.consecutiveFailures, 0)
    }
}
