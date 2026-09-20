import Foundation
import SQLCipher
import Shared

/// V22 Migration: rescopes `memory_entity`'s uniqueness constraint from bare `normalizedValue`
/// to the pair `(entityType, normalizedValue)`.
///
/// V21 declared `normalizedValue TEXT NOT NULL UNIQUE` with no type component, so two entities
/// of different types that normalize to the same string silently merged into one row,
/// corrupting `entity_mention`/`entity_association` data for one of them with no surfaced error.
/// This is a new migration rather than an in-place edit to V21 because V21 may already be
/// applied on real user databases — SQLite can't alter a UNIQUE constraint via `ALTER TABLE`,
/// so the table is rebuilt (matching `V5_FTSUnicode61`'s rename/copy/swap pattern), preserving
/// every row's `id` so `entity_mention`/`entity_association` references stay valid.
struct V22_MemoryEntityTypeScopedUniqueness: Migration {
    let version = 22

    func migrate(db: OpaquePointer) async throws {
        Log.info("🧠 Rescoping memory_entity uniqueness to (entityType, normalizedValue)...", category: .database)
        try rebuildMemoryEntityTable(db: db)
        Log.info("✅ V22 migration completed: memory_entity now unique on (entityType, normalizedValue)", category: .database)
    }

    // MARK: - Table Rebuild

    private func rebuildMemoryEntityTable(db: OpaquePointer) throws {
        // Clean up any failed previous attempts
        try execute(db: db, sql: "DROP TABLE IF EXISTS memory_entity_new;")
        try execute(db: db, sql: "DROP TABLE IF EXISTS memory_entity_old;")

        // Create new memory_entity table with uniqueness scoped to (entityType, normalizedValue)
        try execute(db: db, sql: """
            CREATE TABLE memory_entity_new (
                id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                entityType          TEXT NOT NULL,
                normalizedValue     TEXT NOT NULL,
                displayName         TEXT NOT NULL,
                firstSeenAt         INTEGER NOT NULL,
                lastSeenAt          INTEGER NOT NULL,
                occurrenceCount     INTEGER NOT NULL DEFAULT 1,
                UNIQUE(entityType, normalizedValue)
            );
            """)
        Log.debug("✓ Created memory_entity_new with (entityType, normalizedValue) uniqueness")

        // Copy data, preserving ids so entity_mention/entity_association references stay valid.
        // V21's bare-normalizedValue UNIQUE was strictly stronger than the new pair constraint,
        // so no row can conflict on the copy.
        try execute(db: db, sql: """
            INSERT INTO memory_entity_new (id, entityType, normalizedValue, displayName, firstSeenAt, lastSeenAt, occurrenceCount)
            SELECT id, entityType, normalizedValue, displayName, firstSeenAt, lastSeenAt, occurrenceCount FROM memory_entity;
            """)
        Log.debug("✓ Copied memory_entity rows to memory_entity_new")

        // Rename old table as backup
        try execute(db: db, sql: "ALTER TABLE memory_entity RENAME TO memory_entity_old;")
        Log.debug("✓ Renamed old table to memory_entity_old")

        // Swap in the new table
        try execute(db: db, sql: "ALTER TABLE memory_entity_new RENAME TO memory_entity;")
        Log.debug("✓ Renamed new table to memory_entity")

        // Drop the old table
        try execute(db: db, sql: "DROP TABLE IF EXISTS memory_entity_old;")
        Log.debug("✓ Dropped old memory_entity_old table")

        // Recreate the indexes V21 defined on memory_entity
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_memory_entity_type ON memory_entity(entityType);")
        try execute(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_memory_entity_norm ON memory_entity(normalizedValue);")
        Log.debug("✓ Recreated memory_entity indexes")
    }

    // MARK: - Helper

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)

        if result != SQLITE_OK {
            let errorMessage = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.migrationFailed(version: 22, underlying: "SQL execution failed: \(errorMessage)")
        }
    }
}
