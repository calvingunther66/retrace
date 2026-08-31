import Foundation
import SQLCipher
import Shared

/// V20 Migration: adds AI visual semantic indexing support.
/// `semanticStatus` tracks per-frame indexing progress (0 pending, 1 in-flight,
/// 2 completed, 3 retryable failure, 4 skipped, 8 permanently failed).
/// `semanticRanking` is a standalone FTS5 table (separate from `searchRanking`)
/// so the existing OCR write path is never touched by this feature.
/// `semantic_index_requests` is the durable daily-budget counter for the
/// backfill indexer — a DB row, not UserDefaults, so a crash mid-request still
/// counts against the day's budget on next launch.
struct V20_SemanticIndex: Migration {
    let version = 20

    func migrate(db: OpaquePointer) async throws {
        Log.info("🧠 Verifying V20 semantic indexing schema...", category: .database)

        if try hasColumn(db: db, table: "frame", column: "semanticStatus") {
            Log.debug("✓ frame.semanticStatus already exists")
        } else {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN semanticStatus INTEGER NOT NULL DEFAULT 0;")
            Log.debug("✓ Added frame.semanticStatus column")
        }

        if try hasColumn(db: db, table: "frame", column: "semanticIndexedAt") {
            Log.debug("✓ frame.semanticIndexedAt already exists")
        } else {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN semanticIndexedAt INTEGER;")
            Log.debug("✓ Added frame.semanticIndexedAt column")
        }

        if try hasColumn(db: db, table: "frame", column: "semanticRetryCount") {
            Log.debug("✓ frame.semanticRetryCount already exists")
        } else {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN semanticRetryCount INTEGER NOT NULL DEFAULT 0;")
            Log.debug("✓ Added frame.semanticRetryCount column")
        }

        // Guard on `createdAt` existing before indexing it: every real (post-V1) database has
        // this column, but the migration runner must never let a secondary performance index
        // take down the entire migration chain for every version after it over a column that,
        // in some non-standard schema, isn't there. Skipping the index in that case is safe —
        // the selection query in SemanticIndexQueries still works, just without this optimization.
        if try hasColumn(db: db, table: "frame", column: "createdAt") {
            try execute(
                db: db,
                sql: """
                    CREATE INDEX IF NOT EXISTS idx_frame_semantic_pending
                    ON frame(semanticStatus, createdAt)
                    WHERE semanticStatus IN (0, 3);
                    """
            )
            Log.debug("✓ Created pending/retryable semantic-index selection index")
        } else {
            Log.warning("⚠️ frame.createdAt not found — skipping idx_frame_semantic_pending index", category: .database)
        }

        // `unicode61`, not `porter` — V5 deliberately rebuilt `searchRanking` away from the
        // porter stemmer to unicode61 (Database/Migrations/V5_FTSUnicode61.swift). Whatever
        // motivated that applies equally here: a query run through `buildSemanticFTSQuery`
        // should stem the same way regardless of which of the two FTS tables it hits, or
        // identical search terms silently match different things across the two indexes.
        try execute(
            db: db,
            sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS semanticRanking USING fts5(
                    description,
                    tokenize=unicode61
                );
                """
        )
        Log.debug("✓ Created semanticRanking FTS5 table")

        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS semantic_doc_frame (
                    docid     INTEGER PRIMARY KEY,
                    frameId   INTEGER NOT NULL UNIQUE,
                    createdAt INTEGER NOT NULL
                );
                """
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_semantic_doc_frame_frameid ON semantic_doc_frame(frameId);"
        )
        Log.debug("✓ Created semantic_doc_frame junction table")

        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS semantic_index_requests (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    requestedAt   INTEGER NOT NULL,
                    frameIds      TEXT NOT NULL,
                    frameCount    INTEGER NOT NULL,
                    lane          TEXT NOT NULL DEFAULT 'backfill',
                    status        TEXT NOT NULL DEFAULT 'dispatched',
                    httpStatus    INTEGER,
                    errorMessage  TEXT
                );
                """
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_semantic_requests_requestedat ON semantic_index_requests(requestedAt);"
        )
        Log.debug("✓ Created semantic_index_requests budget-tracking table")

        Log.info(
            "✅ V20 migration completed: semantic indexing schema verified",
            category: .database
        )
    }

    private func hasColumn(db: OpaquePointer, table: String, column: String) throws -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.migrationFailed(
                version: version,
                underlying: "Failed to inspect table info: \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                continue
            }
            if name == column {
                return true
            }
        }

        return false
    }

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: version, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
