import Foundation
import Shared

/// Main search manager implementing SearchProtocol
/// Coordinates query parsing, FTS search, and result ranking
public actor SearchManager: SearchProtocol {

    // MARK: - Dependencies

    private let database: any DatabaseProtocol
    private let ftsEngine: any FTSProtocol
    private let queryParser: QueryParser
    private let resultRanker: ResultRanker
    // ⚠️ RELEASE 2 ONLY - Search highlighting removed for Release 1
    // private let snippetGenerator: SnippetGenerator

    // MARK: - State

    private var config: SearchConfig
    private var isInitialized = false

    // Statistics
    private var totalSearches = 0
    private var searchTimes: [Double] = []

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        ftsEngine: any FTSProtocol
    ) {
        self.database = database
        self.ftsEngine = ftsEngine
        self.queryParser = QueryParser()
        self.resultRanker = ResultRanker()
        // ⚠️ RELEASE 2 ONLY - Search highlighting removed for Release 1
        // self.snippetGenerator = SnippetGenerator()
        self.config = .default
    }

    // MARK: - SearchProtocol: Lifecycle

    public func initialize(config: SearchConfig) async throws {
        self.config = config
        isInitialized = true
        Log.info("Search manager initialized", category: .search)
    }

    // MARK: - SearchProtocol: Full-Text Search

    public func search(query: SearchQuery) async throws -> SearchResults {
        try await performSearch(query: query, matchAny: false)
    }

    /// Search tailored for building "Ask AI" context from a raw natural-language question rather
    /// than a deliberate keyword search. `search(query:)` ANDs every significant term together
    /// (required so a precise keyword search stays precise), which means a full question like
    /// "when was my 5 hour window going to reset" — 8+ significant tokens that must ALL appear
    /// verbatim in the same frame's OCR text — matches essentially nothing. This ORs the terms
    /// instead (after dropping common stopwords, so "the"/"was"/"to" don't just match everything
    /// and drown out the terms that actually matter), so the AI gets whatever frames are at least
    /// loosely related instead of a hard "no matching records" every time someone asks a real
    /// question instead of typing search keywords.
    public func searchForAIContext(question: String, filters: SearchFilters = .none, limit: Int = 30) async throws -> SearchResults {
        let query = SearchQuery(text: question, filters: filters, limit: limit, offset: 0)
        return try await performSearch(query: query, matchAny: true)
    }

    private func performSearch(query: SearchQuery, matchAny: Bool) async throws -> SearchResults {
        guard isInitialized else {
            Log.error("[SearchManager] Search attempted before search manager is initialized", category: .search)
            throw SearchError.indexNotReady
        }

        let startTime = Date()

        // Validate query
        let validationErrors = queryParser.validate(query: query)
        if !validationErrors.isEmpty {
            let reason = validationErrors.first?.message ?? "Invalid query"
            let error = SearchError.invalidQuery(reason: reason)
            Log.warning("[SearchManager] Invalid search query '\(query.text)': \(reason)", category: .search)
            throw error
        }

        // Parse query
        let parsed = try queryParser.parse(rawQuery: query.text)

        // Build FTS query
        let searchableColumnsFTSQuery = Self.buildScopedFTSQuery(for: parsed, matchAny: matchAny)
        Log.debug("[SearchManager] Raw query: '\(query.text)' → FTS query: '\(searchableColumnsFTSQuery)' | terms: \(parsed.searchTerms) | phrases: \(parsed.phrases) | excluded: \(parsed.excludedTerms)", category: .search)

        // Build filters
        var filters = query.filters
        if let appFilter = parsed.appFilter {
            filters = SearchFilters(
                startDate: filters.startDate ?? parsed.dateRange.start,
                endDate: filters.endDate ?? parsed.dateRange.end,
                dateRanges: filters.dateRanges,
                appBundleIDs: [appFilter],
                excludedAppBundleIDs: filters.excludedAppBundleIDs,
                selectedTagIds: filters.selectedTagIds,
                excludedTagIds: filters.excludedTagIds,
                hiddenFilter: filters.hiddenFilter,
                commentFilter: filters.commentFilter,
                windowNameFilter: filters.windowNameFilter,
                browserUrlFilter: filters.browserUrlFilter
            )
        } else if parsed.dateRange.start != nil || parsed.dateRange.end != nil {
            filters = SearchFilters(
                startDate: filters.startDate ?? parsed.dateRange.start,
                endDate: filters.endDate ?? parsed.dateRange.end,
                dateRanges: filters.dateRanges,
                appBundleIDs: filters.appBundleIDs,
                excludedAppBundleIDs: filters.excludedAppBundleIDs,
                selectedTagIds: filters.selectedTagIds,
                excludedTagIds: filters.excludedTagIds,
                hiddenFilter: filters.hiddenFilter,
                commentFilter: filters.commentFilter,
                windowNameFilter: filters.windowNameFilter,
                browserUrlFilter: filters.browserUrlFilter
            )
        }

        // Execute FTS search (local OCR text — the primary, higher-fidelity index)
        let ftsMatches = try await ftsEngine.search(
            query: searchableColumnsFTSQuery,
            filters: filters,
            limit: query.limit,
            offset: query.offset
        )

        // Also search the AI-generated visual-description index — but only on the first page.
        // OCR and semantic are two independent FTS indexes each paginated by their own
        // rank-ordered offset; merging both on every page would duplicate/skip frames across
        // pages once offset > 0 (there's no way to express "page 2 of the merged, re-ranked
        // set" as an offset into either individual index). Restricting the merge to offset==0
        // means later pages fall back to OCR-only, which is a real limitation (semantic-only
        // matches beyond page 1 won't surface) but a correct one, rather than a subtly broken
        // "correct-looking" merge on every page.
        // Also skip when OCR alone already fills the page — a common case for well-populated
        // OCR indexes with the default page size, and every semantic row fetched in that case
        // would just be discarded by the merge's `mergedMatches.count < query.limit` guard
        // below. Narrowing the limit to the remaining slots (rather than a flat `query.limit`)
        // means semantic never fetches more than it could possibly contribute either.
        let remainingSlots = query.limit - ftsMatches.count
        var semanticMatches: [FTSMatch] = []
        if query.offset == 0 && remainingSlots > 0 {
            let semanticFTSQuery = Self.buildSemanticFTSQuery(for: parsed, matchAny: matchAny)
            do {
                semanticMatches = try await ftsEngine.searchSemantic(
                    query: semanticFTSQuery,
                    filters: filters,
                    limit: remainingSlots,
                    offset: 0
                )
            } catch {
                // Semantic index is an additive enhancement — never let it break OCR search.
                Log.warning("[SearchManager] Semantic search failed, continuing with OCR-only results: \(error.localizedDescription)", category: .search)
                semanticMatches = []
            }
        }

        // Merge: OCR matches win on conflict (already have a searchable snippet); semantic-only
        // matches fill in frames OCR search missed entirely. Truncate back to the requested
        // page size — the merge can otherwise exceed `query.limit`.
        var seenFrameIDs = Set(ftsMatches.map(\.frameID))
        var mergedMatches: [(match: FTSMatch, matchSource: SearchResult.MatchSource)] =
            ftsMatches.map { ($0, .ocr) }
        for match in semanticMatches where !seenFrameIDs.contains(match.frameID) {
            guard mergedMatches.count < query.limit else { break }
            mergedMatches.append((match, .semantic))
            seenFrameIDs.insert(match.frameID)
        }

        // Convert FTS matches to SearchResults
        var results: [SearchResult] = []
        for (match, matchSource) in mergedMatches {
            // Get frame reference to get segment info
            if let frame = try await database.getFrame(id: match.frameID) {
                // ⚠️ RELEASE 2 ONLY - Use simple matched text extraction for Release 1
                let matchedText = match.snippet.components(separatedBy: " ").prefix(5).joined(separator: " ")

                Log.debug("[SearchManager] Creating SearchResult: frameID=\(match.frameID.value), videoID=\(match.videoID.value), frameIndex=\(match.frameIndex), snippet='\(match.snippet.prefix(50))...', matchSource=\(matchSource)", category: .search)

                let result = SearchResult(
                    id: match.frameID,
                    timestamp: match.timestamp,
                    snippet: match.snippet,
                    matchedText: matchedText,
                    relevanceScore: normalizeRank(match.rank),
                    metadata: FrameMetadata(
                        appBundleID: nil,
                        appName: match.appName,
                        windowName: match.windowName,
                        browserURL: nil
                    ),
                    segmentID: frame.segmentID,
                    videoID: match.videoID,
                    frameIndex: match.frameIndex,
                    matchSource: matchSource
                )
                results.append(result)
            }
        }

        // Rank results
        let rankedResults = resultRanker.rank(results, forQuery: query.text)

        // Filter by minimum relevance score
        let filteredResults = rankedResults.filter { $0.relevanceScore >= config.minimumRelevanceScore }

        let searchTimeMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Update statistics
        totalSearches += 1
        searchTimes.append(Double(searchTimeMs))

        Log.searchQuery(query: query.text, resultCount: filteredResults.count, timeMs: searchTimeMs)

        return SearchResults(
            query: query,
            results: filteredResults,
            searchTimeMs: searchTimeMs
        )
    }

    public func search(text: String, limit: Int) async throws -> SearchResults {
        return try await search(query: SearchQuery(text: text, limit: limit))
    }

    public func getSuggestions(prefix: String, limit: Int) async throws -> [String] {
        guard isInitialized else {
            throw SearchError.indexNotReady
        }

        // Use prefix search to find matching terms
        // Search for "prefix*" to get documents containing words starting with prefix
        let prefixQuery = scopeToSearchableColumns("\(prefix)*")

        do {
            let results = try await ftsEngine.search(
                query: prefixQuery,
                filters: SearchFilters(),
                limit: min(limit * 3, 100),  // Get more results to extract unique words
                offset: 0
            )

            // Extract unique words from snippets that start with prefix
            var suggestions = Set<String>()
            let lowercasePrefix = prefix.lowercased()

            for match in results {
                // Parse words from snippet
                let words = match.snippet
                    .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                    .map { word in
                        // Remove punctuation
                        word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            .lowercased()
                    }
                    .filter { word in
                        // Only keep words that start with prefix
                        !word.isEmpty && word.hasPrefix(lowercasePrefix)
                    }

                suggestions.formUnion(words)

                if suggestions.count >= limit {
                    break
                }
            }

            // Return sorted suggestions
            return Array(suggestions)
                .sorted()
                .prefix(limit)
                .map { $0 }
        } catch {
            // If prefix search fails (e.g., empty prefix), return empty
            return []
        }
    }


    // MARK: - SearchProtocol: Indexing

    public func index(text: ExtractedText, segmentId: Int64, frameId: Int64) async throws -> Int64 {
        guard isInitialized else {
            throw SearchError.indexNotReady
        }

        // Skip empty text
        guard !text.isEmpty else {
            // Return 0 for empty text (no docid assigned)
            return 0
        }

        // Use Rewind-compatible FTS insertion:
        // 1. INSERT INTO searchRanking_content (c0, c1, c2) → get docid
        // 2. INSERT INTO doc_segment (docid, segmentId, frameId)
        // chromeText is now populated from UI chrome separation (menu bar, dock, status bar)
        let docid = try await database.indexFrameText(
            mainText: text.fullText,                       // c0: Main OCR text (excluding chrome)
            chromeText: text.chromeText.isEmpty ? nil : text.chromeText, // c1: UI chrome text
            windowTitle: text.metadata.windowName,         // c2: Window title
            segmentId: segmentId,
            frameId: frameId
        )

        // Log.debug("Indexed FTS content \(docid) for frame \(frameId)", category: .search)

        return docid
    }

    public func removeFromIndex(frameID: FrameID) async throws {
        // Delete FTS content and doc_segment for this frame
        try await database.deleteFTSContent(frameId: frameID.value)
        Log.debug("Removed FTS content for frame \(frameID.value)", category: .search)
    }

    public func rebuildIndex() async throws {
        Log.info("Rebuilding FTS index", category: .search)
        try await ftsEngine.rebuildIndex()
        Log.info("FTS index rebuild complete", category: .search)
    }

    // MARK: - SearchProtocol: Statistics

    public func getStatistics() async -> SearchStatistics {
        let dbStats = (try? await database.getStatistics()) ?? DatabaseStatistics(
            frameCount: 0,
            segmentCount: 0,
            documentCount: 0,
            databaseSizeBytes: 0,
            oldestFrameDate: nil,
            newestFrameDate: nil
        )

        let avgSearchTime = searchTimes.isEmpty ? 0.0 : searchTimes.reduce(0, +) / Double(searchTimes.count)

        return SearchStatistics(
            totalDocuments: dbStats.documentCount,
            totalSearches: totalSearches,
            averageSearchTimeMs: avgSearchTime
        )
    }

    // MARK: - Private Helpers

    /// Normalize BM25 rank to 0-1 relevance score
    private func normalizeRank(_ bm25Rank: Double) -> Double {
        // BM25 returns negative values (more negative = better match)
        // Normalize to 0-1 range: higher score for more negative BM25
        return -bm25Rank / (1.0 + abs(bm25Rank))
    }

    /// Scope a plain FTS query to OCR columns only (`text` + `otherText`), excluding `title`.
    /// This is used for include-only helper queries (e.g. suggestions).
    private func scopeToSearchableColumns(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return query }
        return "((text:(\(trimmed))) OR (otherText:(\(trimmed))))"
    }

    /// Build an FTS query that searches OCR columns and applies exclusions globally.
    /// Example: `haseab -wave` becomes:
    /// `((text:(haseab*)) OR (otherText:(haseab*))) NOT ((text:(wave)) OR (otherText:(wave)))`
    static func buildScopedFTSQuery(for parsed: ParsedQuery, matchAny: Bool = false) -> String {
        let includeQuery = buildIncludeFTSQuery(for: parsed, matchAny: matchAny)
        let trimmedInclude = includeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInclude.isEmpty else { return includeQuery }

        var query = "((text:(\(trimmedInclude))) OR (otherText:(\(trimmedInclude))))"
        for excluded in parsed.excludedTerms {
            let escaped = QueryTokenizer.sanitizeFTSTerm(excluded)
            let excludedToken = excluded.contains(where: \.isWhitespace) ? "\"\(escaped)\"" : escaped
            let excludedScope = "((text:(\(excludedToken))) OR (otherText:(\(excludedToken))))"
            query = "(\(query) NOT \(excludedScope))"
        }

        return query
    }

    /// Build an FTS query for the semantic (AI description) index. Unlike
    /// `buildScopedFTSQuery`, this is NOT column-scoped — `semanticRanking` has a single
    /// `description` column, so a `text:`/`otherText:` prefix (valid only on the OCR table)
    /// would be a malformed FTS5 column reference here.
    static func buildSemanticFTSQuery(for parsed: ParsedQuery, matchAny: Bool = false) -> String {
        let includeQuery = buildIncludeFTSQuery(for: parsed, matchAny: matchAny)
        let trimmedInclude = includeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInclude.isEmpty else { return includeQuery }

        var query = trimmedInclude
        for excluded in parsed.excludedTerms {
            let escaped = QueryTokenizer.sanitizeFTSTerm(excluded)
            let excludedToken = excluded.contains(where: \.isWhitespace) ? "\"\(escaped)\"" : escaped
            query = "(\(query) NOT \(excludedToken))"
        }

        return query
    }

    /// Common words dropped only in `matchAny` mode — ORing them in would match nearly every
    /// frame's OCR text and drown out the terms that actually distinguish the query.
    /// `matchAny` mode is used for AI-context gathering, not user-facing keyword search, where
    /// dropping stopwords the user explicitly typed would be surprising.
    private static let aiContextStopwords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "for", "and", "or", "but", "was", "were",
        "is", "are", "am", "be", "been", "being", "my", "your", "his", "her", "its", "our",
        "their", "i", "you", "he", "she", "it", "we", "they", "when", "what", "where", "who",
        "why", "how", "did", "do", "does", "had", "have", "has", "having", "last", "going",
        "with", "at", "as", "by", "from", "about", "this", "that", "these", "those", "will",
        "would", "could", "should", "can", "not", "no"
    ]

    private static func buildIncludeFTSQuery(for parsed: ParsedQuery, matchAny: Bool = false) -> String {
        var parts: [String] = []

        for term in parsed.searchTerms {
            if matchAny && aiContextStopwords.contains(term.lowercased()) { continue }
            let escaped = QueryTokenizer.sanitizeFTSTerm(term)
            parts.append("\(escaped)*")
        }

        for phrase in parsed.phrases {
            let escaped = QueryTokenizer.sanitizeFTSTerm(phrase)
            parts.append("\"\(escaped)\"")
        }

        return parts.joined(separator: matchAny ? " OR " : " ")
    }
}
