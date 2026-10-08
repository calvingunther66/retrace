import Foundation

/// A minimal chat call, so the refiner can be tested without the network.
public protocol AIChatTransport: Sendable {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

extension AIEvidencePack {
    /// Facets whose evidence is missing or only weakly covers the facet's words.
    public var weakFacets: [AIQueryFacet] {
        plan.facets.filter { facet in
            guard !facet.terms.isEmpty else { return false }
            let best = evidence.filter { $0.facetLabels.contains(facet.label) }.map(\.coverage).max() ?? 0
            return best < 0.7
        }
    }

    /// Adds evidence from a refinement round without disturbing what was already strong.
    public func merging(_ extra: AIEvidencePack, maxEvidence: Int = 12) -> AIEvidencePack {
        var byFrame: [Int64: AIEvidence] = [:]
        var order: [Int64] = []
        for e in evidence + extra.evidence {
            if let old = byFrame[e.frameID] {
                byFrame[e.frameID] = AIEvidence(
                    frameID: old.frameID, timestamp: old.timestamp, bundleID: old.bundleID, appName: old.appName,
                    windowTitle: old.windowTitle, snippet: old.snippet.count >= e.snippet.count ? old.snippet : e.snippet,
                    facetLabels: old.facetLabels + e.facetLabels.filter { !old.facetLabels.contains($0) },
                    coverage: max(old.coverage, e.coverage), relevance: max(old.relevance, e.relevance), scoped: old.scoped || e.scoped
                )
            } else {
                byFrame[e.frameID] = e
                order.append(e.frameID)
            }
        }
        var merged = order.compactMap { byFrame[$0] }
        if plan.recency == .latest { merged.sort { $0.timestamp > $1.timestamp } }
        merged = Array(merged.prefix(maxEvidence))

        let mergedPlan = AIQueryPlan(
            question: plan.question, now: plan.now, recency: plan.recency, timeStart: plan.timeStart, timeEnd: plan.timeEnd,
            apps: plan.apps, facets: plan.facets + extra.plan.facets.filter { f in !plan.facets.contains { $0.label == f.label } },
            planner: plan.planner + "+refined"
        )
        return AIEvidencePack(
            plan: mergedPlan, evidence: merged, anchors: anchors,
            notes: notes + ["Search terms were refined with the model's help for the parts that matched weakly."] + extra.notes,
            timingsMs: timingsMs.merging(Dictionary(uniqueKeysWithValues: extra.timingsMs.map { ("refine:" + $0.key, $0.value) })) { a, _ in a },
            usedHints: usedHints.merging(extra.usedHints) { a, _ in a }
        )
    }
}

/// Asks a model for *search vocabulary*, never answers.
///
/// Privacy / safety properties:
///  * the model sees the question, app names and per-facet match statistics — never screen text;
///  * its reply is parsed as strict JSON and every field is validated: terms are lowercase alphanumeric words,
///    apps must be ones that exist, counts are capped. Anything else is discarded;
///  * any failure (timeout, unsupported model, bad JSON) simply means "no refinement" and the normal path continues.
public enum AIQueryRefiner {
    public static let systemPrompt = """
    You help search a personal screen-recording archive. The archive is full-text OCR of everything that was on the \
    user's screen. You do NOT answer the question. You propose better search terms.

    Reply with ONLY a JSON object, no prose, no code fences:
    {"facets":[{"label":"short description","terms":["word","word"],"app":"App Name or null","latest":true}]}

    Rules:
    - terms: 3 to 8 single lowercase words that would literally appear on the screen when the answer is visible. \
    Think about how an app's UI words things (e.g. "session", "resets", "limit", "used") rather than how the user phrased it. \
    Include likely synonyms and abbreviations ("hr" for hour).
    - app: one of the listed app names where the answer most likely appears, or null.
    - latest: true if the user wants the most recent value/occurrence.
    - At most 4 facets. Do not repeat terms already tried unless you change the app or combination.
    """

    public static func userPrompt(question: String, now: Date, appNames: [String], weak: [AIQueryFacet], tried: [String]) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d yyyy, h:mm a zzz"
        var lines = ["Question: \(question)", "Current time: \(f.string(from: now))"]
        lines.append("Apps that exist in the archive: " + appNames.prefix(60).joined(separator: ", "))
        lines.append("Parts that matched poorly so far (search terms already tried):")
        for facet in weak { lines.append("- \"\(facet.label)\" tried: \(facet.terms.joined(separator: " "))") }
        if !tried.isEmpty { lines.append("Earlier refinement attempts that also failed: " + tried.joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }

    /// Parses and validates a model reply into new facets plus an app scope. Returns nil if nothing usable.
    public static func parse(_ reply: String, knownApps: [AIQueryApp]) -> (facets: [AIQueryFacet], apps: [AIQueryApp], latest: Bool)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["facets"] as? [[String: Any]] else { return nil }

        var facets: [AIQueryFacet] = []
        var apps: [AIQueryApp] = []
        var latest = false
        for item in raw.prefix(4) {
            let terms = ((item["terms"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { $0.count >= 2 && $0.count <= 24 }
            var unique: [String] = []
            for t in terms where !unique.contains(t) { unique.append(t) }
            guard unique.count >= 2 else { continue }
            let label = String(((item["label"] as? String) ?? unique.joined(separator: " ")).prefix(80))
            facets.append(AIQueryFacet(label: label, terms: Array(unique.prefix(8))))
            if let name = (item["app"] as? String)?.lowercased(),
               let app = knownApps.first(where: { $0.name.lowercased() == name }),
               !apps.contains(where: { $0.bundleID == app.bundleID }) {
                apps.append(app)
            }
            if (item["latest"] as? Bool) == true { latest = true }
        }
        return facets.isEmpty ? nil : (facets, apps, latest)
    }

    /// Up to `rounds` refinement rounds over the weak facets. Returns the improved pack (or the original).
    public static func refine(
        pack: AIEvidencePack,
        retriever: AIEvidenceRetriever,
        transport: any AIChatTransport,
        knownApps: [AIQueryApp],
        rounds: Int = 2
    ) async -> AIEvidencePack {
        var current = pack
        var tried: [String] = []
        var weak = pack.weakFacets
        for _ in 0..<max(0, rounds) {
            guard !weak.isEmpty else { break }
            let prompt = userPrompt(question: pack.plan.question, now: pack.plan.now, appNames: knownApps.map(\.name), weak: weak, tried: tried)
            guard let reply = try? await transport.complete(system: systemPrompt, user: prompt, maxTokens: 400),
                  let parsed = parse(reply, knownApps: knownApps) else { break }
            tried.append(parsed.facets.map { $0.terms.joined(separator: " ") }.joined(separator: " / "))

            let plan = AIQueryPlan(
                question: pack.plan.question, now: pack.plan.now,
                recency: parsed.latest ? .latest : pack.plan.recency,
                timeStart: pack.plan.timeStart, timeEnd: pack.plan.timeEnd,
                apps: parsed.apps.isEmpty ? pack.plan.apps : parsed.apps,
                facets: parsed.facets, planner: "model-refined"
            )
            let extra = await retriever.retrieve(plan: plan)
            // Only what the refined terms still failed to find justifies another round.
            weak = extra.weakFacets
            guard !extra.isEmpty else { continue }
            current = current.merging(extra)
        }
        return current
    }
}
