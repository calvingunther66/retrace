import XCTest
@testable import Search
import Shared

final class AIQueryPlannerTests: XCTestCase {
    private let apps = [
        AIQueryApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
        AIQueryApp(name: "Code", bundleID: "com.microsoft.VSCode"),
        AIQueryApp(name: "Cursor", bundleID: "com.todesktop.cursor"),
        AIQueryApp(name: "Xcode", bundleID: "com.apple.dt.Xcode")
    ]
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }
    private let now = Date(timeIntervalSince1970: 1_791_398_400)   // fixed instant

    func testCompoundRecencyQuestionSplitsIntoFacetsAndLiftsScope() {
        let q = "the last time I had claude code open, what was my weekly limit at, and when will my rolling 5 hour window reset"
        let plan = AIQueryPlanner.plan(question: q, now: now, apps: apps, calendar: calendar)

        XCTAssertEqual(plan.recency, .latest)
        // "Claude Code" is a product: must scope to Claude and NOT to the editor literally named "Code".
        XCTAssertEqual(plan.apps.map(\.bundleID), ["com.anthropic.claudefordesktop"])
        XCTAssertEqual(plan.facets.map(\.terms), [["weekly", "limit"], ["rolling", "hour", "window", "reset"]])
    }

    func testScopeOnlyQuestionKeepsAppAndTimeWindow() {
        let plan = AIQueryPlanner.plan(question: "what was I doing in Xcode yesterday?", now: now, apps: apps, calendar: calendar)

        XCTAssertEqual(plan.apps.map(\.name), ["Xcode"])
        XCTAssertEqual(plan.facets.count, 1)
        XCTAssertTrue(plan.facets[0].terms.isEmpty, "nothing but scope → a scope-only facet")
        let startOfToday = calendar.startOfDay(for: now)
        XCTAssertEqual(plan.timeEnd, startOfToday)
        XCTAssertEqual(plan.timeStart, calendar.date(byAdding: .day, value: -1, to: startOfToday))
    }

    func testPlainKeywordsStayOneFacetWithoutRecency() {
        let plan = AIQueryPlanner.plan(question: "claude usage limit reset time", now: now, apps: apps, calendar: calendar)

        XCTAssertEqual(plan.recency, .any)
        XCTAssertEqual(plan.facets.count, 1)
        XCTAssertEqual(plan.facets[0].terms, ["usage", "limit", "reset"])
    }

    func testRelaxingQueriesGoStrictToLoose() {
        let facet = AIQueryFacet(label: "x", terms: ["weekly", "limit", "reset"])
        let queries = AIEvidenceRetriever.relaxingQueries(for: facet)

        XCTAssertEqual(queries.count, 3)   // all terms → all-but-one → any term
        XCTAssertTrue(queries[0].contains("(weekly* OR week*) AND (limit* OR limits*) AND (reset* OR resets* OR resetting*)"))
        XCTAssertTrue(queries[2].contains(" OR "))
        XCTAssertFalse(queries[2].contains(" AND "))
    }

    func testSnippetKeepsTheNumbersNextToTheMatchedWords() {
        // Realistic OCR: lots of unrelated chat text before the usage panel.
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 60)
        let text = filler + "Plan usage limits Session limit Resets in 4 hr 26 min 10% Weekly all models Resets Sat 12:00 PM 21% " + filler
        let facet = AIQueryFacet(label: "weekly limit", terms: ["weekly", "limit"])

        let (snippet, coverage) = AIEvidenceRetriever.snippet(from: text, facet: facet)

        XCTAssertEqual(coverage, 1.0)
        XCTAssertTrue(snippet.contains("21%"), "the value beside the match must survive: \(snippet)")
        XCTAssertLessThan(snippet.count, 1000)
    }

    func testSnippetReportsPartialCoverage() {
        let facet = AIQueryFacet(label: "x", terms: ["weekly", "nonexistentword"])
        let (snippet, coverage) = AIEvidenceRetriever.snippet(from: "Weekly all models 21%", facet: facet)

        XCTAssertFalse(snippet.isEmpty)
        XCTAssertEqual(coverage, 0.5, accuracy: 0.001)
    }
}
