import XCTest
@testable import Export

final class ExportDenyListTests: XCTestCase {

    func testParsesPrivacyTableWithCommentsMultilineArraysAndTrailingCommas() {
        let toml = """
        [database]
        path = "/ignored"

        [privacy]
        # a comment mentioning "quotes" and [brackets]
        exclude_bundles = [
          # --- password managers ---
          "com.1password.1password",   # 1Password "8"
          'com.apple.Terminal',
        ]
        exclude_url_patterns = ["chase.com", "bank\\"of.com"]
        exclude_window_patterns = ["Payroll"]
        exclude_hidden_segments = false

        [other]
        exclude_bundles = ["should.not.be.read"]
        """
        let list = ExportDenyList.parse(toml: toml)

        XCTAssertEqual(list.excludeBundles, ["com.1password.1password", "com.apple.Terminal"])
        XCTAssertEqual(list.excludeURLPatterns, ["chase.com", "bank\"of.com"])
        XCTAssertEqual(list.excludeWindowPatterns, ["Payroll"])
        XCTAssertFalse(list.excludeHiddenSegments)
    }

    func testHiddenSegmentsAreExcludedByDefaultLikeTheMCPServer() {
        XCTAssertTrue(ExportDenyList.parse(toml: "[privacy]\nexclude_bundles = []\n").excludeHiddenSegments)
    }

    func testMatchingRules() {
        let list = ExportDenyList(
            excludeBundles: ["com.bank.app"],
            excludeURLPatterns: ["chase.com"],
            excludeWindowPatterns: ["payroll"],
            excludeHiddenSegments: true
        )
        XCTAssertEqual(list.violation(bundleIDs: ["com.bank.app"], urls: [], windowTitles: [], isHidden: false), .bundle)
        XCTAssertEqual(list.violation(bundleIDs: [nil, "com.ok"], urls: ["https://secure.CHASE.com/x"], windowTitles: [], isHidden: false), .url)
        XCTAssertEqual(list.violation(bundleIDs: [], urls: [], windowTitles: ["Q3 PAYROLL"], isHidden: false), .window)
        XCTAssertEqual(list.violation(bundleIDs: [], urls: [], windowTitles: [], isHidden: true), .hidden)
        XCTAssertNil(list.violation(bundleIDs: ["com.ok"], urls: ["https://example.com"], windowTitles: ["Notes"], isHidden: false))
    }

    func testBlankPatternsMatchNothing() {
        let list = ExportDenyList(excludeURLPatterns: [""], excludeWindowPatterns: [""])
        XCTAssertNil(list.violation(bundleIDs: [], urls: ["https://anything"], windowTitles: ["anything"], isHidden: false))
    }

    func testMergeAppliesRulesFromBothLists() {
        let a = ExportDenyList(excludeBundles: ["a"], excludeURLPatterns: ["x"], excludeHiddenSegments: false)
        let b = ExportDenyList(excludeBundles: ["b"], excludeURLPatterns: ["x", "y"], excludeHiddenSegments: true)
        let merged = a.merged(with: b)
        XCTAssertEqual(merged.excludeBundles, ["a", "b"])
        XCTAssertEqual(merged.excludeURLPatterns, ["x", "y"])
        XCTAssertTrue(merged.excludeHiddenSegments)
    }

    /// The real deny-list the MCP server uses, if this machine has it.
    func testParsesTheRealMCPConfigWhenPresent() throws {
        let path = NSString(string: "~/dev/retrace-mcp/retrace_mcp.toml").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "MCP config not on this machine")
        let list = try ExportDenyList.load(path: path)
        XCTAssertTrue(list.excludeBundles.contains("com.1password.1password"))
        XCTAssertTrue(list.excludeURLPatterns.contains("chase.com"))
        XCTAssertGreaterThan(list.excludeBundles.count, 20)
    }
}
