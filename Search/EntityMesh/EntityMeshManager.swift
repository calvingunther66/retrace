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
        var rawCandidates: [(entityType: String, normalizedValue: String, displayName: String)] = []
        let now = Date()

        // 1. Browser URL entity
        if let browserURL, !browserURL.isEmpty, let url = URL(string: browserURL) {
            let normHost = url.host?.lowercased() ?? browserURL.lowercased()
            rawCandidates.append((
                entityType: MemoryEntityType.url.rawValue,
                normalizedValue: normHost,
                displayName: browserURL
            ))
        }

        // 2. Extract embedded URLs from OCR
        for match in extractMatches(regex: urlRegex, in: text) {
            let norm = match.lowercased()
            rawCandidates.append((
                entityType: MemoryEntityType.url.rawValue,
                normalizedValue: norm,
                displayName: match
            ))
        }

        // 3. Extract File Paths
        let allContext = [text, windowTitle ?? ""].joined(separator: " ")
        for match in extractMatches(regex: filePathRegex, in: allContext) {
            let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { continue }
            let norm = trimmed.lowercased()
            rawCandidates.append((
                entityType: MemoryEntityType.file.rawValue,
                normalizedValue: norm,
                displayName: trimmed
            ))
        }

        // 4. Extract Tickets (Linear, Jira)
        for match in extractMatches(regex: ticketRegex, in: allContext) {
            let norm = match.uppercased()
            rawCandidates.append((
                entityType: MemoryEntityType.ticket.rawValue,
                normalizedValue: norm,
                displayName: norm
            ))
        }

        // 5. Extract People (@mentions & emails)
        for match in extractMatches(regex: mentionRegex, in: text) {
            let norm = "@" + match.lowercased()
            rawCandidates.append((
                entityType: MemoryEntityType.person.rawValue,
                normalizedValue: norm,
                displayName: "@" + match
            ))
        }

        for match in extractMatches(regex: emailRegex, in: text) {
            let norm = match.lowercased()
            rawCandidates.append((
                entityType: MemoryEntityType.person.rawValue,
                normalizedValue: norm,
                displayName: match
            ))
        }

        // In-memory deduplication by (entityType, normalizedValue) and cap at 25 to prevent edge explosion
        var seen = Set<String>()
        var dedupedCandidates: [(entityType: String, normalizedValue: String, displayName: String)] = []
        for candidate in rawCandidates {
            let key = "\(candidate.entityType):\(candidate.normalizedValue)"
            if seen.insert(key).inserted {
                dedupedCandidates.append(candidate)
                if dedupedCandidates.count >= 25 {
                    break
                }
            }
        }

        guard !dedupedCandidates.isEmpty else {
            return []
        }

        return try await database.recordFrameEntities(
            frameId: frameID,
            timestamp: now,
            entities: dedupedCandidates
        )
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
