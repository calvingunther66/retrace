import XCTest
@testable import Search
import Shared

final class OnDeviceLanguageModelTests: XCTestCase {
    private func frame(_ id: Int64, chars: Int) -> OpenRouterContextFrame {
        OpenRouterContextFrame(frameID: id, timestamp: Date(timeIntervalSince1970: 1_000 + Double(id)), appName: "Claude",
                               extractedText: String(repeating: "x", count: chars))
    }

    func testEvidenceThatFitsIsKeptWhole() {
        let frames = (1...4).map { frame($0, chars: 300) }
        let fitted = OnDeviceLanguageModel.fit(query: "q", frames: frames, preamble: "now", contextTokens: 8_192)
        XCTAssertEqual(fitted.framesUsed, 4)
        XCTAssertTrue(fitted.prompt.contains("[Frame #4]"))
    }

    func testOversizedEvidenceDropsTheOldestFramesFirstAndNeverEmpties() {
        // Packs are newest-first for "latest" questions, so trimming from the end drops the oldest evidence.
        let frames = (1...12).map { frame($0, chars: 900) }
        let fitted = OnDeviceLanguageModel.fit(query: "q", frames: frames, preamble: nil, contextTokens: 4_096)

        XCTAssertLessThan(fitted.framesUsed, 12)
        XCTAssertGreaterThanOrEqual(fitted.framesUsed, 1)
        XCTAssertTrue(fitted.prompt.contains("[Frame #1]"), "the first (newest) frame must survive")
        XCTAssertFalse(fitted.prompt.contains("[Frame #12]"))
        XCTAssertLessThanOrEqual(fitted.prompt.count, (4_096 - 1_100) * 3 + 200)
    }

    func testSingleHugeFrameIsClippedRatherThanDropped() {
        let fitted = OnDeviceLanguageModel.fit(query: "q", frames: [frame(1, chars: 50_000)], preamble: nil, contextTokens: 4_096)
        XCTAssertEqual(fitted.framesUsed, 1)
        XCTAssertLessThan(fitted.prompt.count, 3_000)
    }
}
