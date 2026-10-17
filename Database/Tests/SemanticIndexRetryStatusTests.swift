import XCTest
import Foundation
import SQLCipher
@testable import Database

/// Real on-disk SQLite through the real `MigrationRunner` chain (so V23 is exercised too).
///
/// Covers the two deep-indexing fixes that need a database to be meaningful:
///  1. A failed/unparsed attempt must return a frame that already has a baseline description to status 5, not 0.
///     Status 0 sends the frame back through the on-device baseline stage and rewrites its baseline row — it
///     happened for every frame of every failed request (≈43% of requests).
///  2. V23 telemetry columns exist, are idempotent, and round-trip through the query layer.
final class SemanticIndexRetryStatusTests: XCTestCase {
    private var path = ""
    private var db: OpaquePointer!

    override func setUp() async throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("SemanticRetry-\(UUID().uuidString).sqlite").path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        db = handle
        try exec("PRAGMA journal_mode = WAL;")
        try await MigrationRunner(db: db).runMigrations()
        try exec("PRAGMA foreign_keys = OFF;")   // seed frames without building segment/video rows
    }

    override func tearDown() async throws {
        sqlite3_close(db)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func testTransientRetryRestoresBaselineStatusOnlyForFramesThatHaveABaseline() throws {
        try seedFrame(id: 1, status: 1, retry: 0, hasBaseline: true)
        try seedFrame(id: 2, status: 1, retry: 0, hasBaseline: false)
        try SemanticIndexQueries.markTransientRetry(db: db, frameIDs: [1, 2])
        XCTAssertEqual(try status(of: 1), 5, "baseline description present -> back to baseline-only, not re-baselined")
        XCTAssertEqual(try status(of: 2), 0, "no baseline row -> pending")
        XCTAssertEqual(try retryCount(of: 1), 0, "a transient failure never spends a retry attempt")
    }

    func testRetryPendingStrikesAndRestoresBaselineStatusUntilTheThirdStrike() throws {
        try seedFrame(id: 1, status: 5, retry: 0, hasBaseline: true)
        try seedFrame(id: 2, status: 0, retry: 0, hasBaseline: false)
        try SemanticIndexQueries.markRetryPending(db: db, frameIDs: [1, 2])
        XCTAssertEqual(try status(of: 1), 5); XCTAssertEqual(try retryCount(of: 1), 1)
        XCTAssertEqual(try status(of: 2), 0); XCTAssertEqual(try retryCount(of: 2), 1)
        try SemanticIndexQueries.markRetryPending(db: db, frameIDs: [1, 2])
        try SemanticIndexQueries.markRetryPending(db: db, frameIDs: [1, 2])
        XCTAssertEqual(try status(of: 1), 8, "third strike is permanent failure even with a baseline")
        XCTAssertEqual(try status(of: 2), 8)
    }

    func testRestoredFramesAreStillSelectedForDeepIndexing() throws {
        try seedFrame(id: 1, status: 1, retry: 0, hasBaseline: true, encoded: true)
        try SemanticIndexQueries.markTransientRetry(db: db, frameIDs: [1])
        let pending = try SemanticIndexQueries.selectPending(db: db, limit: 10, freshCutoffMs: 0)
        XCTAssertEqual(pending.map(\.frameID), [1])
    }

    func testPendingSelectionCarriesTheSegmentID() throws {
        try seedFrame(id: 1, status: 5, retry: 0, hasBaseline: true, encoded: true)
        XCTAssertEqual(try SemanticIndexQueries.selectPending(db: db, limit: 10, freshCutoffMs: 0).map(\.segmentID), [1])
    }

    /// Description propagation to a near-identical run writes one description to several frames. Each must end
    /// up with its own FTS row so retention deleting one frame cannot remove a sibling's searchable description.
    func testPropagatedDescriptionsGetOwnRowsAndSurviveSiblingDeletion() throws {
        try seedFrame(id: 1, status: 5, retry: 0, hasBaseline: true, encoded: true)   // representative
        try seedFrame(id: 2, status: 5, retry: 0, hasBaseline: true, encoded: true)   // sibling that had a baseline
        try seedFrame(id: 3, status: 0, retry: 0, hasBaseline: false, encoded: true)  // sibling without one
        for id: Int64 in [1, 2, 3] {
            try SemanticIndexQueries.writeDescription(db: db, frameID: id, description: "Settings window with component toggles", indexedAtMs: 9_000)
        }
        for id: Int64 in [1, 2, 3] { XCTAssertEqual(try status(of: id), 2) }
        XCTAssertEqual(try scalarText("SELECT COUNT(DISTINCT docid) FROM semantic_doc_frame;"), "3", "one FTS row per frame")
        XCTAssertEqual(try scalarText("SELECT COUNT(*) FROM semanticRanking WHERE semanticRanking MATCH 'toggles';"), "3", "baseline text was replaced, not duplicated")

        try SemanticIndexQueries.deleteDescriptions(db: db, frameIDs: [2])
        XCTAssertEqual(try scalarText("SELECT COUNT(*) FROM semanticRanking WHERE semanticRanking MATCH 'toggles';"), "2")
        XCTAssertEqual(try scalarText("SELECT COUNT(*) FROM semantic_doc_frame WHERE frameId IN (1, 3);"), "2")
    }

    func testV23AddsTelemetryColumnsAndRoundTripsThem() throws {
        for column in ["bodyBytes", "promptTokens", "completionTokens", "finishReason", "latencyMs", "parsedCount", "contentEmpty", "batchTarget", "arm", "errorKind"] {
            XCTAssertTrue(try columnExists("semantic_index_requests", column), column)
        }
        let row = try SemanticIndexQueries.recordDispatch(db: db, frameIDs: [1, 2, 3], lane: "backfill", requestedAtMs: 1_000, batchTarget: 8, arm: "ramp")
        try SemanticIndexQueries.updateRequestOutcome(db: db, requestRowID: row, status: "success", httpStatus: 200, errorMessage: nil)
        try SemanticIndexQueries.updateRequestTelemetry(
            db: db, requestRowID: row,
            telemetry: .init(bodyBytes: 910_000, promptTokens: 4_200, completionTokens: 380, finishReason: "stop", latencyMs: 16_400, parsedCount: 3, contentEmpty: false)
        )
        XCTAssertEqual(try scalarText("SELECT arm || ':' || batchTarget || ':' || finishReason || ':' || bodyBytes || ':' || parsedCount FROM semantic_index_requests WHERE id = \(row);"), "ramp:8:stop:910000:3")
        // Search-lane callers use the original signature and leave the new columns NULL.
        let search = try SemanticIndexQueries.recordDispatch(db: db, frameIDs: [9], lane: "search", requestedAtMs: 2_000)
        XCTAssertEqual(try scalarText("SELECT COALESCE(arm, 'null') FROM semantic_index_requests WHERE id = \(search);"), "null")
    }

    func testCompletionsCountExcludesFailuresAndSearchLane() throws {
        func add(_ lane: String, _ status: String) throws {
            let id = try SemanticIndexQueries.recordDispatch(db: db, frameIDs: [1], lane: lane, requestedAtMs: 5_000)
            try SemanticIndexQueries.updateRequestOutcome(db: db, requestRowID: id, status: status, httpStatus: nil, errorMessage: nil)
        }
        try add("backfill", "success"); try add("fresh", "partial"); try add("backfill", "failed"); try add("search", "success")
        XCTAssertEqual(try SemanticIndexQueries.countVisualIndexingCompletionsToday(db: db, utcDayStartMs: 0), 2)
        XCTAssertEqual(try SemanticIndexQueries.countVisualIndexingRequestsToday(db: db, utcDayStartMs: 0), 3, "attempts still count failures")
    }

    // MARK: - Helpers

    private func seedFrame(id: Int64, status: Int, retry: Int, hasBaseline: Bool, encoded: Bool = false) throws {
        try exec("INSERT OR IGNORE INTO segment (id, bundleID, startDate, endDate, type) VALUES (1, 'com.example.app', 0, 0, 0);")
        try exec("""
            INSERT INTO frame (id, createdAt, imageFileName, segmentId, semanticStatus, semanticRetryCount, encodedAt)
            VALUES (\(id), \(1_000 + id), 'f\(id)', 1, \(status), \(retry), \(encoded ? "1" : "NULL"));
            """)
        if hasBaseline {
            try exec("INSERT INTO semanticRanking (rowid, description) VALUES (\(id), 'baseline');")
            try exec("INSERT INTO semantic_doc_frame (docid, frameId, createdAt) VALUES (\(id), \(id), 1);")
        }
    }

    private func status(of id: Int64) throws -> Int { Int(try scalarText("SELECT semanticStatus FROM frame WHERE id = \(id);")) ?? -1 }
    private func retryCount(of id: Int64) throws -> Int { Int(try scalarText("SELECT semanticRetryCount FROM frame WHERE id = \(id);")) ?? -1 }

    private func columnExists(_ table: String, _ column: String) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil), SQLITE_OK)
        while sqlite3_step(statement) == SQLITE_ROW {
            if sqlite3_column_text(statement, 1).map({ String(cString: $0) }) == column { return true }
        }
        return false
    }

    private func scalarText(_ sql: String) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SemanticIndexRetryStatusTests", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: text)
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(message) }
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            throw NSError(domain: "SemanticIndexRetryStatusTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? "sql error"])
        }
    }
}
