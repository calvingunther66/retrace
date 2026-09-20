import XCTest
import Foundation
import SQLCipher
@testable import Database

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║                            MIGRATION TESTS                                   ║
// ║                                                                              ║
// ║  Verifies migrations run correctly against a real, on-disk SQLite database   ║
// ║  via the module's actual `MigrationRunner`, and create the expected schema.  ║
// ║                                                                              ║
// ║  Covers V20 (AI visual semantic indexing) and V21 (Cognitive Memory System), ║
// ║  the two newest migrations at the time of writing, which previously had no   ║
// ║  direct test coverage (see local/docs/2026-09-18-stable-release-audit.md,   ║
// ║  finding #25).                                                              ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

final class MigrationTests: XCTestCase {

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ V20 + V21: FRESH DATABASE, FULL MIGRATION CHAIN                          │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testV20AndV21_RunAgainstFreshDatabase_CreateExpectedCMSSchema() async throws {
        let dbPath = temporaryDatabasePath()
        let db = try openRawDatabase(at: dbPath)
        defer {
            sqlite3_close(db)
            removeSQLiteTestArtifacts(atPath: dbPath)
        }

        // Fresh, on-disk database at version 0: run the full migration chain
        // (V1...latest) through the actual MigrationRunner, exactly as
        // DatabaseManager.initialize() does for a real install.
        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()

        let currentVersion = try fetchInt64("SELECT MAX(version) FROM schema_migrations;", db: db)
        XCTAssertGreaterThanOrEqual(currentVersion, 21)

        // V20: AI visual semantic indexing schema
        XCTAssertTrue(try columnExists(table: "frame", column: "semanticStatus", db: db))
        XCTAssertTrue(try columnExists(table: "frame", column: "semanticIndexedAt", db: db))
        XCTAssertTrue(try columnExists(table: "frame", column: "semanticRetryCount", db: db))
        XCTAssertTrue(try tableExists("semanticRanking", db: db))
        XCTAssertTrue(try tableExists("semantic_doc_frame", db: db))
        XCTAssertTrue(try tableExists("semantic_index_requests", db: db))
        XCTAssertTrue(try indexExists("idx_frame_semantic_pending", db: db))
        XCTAssertTrue(try indexExists("idx_semantic_doc_frame_frameid", db: db))
        XCTAssertTrue(try indexExists("idx_semantic_requests_requestedat", db: db))

        // V21: Cognitive Memory System schema
        XCTAssertTrue(try tableExists("cognitive_episode", db: db))
        XCTAssertTrue(try tableExists("episode_frame", db: db))
        XCTAssertTrue(try tableExists("memory_entity", db: db))
        XCTAssertTrue(try tableExists("entity_mention", db: db))
        XCTAssertTrue(try tableExists("entity_association", db: db))
        XCTAssertTrue(try tableExists("keyframe_vector_metadata", db: db))
        XCTAssertTrue(try indexExists("idx_episode_time", db: db))
        XCTAssertTrue(try indexExists("idx_episode_frame_fid", db: db))
        XCTAssertTrue(try indexExists("idx_episode_frame_keyframe", db: db))
        XCTAssertTrue(try indexExists("idx_memory_entity_type", db: db))
        XCTAssertTrue(try indexExists("idx_memory_entity_norm", db: db))
        XCTAssertTrue(try indexExists("idx_entity_mention_fid", db: db))
        XCTAssertTrue(try indexExists("idx_entity_mention_eid", db: db))
        XCTAssertTrue(try indexExists("idx_entity_assoc_source", db: db))
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ IDEMPOTENCY: RUNNER-LEVEL RE-RUN                                        │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testRunningFullMigrationSetTwice_IsANoOpAndDoesNotDuplicateSchemaObjects() async throws {
        let dbPath = temporaryDatabasePath()
        let db = try openRawDatabase(at: dbPath)
        defer {
            sqlite3_close(db)
            removeSQLiteTestArtifacts(atPath: dbPath)
        }

        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()

        let versionAfterFirstRun = try fetchInt64("SELECT MAX(version) FROM schema_migrations;", db: db)
        let migrationRowCountAfterFirstRun = try fetchInt64("SELECT COUNT(*) FROM schema_migrations;", db: db)
        let cmsTableCountAfterFirstRun = try sqliteMasterCount(name: "cognitive_episode", type: "table", db: db)

        // Re-running the full migration set against an already-migrated database (e.g. app
        // relaunch on the same DB) must not error and must not re-apply or duplicate anything:
        // MigrationRunner only runs migrations whose version exceeds the recorded current
        // version, so this exercises that gate directly rather than assuming it.
        try await runner.runMigrations()

        let versionAfterSecondRun = try fetchInt64("SELECT MAX(version) FROM schema_migrations;", db: db)
        let migrationRowCountAfterSecondRun = try fetchInt64("SELECT COUNT(*) FROM schema_migrations;", db: db)
        let cmsTableCountAfterSecondRun = try sqliteMasterCount(name: "cognitive_episode", type: "table", db: db)

        XCTAssertEqual(versionAfterFirstRun, versionAfterSecondRun)
        XCTAssertEqual(migrationRowCountAfterFirstRun, migrationRowCountAfterSecondRun)
        XCTAssertEqual(cmsTableCountAfterFirstRun, 1)
        XCTAssertEqual(cmsTableCountAfterSecondRun, 1)
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ IDEMPOTENCY: V20/V21 `migrate()` RE-INVOKED DIRECTLY                    │
    // └─────────────────────────────────────────────────────────────────────────┘

    func testV20AndV21Migrate_ReInvokedDirectly_IsIdempotentAndDoesNotDuplicateSchemaObjects() async throws {
        let dbPath = temporaryDatabasePath()
        let db = try openRawDatabase(at: dbPath)
        defer {
            sqlite3_close(db)
            removeSQLiteTestArtifacts(atPath: dbPath)
        }

        let runner = MigrationRunner(db: db)
        try await runner.runMigrations()

        // Bypass MigrationRunner's schema_migrations version gate and call V20/V21's own
        // `migrate()` a second time directly. Both migrations guard every statement with
        // `IF NOT EXISTS` / a `hasColumn` check specifically so this is safe -- this is the
        // property this test locks down, independent of the runner's own bookkeeping above.
        try await V20_SemanticIndex().migrate(db: db)
        try await V21_CognitiveMemorySystem().migrate(db: db)

        XCTAssertEqual(try sqliteMasterCount(name: "semanticRanking", type: "table", db: db), 1)
        XCTAssertEqual(try sqliteMasterCount(name: "semantic_doc_frame", type: "table", db: db), 1)
        XCTAssertEqual(try sqliteMasterCount(name: "semantic_index_requests", type: "table", db: db), 1)
        XCTAssertEqual(try sqliteMasterCount(name: "cognitive_episode", type: "table", db: db), 1)
        XCTAssertEqual(try sqliteMasterCount(name: "memory_entity", type: "table", db: db), 1)
        XCTAssertEqual(try sqliteMasterCount(name: "keyframe_vector_metadata", type: "table", db: db), 1)
        XCTAssertEqual(try columnOccurrenceCount(table: "frame", column: "semanticStatus", db: db), 1)

        // The full chain (run above via the runner) already applied V22, which rebuilds
        // memory_entity to rescope its UNIQUE constraint from bare `normalizedValue` to the
        // pair `(entityType, normalizedValue)`. Re-invoking V21's `migrate()` directly issues
        // `CREATE TABLE IF NOT EXISTS memory_entity (...)` with V21's ORIGINAL (bare-column)
        // UNIQUE definition -- but since the table already exists, that statement is a no-op
        // and must NOT resurrect V21's weaker constraint. Verify the V22 constraint survived
        // by proving two different entity types can share a normalizedValue (impossible under
        // V21's bare-column UNIQUE, allowed under V22's compound UNIQUE).
        try executeRawSQL(
            """
            INSERT INTO memory_entity (entityType, normalizedValue, displayName, firstSeenAt, lastSeenAt)
            VALUES ('person', 'jane@example.com', 'jane', 0, 0),
                   ('email',  'jane@example.com', 'jane', 0, 0);
            """,
            db: db
        )
        XCTAssertEqual(
            try fetchInt64("SELECT COUNT(*) FROM memory_entity WHERE normalizedValue = 'jane@example.com';", db: db),
            2,
            "Re-running V21's migrate() must not resurrect its superseded bare-normalizedValue UNIQUE constraint"
        )
    }

    // ┌─────────────────────────────────────────────────────────────────────────┐
    // │ HELPERS                                                                 │
    // └─────────────────────────────────────────────────────────────────────────┘

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RetraceMigrationTests-\(UUID().uuidString).sqlite")
            .path
    }

    private func openRawDatabase(at path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Failed to open raw database"
            sqlite3_close(db)
            throw NSError(domain: "MigrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        try executeRawSQL("PRAGMA foreign_keys = ON;", db: db)
        try executeRawSQL("PRAGMA journal_mode = WAL;", db: db)
        try executeRawSQL("PRAGMA synchronous = NORMAL;", db: db)
        return db
    }

    private func removeSQLiteTestArtifacts(atPath path: String) {
        for suffix in ["", "-wal", "-shm"] {
            let candidate = path + suffix
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            try? FileManager.default.removeItem(atPath: candidate)
        }
    }

    private func executeRawSQL(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(errorMessage) }

        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQL error"
            throw NSError(domain: "MigrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func fetchInt64(_ sql: String, db: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "MigrationTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "MigrationTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Expected one row for query: \(sql)"])
        }

        return sqlite3_column_int64(statement, 0)
    }

    private func sqliteMasterCount(name: String, type: String, db: OpaquePointer) throws -> Int64 {
        try fetchInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = '\(type)' AND name = '\(name)';",
            db: db
        )
    }

    private func tableExists(_ name: String, db: OpaquePointer) throws -> Bool {
        try sqliteMasterCount(name: name, type: "table", db: db) > 0
    }

    private func indexExists(_ name: String, db: OpaquePointer) throws -> Bool {
        try sqliteMasterCount(name: name, type: "index", db: db) > 0
    }

    private func columnOccurrenceCount(table: String, column: String, db: OpaquePointer) throws -> Int {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "MigrationTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        var count = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }), name == column {
                count += 1
            }
        }
        return count
    }

    private func columnExists(table: String, column: String, db: OpaquePointer) throws -> Bool {
        try columnOccurrenceCount(table: table, column: column, db: db) > 0
    }
}
