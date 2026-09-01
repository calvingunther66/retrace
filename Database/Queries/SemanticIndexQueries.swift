import Foundation
import SQLCipher
import Shared

/// Raw SQL operations backing `SemanticIndexer` (AI visual semantic indexing).
/// Mirrors the style of `FTSQueries`/`FrameQueries`: static functions taking a raw
/// `OpaquePointer` connection, called from `DatabaseManager` wrapper methods.
public enum SemanticIndexQueries {

    public struct PendingFrame: Sendable {
        public let frameID: Int64
        public let videoID: Int64
        public let frameIndexInSegment: Int
        public let createdAtMs: Int64
        public let bundleID: String?
        public let windowName: String?
        public let browserUrl: String?

        public init(
            frameID: Int64,
            videoID: Int64,
            frameIndexInSegment: Int,
            createdAtMs: Int64,
            bundleID: String?,
            windowName: String? = nil,
            browserUrl: String? = nil
        ) {
            self.frameID = frameID
            self.videoID = videoID
            self.frameIndexInSegment = frameIndexInSegment
            self.createdAtMs = createdAtMs
            self.bundleID = bundleID
            self.windowName = windowName
            self.browserUrl = browserUrl
        }
    }

    // MARK: - Selection

    /// Selects up to `limit` pending/retryable frames, fresh (recently captured) frames first,
    /// newest-first within each lane (deliberate recency bias for a memory tool: when the daily
    /// backfill budget runs out mid-lane, we'd rather have indexed the screens closest to "now"
    /// than the oldest ones in the backlog). Excludes non-finalized (WAL-only) and redacted frames.
    public static func selectPending(
        db: OpaquePointer,
        limit: Int,
        freshCutoffMs: Int64
    ) throws -> [PendingFrame] {
        let sql = """
            SELECT f.id, f.videoId, f.videoFrameIndex, f.createdAt, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            JOIN segment s ON f.segmentId = s.id
            WHERE f.semanticStatus IN (0, 3, 5)
              AND f.encodedAt IS NOT NULL
              AND f.redactionReason IS NULL
              AND f.semanticRetryCount < 3
            ORDER BY
              CASE WHEN f.semanticStatus = 0 THEN 0 WHEN f.semanticStatus = 5 THEN 1 ELSE 2 END ASC,
              CASE WHEN f.createdAt >= ? THEN 0 ELSE 1 END ASC,
              f.semanticRetryCount ASC,
              f.createdAt DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, freshCutoffMs)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [PendingFrame] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameID = sqlite3_column_int64(statement, 0)
            let videoID = sqlite3_column_int64(statement, 1)
            let frameIndex = Int(sqlite3_column_int64(statement, 2))
            let createdAt = sqlite3_column_int64(statement, 3)
            let bundleID = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let windowName = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let browserUrl = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            results.append(PendingFrame(
                frameID: frameID,
                videoID: videoID,
                frameIndexInSegment: frameIndex,
                createdAtMs: createdAt,
                bundleID: bundleID,
                windowName: windowName,
                browserUrl: browserUrl
            ))
        }
        return results
    }

    /// Selects newly OCR'd frames (semanticStatus = 0) for Stage 1 fast on-device baseline indexing.
    public static func selectPendingBaseline(
        db: OpaquePointer,
        limit: Int
    ) throws -> [PendingFrame] {
        let sql = """
            SELECT f.id, f.videoId, f.videoFrameIndex, f.createdAt, s.bundleID, s.windowName, s.browserUrl
            FROM frame f
            JOIN segment s ON f.segmentId = s.id
            WHERE f.semanticStatus = 0
              AND f.encodedAt IS NOT NULL
              AND f.redactionReason IS NULL
            ORDER BY f.createdAt DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var results: [PendingFrame] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameID = sqlite3_column_int64(statement, 0)
            let videoID = sqlite3_column_int64(statement, 1)
            let frameIndex = Int(sqlite3_column_int64(statement, 2))
            let createdAt = sqlite3_column_int64(statement, 3)
            let bundleID = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let windowName = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let browserUrl = sqlite3_column_text(statement, 6).map { String(cString: $0) }
            results.append(PendingFrame(
                frameID: frameID,
                videoID: videoID,
                frameIndexInSegment: frameIndex,
                createdAtMs: createdAt,
                bundleID: bundleID,
                windowName: windowName,
                browserUrl: browserUrl
            ))
        }
        return results
    }

    // MARK: - Status updates

    public static func markSkipped(db: OpaquePointer, frameIDs: [Int64]) throws {
        try updateStatus(db: db, frameIDs: frameIDs, status: 4, incrementRetry: false)
    }

    /// Marks frames failed. When `permanently` is false, mirrors `markRetryPending`'s retry-cap
    /// guard: without it, a frame that fails 3 times sits at status 3 with
    /// `semanticRetryCount >= 3` forever — excluded by `selectPending`'s `semanticRetryCount < 3`
    /// filter, so it's never retried AND never surfaces as failed. Silent, permanent limbo.
    public static func markFailed(db: OpaquePointer, frameIDs: [Int64], permanently: Bool) throws {
        guard !frameIDs.isEmpty else { return }
        if permanently {
            try updateStatus(db: db, frameIDs: frameIDs, status: 8, incrementRetry: true)
            return
        }

        let placeholders = frameIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            UPDATE frame
            SET semanticRetryCount = semanticRetryCount + 1,
                semanticStatus = CASE WHEN semanticRetryCount + 1 >= 3 THEN 8 ELSE 3 END
            WHERE id IN (\(placeholders));
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        for (offset, frameID) in frameIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(1 + offset), frameID)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Resets frames back to pending WITHOUT incrementing the retry counter — for lane/API-wide
    /// transient failures (429 rate limits, 5xx, transport errors) that say nothing about
    /// whether these particular frames are processable. Using `markFailed` here would burn
    /// through the 3-attempt cap on failures that have nothing to do with the frame itself,
    /// permanently stranding frames that just had the bad luck to be in-flight during a blip.
    public static func markTransientRetry(db: OpaquePointer, frameIDs: [Int64]) throws {
        try updateStatus(db: db, frameIDs: frameIDs, status: 0, incrementRetry: false)
    }

    /// Resets a frame back to pending (e.g. an unparsed image in an otherwise-successful batch)
    /// UNLESS this exhausts the retry cap, in which case it's marked permanently failed (8)
    /// instead. Without this, a frame that keeps failing to parse would sit at status 0 with
    /// `semanticRetryCount >= 3` forever — invisible to the `semanticRetryCount < 3` selection
    /// filter, so it's never retried AND never counted as failed. Silent, permanent limbo.
    public static func markRetryPending(db: OpaquePointer, frameIDs: [Int64]) throws {
        guard !frameIDs.isEmpty else { return }
        let placeholders = frameIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            UPDATE frame
            SET semanticRetryCount = semanticRetryCount + 1,
                semanticStatus = CASE WHEN semanticRetryCount + 1 >= 3 THEN 8 ELSE 0 END
            WHERE id IN (\(placeholders));
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        for (offset, frameID) in frameIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(1 + offset), frameID)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func updateStatus(
        db: OpaquePointer,
        frameIDs: [Int64],
        status: Int,
        incrementRetry: Bool
    ) throws {
        guard !frameIDs.isEmpty else { return }
        let placeholders = frameIDs.map { _ in "?" }.joined(separator: ",")
        let retryClause = incrementRetry ? ", semanticRetryCount = semanticRetryCount + 1" : ""
        let sql = "UPDATE frame SET semanticStatus = ?\(retryClause) WHERE id IN (\(placeholders));"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int(statement, 1, Int32(status))
        for (offset, frameID) in frameIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(2 + offset), frameID)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Writes a completed description: inserts into `semanticRanking` (FTS5), links it via
    /// `semantic_doc_frame`, and marks the frame completed. Deletes any prior description first
    /// (idempotent re-index, e.g. after a manual reprocess).
    ///
    /// Wrapped in a transaction (matching `MigrationRunner`'s pattern) — this is 4 sequential
    /// statements, and a mid-sequence failure (WAL busy, disk full) without a rollback path
    /// would otherwise be able to leave an orphaned `semanticRanking` row (invisible to search,
    /// permanently un-reclaimable since `deleteDescriptions` finds rows via the very link table
    /// that failed to insert) or a frame that's searchable but stuck at a non-completed status
    /// (re-selected and re-billed against the daily budget forever).
    public static func writeDescription(
        db: OpaquePointer,
        frameID: Int64,
        description: String,
        indexedAtMs: Int64
    ) throws {
        try execute(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;", int64Params: [])
        do {
            try writeDescriptionUnguarded(db: db, frameID: frameID, description: description, indexedAtMs: indexedAtMs)
            try execute(db: db, sql: "COMMIT;", int64Params: [])
        } catch {
            try? execute(db: db, sql: "ROLLBACK;", int64Params: [])
            throw error
        }
    }

    private static func writeDescriptionUnguarded(
        db: OpaquePointer,
        frameID: Int64,
        description: String,
        indexedAtMs: Int64
    ) throws {
        try deleteDescriptions(db: db, frameIDs: [frameID])

        let insertSQL = "INSERT INTO semanticRanking (description) VALUES (?);"
        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }

        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: insertSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(insertStatement, 1, description, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(insertStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: insertSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        let docid = sqlite3_last_insert_rowid(db)

        let linkSQL = "INSERT INTO semantic_doc_frame (docid, frameId, createdAt) VALUES (?, ?, ?);"
        var linkStatement: OpaquePointer?
        defer { sqlite3_finalize(linkStatement) }

        guard sqlite3_prepare_v2(db, linkSQL, -1, &linkStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: linkSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(linkStatement, 1, docid)
        sqlite3_bind_int64(linkStatement, 2, frameID)
        sqlite3_bind_int64(linkStatement, 3, indexedAtMs)

        guard sqlite3_step(linkStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: linkSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let updateSQL = "UPDATE frame SET semanticStatus = 2, semanticIndexedAt = ? WHERE id = ?;"
        var updateStatement: OpaquePointer?
        defer { sqlite3_finalize(updateStatement) }

        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: updateSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(updateStatement, 1, indexedAtMs)
        sqlite3_bind_int64(updateStatement, 2, frameID)

        guard sqlite3_step(updateStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: updateSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Writes a Stage 1 baseline description (from on-device Apple Foundation Models):
    /// inserts into `semanticRanking` (FTS5), links via `semantic_doc_frame`, and marks the frame
    /// with `semanticStatus = 5` (Baseline Indexed), keeping it eligible for Stage 2 deep visual upgrade.
    public static func writeBaselineDescription(
        db: OpaquePointer,
        frameID: Int64,
        description: String,
        indexedAtMs: Int64
    ) throws {
        try execute(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;", int64Params: [])
        do {
            try writeBaselineDescriptionUnguarded(db: db, frameID: frameID, description: description, indexedAtMs: indexedAtMs)
            try execute(db: db, sql: "COMMIT;", int64Params: [])
        } catch {
            try? execute(db: db, sql: "ROLLBACK;", int64Params: [])
            throw error
        }
    }

    private static func writeBaselineDescriptionUnguarded(
        db: OpaquePointer,
        frameID: Int64,
        description: String,
        indexedAtMs: Int64
    ) throws {
        try deleteDescriptions(db: db, frameIDs: [frameID])

        let insertSQL = "INSERT INTO semanticRanking (description) VALUES (?);"
        var insertStatement: OpaquePointer?
        defer { sqlite3_finalize(insertStatement) }

        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: insertSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(insertStatement, 1, description, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(insertStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: insertSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        let docid = sqlite3_last_insert_rowid(db)

        let linkSQL = "INSERT INTO semantic_doc_frame (docid, frameId, createdAt) VALUES (?, ?, ?);"
        var linkStatement: OpaquePointer?
        defer { sqlite3_finalize(linkStatement) }

        guard sqlite3_prepare_v2(db, linkSQL, -1, &linkStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: linkSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(linkStatement, 1, docid)
        sqlite3_bind_int64(linkStatement, 2, frameID)
        sqlite3_bind_int64(linkStatement, 3, indexedAtMs)

        guard sqlite3_step(linkStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: linkSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let updateSQL = "UPDATE frame SET semanticStatus = 5, semanticIndexedAt = ? WHERE id = ?;"
        var updateStatement: OpaquePointer?
        defer { sqlite3_finalize(updateStatement) }

        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: updateSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(updateStatement, 1, indexedAtMs)
        sqlite3_bind_int64(updateStatement, 2, frameID)

        guard sqlite3_step(updateStatement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: updateSQL, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Retrieves extracted OCR text for a frame (from `searchRanking_content` via `doc_segment`).
    public static func getOCRTextForFrame(
        db: OpaquePointer,
        frameID: Int64
    ) throws -> (mainText: String, chromeText: String?, title: String?)? {
        let sql = """
            SELECT sc.c0, sc.c1, sc.c2
            FROM doc_segment ds
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE ds.frameId = ?;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, frameID)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        let mainText = getTextOrEmpty(statement, 0)
        let chromeText = getTextOrNil(statement, 1)
        let title = getTextOrNil(statement, 2)
        return (mainText: mainText, chromeText: chromeText, title: title)
    }

    /// Deletes semantic descriptions for the given frames (retention cleanup, or reprocess-before-rewrite).
    public static func deleteDescriptions(db: OpaquePointer, frameIDs: [Int64]) throws {
        guard !frameIDs.isEmpty else { return }
        let placeholders = frameIDs.map { _ in "?" }.joined(separator: ",")

        let deleteRankingSQL = """
            DELETE FROM semanticRanking WHERE rowid IN (
                SELECT docid FROM semantic_doc_frame WHERE frameId IN (\(placeholders))
            );
            """
        try execute(db: db, sql: deleteRankingSQL, int64Params: frameIDs)

        let deleteLinkSQL = "DELETE FROM semantic_doc_frame WHERE frameId IN (\(placeholders));"
        try execute(db: db, sql: deleteLinkSQL, int64Params: frameIDs)
    }

    // MARK: - Budget tracking

    public static func recordDispatch(
        db: OpaquePointer,
        frameIDs: [Int64],
        lane: String,
        requestedAtMs: Int64
    ) throws -> Int64 {
        let sql = """
            INSERT INTO semantic_index_requests (requestedAt, frameIds, frameCount, lane, status)
            VALUES (?, ?, ?, ?, 'dispatched');
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let frameIdsJSON = "[\(frameIDs.map(String.init).joined(separator: ","))]"

        sqlite3_bind_int64(statement, 1, requestedAtMs)
        sqlite3_bind_text(statement, 2, frameIdsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 3, Int32(frameIDs.count))
        sqlite3_bind_text(statement, 4, lane, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    public static func updateRequestOutcome(
        db: OpaquePointer,
        requestRowID: Int64,
        status: String,
        httpStatus: Int?,
        errorMessage: String?
    ) throws {
        let sql = "UPDATE semantic_index_requests SET status = ?, httpStatus = ?, errorMessage = ? WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, status, -1, SQLITE_TRANSIENT)
        if let httpStatus {
            sqlite3_bind_int(statement, 2, Int32(httpStatus))
        } else {
            sqlite3_bind_null(statement, 2)
        }
        bindTextOrNull(statement, 3, errorMessage)
        sqlite3_bind_int64(statement, 4, requestRowID)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Counts requests in the backfill lane today (legacy compatibility).
    public static func countBackfillRequestsToday(db: OpaquePointer, utcDayStartMs: Int64) throws -> Int {
        let sql = "SELECT COUNT(*) FROM semantic_index_requests WHERE requestedAt >= ? AND lane = 'backfill' AND status != 'cancelled';"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, utcDayStartMs)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: "No result row")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Counts TOTAL non-cancelled semantic index requests dispatched today across ALL lanes.
    /// Used to enforce the daily 600-request quota and prevent API exhaustion.
    public static func countTotalRequestsToday(db: OpaquePointer, utcDayStartMs: Int64) throws -> Int {
        let sql = "SELECT COUNT(*) FROM semantic_index_requests WHERE requestedAt >= ? AND status != 'cancelled';"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, utcDayStartMs)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: "No result row")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Recovery & Maintenance

    /// Resets frames stuck in status 1 (in-flight) or 3 (retryable error) back to status 0 (pending)
    /// and resets their retry count to 0 so they can be re-indexed immediately.
    /// If `includePermanentlyFailed` is true, status 8 frames are also reset.
    public static func resetStalledAndFailedFrames(
        db: OpaquePointer,
        includePermanentlyFailed: Bool = false
    ) throws -> Int {
        let statusClause = includePermanentlyFailed ? "1, 3, 8" : "1, 3"
        let sql = """
            UPDATE frame
            SET semanticStatus = 0,
                semanticRetryCount = 0
            WHERE semanticStatus IN (\(statusClause));
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    /// Marks any orphaned `semantic_index_requests` rows in 'dispatched' status as 'cancelled'.
    public static func cleanDanglingDispatchedRequests(db: OpaquePointer) throws -> Int {
        let sql = """
            UPDATE semantic_index_requests
            SET status = 'cancelled',
                errorMessage = 'Interrupted / reset'
            WHERE status = 'dispatched';
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: - Progress reporting

    /// Total indexed frames (both Stage 1 baseline and Stage 2 deep visual).
    public static func countIndexed(db: OpaquePointer) throws -> Int {
        try scalarCount(db: db, sql: "SELECT COUNT(*) FROM frame WHERE semanticStatus IN (2, 5);")
    }

    /// Frames with deep Stage 2 visual descriptions.
    public static func countDeepIndexed(db: OpaquePointer) throws -> Int {
        try scalarCount(db: db, sql: "SELECT COUNT(*) FROM frame WHERE semanticStatus = 2;")
    }

    /// Frames with Stage 1 baseline descriptions.
    public static func countBaselineIndexed(db: OpaquePointer) throws -> Int {
        try scalarCount(db: db, sql: "SELECT COUNT(*) FROM frame WHERE semanticStatus = 5;")
    }

    public static func countFailed(db: OpaquePointer) throws -> Int {
        try scalarCount(db: db, sql: "SELECT COUNT(*) FROM frame WHERE semanticStatus IN (3, 8);")
    }

    public static func countPending(db: OpaquePointer) throws -> Int {
        try scalarCount(
            db: db,
            sql: "SELECT COUNT(*) FROM frame WHERE semanticStatus = 0 AND encodedAt IS NOT NULL AND redactionReason IS NULL;"
        )
    }

    public static func countEligibleTotal(db: OpaquePointer) throws -> Int {
        try scalarCount(
            db: db,
            sql: "SELECT COUNT(*) FROM frame WHERE encodedAt IS NOT NULL AND redactionReason IS NULL;"
        )
    }

    private static func scalarCount(db: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: "No result row")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Helpers

    private static func execute(db: OpaquePointer, sql: String, int64Params: [Int64]) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in int64Params.enumerated() {
            sqlite3_bind_int64(statement, Int32(1 + offset), value)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func bindTextOrNull(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func getTextOrEmpty(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private static func getTextOrNil(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}
