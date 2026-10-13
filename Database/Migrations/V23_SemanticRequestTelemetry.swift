import Foundation
import SQLCipher
import Shared

/// V23 Migration: per-request telemetry for the cloud-vision deep-indexing lane.
///
/// `semantic_index_requests` only ever recorded "a request happened and how it ended". That was not
/// enough to answer the questions that decide how big a batch can safely be: did the model stop
/// because of `max_tokens`, how many bytes/tokens did a request carry, how long did it take, which
/// batch size / arm sent it, and was a failure a real HTTP error or an HTTP-200 envelope carrying an
/// upstream error. All columns are nullable and written best-effort; there is no backfill.
struct V23_SemanticRequestTelemetry: Migration {
    let version = 23

    private static let columns: [(name: String, type: String)] = [
        ("bodyBytes", "INTEGER"),
        ("promptTokens", "INTEGER"),
        ("completionTokens", "INTEGER"),
        ("finishReason", "TEXT"),
        ("latencyMs", "INTEGER"),
        ("parsedCount", "INTEGER"),
        ("contentEmpty", "INTEGER"),
        ("batchTarget", "INTEGER"),
        ("arm", "TEXT"),
        ("errorKind", "TEXT")
    ]

    func migrate(db: OpaquePointer) async throws {
        Log.info("🧠 Verifying V23 semantic request telemetry schema...", category: .database)
        for column in Self.columns {
            if try hasColumn(db: db, table: "semantic_index_requests", column: column.name) {
                Log.debug("✓ semantic_index_requests.\(column.name) already exists")
                continue
            }
            try execute(
                db: db,
                sql: "ALTER TABLE semantic_index_requests ADD COLUMN \(column.name) \(column.type);"
            )
            Log.debug("✓ Added semantic_index_requests.\(column.name)")
        }
        Log.info("✅ V23 migration completed: semantic request telemetry columns present", category: .database)
    }

    private func execute(db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError.migrationFailed(version: version, underlying: message)
        }
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
            if let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }), name == column {
                return true
            }
        }
        return false
    }
}
