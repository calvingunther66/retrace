import Foundation
import SQLCipher
import Shared

/// V21 Migration: adds Retrace Cognitive Memory System (CMS) schema.
/// Supports episodic multi-app task clustering (`cognitive_episode`, `episode_frame`),
/// cross-referencing knowledge graph (`memory_entity`, `entity_mention`, `entity_association`),
/// and keyframe vector metadata (`keyframe_vector_metadata`).
struct V21_CognitiveMemorySystem: Migration {
    let version = 21

    func migrate(db: OpaquePointer) async throws {
        Log.info("🧠 Verifying V21 Cognitive Memory System schema...", category: .database)

        // 1. Cognitive Episodes (task-level clustering across apps)
        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS cognitive_episode (
                    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                    startTime           INTEGER NOT NULL,
                    endTime             INTEGER NOT NULL,
                    title               TEXT,
                    summary             TEXT,
                    primaryAppBundleID  TEXT,
                    keyframeIDs         TEXT,
                    createdAt           INTEGER NOT NULL
                );
                """
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_episode_time ON cognitive_episode(startTime, endTime);"
        )
        Log.debug("✓ Created cognitive_episode table and index", category: .database)

        // 2. Episode Frame Link & Salience
        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS episode_frame (
                    episodeId           INTEGER NOT NULL,
                    frameId             INTEGER NOT NULL,
                    salienceScore       REAL NOT NULL DEFAULT 0.0,
                    isKeyframe          INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (episodeId, frameId)
                );
                """
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_episode_frame_fid ON episode_frame(frameId);"
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_episode_frame_keyframe ON episode_frame(isKeyframe, salienceScore DESC);"
        )
        Log.debug("✓ Created episode_frame table and indexes", category: .database)

        // 3. Memory Entities (canonical nodes in Knowledge Mesh)
        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS memory_entity (
                    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                    entityType          TEXT NOT NULL,
                    normalizedValue     TEXT NOT NULL UNIQUE,
                    displayName         TEXT NOT NULL,
                    firstSeenAt         INTEGER NOT NULL,
                    lastSeenAt          INTEGER NOT NULL,
                    occurrenceCount     INTEGER NOT NULL DEFAULT 1
                );
                """
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_memory_entity_type ON memory_entity(entityType);"
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_memory_entity_norm ON memory_entity(normalizedValue);"
        )
        Log.debug("✓ Created memory_entity table and indexes", category: .database)

        // 4. Entity Mentions per Frame
        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS entity_mention (
                    entityId            INTEGER NOT NULL,
                    frameId             INTEGER NOT NULL,
                    confidence          REAL NOT NULL DEFAULT 1.0,
                    PRIMARY KEY (entityId, frameId)
                );
                """
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_entity_mention_fid ON entity_mention(frameId);"
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_entity_mention_eid ON entity_mention(entityId);"
        )
        Log.debug("✓ Created entity_mention table and indexes", category: .database)

        // 5. Entity Associations (co-occurrence graph edges)
        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS entity_association (
                    sourceEntityId      INTEGER NOT NULL,
                    targetEntityId      INTEGER NOT NULL,
                    weight              REAL NOT NULL DEFAULT 1.0,
                    coOccurrenceCount   INTEGER NOT NULL DEFAULT 1,
                    lastCoOccurredAt    INTEGER NOT NULL,
                    PRIMARY KEY (sourceEntityId, targetEntityId)
                );
                """
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS idx_entity_assoc_source ON entity_association(sourceEntityId, weight DESC);"
        )
        Log.debug("✓ Created entity_association table and indexes", category: .database)

        // 6. Keyframe Vector Metadata Registry
        try execute(
            db: db,
            sql: """
                CREATE TABLE IF NOT EXISTS keyframe_vector_metadata (
                    frameId             INTEGER PRIMARY KEY,
                    vectorOffset        INTEGER NOT NULL,
                    dimensions          INTEGER NOT NULL,
                    modelName           TEXT NOT NULL,
                    createdAt           INTEGER NOT NULL
                );
                """
        )
        Log.debug("✓ Created keyframe_vector_metadata registry table", category: .database)

        Log.info("✅ V21 migration completed: Cognitive Memory System schema verified", category: .database)
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
