import XCTest
@testable import Search
import Shared

final class AIAgentToolsTests: XCTestCase {
    func testQuotedPhraseAndPrefixWords() {
        let p = AIAgentTools.parseQuery("\"rate limit\" claude")
        XCTAssertEqual(AIAgentTools.expression(p, tier: 0), "\"rate limit\" AND claude*")
        XCTAssertEqual(AIAgentTools.expression(p, tier: 1), "\"rate limit\" OR claude*")
    }

    func testPunctuationAndOperatorsCannotBreakFTS() {
        let p = AIAgentTools.parseQuery("gpt-4 AND foo) \"unterminated NEAR")
        let expr = AIAgentTools.expression(p, tier: 0)
        XCTAssertFalse(expr.contains(")"))
        XCTAssertTrue(expr.contains("\"gpt 4\""))
        XCTAssertFalse(p.units.contains { $0.words == ["and"] })
    }

    func testResolveAppByLooseName() {
        let apps = [AIQueryApp(name: "Google Chrome", bundleID: "com.google.Chrome"), AIQueryApp(name: "Xcode", bundleID: "com.apple.dt.Xcode")]
        XCTAssertEqual(AIAgentTools.resolveApp("chrome", in: apps), .found(apps[0]))
        XCTAssertEqual(AIAgentTools.resolveApp("com.apple.dt.xcode", in: apps), .found(apps[1]))
        if case .found = AIAgentTools.resolveApp("slack", in: apps) { XCTFail("should not match") }
    }
}
