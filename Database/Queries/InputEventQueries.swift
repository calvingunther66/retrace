import Foundation
import SQLCipher
import Shared

/// Frame facts for deciding whether a frame may be exported, and where its pixels live.
public struct InputExportFrameInfo: Sendable, Equatable {
    public let frameID: Int64
    public let createdAtMs: Int64
    /// Non-nil when capture blurred part of the frame.
    public let redactionReason: String?
    /// 0 pending, 1 processing, 2 done, 3 failed, 4 not yet readable, 5-8 rewrite states.
    public let processingStatus: Int?
    /// `redaction` | `deletion` | nil.
    public let rewritePurpose: String?
    public let rewrittenAtMs: Int64?
    public let encodedAtMs: Int64?
    public let displayID: UInt32?
    public let videoFrameIndex: Int?
    public let videoPath: String?
    public let videoFrameRate: Double?
    public let videoWidth: Int?
    public let videoHeight: Int?
    /// 0 = finalized, 1 = still being written.
    public let videoProcessingState: Int?
    public let bundleID: String?
    public let windowName: String?
    public let browserURL: String?
    /// The segment carries the built-in `hidden` tag.
    public let isHidden: Bool
}

/// CRUD and frame-link resolution for `input_event` / `input_event_ax` (V24).
///
/// Privacy: typed characters have no column here. Typing is `typedCount` only; shortcuts are
/// `keyCombo` only. Events whose accessibility target is a secure text field are refused at insert
/// as a last line of defence (capture is expected to have dropped them already).
public enum InputEventQueries {

    // MARK: - Link Resolution Tuning

    /// A click's "after" frame must be taken at least this long after mouse-up. The scheduler's click
    /// settle delay is 150ms, so a frame stamped earlier is still mid-transition.
    static let settleAfterActionMs: Int64 = 120

    // MARK: - Columns

    /// Insert/select column order; the binder and the row reader both follow this list.
    private static let columns: [String] = [
        "tsMs", "endTsMs", "kind", "button", "clickCount", "mods",
        "x", "y", "scrollDx", "scrollDy", "keyCombo", "typedCount",
        "displayId", "displayPixelWidth", "displayPixelHeight", "displayScale", "displays",
        "bundleId", "windowTitle", "windowX", "windowY", "windowW", "windowH",
        "axRole", "axSubrole", "axTitle", "axIdentifier", "axX", "axY", "axW", "axH",
        "preFrameId", "preGapMs", "downFrameTsMs", "downFrameId", "postFrameId",
        "linkState", "privacyState", "redacted"
    ]

    // MARK: - Insert

    /// Insert events (and their AX snapshots) in one transaction. Returns the new row ids in order,
    /// excluding any event refused for targeting a secure text field.
    @discardableResult
    static func insertBatch(db: OpaquePointer, events: [InputEvent]) throws -> [Int64] {
        let accepted = events.filter { !($0.axTarget?.isSecureTextField ?? false) }
        guard !accepted.isEmpty else { return [] }

        let sql = """
            INSERT INTO input_event (\(columns.joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")));
            """

        let ownsTransaction = sqlite3_get_autocommit(db) != 0
        if ownsTransaction {
            try exec(db, "BEGIN IMMEDIATE;")
        }

        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            var ids: [Int64] = []
            ids.reserveCapacity(accepted.count)

            for event in accepted {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                var bind = Binder(statement: statement)

                bind.int64(event.tsMs)
                bind.int64(event.endTsMs)
                bind.text(event.kind.rawValue)
                bind.text(event.button)
                bind.int64(event.clickCount.map(Int64.init))
                bind.text(event.modifiers.isEmpty ? nil : event.modifiers.joined(separator: ","))
                bind.double(event.x)
                bind.double(event.y)
                bind.double(event.scrollDx)
                bind.double(event.scrollDy)
                bind.text(event.keyCombo)
                bind.int64(event.typedCount.map(Int64.init))
                bind.int64(event.displayID.map(Int64.init))
                bind.int64(event.displayPixelWidth.map(Int64.init))
                bind.int64(event.displayPixelHeight.map(Int64.init))
                bind.double(event.displayScale)
                bind.text(event.displays.isEmpty ? nil : (try? encoder.encode(event.displays)).flatMap { String(data: $0, encoding: .utf8) })
                bind.text(event.bundleID)
                bind.text(event.windowTitle)
                bind.double(event.windowX)
                bind.double(event.windowY)
                bind.double(event.windowWidth)
                bind.double(event.windowHeight)
                bind.text(event.axTarget?.role)
                bind.text(event.axTarget?.subrole)
                bind.text(event.axTarget?.title)
                bind.text(event.axTarget?.identifier)
                bind.double(event.axTarget?.x)
                bind.double(event.axTarget?.y)
                bind.double(event.axTarget?.width)
                bind.double(event.axTarget?.height)
                bind.int64(event.preFrameID)
                bind.int64(event.preGapMs)
                bind.int64(event.downFrameTsMs)
                bind.int64(event.downFrameID)
                bind.int64(event.postFrameID)
                bind.int64(Int64(event.linkState.rawValue))
                bind.text(event.privacyState)
                bind.int64(event.redacted ? 1 : 0)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
                }
                let rowID = sqlite3_last_insert_rowid(db)
                ids.append(rowID)

                if !event.axElements.isEmpty {
                    try writeAXElements(db: db, eventID: rowID, elements: event.axElements, encoder: encoder)
                }
            }

            if ownsTransaction {
                try exec(db, "COMMIT;")
            }
            return ids
        } catch {
            if ownsTransaction {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
            throw error
        }
    }

    private static func writeAXElements(
        db: OpaquePointer,
        eventID: Int64,
        elements: [InputAXElement],
        encoder: JSONEncoder
    ) throws {
        let json = try encoder.encode(elements)
        let compressed = try (json as NSData).compressed(using: .zlib) as Data

        let sql = "INSERT OR REPLACE INTO input_event_ax (eventId, elements) VALUES (?, ?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, eventID)
        _ = compressed.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Read

    static func fetch(db: OpaquePointer, id: Int64) throws -> InputEvent? {
        let sql = "SELECT id, \(columns.joined(separator: ", ")) FROM input_event WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return readEvent(statement)
    }

    /// Events with `sinceMs <= tsMs < untilMs`, oldest first, paged by `afterID` (exclusive).
    static func fetchRange(
        db: OpaquePointer,
        sinceMs: Int64,
        untilMs: Int64,
        kinds: [InputEventKind]? = nil,
        afterID: Int64 = 0,
        limit: Int = 500
    ) throws -> [InputEvent] {
        var sql = """
            SELECT id, \(columns.joined(separator: ", ")) FROM input_event
            WHERE tsMs >= ? AND tsMs < ? AND id > ?
            """
        if let kinds, !kinds.isEmpty {
            // Raw values come from a closed enum, so inlining them is injection-safe.
            sql += " AND kind IN (\(kinds.map { "'\($0.rawValue)'" }.joined(separator: ", ")))"
        }
        sql += " ORDER BY id ASC LIMIT ?;"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, sinceMs)
        sqlite3_bind_int64(statement, 2, untilMs)
        sqlite3_bind_int64(statement, 3, afterID)
        sqlite3_bind_int(statement, 4, Int32(limit))

        var events: [InputEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            events.append(readEvent(statement))
        }
        return events
    }

    static func fetchAXElements(db: OpaquePointer, eventID: Int64) throws -> [InputAXElement] {
        let sql = "SELECT elements FROM input_event_ax WHERE eventId = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, eventID)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else {
            return []
        }
        let length = Int(sqlite3_column_bytes(statement, 0))
        let compressed = Data(bytes: bytes, count: length)
        guard let json = try? (compressed as NSData).decompressed(using: .zlib) as Data else {
            return []
        }
        return (try? JSONDecoder().decode([InputAXElement].self, from: json)) ?? []
    }

    // MARK: - Down-Frame Correlation

    /// Attach the forced mouse-down frame's exact timestamp to an already-stored click. Capture reports
    /// it ~100ms after mouse-down, which can land after the event was flushed. Only fills a NULL, and
    /// only for clicks, so a later report can never overwrite or touch another event kind.
    @discardableResult
    static func setDownFrameTimestamp(db: OpaquePointer, eventTsMs: Int64, frameTsMs: Int64) throws -> Bool {
        let sql = """
            UPDATE input_event SET downFrameTsMs = ?
            WHERE tsMs = ? AND kind = 'click' AND downFrameTsMs IS NULL AND linkState = 0;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, frameTsMs)
        sqlite3_bind_int64(statement, 2, eventTsMs)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_changes(db) > 0
    }

    // MARK: - Link Resolution

    /// Pair pending events with the frames around them, by timestamp.
    ///
    /// Frame ids only exist after the capture pipeline inserts the row, and dedup can drop frames, so
    /// the link is resolved lazily rather than carried through capture:
    /// - `pre`: the strict last frame with `createdAt <= tsMs` (the screen before the action).
    /// - `down`: the forced mouse-down capture, matched by its exact reported timestamp. It can
    ///   already show a pressed button or open menu, so it is never used as `pre`.
    /// - `post`: the first frame at least `settleAfterActionMs` after the action ended, other than `down`.
    ///
    /// An event stays pending until a post frame exists or `giveUpAfterMs` has passed. Frames
    /// redacted at capture time strip window/AX detail from the event.
    static func resolveLinks(
        db: OpaquePointer,
        nowMs: Int64,
        minAgeMs: Int64 = 5_000,
        giveUpAfterMs: Int64 = 30_000,
        limit: Int = 200
    ) throws -> InputEventLinkSummary {
        var summary = InputEventLinkSummary()

        let pendingSQL = """
            SELECT id, tsMs, endTsMs, displayId, downFrameTsMs FROM input_event
            WHERE linkState = 0 AND tsMs <= ?
            ORDER BY tsMs ASC LIMIT ?;
            """
        struct Pending {
            let id: Int64
            let tsMs: Int64
            let endTsMs: Int64?
            let displayID: Int64?
            let downFrameTsMs: Int64?
        }

        var pending: [Pending] = []
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, pendingSQL, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: pendingSQL, underlying: String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_int64(statement, 1, nowMs - minAgeMs)
            sqlite3_bind_int(statement, 2, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                pending.append(Pending(
                    id: sqlite3_column_int64(statement, 0),
                    tsMs: sqlite3_column_int64(statement, 1),
                    endTsMs: optionalInt64(statement, 2),
                    displayID: optionalInt64(statement, 3),
                    downFrameTsMs: optionalInt64(statement, 4)
                ))
            }
        }
        guard !pending.isEmpty else { return summary }

        let ownsTransaction = sqlite3_get_autocommit(db) != 0
        if ownsTransaction {
            try exec(db, "BEGIN IMMEDIATE;")
        }

        do {
            for event in pending {
                let pre = try lookupFrame(
                    db: db,
                    sql: """
                        SELECT id, createdAt, redactionReason FROM frame
                        WHERE createdAt <= ?1 AND COALESCE(rewritePurpose, '') != 'deletion'
                          AND (?2 IS NULL OR displayId IS NULL OR displayId = ?2)
                        ORDER BY createdAt DESC, id DESC LIMIT 1;
                        """,
                    bind: { statement in
                        sqlite3_bind_int64(statement, 1, event.tsMs)
                        bindOptionalInt64(statement, 2, event.displayID)
                    }
                )

                let down: FrameHit? = try event.downFrameTsMs.flatMap { downTs in
                    try lookupFrame(
                        db: db,
                        sql: """
                            SELECT id, createdAt, redactionReason FROM frame
                            WHERE createdAt = ?1 ORDER BY id DESC LIMIT 1;
                            """,
                        bind: { sqlite3_bind_int64($0, 1, downTs) }
                    )
                }

                let settledAt = max(event.endTsMs ?? event.tsMs, event.tsMs) + settleAfterActionMs
                let post = try lookupFrame(
                    db: db,
                    sql: """
                        SELECT id, createdAt, redactionReason FROM frame
                        WHERE createdAt >= ?1 AND id != ?2 AND COALESCE(rewritePurpose, '') != 'deletion'
                          AND (?3 IS NULL OR displayId IS NULL OR displayId = ?3)
                        ORDER BY createdAt ASC, id ASC LIMIT 1;
                        """,
                    bind: { statement in
                        sqlite3_bind_int64(statement, 1, settledAt)
                        sqlite3_bind_int64(statement, 2, down?.id ?? -1)
                        bindOptionalInt64(statement, 3, event.displayID)
                    }
                )

                let gaveUp = post == nil && (nowMs - event.tsMs) >= giveUpAfterMs
                let state: InputEventLinkState = post != nil ? .resolved : (gaveUp ? .gaveUp : .pending)

                if pre == nil { summary.preMissing += 1 }
                if gaveUp { summary.postMissing += 1 }

                try updateLinks(
                    db: db,
                    eventID: event.id,
                    pre: pre,
                    tsMs: event.tsMs,
                    down: down,
                    post: post,
                    state: state
                )

                if [pre, down, post].contains(where: { $0?.redactionReason != nil }) {
                    try stripRedactedDetail(db: db, eventID: event.id)
                    summary.redacted += 1
                }

                switch state {
                case .resolved: summary.resolved += 1
                case .gaveUp: summary.gaveUp += 1
                case .pending: summary.stillPending += 1
                }
            }

            if ownsTransaction {
                try exec(db, "COMMIT;")
            }
        } catch {
            if ownsTransaction {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
            throw error
        }

        return summary
    }

    private struct FrameHit: Equatable {
        let id: Int64
        let createdAt: Int64
        let redactionReason: String?
    }

    private static func lookupFrame(
        db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer?) -> Void
    ) throws -> FrameHit? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return FrameHit(
            id: sqlite3_column_int64(statement, 0),
            createdAt: sqlite3_column_int64(statement, 1),
            redactionReason: sqlite3_column_text(statement, 2).map { String(cString: $0) }
        )
    }

    private static func updateLinks(
        db: OpaquePointer,
        eventID: Int64,
        pre: FrameHit?,
        tsMs: Int64,
        down: FrameHit?,
        post: FrameHit?,
        state: InputEventLinkState
    ) throws {
        let sql = """
            UPDATE input_event
            SET preFrameId = ?1, preGapMs = ?2, downFrameId = ?3, postFrameId = ?4, linkState = ?5
            WHERE id = ?6;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        bindOptionalInt64(statement, 1, pre?.id)
        bindOptionalInt64(statement, 2, pre.map { tsMs - $0.createdAt })
        bindOptionalInt64(statement, 3, down?.id)
        bindOptionalInt64(statement, 4, post?.id)
        sqlite3_bind_int64(statement, 5, Int64(state.rawValue))
        sqlite3_bind_int64(statement, 6, eventID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// A linked frame was redacted at capture time: drop the text-bearing detail. The app bundle id
    /// stays (capture keeps it on redacted frames too); export skips `redacted` events entirely.
    private static func stripRedactedDetail(db: OpaquePointer, eventID: Int64) throws {
        try execBound(db, """
            UPDATE input_event
            SET redacted = 1, windowTitle = NULL,
                axRole = NULL, axSubrole = NULL, axTitle = NULL, axIdentifier = NULL,
                axX = NULL, axY = NULL, axW = NULL, axH = NULL
            WHERE id = ?;
            """, eventID)
        try execBound(db, "DELETE FROM input_event_ax WHERE eventId = ?;", eventID)
    }

    // MARK: - Export Frame Facts

    /// Everything an exporter needs to decide whether a frame's pixels may leave the machine, and
    /// where to decode them from. One row per frame id; ids that no longer exist are absent.
    static func exportFrameInfo(db: OpaquePointer, frameIDs: [Int64]) throws -> [Int64: InputExportFrameInfo] {
        guard !frameIDs.isEmpty else { return [:] }

        var result: [Int64: InputExportFrameInfo] = [:]
        // Stay well below SQLite's bound-variable limit.
        for chunk in stride(from: 0, to: frameIDs.count, by: 400).map({ Array(frameIDs[$0..<min($0 + 400, frameIDs.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let sql = """
                SELECT f.id, f.createdAt, f.redactionReason, f.processingStatus, f.rewritePurpose,
                       f.rewrittenAt, f.encodedAt, f.displayId, f.videoFrameIndex,
                       v.path, v.frameRate, v.width, v.height, v.processingState,
                       s.bundleID, s.windowName, s.browserUrl,
                       EXISTS (
                           SELECT 1 FROM segment_tag st JOIN tag t ON t.id = st.tagId
                           WHERE st.segmentId = f.segmentId AND t.name = 'hidden'
                       )
                FROM frame f
                LEFT JOIN video v ON v.id = f.videoId
                LEFT JOIN segment s ON s.id = f.segmentId
                WHERE f.id IN (\(placeholders));
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
            }
            for (index, id) in chunk.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), id)
            }

            func text(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            func int(_ column: Int32) -> Int64? { optionalInt64(statement, column) }
            func double(_ column: Int32) -> Double? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                let info = InputExportFrameInfo(
                    frameID: sqlite3_column_int64(statement, 0),
                    createdAtMs: sqlite3_column_int64(statement, 1),
                    redactionReason: text(2),
                    processingStatus: int(3).map(Int.init),
                    rewritePurpose: text(4),
                    rewrittenAtMs: int(5),
                    encodedAtMs: int(6),
                    displayID: int(7).map { UInt32(truncatingIfNeeded: $0) },
                    videoFrameIndex: int(8).map(Int.init),
                    videoPath: text(9),
                    videoFrameRate: double(10),
                    videoWidth: int(11).map(Int.init),
                    videoHeight: int(12).map(Int.init),
                    videoProcessingState: int(13).map(Int.init),
                    bundleID: text(14),
                    windowName: text(15),
                    browserURL: text(16),
                    isHidden: (int(17) ?? 0) != 0
                )
                result[info.frameID] = info
            }
        }
        return result
    }

    // MARK: - Retention

    /// Delete events older than `cutoffMs`, at most `limit` rows. AX snapshots cascade.
    static func deleteOlderThan(db: OpaquePointer, cutoffMs: Int64, limit: Int = 500) throws -> Int {
        let sql = """
            DELETE FROM input_event
            WHERE id IN (SELECT id FROM input_event WHERE tsMs < ? ORDER BY tsMs ASC LIMIT ?);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, cutoffMs)
        sqlite3_bind_int(statement, 2, Int32(limit))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: - Row Reading

    private static func readEvent(_ statement: OpaquePointer?) -> InputEvent {
        // Column 0 is `id`; the rest follow `columns`.
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        func int64(_ index: Int32) -> Int64? { optionalInt64(statement, index) }
        func double(_ index: Int32) -> Double? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
        }

        var axTarget: InputAXTarget?
        if text(24) != nil || text(25) != nil || text(26) != nil || text(27) != nil || double(28) != nil {
            axTarget = InputAXTarget(
                role: text(24),
                subrole: text(25),
                title: text(26),
                identifier: text(27),
                x: double(28),
                y: double(29),
                width: double(30),
                height: double(31)
            )
        }

        let displays: [InputDisplayGeometry] = text(17)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([InputDisplayGeometry].self, from: $0) } ?? []

        return InputEvent(
            id: sqlite3_column_int64(statement, 0),
            tsMs: sqlite3_column_int64(statement, 1),
            endTsMs: int64(2),
            kind: text(3).flatMap(InputEventKind.init(rawValue:)) ?? .click,
            button: text(4),
            clickCount: int64(5).map(Int.init),
            modifiers: text(6)?.split(separator: ",").map(String.init) ?? [],
            x: double(7),
            y: double(8),
            scrollDx: double(9),
            scrollDy: double(10),
            keyCombo: text(11),
            typedCount: int64(12).map(Int.init),
            displayID: int64(13).map { UInt32(truncatingIfNeeded: $0) },
            displayPixelWidth: int64(14).map(Int.init),
            displayPixelHeight: int64(15).map(Int.init),
            displayScale: double(16),
            displays: displays,
            bundleID: text(18),
            windowTitle: text(19),
            windowX: double(20),
            windowY: double(21),
            windowWidth: double(22),
            windowHeight: double(23),
            axTarget: axTarget,
            axElements: [],
            preFrameID: int64(32),
            preGapMs: int64(33),
            downFrameTsMs: int64(34),
            downFrameID: int64(35),
            postFrameID: int64(36),
            linkState: int64(37).flatMap { InputEventLinkState(rawValue: Int($0)) } ?? .pending,
            privacyState: text(38) ?? InputEvent.privacyOK,
            redacted: (int64(39) ?? 0) != 0
        )
    }

    // MARK: - SQLite Helpers

    private struct Binder {
        let statement: OpaquePointer?
        private var index: Int32 = 0

        init(statement: OpaquePointer?) {
            self.statement = statement
        }

        mutating func int64(_ value: Int64?) {
            index += 1
            if let value { sqlite3_bind_int64(statement, index, value) } else { sqlite3_bind_null(statement, index) }
        }

        mutating func double(_ value: Double?) {
            index += 1
            if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
        }

        mutating func text(_ value: String?) {
            index += 1
            if let value {
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
    }

    private static func optionalInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private static func bindOptionalInt64(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        if let value { sqlite3_bind_int64(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }

    private static func execBound(_ db: OpaquePointer, _ sql: String, _ value: Int64) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(statement, 1, value)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }
}
