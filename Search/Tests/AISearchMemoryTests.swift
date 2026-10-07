import XCTest
@testable import Search
import Shared

final class AISearchMemoryTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ai_search_memory_\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func evidence(snippet: String, bundle: String = "com.anthropic.claudefordesktop") -> AIEvidence {
        AIEvidence(
            frameID: 1, timestamp: Date(), bundleID: bundle, appName: "Claude", windowTitle: nil,
            snippet: snippet, facetLabels: ["weekly limit"], coverage: 1, relevance: 1, scoped: true
        )
    }

    func testLearnedHintIsRecalledForAParaphraseButNotForAnUnrelatedQuestion() async {
        let memory = AISearchMemory(fileURL: fileURL)
        let e = evidence(snippet: "Plan usage limits Session limit Resets in 4 hr 26 min Weekly all models Resets Sat 12:00 PM 21%")
        await memory.learn(facetTerms: ["weekly", "limit"], from: [e]) { _ in false }

        let hint = await memory.recall(facetTerms: ["weekly", "usage"])
        XCTAssertEqual(hint?.bundleIDs, ["com.anthropic.claudefordesktop"])
        let unrelated = await memory.recall(facetTerms: ["invoice", "total"])
        XCTAssertNil(unrelated)
    }

    func testMemoryPersistsAcrossInstances() async {
        let first = AISearchMemory(fileURL: fileURL)
        await first.learn(facetTerms: ["weekly", "limit"], from: [evidence(snippet: "Session limit resets Weekly all models")]) { _ in false }

        let second = AISearchMemory(fileURL: fileURL)
        let hint = await second.recall(facetTerms: ["weekly", "limit"])
        XCTAssertNotNil(hint)
    }

    func testRecipeThatKeepsMissingIsEvicted() async throws {
        let memory = AISearchMemory(fileURL: fileURL)
        await memory.learn(facetTerms: ["weekly", "limit"], from: [evidence(snippet: "Weekly limit 21%")]) { _ in false }
        let recalled = await memory.recall(facetTerms: ["weekly", "limit"])
        let id = try XCTUnwrap(recalled?.recipeID)

        for _ in 0..<4 { await memory.recordOutcome(recipeID: id, success: false) }

        let hint = await memory.recall(facetTerms: ["weekly", "limit"])
        XCTAssertNil(hint, "UIs change: a recipe that keeps missing must stop steering search")
    }

    func testRejectedPhrasesAreNotStored() async {
        let memory = AISearchMemory(fileURL: fileURL)
        let e = evidence(snippet: "Session limit resets Weekly all models Window Help")
        // Reject every phrase (as the retrieval layer does for ones that appear in most frames).
        await memory.learn(facetTerms: ["weekly", "limit"], from: [e]) { _ in true }

        let recipes = await memory.list()
        XCTAssertEqual(recipes.count, 1)
        XCTAssertTrue(recipes[0].phrases.isEmpty)
        XCTAssertEqual(recipes[0].bundleIDs, ["com.anthropic.claudefordesktop"])
    }

    func testAdjacentPhrasesComeFromScreenWordsNextToTheMatchOnly() {
        let phrases = AISearchMemory.adjacentPhrases(
            in: "Plan usage limits Session limit Resets in 4 hr 26 min 10% Weekly all models Resets Sat 12:00 PM",
            facetTerms: ["weekly", "limit"]
        )
        XCTAssertTrue(phrases.contains("session limit"))
        XCTAssertTrue(phrases.allSatisfy { $0.allSatisfy { $0.isLetter || $0 == " " } }, "must be safe inside an FTS5 phrase: \(phrases)")
        XCTAssertFalse(phrases.contains { $0.contains("the ") || $0.hasPrefix("in ") })
    }
}
