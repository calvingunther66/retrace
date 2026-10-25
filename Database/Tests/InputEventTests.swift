import XCTest
import SQLite3
import Shared
@testable import Database

/// Input event logging (V24) against a real in-memory SQLite database with the full migration chain.
/// Frames are inserted with raw SQL at exact millisecond `createdAt` values so link resolution can be
/// asserted precisely (going through `Date` would risk off-by-one-ms float truncation).
final class InputEventTests: XCTestCase {

    private var db: OpaquePointer!
    private var segmentID: Int64 = 0

    override func setUp() async throws {
        sqlite3_open(":memory:", &db)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        try await MigrationRunner(db: db).runMigrations()
        segmentID = try insertSegment()
    }

    override func tearDown() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Migration

    func testMigrationCreatesInputEventSchema() throws {
        XCTAssertTrue(try exists(type: "table", name: "input_event"))
        XCTAssertTrue(try exists(type: "table", name: "input_event_ax"))
        XCTAssertTrue(try exists(type: "index", name: "idx_input_event_ts"))
        XCTAssertTrue(try exists(type: "index", name: "idx_input_event_pending"))
        XCTAssertTrue(try exists(type: "index", name: "idx_input_event_pre_frame"))
        XCTAssertTrue(try exists(type: "index", name: "idx_input_event_down_frame"))
        XCTAssertTrue(try exists(type: "index", name: "idx_input_event_post_frame"))
        XCTAssertEqual(try columnCount(table: "frame", column: "displayId"), 1)
    }

    func testMigrationIsIdempotent() async throws {
        try await V24_InputEvents().migrate(db: db)
        try await V24_InputEvents().migrate(db: db)
        XCTAssertEqual(try columnCount(table: "frame", column: "displayId"), 1)
        XCTAssertTrue(try exists(type: "table", name: "input_event"))
    }

    func testFrameInsertPersistsDisplayID() throws {
        let known = FrameReference(
            id: FrameID(value: 0),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            segmentID: AppSegmentID(value: segmentID),
            videoID: VideoSegmentID(value: 0),
            frameIndexInSegment: 0,
            metadata: FrameMetadata(displayID: 724_001_234)
        )
        let unknown = FrameReference(
            id: FrameID(value: 0),
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            segmentID: AppSegmentID(value: segmentID),
            videoID: VideoSegmentID(value: 0),
            frameIndexInSegment: 1,
            metadata: .empty
        )
        let knownID = try FrameQueries.insert(db: db, frame: known)
        let unknownID = try FrameQueries.insert(db: db, frame: unknown)

        XCTAssertEqual(try scalar("SELECT displayId FROM frame WHERE id = \(knownID);"), 724_001_234)
        XCTAssertNil(try scalar("SELECT displayId FROM frame WHERE id = \(unknownID);"), "display 0 is unknown and stored as NULL")
    }

    // MARK: - Insert / read round trip

    func testClickRoundTripsAllFieldsIncludingAXSnapshot() throws {
        let display = InputDisplayGeometry(
            id: 1, x: 0, y: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, scale: 2
        )
        let elements = [
            InputAXElement(role: "AXButton", name: "Share", box: [1398, 76, 30, 24]),
            InputAXElement(role: "AXTextField", name: nil, box: [10, 10, 200, 22])
        ]
        let event = InputEvent(
            tsMs: 1_761_343_339_123,
            endTsMs: 1_761_343_339_190,
            kind: .click,
            button: "left",
            clickCount: 2,
            modifiers: ["cmd", "shift"],
            x: 1412, y: 88,
            displayID: 1, displayPixelWidth: 3024, displayPixelHeight: 1964, displayScale: 2,
            displays: [display],
            bundleID: "com.apple.finder",
            windowTitle: "Downloads",
            windowX: 0, windowY: 25, windowWidth: 1512, windowHeight: 932,
            axTarget: InputAXTarget(
                role: "AXButton", title: "Share", identifier: "share-btn",
                x: 1398, y: 76, width: 30, height: 24
            ),
            axElements: elements,
            downFrameTsMs: 1_761_343_339_160
        )

        let ids = try InputEventQueries.insertBatch(db: db, events: [event])
        XCTAssertEqual(ids.count, 1)

        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: ids[0]))
        var expected = event
        expected.id = ids[0]
        expected.axElements = []  // snapshot lives in the side table
        XCTAssertEqual(stored, expected)
        XCTAssertEqual(stored.linkState, .pending)
        XCTAssertEqual(try InputEventQueries.fetchAXElements(db: db, eventID: ids[0]), elements)
    }

    func testTypingEventKeepsCountOnly() throws {
        let event = InputEvent(
            tsMs: 5_000, endTsMs: 7_500, kind: .typing, typedCount: 17,
            bundleID: "com.apple.TextEdit",
            axTarget: InputAXTarget(role: "AXTextArea", identifier: "body")
        )
        let ids = try InputEventQueries.insertBatch(db: db, events: [event])
        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: ids[0]))
        XCTAssertEqual(stored.typedCount, 17)
        XCTAssertNil(stored.keyCombo)
        XCTAssertNil(stored.axTarget?.title, "no element value or text is recorded for typing")
    }

    func testSecureTextFieldEventsAreRefusedAtInsert() throws {
        let secureByRole = InputEvent(
            tsMs: 1_000, kind: .click, x: 1, y: 1, axTarget: InputAXTarget(role: "AXSecureTextField")
        )
        let secureBySubrole = InputEvent(
            tsMs: 2_000, kind: .typing, typedCount: 8,
            axTarget: InputAXTarget(role: "AXTextField", subrole: "AXSecureTextField")
        )
        let normal = InputEvent(tsMs: 3_000, kind: .click, x: 1, y: 1, axTarget: InputAXTarget(role: "AXButton"))

        let ids = try InputEventQueries.insertBatch(db: db, events: [secureByRole, secureBySubrole, normal])

        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM input_event;"), 1)
        XCTAssertEqual(try InputEventQueries.fetch(db: db, id: ids[0])?.tsMs, 3_000)
    }

    func testFetchRangeFiltersByKindAndPages() throws {
        let events = [
            InputEvent(tsMs: 1_000, kind: .click),
            InputEvent(tsMs: 2_000, kind: .scroll, scrollDy: -40),
            InputEvent(tsMs: 3_000, kind: .shortcut, modifiers: ["cmd"], keyCombo: "cmd+t"),
            InputEvent(tsMs: 4_000, kind: .click),
            InputEvent(tsMs: 9_000, kind: .click)
        ]
        try InputEventQueries.insertBatch(db: db, events: events)

        let clicks = try InputEventQueries.fetchRange(db: db, sinceMs: 0, untilMs: 5_000, kinds: [.click])
        XCTAssertEqual(clicks.map(\.tsMs), [1_000, 4_000])

        let first = try InputEventQueries.fetchRange(db: db, sinceMs: 0, untilMs: 10_000, limit: 2)
        let second = try InputEventQueries.fetchRange(
            db: db, sinceMs: 0, untilMs: 10_000, afterID: first.last?.id ?? 0, limit: 10
        )
        XCTAssertEqual(first.map(\.tsMs), [1_000, 2_000])
        XCTAssertEqual(second.map(\.tsMs), [3_000, 4_000, 9_000])
        XCTAssertEqual(second.first?.keyCombo, "cmd+t")
    }

    // MARK: - Link resolution

    func testPreIsStrictLastFrameBeforeActionAndDownIsNeverPre() throws {
        let earlier = try insertFrame(createdAt: 9_000)
        let pre = try insertFrame(createdAt: 9_500)
        let down = try insertFrame(createdAt: 10_050)          // forced mouse-down capture, after tsMs
        _ = try insertFrame(createdAt: 10_130)                 // before settle (end 10_080 + 120)
        let post = try insertFrame(createdAt: 10_260)
        _ = earlier

        let id = try insertEvent(tsMs: 10_000, endTsMs: 10_080, downFrameTsMs: 10_050)
        let summary = try InputEventQueries.resolveLinks(db: db, nowMs: 100_000)

        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: id))
        XCTAssertEqual(stored.preFrameID, pre, "pre must be the last frame at or before mouse-down, not the forced frame")
        XCTAssertEqual(stored.preGapMs, 500)
        XCTAssertEqual(stored.downFrameID, down)
        XCTAssertEqual(stored.postFrameID, post, "post must wait for the action to settle")
        XCTAssertEqual(stored.linkState, .resolved)
        XCTAssertEqual(summary.resolved, 1)
    }

    func testPostNeverEqualsDownFrame() throws {
        _ = try insertFrame(createdAt: 9_900)
        let down = try insertFrame(createdAt: 10_300)   // slow forced capture, after settle point 10_200
        let post = try insertFrame(createdAt: 10_700)

        let id = try insertEvent(tsMs: 10_000, endTsMs: 10_080, downFrameTsMs: 10_300)
        _ = try InputEventQueries.resolveLinks(db: db, nowMs: 100_000)

        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: id))
        XCTAssertEqual(stored.downFrameID, down)
        XCTAssertEqual(stored.postFrameID, post)
    }

    func testEventStaysPendingUntilPostFrameThenGivesUp() throws {
        let pre = try insertFrame(createdAt: 9_800)
        let id = try insertEvent(tsMs: 10_000, endTsMs: 10_050)

        // Old enough to look at, but no post frame yet and not past the give-up window.
        var summary = try InputEventQueries.resolveLinks(db: db, nowMs: 16_000)
        var stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: id))
        XCTAssertEqual(stored.linkState, .pending)
        XCTAssertEqual(stored.preFrameID, pre, "pre is recorded even while post is pending")
        XCTAssertEqual(summary.stillPending, 1)

        // A post frame shows up later: resolves.
        let post = try insertFrame(createdAt: 12_500)
        summary = try InputEventQueries.resolveLinks(db: db, nowMs: 17_000)
        stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: id))
        XCTAssertEqual(stored.postFrameID, post)
        XCTAssertEqual(stored.linkState, .resolved)
        XCTAssertEqual(summary.resolved, 1)
    }

    func testGivesUpWhenNoPostFrameAppears() throws {
        let id = try insertEvent(tsMs: 10_000, endTsMs: 10_050)
        let summary = try InputEventQueries.resolveLinks(db: db, nowMs: 10_000 + 31_000)

        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: id))
        XCTAssertEqual(stored.linkState, .gaveUp)
        XCTAssertNil(stored.postFrameID)
        XCTAssertNil(stored.preFrameID)
        XCTAssertEqual(summary.gaveUp, 1)
        XCTAssertEqual(summary.postMissing, 1)
        XCTAssertEqual(summary.preMissing, 1)
    }

    func testTooYoungEventsAreLeftAlone() throws {
        _ = try insertFrame(createdAt: 9_000)
        let id = try insertEvent(tsMs: 10_000, endTsMs: 10_050)

        let summary = try InputEventQueries.resolveLinks(db: db, nowMs: 11_000)

        XCTAssertEqual(summary, InputEventLinkSummary())
        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: id))
        XCTAssertEqual(stored.linkState, .pending)
        XCTAssertNil(stored.preFrameID)
    }

    func testLinkingPrefersFramesOfTheClickedDisplay() throws {
        let sameDisplay = try insertFrame(createdAt: 9_000, displayID: 7)
        _ = try insertFrame(createdAt: 9_800, displayID: 9)      // other display, newer
        let legacy = try insertFrame(createdAt: 9_900, displayID: nil)  // pre-V24 frame: unknown display
        let post = try insertFrame(createdAt: 10_600, displayID: 7)
        _ = try insertFrame(createdAt: 10_400, displayID: 9)

        let id = try insertEvent(tsMs: 10_000, endTsMs: 10_050, displayID: 7)
        _ = try InputEventQueries.resolveLinks(db: db, nowMs: 100_000)

        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: id))
        XCTAssertEqual(stored.preFrameID, legacy, "unknown-display frames stay eligible; other displays do not")
        XCTAssertEqual(stored.postFrameID, post)
        XCTAssertNotEqual(stored.preFrameID, sameDisplay)
    }

    func testDeletionRewriteFramesAreNotLinked() throws {
        let kept = try insertFrame(createdAt: 9_000)
        let doomed = try insertFrame(createdAt: 9_900)
        try exec("UPDATE frame SET rewritePurpose = 'deletion' WHERE id = \(doomed);")
        _ = try insertFrame(createdAt: 10_500)

        let id = try insertEvent(tsMs: 10_000, endTsMs: 10_050)
        _ = try InputEventQueries.resolveLinks(db: db, nowMs: 100_000)

        XCTAssertEqual(try InputEventQueries.fetch(db: db, id: id)?.preFrameID, kept)
    }

    func testRedactedFrameStripsWindowAndAXDetail() throws {
        let pre = try insertFrame(createdAt: 9_800)
        try exec("UPDATE frame SET redactionReason = 'Excluded app: FaceTime' WHERE id = \(pre);")
        _ = try insertFrame(createdAt: 10_600)

        let ids = try InputEventQueries.insertBatch(db: db, events: [
            InputEvent(
                tsMs: 10_000, endTsMs: 10_050, kind: .click, button: "left", clickCount: 1,
                x: 5, y: 5,
                bundleID: "com.apple.FaceTime", windowTitle: "Call with Sam",
                axTarget: InputAXTarget(role: "AXButton", title: "End Call", identifier: "end", x: 1, y: 1, width: 2, height: 2),
                axElements: [InputAXElement(role: "AXButton", name: "End Call", box: [1, 1, 2, 2])]
            )
        ])
        let summary = try InputEventQueries.resolveLinks(db: db, nowMs: 100_000)

        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: ids[0]))
        XCTAssertTrue(stored.redacted)
        XCTAssertNil(stored.windowTitle)
        XCTAssertNil(stored.axTarget)
        XCTAssertEqual(stored.bundleID, "com.apple.FaceTime")
        XCTAssertEqual(try InputEventQueries.fetchAXElements(db: db, eventID: ids[0]), [])
        XCTAssertEqual(summary.redacted, 1)
    }

    // MARK: - Foreign keys and retention

    func testDeletingAFrameNullsTheLinkInsteadOfDeletingTheEvent() throws {
        let pre = try insertFrame(createdAt: 9_800)
        let post = try insertFrame(createdAt: 10_600)
        let id = try insertEvent(tsMs: 10_000, endTsMs: 10_050)
        _ = try InputEventQueries.resolveLinks(db: db, nowMs: 100_000)

        try exec("DELETE FROM frame WHERE id IN (\(pre), \(post));")

        let stored = try XCTUnwrap(InputEventQueries.fetch(db: db, id: id))
        XCTAssertNil(stored.preFrameID)
        XCTAssertNil(stored.postFrameID)
        XCTAssertEqual(stored.linkState, .resolved)
    }

    func testRetentionDeletesOldEventsAndTheirAXSnapshots() throws {
        let ids = try InputEventQueries.insertBatch(db: db, events: [
            InputEvent(tsMs: 1_000, kind: .click, axElements: [InputAXElement(role: "AXButton", name: "A", box: [0, 0, 1, 1])]),
            InputEvent(tsMs: 2_000, kind: .click, axElements: [InputAXElement(role: "AXButton", name: "B", box: [0, 0, 1, 1])]),
            InputEvent(tsMs: 9_000, kind: .click, axElements: [InputAXElement(role: "AXButton", name: "C", box: [0, 0, 1, 1])])
        ])

        let deleted = try InputEventQueries.deleteOlderThan(db: db, cutoffMs: 5_000)

        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM input_event;"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM input_event_ax;"), 1, "AX rows cascade with their event")
        XCTAssertEqual(try InputEventQueries.fetchAXElements(db: db, eventID: ids[2]).first?.name, "C")
    }

    func testRetentionRespectsBatchLimit() throws {
        try InputEventQueries.insertBatch(db: db, events: (1...5).map { InputEvent(tsMs: Int64($0) * 100, kind: .click) })
        XCTAssertEqual(try InputEventQueries.deleteOlderThan(db: db, cutoffMs: 10_000, limit: 3), 3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM input_event;"), 2)
    }

    // MARK: - Export frame facts

    func testExportFrameInfoReportsRedactionRewriteVideoAndHiddenTag() throws {
        try exec("INSERT INTO video (height, width, path, frameRate, processingState) VALUES (1601, 2560, 'chunks/202610/24/1761343339123', 0.5, 0);")
        let videoID = sqlite3_last_insert_rowid(db)

        let clean = try insertFrame(createdAt: 1_000, displayID: 7)
        try exec("UPDATE frame SET videoId = \(videoID), videoFrameIndex = 12, processingStatus = 2, encodedAt = 1_050 WHERE id = \(clean);".replacingOccurrences(of: "1_050", with: "1050"))

        let redacted = try insertFrame(createdAt: 2_000)
        try exec("UPDATE frame SET redactionReason = 'Excluded app: FaceTime', rewritePurpose = 'redaction', rewrittenAt = 2500 WHERE id = \(redacted);")

        // Hide the segment of a third frame via the built-in tag.
        try exec("INSERT INTO segment (bundleID, startDate, endDate, windowName, browserUrl, type) VALUES ('com.hidden.app', 0, 0, 'Secret', 'https://bank.example/login', 0);")
        let hiddenSegment = sqlite3_last_insert_rowid(db)
        try exec("INSERT INTO frame (createdAt, imageFileName, segmentId, videoFrameIndex, isStarred, processingStatus) VALUES (3000, 'f', \(hiddenSegment), 0, 0, 2);")
        let hiddenFrame = sqlite3_last_insert_rowid(db)
        try exec("INSERT INTO segment_tag (segmentId, tagId) SELECT \(hiddenSegment), id FROM tag WHERE name = 'hidden';")

        let info = try InputEventQueries.exportFrameInfo(db: db, frameIDs: [clean, redacted, hiddenFrame, 999_999_999])

        XCTAssertEqual(info.count, 3, "ids that do not exist are simply absent")
        let cleanInfo = try XCTUnwrap(info[clean])
        XCTAssertEqual(cleanInfo.createdAtMs, 1_000)
        XCTAssertEqual(cleanInfo.displayID, 7)
        XCTAssertEqual(cleanInfo.processingStatus, 2)
        XCTAssertEqual(cleanInfo.encodedAtMs, 1_050)
        XCTAssertEqual(cleanInfo.videoPath, "chunks/202610/24/1761343339123")
        XCTAssertEqual(cleanInfo.videoFrameIndex, 12)
        XCTAssertEqual(cleanInfo.videoFrameRate, 0.5)
        XCTAssertEqual(cleanInfo.videoWidth, 2560)
        XCTAssertEqual(cleanInfo.videoProcessingState, 0)
        XCTAssertEqual(cleanInfo.bundleID, "com.test.app")
        XCTAssertFalse(cleanInfo.isHidden)
        XCTAssertNil(cleanInfo.redactionReason)

        let redactedInfo = try XCTUnwrap(info[redacted])
        XCTAssertEqual(redactedInfo.redactionReason, "Excluded app: FaceTime")
        XCTAssertEqual(redactedInfo.rewritePurpose, "redaction")
        XCTAssertEqual(redactedInfo.rewrittenAtMs, 2500)
        XCTAssertNil(redactedInfo.videoPath, "no video row linked yet")

        let hiddenInfo = try XCTUnwrap(info[hiddenFrame])
        XCTAssertTrue(hiddenInfo.isHidden)
        XCTAssertEqual(hiddenInfo.windowName, "Secret")
        XCTAssertEqual(hiddenInfo.browserURL, "https://bank.example/login")
    }

    func testExportFrameInfoHandlesMoreIdsThanOneStatementCanBind() throws {
        let ids = try (0..<450).map { try insertFrame(createdAt: Int64($0)) }
        let info = try InputEventQueries.exportFrameInfo(db: db, frameIDs: ids)
        XCTAssertEqual(info.count, 450)
    }

    // MARK: - Helpers

    @discardableResult
    private func insertEvent(
        tsMs: Int64,
        endTsMs: Int64?,
        downFrameTsMs: Int64? = nil,
        displayID: UInt32? = nil
    ) throws -> Int64 {
        let ids = try InputEventQueries.insertBatch(db: db, events: [
            InputEvent(
                tsMs: tsMs, endTsMs: endTsMs, kind: .click, button: "left", clickCount: 1,
                x: 10, y: 10, displayID: displayID, downFrameTsMs: downFrameTsMs
            )
        ])
        return ids[0]
    }

    private func insertSegment() throws -> Int64 {
        try exec("""
            INSERT INTO segment (bundleID, startDate, endDate, windowName, browserUrl, type)
            VALUES ('com.test.app', 0, 0, NULL, NULL, 0);
            """)
        return sqlite3_last_insert_rowid(db)
    }

    private func insertFrame(createdAt: Int64, displayID: UInt32? = nil) throws -> Int64 {
        let display = displayID.map(String.init) ?? "NULL"
        try exec("""
            INSERT INTO frame (createdAt, imageFileName, segmentId, videoFrameIndex, isStarred, processingStatus, displayId)
            VALUES (\(createdAt), 'f', \(segmentID), 0, 0, 0, \(display));
            """)
        return sqlite3_last_insert_rowid(db)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw NSError(domain: "InputEventTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func scalar(_ sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "InputEventTests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func exists(type: String, name: String) throws -> Bool {
        (try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = '\(type)' AND name = '\(name)';") ?? 0) > 0
    }

    private func columnCount(table: String, column: String) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else { return 0 }
        var count = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            if sqlite3_column_text(statement, 1).map({ String(cString: $0) }) == column { count += 1 }
        }
        return count
    }
}
