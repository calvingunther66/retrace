import Foundation
import Shared

/// What the engine has learned about *where* and *with which words* a kind of question gets answered.
///
/// SECURITY MODEL: this memory only ever holds structured, deterministically derived search hints — app bundle
/// IDs and short alphanumeric phrases that appeared next to matched words in frames the answer cited. It never
/// stores model-written text and never feeds anything into a prompt as an instruction. Screen text is untrusted,
/// so a hostile page can at worst nudge *which frames get searched first*; the normal search path always runs as
/// a fallback.
public struct AISearchRecipe: Codable, Sendable, Equatable {
    public var id: String
    /// Canonical (stemmed) facet terms this recipe answers, sorted.
    public var terms: [String]
    /// Apps whose frames answered it.
    public var bundleIDs: [String]
    /// Phrases seen beside the matched words ("session limit", "weekly all models").
    public var phrases: [String]
    public var uses: Int
    public var hits: Int
    public var misses: Int
    public var updatedAt: Date
}

public struct AISearchHint: Sendable, Equatable {
    public let recipeID: String
    public let bundleIDs: [String]
    public let phrases: [String]
}

public actor AISearchMemory {
    public static let maxRecipes = 300
    private static let maxPhrases = 6
    private static let maxApps = 4

    private let fileURL: URL
    private var recipes: [AISearchRecipe] = []
    private var loaded = false

    /// Process-wide instance backed by `<storage root>/ai_search_memory.json`.
    public static let shared = AISearchMemory(
        fileURL: URL(fileURLWithPath: AppPaths.expandedStorageRoot).appendingPathComponent("ai_search_memory.json")
    )

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Recall

    /// Best-matching recipe for a facet, if any. Matching is on canonical term sets so paraphrases hit
    /// ("weekly limit" ↔ "how much of my weekly usage…").
    public func recall(facetTerms: [String]) -> AISearchHint? {
        loadIfNeeded()
        let query = Self.canonicalSet(facetTerms)
        guard !query.isEmpty else { return nil }

        var best: (recipe: AISearchRecipe, score: Double)?
        for r in recipes {
            let other = Set(r.terms)
            let shared = query.intersection(other).count
            guard shared > 0 else { continue }
            let containment = Double(shared) / Double(min(query.count, other.count))
            guard containment >= 0.5 else { continue }
            // A recipe that keeps missing is stale (UIs change).
            guard r.misses < 3 || r.hits >= r.misses else { continue }
            let score = containment + Double(r.hits) * 0.05
            if best == nil || score > best!.score { best = (r, score) }
        }
        guard let hit = best?.recipe else { return nil }
        return AISearchHint(recipeID: hit.id, bundleIDs: hit.bundleIDs, phrases: hit.phrases)
    }

    // MARK: Learning

    /// Learns from one facet whose evidence was cited by the answer **and** actually covered the facet.
    /// - Parameter evidence: only frames that satisfied both conditions.
    public func learn(facetTerms: [String], from evidence: [AIEvidence], rejectPhrase: (String) async -> Bool) async {
        loadIfNeeded()
        let key = Self.canonicalSet(facetTerms)
        guard !key.isEmpty, !evidence.isEmpty else { return }

        var apps: [String] = []
        for e in evidence { if let b = e.bundleID, !apps.contains(b) { apps.append(b) } }

        // Phrases beside matched words, ranked by how many cited frames they appear in.
        var counts: [String: Int] = [:]
        for e in evidence {
            for p in Set(Self.adjacentPhrases(in: e.snippet, facetTerms: facetTerms)) { counts[p, default: 0] += 1 }
        }
        var phrases: [String] = []
        for (p, _) in counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
            if phrases.count >= Self.maxPhrases { break }
            if await rejectPhrase(p) { continue }      // too common or one-off
            phrases.append(p)
        }

        let sortedKey = key.sorted()
        if let idx = recipes.firstIndex(where: { $0.terms == sortedKey }) {
            var r = recipes[idx]
            r.bundleIDs = Self.merge(apps, into: r.bundleIDs, limit: Self.maxApps)
            r.phrases = Self.merge(phrases, into: r.phrases, limit: Self.maxPhrases)
            r.hits += 1
            r.updatedAt = Date()
            recipes[idx] = r
        } else {
            recipes.append(AISearchRecipe(
                id: UUID().uuidString, terms: sortedKey, bundleIDs: Array(apps.prefix(Self.maxApps)),
                phrases: phrases, uses: 0, hits: 1, misses: 0, updatedAt: Date()
            ))
        }
        evict()
        save()
    }

    /// Feedback for a recipe that was applied to a facet: did the answer end up citing covering evidence?
    public func recordOutcome(recipeID: String, success: Bool) {
        loadIfNeeded()
        guard let idx = recipes.firstIndex(where: { $0.id == recipeID }) else { return }
        recipes[idx].uses += 1
        if success { recipes[idx].hits += 1 } else { recipes[idx].misses += 1 }
        recipes[idx].updatedAt = Date()
        evict()
        save()
    }

    // MARK: Inspection

    public func list() -> [AISearchRecipe] {
        loadIfNeeded()
        return recipes.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func clear() {
        recipes = []
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Helpers

    /// Phrases are letters/digits/spaces only, 2 words, ≤ 40 chars — safe to embed in an FTS5 phrase query.
    static func adjacentPhrases(in snippet: String, facetTerms: [String]) -> [String] {
        let words = snippet.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        guard words.count >= 2 else { return [] }
        let matchers = Set(facetTerms.flatMap { [$0] + (AIQueryPlanner.synonyms[$0] ?? []) }.map { $0.lowercased() })
        func isMatch(_ w: String) -> Bool { matchers.contains { w.hasPrefix($0) } }
        func usable(_ w: String) -> Bool { w.count >= 3 && w.contains(where: \.isLetter) && !AIQueryPlanner.stopwords.contains(w) }

        var out: [String] = []
        for i in words.indices where isMatch(words[i]) {
            for j in [i - 1, i + 1] where words.indices.contains(j) {
                let a = min(i, j), b = max(i, j)
                guard usable(words[a]), usable(words[b]) else { continue }
                let phrase = words[a] + " " + words[b]
                // Skip phrases made only of the question's own words — they teach nothing new.
                if isMatch(words[a]) && isMatch(words[b]) { continue }
                if phrase.count <= 40 { out.append(phrase) }
            }
        }
        return out
    }

    static func canonicalSet(_ terms: [String]) -> Set<String> {
        var set = Set<String>()
        for t in terms { set.insert(stem(t)) }
        return set
    }

    static func stem(_ word: String) -> String {
        var w = word.lowercased()
        for suffix in ["ing", "ly", "es", "ed", "s"] where w.count > 4 && w.hasSuffix(suffix) {
            w.removeLast(suffix.count)
            break
        }
        return w
    }

    private static func merge(_ new: [String], into old: [String], limit: Int) -> [String] {
        var out = new
        for o in old where !out.contains(o) { out.append(o) }
        return Array(out.prefix(limit))
    }

    private func evict() {
        recipes.removeAll { $0.misses >= 3 && $0.hits < $0.misses }
        if recipes.count > Self.maxRecipes {
            recipes = Array(recipes.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.maxRecipes))
        }
    }

    // MARK: Persistence

    private struct Envelope: Codable { var version: Int; var recipes: [AISearchRecipe] }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let env = try? decoder.decode(Envelope.self, from: data), env.version == 1 { recipes = env.recipes }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Envelope(version: 1, recipes: recipes)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
