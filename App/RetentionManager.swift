import Foundation
import Shared
import Database
import Storage
import Search

/// SQLITE_TRANSIENT constant - tells SQLite to make its own copy of the string
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Manages data retention policy enforcement
/// Periodically cleans up old frames, video segments, and related data based on user settings
/// Owner: APP integration
public actor RetentionManager {

    // MARK: - Properties

    private let database: DatabaseManager
    private let storage: StorageManager
    private let search: SearchManager

    private var cleanupTask: Task<Void, Never>?
    private var isRunning = false

    /// Interval between cleanup checks (default: 1 hour)
    private let cleanupInterval: TimeInterval = 3600

    /// Last cleanup timestamp for rate limiting
    private var lastCleanupTime: Date?

    /// Minimum interval between cleanups (10 minutes)
    private let minimumCleanupInterval: TimeInterval = 600

    // MARK: - Initialization

    public init(
        database: DatabaseManager,
        storage: StorageManager,
        search: SearchManager
    ) {
        self.database = database
        self.storage = storage
        self.search = search
    }

    // MARK: - Lifecycle

    /// Start the retention manager (runs cleanup periodically)
    public func start() async {
        guard !isRunning else {
            Log.warning("[RetentionManager] Already running", category: .app)
            return
        }

        isRunning = true
        Log.info("[RetentionManager] Started", category: .app)

        // Start periodic cleanup task (runs in background, doesn't block startup)
        cleanupTask = Task {
            // Run initial cleanup after a short delay to not block app startup
            try? await Task.sleep(for: .nanoseconds(Int64(5_000_000_000)), clock: .continuous) // 5 second delay

            if Task.isCancelled { return }
            await runCleanupIfNeeded()

            while !Task.isCancelled {
                // Wait for cleanup interval
                try? await Task.sleep(for: .seconds(cleanupInterval), clock: .continuous)

                if Task.isCancelled { break }

                await runCleanupIfNeeded()
            }
        }
    }

    /// Stop the retention manager
    public func stop() async {
        guard isRunning else { return }

        cleanupTask?.cancel()
        cleanupTask = nil
        isRunning = false

        Log.info("[RetentionManager] Stopped", category: .app)
    }

    // MARK: - Cleanup Logic

    /// Get the current retention policy from user settings
    /// Returns nil if retention is set to "Forever" (0 days)
    public nonisolated func getRetentionDays() -> Int? {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let days = defaults.integer(forKey: "retentionDays")
        return days == 0 ? nil : days
    }

    /// Calculate the cutoff date based on retention settings
    /// Returns nil if retention is set to "Forever"
    public nonisolated func getCutoffDate() -> Date? {
        DatabaseConfig.cutoffDate(retentionDays: getRetentionDays())
    }

    /// Get apps excluded from retention cleanup (data from these apps won't be deleted)
    /// NOTE: Exclusions are disabled - everything older than retention window gets deleted
    public nonisolated func getExcludedApps() -> Set<String> {
        // Exclusions disabled - always return empty set
        return []
        // Original code (commented out):
        // let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        // guard let appsString = defaults.string(forKey: "retentionExcludedApps"), !appsString.isEmpty else {
        //     return []
        // }
        // return Set(appsString.split(separator: ",").map { String($0) })
    }

    /// Get tag IDs excluded from retention cleanup (data with these tags won't be deleted)
    /// NOTE: Exclusions are disabled - everything older than retention window gets deleted
    public nonisolated func getExcludedTagIds() -> Set<Int64> {
        // Exclusions disabled - always return empty set
        return []
        // Original code (commented out):
        // let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        // guard let tagsString = defaults.string(forKey: "retentionExcludedTagIds"), !tagsString.isEmpty else {
        //     return []
        // }
        // return Set(tagsString.split(separator: ",").compactMap { Int64($0) })
    }

    /// Check if hidden items should be excluded from retention cleanup
    /// NOTE: Exclusions are disabled - everything older than retention window gets deleted (including hidden)
    public nonisolated func shouldExcludeHidden() -> Bool {
        // Exclusions disabled - never exclude hidden items
        return false
        // Original code (commented out):
        // let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        // return defaults.bool(forKey: "retentionExcludeHidden")
    }

    /// Run cleanup if enough time has passed since the last cleanup
    public func runCleanupIfNeeded() async {
        // Check if we've cleaned up recently
        if let lastCleanup = lastCleanupTime {
            let timeSinceLastCleanup = Date().timeIntervalSince(lastCleanup)
            if timeSinceLastCleanup < minimumCleanupInterval {
                Log.debug("[RetentionManager] Skipping cleanup - last cleanup was \(Int(timeSinceLastCleanup))s ago", category: .app)
                return
            }
        }

        await runCleanup()
    }

    /// Run the cleanup process
    @discardableResult
    public func runCleanup() async -> RetentionCleanupResult {
        guard let cutoffDate = getCutoffDate() else {
            Log.debug("[RetentionManager] Retention set to Forever - no cleanup needed", category: .app)
            return RetentionCleanupResult(
                deletedFrames: 0,
                deletedVideoSegments: 0,
                deletedAppSegments: 0,
                reclaimedBytes: 0,
                cutoffDate: nil,
                success: true,
                error: nil
            )
        }

        Log.info("[RetentionManager] Starting cleanup for data older than \(cutoffDate)", category: .app)
        lastCleanupTime = Date()

        // Get exclusions
        let excludedApps = getExcludedApps()
        let excludedTagIds = getExcludedTagIds()
        let excludeHidden = shouldExcludeHidden()

        if !excludedApps.isEmpty {
            Log.info("[RetentionManager] Excluding \(excludedApps.count) apps from cleanup", category: .app)
        }
        if !excludedTagIds.isEmpty {
            Log.info("[RetentionManager] Excluding \(excludedTagIds.count) tags from cleanup", category: .app)
        }
        if excludeHidden {
            Log.info("[RetentionManager] Excluding hidden items from cleanup", category: .app)
        }

        do {
            // Step 1: Get video segments that will be affected (for cleanup)
            let videoSegmentsToDelete = try await getVideoSegmentsOlderThan(cutoffDate, excludingApps: excludedApps, excludingTagIds: excludedTagIds, excludeHidden: excludeHidden)

            // Step 2: Delete frames from database (this cascades to FTS entries via triggers)
            let deletedFrameCount = try await deleteFrames(olderThan: cutoffDate, excludingApps: excludedApps, excludingTagIds: excludedTagIds, excludeHidden: excludeHidden)
            Log.info("[RetentionManager] Deleted \(deletedFrameCount) frames from database", category: .app)

            // Step 3: Delete old app segments (sessions)
            let deletedSegmentCount = try await deleteAppSegmentsOlderThan(cutoffDate, excludingApps: excludedApps, excludingTagIds: excludedTagIds, excludeHidden: excludeHidden)
            Log.info("[RetentionManager] Deleted \(deletedSegmentCount) app segments", category: .app)

            // Step 4: Delete orphaned video segments and their files
            var reclaimedBytes: Int64 = 0
            var deletedVideoCount = 0

            for videoSegment in videoSegmentsToDelete {
                do {
                    // Get file size before deletion
                    let segmentPath = try await storage.getSegmentPath(id: videoSegment)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: segmentPath.path),
                       let size = attrs[.size] as? Int64 {
                        reclaimedBytes += size
                    }

                    // Delete from storage (file)
                    try await storage.deleteSegment(id: videoSegment)

                    // Delete from database
                    try await database.deleteVideoSegment(id: videoSegment)

                    deletedVideoCount += 1
                } catch {
                    Log.warning("[RetentionManager] Failed to delete video segment \(videoSegment.value): \(error)", category: .app)
                }
            }
            Log.info("[RetentionManager] Deleted \(deletedVideoCount) video segments, reclaimed \(formatBytes(reclaimedBytes))", category: .app)

            // Step 5: Clean up orphaned frame-linked rows (OCR nodes + V21
            // cognitive-memory links) for deleted frames
            let deletedNodesCount = try await cleanupOrphanedNodes()
            if deletedNodesCount > 0 {
                Log.info("[RetentionManager] Cleaned up \(deletedNodesCount) orphaned frame-linked rows", category: .app)
            }

            // Step 6: Vacuum database to reclaim space (do this less frequently)
            if deletedFrameCount > DatabaseConfig.retentionVacuumFrameThreshold || deletedVideoCount > DatabaseConfig.retentionVacuumVideoThreshold {
                try await database.vacuum()
                Log.info("[RetentionManager] Database vacuumed", category: .app)
            }

            Log.info("[RetentionManager] Cleanup complete. Frames: \(deletedFrameCount), Videos: \(deletedVideoCount), Segments: \(deletedSegmentCount), Reclaimed: \(formatBytes(reclaimedBytes))", category: .app)

            return RetentionCleanupResult(
                deletedFrames: deletedFrameCount,
                deletedVideoSegments: deletedVideoCount,
                deletedAppSegments: deletedSegmentCount,
                reclaimedBytes: reclaimedBytes,
                cutoffDate: cutoffDate,
                success: true,
                error: nil
            )

        } catch {
            Log.error("[RetentionManager] Cleanup failed: \(error)", category: .app)
            return RetentionCleanupResult(
                deletedFrames: 0,
                deletedVideoSegments: 0,
                deletedAppSegments: 0,
                reclaimedBytes: 0,
                cutoffDate: cutoffDate,
                success: false,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Private Helpers

    /// Get video segments that have no frames newer than the cutoff date, excluding protected segments
    private func getVideoSegmentsOlderThan(_ cutoffDate: Date, excludingApps: Set<String>, excludingTagIds: Set<Int64>, excludeHidden: Bool) async throws -> [VideoSegmentID] {
        // Video segments where all frames are older than cutoff
        // We use the storage cleanup method which checks file modification dates
        // Note: Storage-level cleanup doesn't know about app/tag exclusions, so we filter after
        let candidates = try await storage.cleanupOldSegments(olderThan: cutoffDate)

        // If no exclusions, return all candidates
        if excludingApps.isEmpty && excludingTagIds.isEmpty && !excludeHidden {
            return candidates
        }

        // Filter out segments that belong to excluded apps or have excluded tags
        var filtered: [VideoSegmentID] = []
        for videoSegmentId in candidates {
            let isExcluded = try await isVideoSegmentExcluded(videoSegmentId, excludingApps: excludingApps, excludingTagIds: excludingTagIds, excludeHidden: excludeHidden)
            if !isExcluded {
                filtered.append(videoSegmentId)
            }
        }

        return filtered
    }

    /// Check if a video segment should be excluded from cleanup
    private func isVideoSegmentExcluded(_ videoSegmentId: VideoSegmentID, excludingApps: Set<String>, excludingTagIds: Set<Int64>, excludeHidden: Bool) async throws -> Bool {
        guard let db = await database.getConnection() else {
            throw RetentionError.databaseNotConnected
        }

        // Check if any frame in this video segment belongs to an excluded app
        if !excludingApps.isEmpty {
            let placeholders = excludingApps.map { _ in "?" }.joined(separator: ", ")
            let appCheckSql = """
                SELECT 1 FROM frame f
                JOIN segment s ON f.segmentId = s.id
                WHERE f.videoId = ? AND s.bundleID IN (\(placeholders))
                LIMIT 1;
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, appCheckSql, -1, &statement, nil) == SQLITE_OK else {
                throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }

            sqlite3_bind_int64(statement, 1, videoSegmentId.value)
            for (index, bundleID) in excludingApps.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 2), bundleID, -1, SQLITE_TRANSIENT)
            }

            if sqlite3_step(statement) == SQLITE_ROW {
                return true // Found a frame from excluded app
            }
        }

        // Check if any segment associated with frames in this video segment has excluded tags
        if !excludingTagIds.isEmpty {
            let placeholders = excludingTagIds.map { _ in "?" }.joined(separator: ", ")
            let tagCheckSql = """
                SELECT 1 FROM frame f
                JOIN segment_tag st ON f.segmentId = st.segmentId
                WHERE f.videoId = ? AND st.tagId IN (\(placeholders))
                LIMIT 1;
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, tagCheckSql, -1, &statement, nil) == SQLITE_OK else {
                throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }

            sqlite3_bind_int64(statement, 1, videoSegmentId.value)
            for (index, tagId) in excludingTagIds.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 2), tagId)
            }

            if sqlite3_step(statement) == SQLITE_ROW {
                return true // Found a frame with excluded tag
            }
        }

        // Check if any segment associated with frames in this video segment has the "hidden" tag
        if excludeHidden {
            let hiddenTagSql = """
                SELECT 1 FROM frame f
                JOIN segment_tag st ON f.segmentId = st.segmentId
                JOIN tag t ON st.tagId = t.id
                WHERE f.videoId = ? AND LOWER(t.name) = 'hidden'
                LIMIT 1;
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, hiddenTagSql, -1, &statement, nil) == SQLITE_OK else {
                throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }

            sqlite3_bind_int64(statement, 1, videoSegmentId.value)

            if sqlite3_step(statement) == SQLITE_ROW {
                return true // Found a segment with hidden tag
            }
        }

        return false
    }

    /// Delete frames older than the cutoff date, excluding frames from protected apps/tags/hidden
    private func deleteFrames(olderThan cutoffDate: Date, excludingApps: Set<String>, excludingTagIds: Set<Int64>, excludeHidden: Bool) async throws -> Int {
        guard let db = await database.getConnection() else {
            throw RetentionError.databaseNotConnected
        }

        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1000)

        // Build SQL with exclusions
        var conditions: [String] = ["f.createdAt < ?"]

        // Exclude frames from protected apps
        if !excludingApps.isEmpty {
            let placeholders = excludingApps.map { _ in "?" }.joined(separator: ", ")
            conditions.append("s.bundleID NOT IN (\(placeholders))")
        }

        // Exclude frames from segments with protected tags
        if !excludingTagIds.isEmpty {
            let placeholders = excludingTagIds.map { _ in "?" }.joined(separator: ", ")
            conditions.append("f.segmentId NOT IN (SELECT segmentId FROM segment_tag WHERE tagId IN (\(placeholders)))")
        }

        // Exclude segments tagged with the "hidden" tag (tag name = 'hidden')
        if excludeHidden {
            conditions.append("f.segmentId NOT IN (SELECT st.segmentId FROM segment_tag st JOIN tag t ON st.tagId = t.id WHERE LOWER(t.name) = 'hidden')")
        }

        let whereClause = conditions.joined(separator: " AND ")

        // Clean up the semantic (AI visual description) index for frames about to be deleted,
        // BEFORE deleting the frame rows — semantic_doc_frame/semanticRanking have no FK to
        // frame, so this must happen first or those rows become permanently orphaned.
        let frameIDSubquery = """
            SELECT f.id FROM frame f
            JOIN segment s ON f.segmentId = s.id
            WHERE \(whereClause)
            ORDER BY f.id
            """

        // Chunked batches: one bounded DELETE per iteration keeps WAL growth
        // and lock hold time flat under retention pressure. Same rows are
        // removed as a single DELETE — just spread across iterations.
        let batchSize = DatabaseConfig.retentionDeleteBatchSize
        var totalDeleted = 0
        while true {
            try deleteSemanticIndexRows(
                db: db,
                frameIDSubquery: frameIDSubquery,
                batchSize: batchSize,
                cutoffMs: cutoffMs,
                excludingApps: excludingApps,
                excludingTagIds: excludingTagIds
            )

            let deleted = try deleteFrameBatch(
                db: db,
                whereClause: whereClause,
                batchSize: batchSize,
                cutoffMs: cutoffMs,
                excludingApps: excludingApps,
                excludingTagIds: excludingTagIds
            )
            totalDeleted += deleted
            if deleted < batchSize { break }
        }

        return totalDeleted
    }

    /// Delete one bounded batch of frames matching the retention WHERE clause.
    /// - Returns: Number of frame rows deleted in this batch.
    private func deleteFrameBatch(
        db: OpaquePointer,
        whereClause: String,
        batchSize: Int,
        cutoffMs: Int64,
        excludingApps: Set<String>,
        excludingTagIds: Set<Int64>
    ) throws -> Int {
        // ORDER BY f.id must match frameIDSubquery's ordering: the semantic-index
        // batch above and this frame batch need to select the same row set, or a
        // frame can be deleted before its semanticRanking/semantic_doc_frame rows
        // are, permanently orphaning them (cleanupOrphanedNodes doesn't sweep
        // those two tables).
        let sql = """
            DELETE FROM frame WHERE id IN (
                SELECT f.id FROM frame f
                JOIN segment s ON f.segmentId = s.id
                WHERE \(whereClause)
                ORDER BY f.id
                LIMIT \(batchSize)
            );
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        // Bind all values
        var bindIndex: Int32 = 1
        sqlite3_bind_int64(statement, bindIndex, cutoffMs)
        bindIndex += 1

        for bundleID in excludingApps {
            sqlite3_bind_text(statement, bindIndex, bundleID, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }

        for tagId in excludingTagIds {
            sqlite3_bind_int64(statement, bindIndex, tagId)
            bindIndex += 1
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Deletes `semanticRanking`/`semantic_doc_frame` rows for frames matching `frameIDSubquery`.
    /// Runs each DELETE as its own prepared statement (each needs the full bind sequence again,
    /// since they're independent statements sharing the same WHERE clause text).
    private func deleteSemanticIndexRows(
        db: OpaquePointer,
        frameIDSubquery: String,
        batchSize: Int,
        cutoffMs: Int64,
        excludingApps: Set<String>,
        excludingTagIds: Set<Int64>
    ) throws {
        func bindAndExecute(sql: String) throws {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }

            var bindIndex: Int32 = 1
            sqlite3_bind_int64(statement, bindIndex, cutoffMs)
            bindIndex += 1
            for bundleID in excludingApps {
                sqlite3_bind_text(statement, bindIndex, bundleID, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
            for tagId in excludingTagIds {
                sqlite3_bind_int64(statement, bindIndex, tagId)
                bindIndex += 1
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }

        try bindAndExecute(sql: """
            DELETE FROM semanticRanking WHERE rowid IN (
                SELECT docid FROM semantic_doc_frame WHERE frameId IN (\(frameIDSubquery) LIMIT \(batchSize))
            );
            """)
        try bindAndExecute(sql: """
            DELETE FROM semantic_doc_frame WHERE frameId IN (\(frameIDSubquery) LIMIT \(batchSize));
            """)
    }

    /// Delete app segments (sessions) older than the cutoff date, excluding protected apps/tags/hidden
    private func deleteAppSegmentsOlderThan(_ cutoffDate: Date, excludingApps: Set<String>, excludingTagIds: Set<Int64>, excludeHidden: Bool) async throws -> Int {
        guard let db = await database.getConnection() else {
            throw RetentionError.databaseNotConnected
        }

        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1000)

        // Build SQL with exclusions
        var conditions: [String] = ["endDate < ?"]

        // Exclude segments from protected apps
        if !excludingApps.isEmpty {
            let placeholders = excludingApps.map { _ in "?" }.joined(separator: ", ")
            conditions.append("bundleID NOT IN (\(placeholders))")
        }

        // Exclude segments with protected tags
        if !excludingTagIds.isEmpty {
            let placeholders = excludingTagIds.map { _ in "?" }.joined(separator: ", ")
            conditions.append("id NOT IN (SELECT segmentId FROM segment_tag WHERE tagId IN (\(placeholders)))")
        }

        // Exclude segments tagged with the "hidden" tag (tag name = 'hidden')
        if excludeHidden {
            conditions.append("id NOT IN (SELECT st.segmentId FROM segment_tag st JOIN tag t ON st.tagId = t.id WHERE LOWER(t.name) = 'hidden')")
        }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = "DELETE FROM segment WHERE \(whereClause);"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        // Bind all values
        var bindIndex: Int32 = 1
        sqlite3_bind_int64(statement, bindIndex, cutoffMs)
        bindIndex += 1

        for bundleID in excludingApps {
            sqlite3_bind_text(statement, bindIndex, bundleID, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }

        for tagId in excludingTagIds {
            sqlite3_bind_int64(statement, bindIndex, tagId)
            bindIndex += 1
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Clean up rows that reference deleted frames: OCR nodes plus the V21
    /// cognitive-memory frame links (episode_frame, entity_mention,
    /// keyframe_vector_metadata). None of these tables has an FK to frame,
    /// so retention must remove dangling rows explicitly (same precedent as
    /// the semantic index cleanup above).
    private func cleanupOrphanedNodes() async throws -> Int {
        guard let db = await database.getConnection() else {
            throw RetentionError.databaseNotConnected
        }

        var total = 0
        total += try deleteOrphanedFrameLinks(db: db, table: "node", column: "frameId")
        total += try deleteOrphanedFrameLinks(db: db, table: "episode_frame", column: "frameId")
        total += try deleteOrphanedFrameLinks(db: db, table: "entity_mention", column: "frameId")
        total += try deleteOrphanedFrameLinks(db: db, table: "keyframe_vector_metadata", column: "frameId")
        return total
    }

    /// Delete one table's rows whose frame link no longer exists, in bounded
    /// batches. Table/column names are internal constants, never user input.
    private func deleteOrphanedFrameLinks(db: OpaquePointer, table: String, column: String) throws -> Int {
        let batchSize = DatabaseConfig.retentionDeleteBatchSize
        var total = 0
        while true {
            let deleted = try deleteOrphanedFrameLinkBatch(db: db, table: table, column: column, batchSize: batchSize)
            total += deleted
            if deleted < batchSize { break }
        }
        return total
    }

    private func deleteOrphanedFrameLinkBatch(db: OpaquePointer, table: String, column: String, batchSize: Int) throws -> Int {
        let sql = """
            DELETE FROM \(table) WHERE rowid IN (
                SELECT rowid FROM \(table)
                WHERE \(column) NOT IN (SELECT id FROM frame)
                LIMIT \(batchSize)
            );
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RetentionError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        return Int(sqlite3_changes(db))
    }

    /// Format bytes into human-readable string
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Supporting Types

/// Result of a retention cleanup operation
public struct RetentionCleanupResult: Sendable {
    public let deletedFrames: Int
    public let deletedVideoSegments: Int
    public let deletedAppSegments: Int
    public let reclaimedBytes: Int64
    public let cutoffDate: Date?
    public let success: Bool
    public let error: String?
}

/// Retention manager errors
public enum RetentionError: Error {
    case databaseNotConnected
    case queryFailed(String)
}

// Need SQLite for direct queries
import SQLCipher
