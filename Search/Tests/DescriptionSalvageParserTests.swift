import XCTest
@testable import Search

/// The legacy parser is kept here, verbatim, only to prove the salvage parser is a strict superset of it and to
/// demonstrate the failure modes it had (a truncated array, one stray quote or trailing bracket lost the WHOLE batch).

final class DescriptionSalvageParserTests: XCTestCase {
    private func obj(_ i: Int, _ d: String) -> String { "{\"image\": \(i), \"description\": \"\(d)\"}" }
    private let ds = [
        "Safari showing a documentation page about URLSession timeouts.",
        "Terminal running swift test with two failing cases visible.",
        "Claude desktop conversation about database indexing strategy.",
        "Finder window listing project folders sorted by date.",
        "Xcode editor open on a Swift actor with a compiler warning."
    ]
    private var full5: String { "[\n" + (1...5).map { obj($0, ds[$0 - 1]) }.joined(separator: ",\n") + "\n]" }

    func testTruncatedArrayRecoversEveryCompleteEntryAndDropsTheDanglingOne() {
        let cut = full5.range(of: "Xcode editor open on")!.lowerBound
        let truncated = String(full5[..<cut])                 // ends inside the 5th description string
        let parsed = DescriptionSalvageParser.parse(truncated, expectedCount: 5)
        XCTAssertEqual(Set(parsed.byPosition.keys), [1, 2, 3, 4])
        XCTAssertTrue(parsed.diagnostics.truncatedTail)
        XCTAssertTrue(LegacyDescriptionParser.parse(truncated).isEmpty, "legacy parser loses the whole batch")
    }

    func testEveryTruncationPointNeverReturnsAPartialEntry() {
        let chars = Array(full5)
        for cut in 0..<chars.count {
            let parsed = DescriptionSalvageParser.parse(String(chars[0..<cut]), expectedCount: 5)
            for (k, v) in parsed.byPosition { XCTAssertEqual(v, ds[k - 1], "cut \(cut)") }
        }
    }

    func testPlaceholderEchoFromThePromptIsRejected() {
        let echo = "[{\"image\": 1, \"description\": \"...\"}, {\"image\": 2, \"description\": \"...\"}, ...]"
        XCTAssertTrue(DescriptionSalvageParser.parse(echo, expectedCount: 5).byPosition.isEmpty)
        XCTAssertEqual(DescriptionSalvageParser.parse(echo + "\n" + full5, expectedCount: 5).byPosition.count, 5)
    }

    func testUnescapedInnerQuoteOnlyCostsThatEntry() {
        let bad = "{\"image\": 3, \"description\": \"Chat app showing the message \"ship it\" in the thread.\"}"
        let text = "[\n" + [obj(1, ds[0]), obj(2, ds[1]), bad, obj(4, ds[3]), obj(5, ds[4])].joined(separator: ",\n") + "\n]"
        XCTAssertTrue(LegacyDescriptionParser.parse(text).isEmpty)
        XCTAssertEqual(DescriptionSalvageParser.parse(text, expectedCount: 5).byPosition.count, 5)
    }

    func testTrailingBracketCommentaryDoesNotHijackTheLastArray() {
        let text = full5 + "\n(see [1] for details)"
        XCTAssertTrue(LegacyDescriptionParser.parse(text).isEmpty)
        XCTAssertEqual(DescriptionSalvageParser.parse(text, expectedCount: 5).byPosition.count, 5)
    }

    func testJSONLinesThinkBlocksFencesAndImageIndexShapes() {
        let lines = (1...5).map { obj($0, ds[$0 - 1]) }.joined(separator: "\n")
        XCTAssertEqual(DescriptionSalvageParser.parse(lines, expectedCount: 5).byPosition.count, 5)
        let thinking = "<think>draft [{\"image\":1,\"description\":\"a draft that is long enough\"}]</think>\n```json\n\(full5)\n```"
        XCTAssertEqual(DescriptionSalvageParser.parse(thinking, expectedCount: 5).byPosition[1], ds[0])
        let shapes = "[{\"image\": \"1\", \"description\": \"\(ds[0])\"}, {\"image\": 2.0, \"description\": \"\(ds[1])\"}, {\"image\": \"Image 3\", \"description\": \"\(ds[2])\"}]"
        XCTAssertEqual(DescriptionSalvageParser.parse(shapes, expectedCount: 3).byPosition.count, 3)
    }

    func testSalvageIsASupersetOfLegacyOnWellFormedOutput() {
        for text in [full5, "```json\n" + full5 + "\n```", "<think>planning</think>" + full5] {
            let legacy = LegacyDescriptionParser.parse(text)
            let salvaged = DescriptionSalvageParser.parse(text, expectedCount: 5).byPosition
            XCTAssertEqual(legacy.count, 5)
            for (k, v) in legacy { XCTAssertEqual(salvaged[k], v) }
        }
    }

    func testEveryTruncationPointOfA12EntryReplyKeepsExactlyTheCompleteEntries() {
        let descriptions = (1...12).map { "Window \($0) shows the application interface with task number \($0) in progress." }
        let reply = "[" + (1...12).map { obj($0, descriptions[$0 - 1]) }.joined(separator: ",") + "]"
        let chars = Array(reply)
        var lastCount = 0
        for cut in 0..<chars.count {
            let parsed = DescriptionSalvageParser.parse(String(chars[0..<cut]), expectedCount: 12).byPosition
            for (k, v) in parsed { XCTAssertEqual(v, descriptions[k - 1], "cut \(cut) returned a partial or wrong entry") }
            XCTAssertGreaterThanOrEqual(parsed.count, lastCount, "recovered entries must not shrink as more text arrives (cut \(cut))")
            lastCount = parsed.count
        }
        XCTAssertEqual(lastCount, 12, "with only the final bracket missing, all 12 entries are complete")
    }

    func testZeroBasedNumberingIsShiftedOnlyWhenUnambiguous() {
        let zero = "[" + (0...4).map { obj($0, ds[$0]) }.joined(separator: ",") + "]"
        let parsed = DescriptionSalvageParser.parse(zero, expectedCount: 5)
        XCTAssertEqual(parsed.byPosition[1], ds[0]); XCTAssertEqual(parsed.byPosition[5], ds[4]); XCTAssertTrue(parsed.diagnostics.zeroBasedShift)
        let ambiguous = "[" + (0...5).map { obj($0, ds[$0 % 5]) }.joined(separator: ",") + "]"
        XCTAssertFalse(DescriptionSalvageParser.parse(ambiguous, expectedCount: 5).diagnostics.zeroBasedShift)
    }
}

private enum LegacyDescriptionParser {
    // MARK: - Legacy behaviour, ported verbatim for A/B testing only

    static func parse(_ rawContent: String) -> [Int: String] {
        var text = rawContent
        if let thinkRange = text.range(of: "<think>"),
           let thinkEndRange = text.range(of: "</think>", range: thinkRange.upperBound..<text.endIndex) {
            text.removeSubrange(thinkRange.lowerBound..<thinkEndRange.upperBound)
        }
        text = text.replacingOccurrences(of: "```json", with: "")
        text = text.replacingOccurrences(of: "```", with: "")
        guard let arrayText = lastBalancedJSONArray(in: text),
              let data = arrayText.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var result: [Int: String] = [:]
        for entry in entries {
            let imageNum: Int? = (entry["image"] as? Int) ?? (Int(entry["image"] as? String ?? ""))
            guard let image = imageNum, let description = entry["description"] as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result[image] = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func lastBalancedJSONArray(in text: String) -> String? {
        let chars = Array(text)
        var lastMatch: String?
        var index = 0
        while index < chars.count {
            if chars[index] == "[" {
                var depth = 0, inString = false, escaped = false
                var end: Int?
                var scan = index
                while scan < chars.count {
                    let c = chars[scan]
                    if inString {
                        if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    } else {
                        if c == "\"" { inString = true }
                        else if c == "[" { depth += 1 }
                        else if c == "]" { depth -= 1; if depth == 0 { end = scan; break } }
                    }
                    scan += 1
                }
                if let end { lastMatch = String(chars[index...end]); index = end + 1; continue }
            }
            index += 1
        }
        return lastMatch
    }
}
