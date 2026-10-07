import XCTest
@testable import Search
import Shared

final class AIQueryRefinerTests: XCTestCase {
    private let apps = [
        AIQueryApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
        AIQueryApp(name: "Terminal", bundleID: "com.apple.Terminal")
    ]

    private func evidence(_ id: Int64, label: String, coverage: Double, snippet: String = "x", at t: TimeInterval = 0) -> AIEvidence {
        AIEvidence(frameID: id, timestamp: Date(timeIntervalSince1970: t), bundleID: "b", appName: "App", windowTitle: nil,
                   snippet: snippet, facetLabels: [label], coverage: coverage, relevance: 1, scoped: false)
    }

    private func pack(facets: [AIQueryFacet], evidence: [AIEvidence]) -> AIEvidencePack {
        let plan = AIQueryPlan(question: "q", now: Date(timeIntervalSince1970: 1000), recency: .latest, facets: facets)
        return AIEvidencePack(plan: plan, evidence: evidence, anchors: [], notes: [], timingsMs: [:], usedHints: [:])
    }

    func testParseAcceptsJSONInsideProseAndCodeFences() throws {
        let reply = """
        Sure! Here you go:
        ```json
        {"facets":[{"label":"weekly usage","terms":["Weekly","usage","Resets","hr"],"app":"claude","latest":true}]}
        ```
        """
        let parsed = try XCTUnwrap(AIQueryRefiner.parse(reply, knownApps: apps))
        XCTAssertEqual(parsed.facets.first?.terms, ["weekly", "usage", "resets", "hr"])
        XCTAssertEqual(parsed.apps.map(\.bundleID), ["com.anthropic.claudefordesktop"])
        XCTAssertTrue(parsed.latest)
    }

    func testParseRejectsUnusableOrHostileOutput() {
        XCTAssertNil(AIQueryRefiner.parse("I think you should look at the settings page.", knownApps: apps))
        XCTAssertNil(AIQueryRefiner.parse(#"{"facets":[{"label":"x","terms":["onlyone"]}]}"#, knownApps: apps), "single-term facets are too weak")

        // Terms are reduced to alphanumerics (safe for FTS5); apps that don't exist are discarded.
        let parsed = AIQueryRefiner.parse(
            #"{"facets":[{"label":"x","terms":["weekly\"; DROP TABLE frame;--","usage*","(limit)"],"app":"Photoshop"}]}"#,
            knownApps: apps
        )
        XCTAssertEqual(parsed?.facets.first?.terms, ["weeklydroptableframe", "usage", "limit"])
        XCTAssertEqual(parsed?.apps.count, 0)
    }

    func testPromptCarriesStatisticsNeverScreenText() {
        let facet = AIQueryFacet(label: "weekly limit", terms: ["weekly", "limit"])
        let p = pack(facets: [facet], evidence: [evidence(1, label: "weekly limit", coverage: 0.5, snippet: "SECRET-SCREEN-TEXT 4111 1111")])
        let prompt = AIQueryRefiner.userPrompt(question: p.plan.question, now: p.plan.now, appNames: ["Claude"], weak: p.weakFacets, tried: [])

        XCTAssertFalse(prompt.contains("SECRET-SCREEN-TEXT"))
        XCTAssertTrue(prompt.contains("weekly limit"))
    }

    func testWeakFacetsAreThoseWithMissingOrPartialCoverage() {
        let strong = AIQueryFacet(label: "strong", terms: ["a1", "b1"])
        let partial = AIQueryFacet(label: "partial", terms: ["a2", "b2"])
        let missing = AIQueryFacet(label: "missing", terms: ["a3", "b3"])
        let p = pack(facets: [strong, partial, missing], evidence: [
            evidence(1, label: "strong", coverage: 1.0), evidence(2, label: "partial", coverage: 0.5)
        ])
        XCTAssertEqual(p.weakFacets.map(\.label), ["partial", "missing"])
    }

    func testMergingKeepsStrongEvidenceAndDeduplicatesFrames() {
        let a = AIQueryFacet(label: "a", terms: ["aa", "bb"])
        let first = pack(facets: [a], evidence: [evidence(1, label: "a", coverage: 1.0, snippet: "kept", at: 10)])
        let refinedFacet = AIQueryFacet(label: "refined", terms: ["cc", "dd"])
        let second = pack(facets: [refinedFacet], evidence: [
            evidence(1, label: "refined", coverage: 1.0, snippet: "kept", at: 10), evidence(2, label: "refined", coverage: 1.0, at: 20)
        ])

        let merged = first.merging(second)

        XCTAssertEqual(Set(merged.evidence.map(\.frameID)), [1, 2])
        XCTAssertEqual(merged.evidence.first { $0.frameID == 1 }?.facetLabels, ["a", "refined"])
        XCTAssertEqual(merged.plan.facets.map(\.label), ["a", "refined"])
        XCTAssertEqual(merged.evidence.first?.frameID, 2, "latest-first ordering is preserved after a merge")
    }
}
