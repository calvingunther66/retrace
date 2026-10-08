import Foundation
import Shared

extension AISearchMemory {
    /// Updates memory after an answer: learn from facets whose cited evidence genuinely covered them, and give
    /// success/miss feedback to any recipe that was applied.
    ///
    /// A citation alone is not enough — models cite while hedging — so evidence must also cover ≥ 70% of the
    /// facet's terms.
    /// - Returns: number of facets learned from.
    @discardableResult
    public func learn(
        from pack: AIEvidencePack,
        citedFrameIDs: Set<Int64>,
        ftsEngine: any FTSProtocol,
        totalDocuments: Int?
    ) async -> Int {
        var learned = 0
        for facet in pack.plan.facets where !facet.terms.isEmpty {
            let good = pack.evidence.filter {
                citedFrameIDs.contains($0.frameID) && $0.coverage >= 0.7 && $0.facetLabels.contains(facet.label)
            }
            if let recipeID = pack.usedHints[facet.label] {
                recordOutcome(recipeID: recipeID, success: !good.isEmpty)
            }
            guard !good.isEmpty else { continue }
            await learn(facetTerms: facet.terms, from: good) { (phrase: String) async -> Bool in
                // Reject phrases that are everywhere ("window help": no signal) or one-offs ("limit auto":
                // a neighbouring button label, not stable UI wording).
                guard let total = totalDocuments, total > 0 else { return false }
                let q = "((text:(\"\(phrase)\")) OR (otherText:(\"\(phrase)\")))"
                guard let df = try? await ftsEngine.documentFrequency(query: q) else { return false }
                return df < 5 || Double(df) / Double(total) > 0.05
            }
            learned += 1
        }
        return learned
    }
}
