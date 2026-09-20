import Foundation
import Shared

/// Cross-referencing Knowledge Mesh manager.
/// Harvests structured entities (files, URLs, symbols, issue tickets, collaborators) from
/// screen OCR text and window context, and maintains an associative co-occurrence graph.
public actor EntityMeshManager: EntityMeshProtocol {

    // MARK: - Dependencies

    private let database: any DatabaseProtocol

    // Regex matchers for entity extraction
    private let urlRegex = try? NSRegularExpression(
        pattern: #"(https?://[a-zA-Z0-9_\-\.]+(?:\.[a-zA-Z]{2,})+(?:/[^\s"<>]*)?)"#,
        options: [.caseInsensitive]
    )
    private let filePathRegex = try? NSRegularExpression(
        pattern: #"(?:^|\s)(/(?:Users|Applications|System|Library|var|private|[a-zA-Z0-9_\-\.]+)/[a-zA-Z0-9_\-\./]+\.[a-zA-Z0-9]{1,8}|[a-zA-Z0-9_\-]+\.(?:swift|py|ts|tsx|js|jsx|go|rs|cpp|c|h|hpp|json|yaml|yml|sql|md|sh))"#,
        options: [.caseInsensitive]
    )
    private let ticketRegex = try? NSRegularExpression(
        pattern: #"\b([A-Z]{2,10}-\d{1,6})\b"#,
        options: []
    )
    private let mentionRegex = try? NSRegularExpression(
        pattern: #"(?:^|\s)@([a-zA-Z0-9_\.\-]{3,30})\b"#,
        options: []
    )
    private let emailRegex = try? NSRegularExpression(
        pattern: #"\b([a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)\b"#,
        options: [.caseInsensitive]
    )

    // MARK: - Initialization

    public init(database: any DatabaseProtocol) {
        self.database = database
    }

    // MARK: - Entity Harvesting

    public func harvestEntities(
        from text: String,
        appName: String?,
        windowTitle: String?,
        browserURL: String?,
        frameID: Int64,
        episodeID: Int64?
    ) async throws -> [MemoryEntity] {
        var harvested: [MemoryEntity] = []
        var discoveredIDs: [Int64] = []
        let now = Date()

        // 1. Browser URL entity
        if let browserURL, !browserURL.isEmpty, let url = URL(string: browserURL) {
            let normHost = url.host?.lowercased() ?? browserURL.lowercased()
            let entId = try await database.upsertMemoryEntity(
                entityType: MemoryEntityType.url.rawValue,
                normalizedValue: normHost,
                displayName: browserURL,
                timestamp: now
            )
            discoveredIDs.append(entId)
            harvested.append(MemoryEntity(
                id: entId,
                entityType: .url,
                normalizedValue: normHost,
                displayName: browserURL,
                firstSeenAt: now,
                lastSeenAt: now
            ))
        }

        // 2. Extract embedded URLs from OCR
        for match in extractMatches(regex: urlRegex, in: text) {
            let norm = match.lowercased()
            let entId = try await database.upsertMemoryEntity(
                entityType: MemoryEntityType.url.rawValue,
                normalizedValue: norm,
                displayName: match,
                timestamp: now
            )
            discoveredIDs.append(entId)
            harvested.append(MemoryEntity(
                id: entId,
                entityType: .url,
                normalizedValue: norm,
                displayName: match,
                firstSeenAt: now,
                lastSeenAt: now
            ))
        }

        // 3. Extract File Paths
        let allContext = [text, windowTitle ?? ""].joined(separator: " ")
        for match in extractMatches(regex: filePathRegex, in: allContext) {
            let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { continue }
            let norm = trimmed.lowercased()
            let entId = try await database.upsertMemoryEntity(
                entityType: MemoryEntityType.file.rawValue,
                normalizedValue: norm,
                displayName: trimmed,
                timestamp: now
            )
            discoveredIDs.append(entId)
            harvested.append(MemoryEntity(
                id: entId,
                entityType: .file,
                normalizedValue: norm,
                displayName: trimmed,
                firstSeenAt: now,
                lastSeenAt: now
            ))
        }

        // 4. Extract Tickets (Linear, Jira)
        for match in extractMatches(regex: ticketRegex, in: allContext) {
            let norm = match.uppercased()
            let entId = try await database.upsertMemoryEntity(
                entityType: MemoryEntityType.ticket.rawValue,
                normalizedValue: norm,
                displayName: norm,
                timestamp: now
            )
            discoveredIDs.append(entId)
            harvested.append(MemoryEntity(
                id: entId,
                entityType: .ticket,
                normalizedValue: norm,
                displayName: norm,
                firstSeenAt: now,
                lastSeenAt: now
            ))
        }

        // 5. Extract People (@mentions & emails)
        for match in extractMatches(regex: mentionRegex, in: text) {
            let norm = "@" + match.lowercased()
            let entId = try await database.upsertMemoryEntity(
                entityType: MemoryEntityType.person.rawValue,
                normalizedValue: norm,
                displayName: "@" + match,
                timestamp: now
            )
            discoveredIDs.append(entId)
            harvested.append(MemoryEntity(
                id: entId,
                entityType: .person,
                normalizedValue: norm,
                displayName: "@" + match,
                firstSeenAt: now,
                lastSeenAt: now
            ))
        }

        for match in extractMatches(regex: emailRegex, in: text) {
            let norm = match.lowercased()
            let entId = try await database.upsertMemoryEntity(
                entityType: MemoryEntityType.person.rawValue,
                normalizedValue: norm,
                displayName: match,
                timestamp: now
            )
            discoveredIDs.append(entId)
            harvested.append(MemoryEntity(
                id: entId,
                entityType: .person,
                normalizedValue: norm,
                displayName: match,
                firstSeenAt: now,
                lastSeenAt: now
            ))
        }

        // Record mentions for this frame
        let uniqueIDs = Array(Set(discoveredIDs))
        for entId in uniqueIDs {
            try await database.recordEntityMention(entityId: entId, frameId: frameID, confidence: 1.0)
        }

        // Record co-occurrence edges between all entities in this frame
        if uniqueIDs.count >= 2 {
            for i in 0..<uniqueIDs.count {
                for j in (i + 1)..<uniqueIDs.count {
                    try await database.recordEntityCoOccurrence(
                        sourceEntityId: uniqueIDs[i],
                        targetEntityId: uniqueIDs[j],
                        timestamp: now
                    )
                }
            }
        }

        return harvested
    }

    // MARK: - Graph Traversal

    public func findEntities(
        type: String? = nil,
        prefix: String? = nil,
        limit: Int = 20
    ) async throws -> [MemoryEntity] {
        try await database.findMemoryEntities(type: type, prefix: prefix, limit: limit)
    }

    public func findAssociatedEntities(
        for entityID: Int64,
        limit: Int = 10
    ) async throws -> [(entity: MemoryEntity, weight: Double)] {
        try await database.getAssociatedEntities(sourceEntityId: entityID, limit: limit)
    }

    public func findFramesForEntity(
        normalizedValue: String,
        limit: Int = 30
    ) async throws -> [Int64] {
        guard let entity = try await database.findMemoryEntity(normalizedValue: normalizedValue) else {
            return []
        }
        return try await database.getFramesForEntity(entityId: entity.id, limit: limit)
    }

    // MARK: - Private Helpers

    private func extractMatches(regex: NSRegularExpression?, in text: String) -> [String] {
        guard let regex, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var results: [String] = []
        for match in matches {
            // Prefer capture group 1 if present
            let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            if let swiftRange = Range(captureRange, in: text) {
                let matchedStr = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !matchedStr.isEmpty {
                    results.append(matchedStr)
                }
            }
        }
        return results
    }
}
