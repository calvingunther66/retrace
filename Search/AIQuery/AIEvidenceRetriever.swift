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
    /// facet label → id of the learned recipe that was applied to it (for outcome feedback).
    public let usedHints: [String: String]

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
    private let memory: AISearchMemory?

    /// Words present in more than this share of all documents carry no signal ("window" is in ~94% of frames).
    private static let commonTermShare = 0.15
    private var termShare: [String: Double] = [:]
    private var totalDocuments: Int?

    /// Retrace's own windows (the overlay the question is typed into) always "match" the question; they are never
    /// evidence unless the user asked about Retrace itself.
    private static let selfBundleIDs = ["io.retrace.app", "io.retrace.app.dev"]

    private static func filters(for plan: AIQueryPlan, start: Date?, appBundleIDs: [String]?) -> SearchFilters {
        let asksAboutRetrace = plan.apps.contains { selfBundleIDs.contains($0.bundleID) }
        return SearchFilters(
            startDate: start, endDate: plan.timeEnd, appBundleIDs: appBundleIDs,
            excludedAppBundleIDs: asksAboutRetrace ? nil : selfBundleIDs
        )
    }

    private static let episodeGap: TimeInterval = 15 * 60
    private static let candidateLimit = 300

    public init(database: any DatabaseProtocol, ftsEngine: any FTSProtocol, appNames: [String: String] = [:], memory: AISearchMemory? = nil) {
        self.database = database
        self.ftsEngine = ftsEngine
        self.appNames = appNames
        self.memory = memory
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
        var usedHints: [String: String] = [:]
        for facet in plan.facets {
            let t0 = clock.now
            let (found, facetNotes, recipeID) = await evidence(for: facet, plan: plan)
            if let recipeID { usedHints[facet.label] = recipeID }
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
        return AIEvidencePack(plan: plan, evidence: evidence, anchors: anchors, notes: notes, timingsMs: timings, usedHints: usedHints)
    }

    // MARK: Per-facet retrieval

    private func evidence(for facet: AIQueryFacet, plan: AIQueryPlan) async -> ([AIEvidence], [String], String?) {
        var notes: [String] = []

        // Scope-only facet ("what was I doing in Xcode yesterday?"): latest activity in the scoped apps/time window.
        if facet.terms.isEmpty {
            return (await scopeOnlyEvidence(label: facet.label, plan: plan), notes, nil)
        }

        // Learned hint: where/with which phrases this kind of question was answered before.
        let hint = await memory?.recall(facetTerms: facet.terms)
        var scopedIDs = plan.apps.map(\.bundleID)
        if let hint {
            for b in hint.bundleIDs where !scopedIDs.contains(b) { scopedIDs.append(b) }
            notes.append("A learned search hint was applied for \"\(facet.label)\".")
        }
        var scopedMatches: [(match: FTSMatch, tier: Int)] = []
        if !scopedIDs.isEmpty {
            scopedMatches = await search(facet: facet, plan: plan, appBundleIDs: scopedIDs, hint: hint)
        }
        var globalMatches: [(match: FTSMatch, tier: Int)] = []
        if scopedMatches.count < 5 {
            globalMatches = await search(facet: facet, plan: plan, appBundleIDs: nil, hint: hint)
            if !scopedIDs.isEmpty {
                notes.append(scopedMatches.isEmpty
                    ? "No captured text in \(plan.apps.map(\.name).joined(separator: "/")) matched \"\(facet.label)\"; the search was widened to all apps."
                    : "Few matches inside \(plan.apps.map(\.name).joined(separator: "/")); results were supplemented from all apps.")
            }
        }

        // Merge by frame, boosting scoped hits.
        var merged: [Int64: Candidate] = [:]
        for (list, scoped) in [(scopedMatches, true), (globalMatches, false)] {
            let rels = Self.normalizedRelevance(list.map(\.match))
            for (entry, r) in zip(list, rels) {
                let score = min(1, r + (scoped ? 0.15 : 0))
                let key = entry.match.frameID.value
                if let old = merged[key] {
                    merged[key] = (old.match, max(old.relevance, score), old.scoped || scoped, min(old.tier, entry.tier))
                } else {
                    merged[key] = (entry.match, score, scoped, entry.tier)
                }
            }
        }
        guard !merged.isEmpty else {
            notes.append("Nothing in the captured history matched \"\(facet.label)\".")
            return ([], notes, hint?.recipeID)
        }

        let pool = selectPool(Array(merged.values), recency: plan.recency)
        func read(_ items: [Candidate]) async -> [AIEvidence] {
            var result: [AIEvidence] = []
            for item in items {
                let m = item.match
                let text = await ocrText(frameID: m.frameID.value)
                let (rawSnippet, coverage) = Self.snippet(from: text, facet: facet)
                guard !rawSnippet.isEmpty else { continue }
                // Relative/partial times ("Resets in 4 hr", "Resets Sat 12:00 PM") are resolved here, in code.
                let snippet = AITimeResolver.annotate(rawSnippet, capturedAt: m.timestamp, now: plan.now)
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
        return (Array(distinct.prefix(keep)), notes, hint?.recipeID)
    }

    /// Chooses which candidate frames deserve an OCR read.
    private typealias Candidate = (match: FTSMatch, relevance: Double, scoped: Bool, tier: Int)

    /// `primary` is always read; `secondary` (an older fallback episode for "latest" questions) only when the
    /// primary doesn't fully answer the facet — otherwise stale values would sit next to current ones.
    private func selectPool(_ items: [Candidate], recency: AIQueryRecency) -> (primary: [Candidate], secondary: [Candidate]) {
        let sorted = items.sorted { $0.match.timestamp > $1.match.timestamp }
        // Cluster into episodes (consecutive frames less than `episodeGap` apart).
        var episodes: [[Candidate]] = []
        for item in sorted {
            if let lastItem = episodes.last?.last,
               lastItem.match.timestamp.timeIntervalSince(item.match.timestamp) <= Self.episodeGap {
                episodes[episodes.count - 1].append(item)
            } else {
                episodes.append([item])
            }
        }
        func bestRel(_ e: [Candidate]) -> Double { e.map(\.relevance).max() ?? 0 }
        func minTier(_ e: [Candidate]) -> Int { e.map(\.tier).min() ?? Int.max }
        func top(_ e: [Candidate], _ n: Int) -> [Candidate] {
            Array(e.sorted { ($0.tier, -$0.relevance) < ($1.tier, -$1.relevance) }.prefix(n))
        }

        // Match *strength* (which relaxation tier produced the hit) decides what qualifies — never a rank
        // normalised against whatever else happens to be in this pool.
        let strongest = items.map(\.tier).min() ?? 0

        switch recency {
        case .latest:
            let qualifying = episodes.filter { minTier($0) == strongest }
            let chosen = qualifying.first ?? episodes.first
            let second = qualifying.dropFirst().first
            return (chosen.map { top($0, 10) } ?? [], second.map { top($0, 4) } ?? [])
        case .any:
            let ranked = episodes.sorted { (minTier($0), -bestRel($0)) < (minTier($1), -bestRel($1)) }.prefix(5)
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

    private func search(facet: AIQueryFacet, plan: AIQueryPlan, appBundleIDs: [String]?, hint: AISearchHint?) async -> [(match: FTSMatch, tier: Int)] {
        let usable = await signalTerms(for: facet)
        let queries = Self.relaxingQueries(for: AIQueryFacet(label: facet.label, terms: usable))

        // "Latest" questions: FTS returns the best-RANKED rows, not the newest. A screen that is open all day
        // (a usage panel) matches in thousands of near-identical frames, so a plain top-N sample can miss the
        // newest ones entirely. Search progressively wider recent windows and stop at the first one that holds a
        // strong (tier-0) match, which guarantees the newest strong matches are in the pool.
        let day: TimeInterval = 86_400
        let spans: [TimeInterval?] = (plan.recency == .latest && plan.timeStart == nil)
            ? [day, 3 * day, 7 * day, 30 * day, nil] : [nil]
        var result: [(match: FTSMatch, tier: Int)] = []
        for span in spans {
            let start = span.map { (plan.timeEnd ?? plan.now).addingTimeInterval(-$0) } ?? plan.timeStart
            let filters = Self.filters(for: plan, start: start, appBundleIDs: appBundleIDs)
            result = await runTiers(queries: queries, filters: filters, hint: hint)
            if result.contains(where: { $0.tier == 0 }) { break }
        }
        return result
    }

    private func runTiers(queries: [String], filters: SearchFilters, hint: AISearchHint?) async -> [(match: FTSMatch, tier: Int)] {
        var seen = Set<Int64>()
        var collected: [(match: FTSMatch, tier: Int)] = []

        // Learned phrases WIDEN the candidate pool (tagged tier 1, upgraded to 0 if the normal strict query also
        // matches them) but never define what counts as "strongest": the newest frames may word things
        // differently. Stored phrases are letters/digits/spaces only, so they are safe in an FTS5 phrase query.
        if let phrases = hint?.phrases.filter({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } }), !phrases.isEmpty {
            let expr = phrases.map { "\"\($0)\"" }.joined(separator: " OR ")
            let q = "((text:(\(expr))) OR (otherText:(\(expr))))"
            if let matches = try? await ftsEngine.search(query: q, filters: filters, limit: Self.candidateLimit, offset: 0) {
                for m in matches where seen.insert(m.frameID.value).inserted { collected.append((m, 1)) }
            }
        }
        for (tier, query) in queries.enumerated() {
            guard let matches = try? await ftsEngine.search(query: query, filters: filters, limit: Self.candidateLimit, offset: 0) else { continue }
            for m in matches {
                if seen.insert(m.frameID.value).inserted {
                    collected.append((m, tier))
                } else if let i = collected.firstIndex(where: { $0.match.frameID == m.frameID }), collected[i].tier > tier {
                    collected[i].tier = tier   // matched a stricter normal tier too
                }
            }
            // A healthy pool from a strict tier is enough; otherwise relax further.
            if collected.count >= 8 { break }
        }
        return collected
    }

    /// The facet's terms minus words that appear in most frames. Never drops everything.
    private func signalTerms(for facet: AIQueryFacet) async -> [String] {
        if totalDocuments == nil { totalDocuments = (try? await database.getFrameCount()) }
        guard let total = totalDocuments, total > 0 else { return facet.terms }
        var kept: [String] = []
        for term in facet.terms {
            let clean = Self.clean(term)
            guard !clean.isEmpty else { continue }
            if termShare[clean] == nil {
                let q = "((text:(\(clean)*)) OR (otherText:(\(clean)*)))"
                if let df = try? await ftsEngine.documentFrequency(query: q) {
                    termShare[clean] = Double(df) / Double(total)
                }
            }
            if (termShare[clean] ?? 0) <= Self.commonTermShare { kept.append(term) }
        }
        return kept.isEmpty ? facet.terms : kept
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
