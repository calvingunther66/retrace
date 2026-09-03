import Foundation
import SQLCipher
import Shared

/// Raw SQL queries backing the Cognitive Memory System:
/// - Cognitive Episode clustering & keyframe tracking
/// - Knowledge mesh entities, mentions, and associative co-occurrence edges
/// - Vector metadata index
public enum CognitiveMemoryQueries {

    // MARK: - SQLite Transient Helper

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Cognitive Episodes

    public static func insertEpisode(
        db: OpaquePointer,
        episode: CognitiveEpisode
    ) throws -> Int64 {
        let sql = """
            INSERT INTO cognitive_episode (startTime, endTime, title, summary, primaryAppBundleID, keyframeIDs, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let startMs = Schema.dateToTimestamp(episode.startTime)
        let endMs = Schema.dateToTimestamp(episode.endTime)
        let createdMs = Schema.dateToTimestamp(episode.createdAt)
        let keyframesJSON: String? = (try? JSONEncoder().encode(episode.keyframeIDs)).flatMap { String(data: $0, encoding: .utf8) }

        sqlite3_bind_int64(statement, 1, startMs)
        sqlite3_bind_int64(statement, 2, endMs)
        bindTextOrNull(statement, 3, episode.title)
        bindTextOrNull(statement, 4, episode.summary)
        bindTextOrNull(statement, 5, episode.primaryAppBundleID)
        bindTextOrNull(statement, 6, keyframesJSON)
        sqlite3_bind_int64(statement, 7, createdMs)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        return sqlite3_last_insert_rowid(db)
    }

    public static func updateEpisode(
        db: OpaquePointer,
        episodeId: Int64,
        endTime: Date,
        title: String?,
        summary: String?,
        primaryAppBundleID: String?,
        keyframeIDs: [Int64]
    ) throws {
        let sql = """
            UPDATE cognitive_episode
            SET endTime = ?, title = COALESCE(?, title), summary = COALESCE(?, summary),
                primaryAppBundleID = COALESCE(?, primaryAppBundleID), keyframeIDs = ?
            WHERE id = ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        let endMs = Schema.dateToTimestamp(endTime)
        let keyframesJSON: String? = (try? JSONEncoder().encode(keyframeIDs)).flatMap { String(data: $0, encoding: .utf8) }

        sqlite3_bind_int64(statement, 1, endMs)
        bindTextOrNull(statement, 2, title)
        bindTextOrNull(statement, 3, summary)
        bindTextOrNull(statement, 4, primaryAppBundleID)
        bindTextOrNull(statement, 5, keyframesJSON)
        sqlite3_bind_int64(statement, 6, episodeId)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    public static func getEpisode(db: OpaquePointer, id: Int64) throws -> CognitiveEpisode? {
        let sql = """
            SELECT id, startTime, endTime, title, summary, primaryAppBundleID, keyframeIDs, createdAt
            FROM cognitive_episode
            WHERE id = ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return parseEpisode(statement: statement!)
    }

    public static func getLatestEpisode(db: OpaquePointer) throws -> CognitiveEpisode? {
        let sql = """
            SELECT id, startTime, endTime, title, summary, primaryAppBundleID, keyframeIDs, createdAt
            FROM cognitive_episode
            ORDER BY endTime DESC
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return parseEpisode(statement: statement!)
    }

    public static func getEpisodeForFrame(db: OpaquePointer, frameId: Int64) throws -> CognitiveEpisode? {
        let sql = """
            SELECT e.id, e.startTime, e.endTime, e.title, e.summary, e.primaryAppBundleID, e.keyframeIDs, e.createdAt
            FROM cognitive_episode e
            JOIN episode_frame ef ON e.id = ef.episodeId
            WHERE ef.frameId = ?
            LIMIT 1;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, frameId)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return parseEpisode(statement: statement!)
    }

    public static func getEpisodes(
        db: OpaquePointer,
        from startDateMs: Int64,
        to endDateMs: Int64,
        limit: Int
    ) throws -> [CognitiveEpisode] {
        let sql = """
            SELECT id, startTime, endTime, title, summary, primaryAppBundleID, keyframeIDs, createdAt
            FROM cognitive_episode
            WHERE endTime >= ? AND startTime <= ?
            ORDER BY startTime DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, startDateMs)
        sqlite3_bind_int64(statement, 2, endDateMs)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var episodes: [CognitiveEpisode] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            episodes.append(parseEpisode(statement: statement!))
        }
        return episodes
    }

    // MARK: - Episode Frame Links

    public static func linkFrameToEpisode(
        db: OpaquePointer,
        episodeId: Int64,
        frameId: Int64,
        salienceScore: Double,
        isKeyframe: Bool
    ) throws {
        let sql = """
            INSERT OR REPLACE INTO episode_frame (episodeId, frameId, salienceScore, isKeyframe)
            VALUES (?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, episodeId)
        sqlite3_bind_int64(statement, 2, frameId)
        sqlite3_bind_double(statement, 3, salienceScore)
        sqlite3_bind_int(statement, 4, isKeyframe ? 1 : 0)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    public static func getKeyframesForEpisode(db: OpaquePointer, episodeId: Int64) throws -> [Int64] {
        let sql = """
            SELECT frameId
            FROM episode_frame
            WHERE episodeId = ? AND isKeyframe = 1
            ORDER BY salienceScore DESC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, episodeId)

        var keyframeIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            keyframeIDs.append(sqlite3_column_int64(statement, 0))
        }
        return keyframeIDs
    }

    // MARK: - Memory Entities

    public static func upsertEntity(
        db: OpaquePointer,
        entityType: String,
        normalizedValue: String,
        displayName: String,
        timestampMs: Int64
    ) throws -> Int64 {
        let sql = """
            INSERT INTO memory_entity (entityType, normalizedValue, displayName, firstSeenAt, lastSeenAt, occurrenceCount)
            VALUES (?, ?, ?, ?, ?, 1)
            ON CONFLICT(normalizedValue) DO UPDATE SET
                lastSeenAt = MAX(lastSeenAt, excluded.lastSeenAt),
                occurrenceCount = occurrenceCount + 1,
                displayName = CASE WHEN LENGTH(excluded.displayName) > LENGTH(displayName) THEN excluded.displayName ELSE displayName END;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(statement, 1, entityType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, normalizedValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, displayName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, timestampMs)
        sqlite3_bind_int64(statement, 5, timestampMs)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        // Return entity id
        if let existing = try findEntity(db: db, normalizedValue: normalizedValue) {
            return existing.id
        }
        return sqlite3_last_insert_rowid(db)
    }

    public static func findEntity(db: OpaquePointer, normalizedValue: String) throws -> MemoryEntity? {
        let sql = """
            SELECT id, entityType, normalizedValue, displayName, firstSeenAt, lastSeenAt, occurrenceCount
            FROM memory_entity
            WHERE normalizedValue = ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(statement, 1, normalizedValue, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return parseEntity(statement: statement!)
    }

    public static func findEntities(
        db: OpaquePointer,
        type: String? = nil,
        prefix: String? = nil,
        limit: Int = 20
    ) throws -> [MemoryEntity] {
        var conditions: [String] = []
        if type != nil { conditions.append("entityType = ?") }
        if prefix != nil { conditions.append("normalizedValue LIKE ?") }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT id, entityType, normalizedValue, displayName, firstSeenAt, lastSeenAt, occurrenceCount
            FROM memory_entity
            \(whereClause)
            ORDER BY occurrenceCount DESC, lastSeenAt DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var bindIdx: Int32 = 1
        if let type {
            sqlite3_bind_text(statement, bindIdx, type, -1, SQLITE_TRANSIENT)
            bindIdx += 1
        }
        if let prefix {
            let pattern = "\(prefix)%"
            sqlite3_bind_text(statement, bindIdx, pattern, -1, SQLITE_TRANSIENT)
            bindIdx += 1
        }
        sqlite3_bind_int(statement, bindIdx, Int32(limit))

        var entities: [MemoryEntity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entities.append(parseEntity(statement: statement!))
        }
        return entities
    }

    // MARK: - Entity Mentions

    public static func recordMention(
        db: OpaquePointer,
        entityId: Int64,
        frameId: Int64,
        confidence: Double
    ) throws {
        let sql = """
            INSERT OR REPLACE INTO entity_mention (entityId, frameId, confidence)
            VALUES (?, ?, ?);
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, entityId)
        sqlite3_bind_int64(statement, 2, frameId)
        sqlite3_bind_double(statement, 3, confidence)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    public static func getEntitiesForFrame(db: OpaquePointer, frameId: Int64) throws -> [MemoryEntity] {
        let sql = """
            SELECT e.id, e.entityType, e.normalizedValue, e.displayName, e.firstSeenAt, e.lastSeenAt, e.occurrenceCount
            FROM memory_entity e
            JOIN entity_mention em ON e.id = em.entityId
            WHERE em.frameId = ?
            ORDER BY em.confidence DESC, e.occurrenceCount DESC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, frameId)

        var entities: [MemoryEntity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entities.append(parseEntity(statement: statement!))
        }
        return entities
    }

    public static func getFramesForEntity(db: OpaquePointer, entityId: Int64, limit: Int) throws -> [Int64] {
        let sql = """
            SELECT em.frameId
            FROM entity_mention em
            JOIN frame f ON em.frameId = f.id
            WHERE em.entityId = ?
            ORDER BY f.createdAt DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, entityId)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var frameIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            frameIDs.append(sqlite3_column_int64(statement, 0))
        }
        return frameIDs
    }

    // MARK: - Entity Associations (Knowledge Graph Edges)

    public static func recordCoOccurrence(
        db: OpaquePointer,
        sourceEntityId: Int64,
        targetEntityId: Int64,
        timestampMs: Int64
    ) throws {
        guard sourceEntityId != targetEntityId else { return }

        // Always record bi-directional edges (symmetric graph)
        let pairs = [(sourceEntityId, targetEntityId), (targetEntityId, sourceEntityId)]
        let sql = """
            INSERT INTO entity_association (sourceEntityId, targetEntityId, weight, coOccurrenceCount, lastCoOccurredAt)
            VALUES (?, ?, 1.0, 1, ?)
            ON CONFLICT(sourceEntityId, targetEntityId) DO UPDATE SET
                weight = weight + 1.0,
                coOccurrenceCount = coOccurrenceCount + 1,
                lastCoOccurredAt = MAX(lastCoOccurredAt, excluded.lastCoOccurredAt);
            """

        for (src, tgt) in pairs {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }

            sqlite3_bind_int64(statement, 1, src)
            sqlite3_bind_int64(statement, 2, tgt)
            sqlite3_bind_int64(statement, 3, timestampMs)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public static func getAssociatedEntities(
        db: OpaquePointer,
        sourceEntityId: Int64,
        limit: Int
    ) throws -> [(entity: MemoryEntity, weight: Double)] {
        let sql = """
            SELECT e.id, e.entityType, e.normalizedValue, e.displayName, e.firstSeenAt, e.lastSeenAt, e.occurrenceCount, ea.weight
            FROM memory_entity e
            JOIN entity_association ea ON e.id = ea.targetEntityId
            WHERE ea.sourceEntityId = ?
            ORDER BY ea.weight DESC, e.occurrenceCount DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, sourceEntityId)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var results: [(entity: MemoryEntity, weight: Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let entity = parseEntity(statement: statement!)
            let weight = sqlite3_column_double(statement, 7)
            results.append((entity: entity, weight: weight))
        }
        return results
    }

    // MARK: - Keyframe Vector Metadata

    public static func recordVectorMetadata(
        db: OpaquePointer,
        frameId: Int64,
        vectorOffset: Int,
        dimensions: Int,
        modelName: String,
        createdAtMs: Int64
    ) throws {
        let sql = """
            INSERT OR REPLACE INTO keyframe_vector_metadata (frameId, vectorOffset, dimensions, modelName, createdAt)
            VALUES (?, ?, ?, ?, ?);
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_int64(statement, 1, frameId)
        sqlite3_bind_int(statement, 2, Int32(vectorOffset))
        sqlite3_bind_int(statement, 3, Int32(dimensions))
        sqlite3_bind_text(statement, 4, modelName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 5, createdAtMs)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    public static func getAllVectorMetadata(db: OpaquePointer) throws -> [(frameId: Int64, offset: Int, dimensions: Int)] {
        let sql = """
            SELECT frameId, vectorOffset, dimensions
            FROM keyframe_vector_metadata
            ORDER BY vectorOffset ASC;
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }

        var results: [(frameId: Int64, offset: Int, dimensions: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let frameId = sqlite3_column_int64(statement, 0)
            let offset = Int(sqlite3_column_int(statement, 1))
            let dims = Int(sqlite3_column_int(statement, 2))
            results.append((frameId: frameId, offset: offset, dimensions: dims))
        }
        return results
    }

    // MARK: - Parsers & Helpers

    private static func parseEpisode(statement: OpaquePointer) -> CognitiveEpisode {
        let id = sqlite3_column_int64(statement, 0)
        let startTime = Schema.timestampToDate(sqlite3_column_int64(statement, 1))
        let endTime = Schema.timestampToDate(sqlite3_column_int64(statement, 2))
        let title = getTextOrNil(statement, 3)
        let summary = getTextOrNil(statement, 4)
        let primaryApp = getTextOrNil(statement, 5)
        let keyframesJSON = getTextOrNil(statement, 6)
        let createdAt = Schema.timestampToDate(sqlite3_column_int64(statement, 7))

        var keyframeIDs: [Int64] = []
        if let json = keyframesJSON?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Int64].self, from: json) {
            keyframeIDs = decoded
        }

        return CognitiveEpisode(
            id: id,
            startTime: startTime,
            endTime: endTime,
            title: title,
            summary: summary,
            primaryAppBundleID: primaryApp,
            keyframeIDs: keyframeIDs,
            createdAt: createdAt
        )
    }

    private static func parseEntity(statement: OpaquePointer) -> MemoryEntity {
        let id = sqlite3_column_int64(statement, 0)
        let typeStr = getTextOrEmpty(statement, 1)
        let entityType = MemoryEntityType(rawValue: typeStr) ?? .topic
        let norm = getTextOrEmpty(statement, 2)
        let display = getTextOrEmpty(statement, 3)
        let firstSeen = Schema.timestampToDate(sqlite3_column_int64(statement, 4))
        let lastSeen = Schema.timestampToDate(sqlite3_column_int64(statement, 5))
        let occurrences = Int(sqlite3_column_int(statement, 6))

        return MemoryEntity(
            id: id,
            entityType: entityType,
            normalizedValue: norm,
            displayName: display,
            firstSeenAt: firstSeen,
            lastSeenAt: lastSeen,
            occurrenceCount: occurrences
        )
    }

    private static func bindTextOrNull(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func getTextOrNil(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private static func getTextOrEmpty(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }
}
