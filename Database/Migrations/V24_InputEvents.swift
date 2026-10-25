import Foundation
import SQLCipher
import Shared

/// V24 Migration: input event logging.
///
/// - `input_event`: one row per user action (click, scroll, shortcut, typing burst), linked to the
///   frames around it. Typed characters are never stored; typing is only a count.
/// - `input_event_ax`: optional compressed snapshot of clickable accessibility elements, kept out of
///   the main table so it stays small and can be pruned independently.
/// - `frame.displayId`: which display a frame shows, so exports never pair a click on display B with
///   a frame of display A. Existing frames keep NULL (unknown).
///
/// Idempotent: `MigrationSafetyTests` re-runs the latest migration on an already-migrated database.
struct V24_InputEvents: Migration {
    let version = 24

    func migrate(db: OpaquePointer) async throws {
        Log.info("🖱️ Adding input event tables...", category: .database)

        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS input_event (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tsMs INTEGER NOT NULL,
                endTsMs INTEGER,
                kind TEXT NOT NULL,
                button TEXT,
                clickCount INTEGER,
                mods TEXT,
                x REAL,
                y REAL,
                scrollDx REAL,
                scrollDy REAL,
                keyCombo TEXT,
                typedCount INTEGER,
                displayId INTEGER,
                displayPixelWidth INTEGER,
                displayPixelHeight INTEGER,
                displayScale REAL,
                displays TEXT,
                bundleId TEXT,
                windowTitle TEXT,
                windowX REAL,
                windowY REAL,
                windowW REAL,
                windowH REAL,
                axRole TEXT,
                axSubrole TEXT,
                axTitle TEXT,
                axIdentifier TEXT,
                axX REAL,
                axY REAL,
                axW REAL,
                axH REAL,
                preFrameId INTEGER REFERENCES frame(id) ON DELETE SET NULL,
                preGapMs INTEGER,
                downFrameTsMs INTEGER,
                downFrameId INTEGER REFERENCES frame(id) ON DELETE SET NULL,
                postFrameId INTEGER REFERENCES frame(id) ON DELETE SET NULL,
                linkState INTEGER NOT NULL DEFAULT 0,
                privacyState TEXT NOT NULL DEFAULT 'ok',
                redacted INTEGER NOT NULL DEFAULT 0
            );
            """)

        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_input_event_ts ON input_event(tsMs);")
        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS idx_input_event_pending
            ON input_event(tsMs) WHERE linkState = 0;
            """)
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_input_event_pre_frame ON input_event(preFrameId);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_input_event_down_frame ON input_event(downFrameId);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_input_event_post_frame ON input_event(postFrameId);")

        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS input_event_ax (
                eventId INTEGER PRIMARY KEY REFERENCES input_event(id) ON DELETE CASCADE,
                elements BLOB NOT NULL
            );
            """)

        if try !hasColumn(db: db, table: "frame", column: "displayId") {
            try execute(db: db, sql: "ALTER TABLE frame ADD COLUMN displayId INTEGER;")
            Log.debug("✓ Added frame.displayId column")
        }

        Log.info("✅ V24 migration completed: input_event, input_event_ax, frame.displayId", category: .database)
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
