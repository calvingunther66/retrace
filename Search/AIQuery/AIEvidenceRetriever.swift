import Foundation
import Shared

// MARK: - Evidence model

/// One screen capture selected as evidence, with only the passages that matter.
public struct AIEvidence: Sendable {
    public let frameID: Int64
    public let timestamp: Date
    public let bundleID: String?
    public let appName: String
    public let windowTitle: String?
    /// Keyword-in-context passages from the frame's OCR text (not the head of the page).
    public let snippet: String
    /// Which facets of the question this frame speaks to.
    public let facetLabels: [String]
    /// Fraction (0...1) of the facet's terms present in the frame text.
    public let coverage: Double
    /// Normalised full-text rank (0...1).
    public let relevance: Double
    public let scoped: Bool
}

/// "<App> was last on screen at <time>" — answers the "last time I had X open" half of a question.
public struct AIAnchor: Sendable {
    public let appName: String
    public let lastSeen: Date
    public let windowTitle: String?
}

public struct AIEvidencePack: Sendable {
    public let plan: AIQueryPlan
    public let evidence: [AIEvidence]
    public let anchors: [AIAnchor]
    /// Retrieval decisions worth telling the model (and the user): widened scope, nothing found, …
    public let notes: [String]
    public let timingsMs: [String: Double]

    public var isEmpty: Bool { evidence.isEmpty }

    /// Frames in the shape `OpenRouterClient` already consumes.
    public func contextFrames() -> [OpenRouterContextFrame] {
        evidence.map { e in
            let tag = e.facetLabels.isEmpty ? "" : "Relevant to: " + e.facetLabels.joined(separator: " / ") + "\n"
            return OpenRouterContextFrame(
                frameID: e.frameID,
                timestamp: e.timestamp,
                appName: e.appName,
                windowTitle: e.windowTitle,
                browserURL: nil,
                extractedText: tag + e.snippet
            )
        }
    }

    /// Text placed ahead of the records: current time, how the question was read, anchors and caveats.
    public func promptPreamble(timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "EEEE, MMM d yyyy, h:mm a zzz"
        var lines: [String] = ["Current local time: \(f.string(from: plan.now))."]
        lines.append("How the question was read: \(plan.summary).")
        if plan.facets.count > 1 || plan.facets.first?.terms.isEmpty == false {
            let items = plan.facets.enumerated().map { "(\($0.offset + 1)) \($0.element.label)" }
            lines.append("Answer each part separately: " + items.joined(separator: " "))
        }
        for a in anchors {
            var line = "\(a.appName) was last on screen at \(f.string(from: a.lastSeen))"
            if let w = a.windowTitle, !w.isEmpty { line += " (window: \(w))" }
            lines.append(line + ".")
        }
        lines.append(contentsOf: notes)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Retriever

/// Executes an `AIQueryPlan` against the local index and returns compact, high-signal evidence.
///
/// Compared with "OR the keywords and take the top 30 by bm25":
///  * facets are searched independently, so a two-part question gets evidence for *both* parts;
///  * queries relax progressively (all terms → all-but-one → any term) instead of failing or flooding;
///  * the question's app scope is tried first and widened only if it finds nothing;
///  * "last time" questions pick the newest *episode* that matches well, not the best-scoring old one;
///  * evidence is the passages around the matched words (with numbers), not the first 400 characters of OCR.
public actor AIEvidenceRetriever {
    private let database: any DatabaseProtocol
    private let ftsEngine: any FTSProtocol
    private let appNames: [String: String]

    private static let episodeGap: TimeInterval = 15 * 60
    private static let candidateLimit = 300
    private static let minRelevantEpisodeScore = 0.4

    public init(database: any DatabaseProtocol, ftsEngine: any FTSProtocol, appNames: [String: String] = [:]) {
        self.database = database
        self.ftsEngine = ftsEngine
        self.appNames = appNames
    }

    public func retrieve(plan: AIQueryPlan, maxEvidence: Int = 12) async -> AIEvidencePack {
        let clock = ContinuousClock()
        let start = clock.now
        var timings: [String: Double] = [:]
        var notes: [String] = []

        // Anchors: when was each named app last seen?
        var anchors: [AIAnchor] = []
        for app in plan.apps.prefix(3) {
            if let seg = try? await database.getSegments(bundleID: app.bundleID, limit: 1).first {
                anchors.append(AIAnchor(appName: app.name, lastSeen: seg.endDate, windowTitle: seg.windowName))
            }
        }

        // Evidence per facet, deduped across facets.
        var byFrame: [Int64: AIEvidence] = [:]
        var order: [Int64] = []
        for facet in plan.facets {
            let t0 = clock.now
            let (found, facetNotes) = await evidence(for: facet, plan: plan)
            timings["facet:" + (facet.terms.first ?? "scope")] = Self.ms(t0.duration(to: clock.now))
            notes.append(contentsOf: facetNotes)
            for e in found {
                if let existing = byFrame[e.frameID] {
                    byFrame[e.frameID] = AIEvidence(
                        frameID: existing.frameID, timestamp: existing.timestamp, bundleID: existing.bundleID,
                        appName: existing.appName, windowTitle: existing.windowTitle,
                        snippet: existing.snippet.count >= e.snippet.count ? existing.snippet : e.snippet,
                        facetLabels: existing.facetLabels + e.facetLabels,
                        coverage: max(existing.coverage, e.coverage), relevance: max(existing.relevance, e.relevance),
                        scoped: existing.scoped || e.scoped
                    )
                } else {
                    byFrame[e.frameID] = e
                    order.append(e.frameID)
                }
            }
        }

        var evidence = order.compactMap { byFrame[$0] }
        if plan.recency == .latest { evidence.sort { $0.timestamp > $1.timestamp } }
        evidence = Array(evidence.prefix(maxEvidence))
        timings["total"] = Self.ms(start.duration(to: clock.now))
        return AIEvidencePack(plan: plan, evidence: evidence, anchors: anchors, notes: notes, timingsMs: timings)
    }

    // MARK: Per-facet retrieval

    private func evidence(for facet: AIQueryFacet, plan: AIQueryPlan) async -> ([AIEvidence], [String]) {
        var notes: [String] = []

        // Scope-only facet ("what was I doing in Xcode yesterday?"): latest activity in the scoped apps/time window.
        if facet.terms.isEmpty {
            return (await scopeOnlyEvidence(label: facet.label, plan: plan), notes)
        }

        let scopedIDs = plan.apps.map(\.bundleID)
        var scopedMatches: [FTSMatch] = []
        if !scopedIDs.isEmpty {
            scopedMatches = await search(facet: facet, plan: plan, appBundleIDs: scopedIDs)
        }
        var globalMatches: [FTSMatch] = []
        if scopedMatches.count < 5 {
            globalMatches = await search(facet: facet, plan: plan, appBundleIDs: nil)
            if !scopedIDs.isEmpty {
                notes.append(scopedMatches.isEmpty
                    ? "No captured text in \(plan.apps.map(\.name).joined(separator: "/")) matched \"\(facet.label)\"; the search was widened to all apps."
                    : "Few matches inside \(plan.apps.map(\.name).joined(separator: "/")); results were supplemented from all apps.")
            }
        }

        // Merge by frame, boosting scoped hits.
        var merged: [Int64: (match: FTSMatch, relevance: Double, scoped: Bool)] = [:]
        for (list, scoped) in [(scopedMatches, true), (globalMatches, false)] {
            let rels = Self.normalizedRelevance(list)
            for (m, r) in zip(list, rels) {
                let score = min(1, r + (scoped ? 0.15 : 0))
                if let old = merged[m.frameID.value], old.relevance >= score { continue }
                merged[m.frameID.value] = (m, score, scoped)
            }
        }
        guard !merged.isEmpty else {
            notes.append("Nothing in the captured history matched \"\(facet.label)\".")
            return ([], notes)
        }

        let pool = selectPool(Array(merged.values), recency: plan.recency)
        func read(_ items: [Candidate]) async -> [AIEvidence] {
            var result: [AIEvidence] = []
            for item in items {
                let m = item.match
                let text = await ocrText(frameID: m.frameID.value)
                let (snippet, coverage) = Self.snippet(from: text, facet: facet)
                guard !snippet.isEmpty else { continue }
                let bundle = m.appName
                result.append(AIEvidence(
                    frameID: m.frameID.value, timestamp: m.timestamp, bundleID: bundle,
                    appName: bundle.flatMap { appNames[$0] } ?? bundle ?? "Unknown",
                    windowTitle: m.windowName, snippet: snippet, facetLabels: [facet.label],
                    coverage: coverage, relevance: item.relevance, scoped: item.scoped
                ))
            }
            return result
        }
        var out = await read(pool.primary)
        if plan.recency == .latest, (out.map(\.coverage).max() ?? 0) < 0.7, !pool.secondary.isEmpty {
            out += await read(pool.secondary)
            notes.append("The newest matching moment did not show every part of \"\(facet.label)\"; an older moment is included as a fallback and may be stale.")
        }

        // Best-covered first (in 0.25 buckets so a near-tie goes to the newer frame when recency matters).
        out.sort { a, b in
            let ba = (a.coverage * 4).rounded(.down), bb = (b.coverage * 4).rounded(.down)
            if ba != bb { return ba > bb }
            return plan.recency == .latest ? a.timestamp > b.timestamp : a.relevance > b.relevance
        }
        // Adjacent captures of the same screen carry the same text; keep one.
        var distinct: [AIEvidence] = []
        for e in out where !distinct.contains(where: {
            $0.snippet == e.snippet || ($0.bundleID == e.bundleID && abs($0.timestamp.timeIntervalSince(e.timestamp)) < 30)
        }) {
            distinct.append(e)
        }
        let keep = plan.recency == .latest ? 2 : 3
        return (Array(distinct.prefix(keep)), notes)
    }

    /// Chooses which candidate frames deserve an OCR read.
    private typealias Candidate = (match: FTSMatch, relevance: Double, scoped: Bool)

    /// `primary` is always read; `secondary` (an older fallback episode for "latest" questions) only when the
    /// primary doesn't fully answer the facet — otherwise stale values would sit next to current ones.
    private func selectPool(_ items: [Candidate], recency: AIQueryRecency) -> (primary: [Candidate], secondary: [Candidate]) {
        let sorted = items.sorted { $0.match.timestamp > $1.match.timestamp }
        // Cluster into episodes (consecutive frames less than `episodeGap` apart).
        var episodes: [[(match: FTSMatch, relevance: Double, scoped: Bool)]] = []
        for item in sorted {
            if var last = episodes.last, let lastItem = last.last,
               lastItem.match.timestamp.timeIntervalSince(item.match.timestamp) <= Self.episodeGap {
                last.append(item)
                episodes[episodes.count - 1] = last
            } else {
                episodes.append([item])
            }
        }
        func best(_ e: [(match: FTSMatch, relevance: Double, scoped: Bool)]) -> Double { e.map(\.relevance).max() ?? 0 }
        func top(_ e: [(match: FTSMatch, relevance: Double, scoped: Bool)], _ n: Int) -> [(match: FTSMatch, relevance: Double, scoped: Bool)] {
            Array(e.sorted { $0.relevance > $1.relevance }.prefix(n))
        }

        switch recency {
        case .latest:
            // Newest episode that matches well; failing that, the best-matching episode overall.
            let chosen = episodes.first { best($0) >= Self.minRelevantEpisodeScore }
                ?? episodes.max { best($0) < best($1) }
            // Also keep the next-newest good episode as a fallback in case the newest lacks the actual figure.
            let second = episodes.drop { $0.first?.match.frameID == chosen?.first?.match.frameID }
                .first { best($0) >= Self.minRelevantEpisodeScore }
            return (chosen.map { top($0, 10) } ?? [], second.map { top($0, 4) } ?? [])
        case .any:
            let ranked = episodes.sorted { best($0) > best($1) }.prefix(5)
            return (ranked.flatMap { top($0, 2) }, [])
        }
    }

    private func scopeOnlyEvidence(label: String, plan: AIQueryPlan) async -> [AIEvidence] {
        var out: [AIEvidence] = []
        for app in plan.apps.prefix(2) {
            guard let seg = try? await database.getSegments(bundleID: app.bundleID, limit: 1).first else { continue }
            let frames = (try? await database.getFrames(from: seg.startDate, to: seg.endDate, limit: 200)) ?? []
            guard let frame = frames.last else { continue }
            let text = await ocrText(frameID: frame.id.value)
            let clipped = String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(900))
            guard !clipped.isEmpty else { continue }
            out.append(AIEvidence(
                frameID: frame.id.value, timestamp: frame.timestamp, bundleID: app.bundleID, appName: app.name,
                windowTitle: seg.windowName, snippet: clipped, facetLabels: [label], coverage: 1, relevance: 1, scoped: true
            ))
        }
        return out
    }

    // MARK: Search helpers

    private func search(facet: AIQueryFacet, plan: AIQueryPlan, appBundleIDs: [String]?) async -> [FTSMatch] {
        let filters = SearchFilters(startDate: plan.timeStart, endDate: plan.timeEnd, appBundleIDs: appBundleIDs)
        var best: [FTSMatch] = []
        for query in Self.relaxingQueries(for: facet) {
            if let matches = try? await ftsEngine.search(query: query, filters: filters, limit: Self.candidateLimit, offset: 0),
               !matches.isEmpty {
                // Keep the first tier that yields a healthy pool; otherwise accumulate and try looser.
                if matches.count >= 8 { return matches }
                if matches.count > best.count { best = matches }
            }
        }
        return best
    }

    /// Strict → loose FTS5 queries for one facet. Each original term is a group of itself + synonyms (prefix-matched).
    static func relaxingQueries(for facet: AIQueryFacet) -> [String] {
        let groups: [[String]] = facet.terms.compactMap { term in
            let variants = ([term] + (AIQueryPlanner.synonyms[term] ?? [])).map(clean).filter { !$0.isEmpty }
            return variants.isEmpty ? nil : variants
        }
        guard !groups.isEmpty else { return [] }

        func groupExpr(_ g: [String]) -> String { "(" + g.map { "\($0)*" }.joined(separator: " OR ") + ")" }
        func scoped(_ expr: String) -> String { "((text:(\(expr))) OR (otherText:(\(expr))))" }

        var queries: [String] = []
        queries.append(scoped(groups.map(groupExpr).joined(separator: " AND ")))
        if groups.count >= 3 && groups.count <= 6 {
            // "At least n-1 of n" terms.
            var alts: [String] = []
            for skip in groups.indices {
                alts.append("(" + groups.enumerated().filter { $0.offset != skip }.map { groupExpr($0.element) }.joined(separator: " AND ") + ")")
            }
            queries.append(scoped(alts.joined(separator: " OR ")))
        }
        queries.append(scoped(groups.map(groupExpr).joined(separator: " OR ")))
        return queries
    }

    private static func clean(_ s: String) -> String {
        String(s.filter { $0.isLetter || $0.isNumber })
    }

    /// bm25 is "more negative = better"; map to 0...1 with 1 = best in this list.
    private static func normalizedRelevance(_ list: [FTSMatch]) -> [Double] {
        guard let best = list.map(\.rank).min(), let worst = list.map(\.rank).max() else { return [] }
        let span = worst - best
        return list.map { span < 1e-9 ? 1 : 1 - ($0.rank - best) / span }
    }

    private func ocrText(frameID: Int64) async -> String {
        guard let t = try? await database.getOCRTextForFrame(frameID: frameID) else { return "" }
        return [t.mainText, t.chromeText ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Keyword-in-context

    /// Returns the passages around the facet's words (merged, budgeted) and the fraction of facet terms found.
    static func snippet(from text: String, facet: AIQueryFacet, window: Int = 200, maxChars: Int = 900) -> (String, Double) {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return ("", 0) }

        struct Hit { var range: Range<Int>; var terms: Set<Int> }
        let chars = Array(flat)
        let lower = Array(flat.lowercased())
        guard lower.count == chars.count else { return (String(flat.prefix(maxChars)), 0) }

        var hits: [Hit] = []
        var matchedTerms = Set<Int>()
        for (ti, term) in facet.terms.enumerated() {
            let variants = ([term] + (AIQueryPlanner.synonyms[term] ?? [])).map { Array($0.lowercased()) }.filter { !$0.isEmpty }
            for v in variants {
                var i = 0
                while i + v.count <= lower.count {
                    if lower[i] == v[0], Array(lower[i..<(i + v.count)]) == v, i == 0 || !(lower[i - 1].isLetter || lower[i - 1].isNumber) {
                        matchedTerms.insert(ti)
                        hits.append(Hit(range: max(0, i - window)..<min(chars.count, i + v.count + window), terms: [ti]))
                        i += v.count
                    } else {
                        i += 1
                    }
                }
            }
        }
        guard !hits.isEmpty else { return ("", 0) }
        let coverage = Double(matchedTerms.count) / Double(max(1, facet.terms.count))

        // Merge overlapping windows.
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [Hit] = []
        for h in hits {
            if var last = merged.last, h.range.lowerBound <= last.range.upperBound {
                last.range = last.range.lowerBound..<max(last.range.upperBound, h.range.upperBound)
                last.terms.formUnion(h.terms)
                merged[merged.count - 1] = last
            } else {
                merged.append(h)
            }
        }

        // Budget: most distinct terms first, then back to reading order.
        var chosen: [Hit] = []
        var used = 0
        for h in merged.sorted(by: { $0.terms.count > $1.terms.count }) {
            let len = h.range.count
            if used + len > maxChars {
                if chosen.isEmpty {   // always keep one, clipped around its start
                    chosen.append(Hit(range: h.range.lowerBound..<min(h.range.upperBound, h.range.lowerBound + maxChars), terms: h.terms))
                }
                continue
            }
            chosen.append(h)
            used += len
        }
        chosen.sort { $0.range.lowerBound < $1.range.lowerBound }
        let text = chosen.map { String(chars[$0.range]) }.joined(separator: " … ")
        return (text, coverage)
    }

    private static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
