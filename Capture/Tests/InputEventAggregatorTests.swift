import XCTest
import Shared
@testable import Capture

/// The aggregator is a pure state machine, so these tests drive it with synthetic timestamps. They
/// pin the privacy contract (no characters, secure input discards typing) and the pairing rules.
final class InputEventAggregatorTests: XCTestCase {

    private var aggregator = InputEventAggregator()

    override func setUp() {
        aggregator = InputEventAggregator()
    }

    // MARK: - Clicks

    func testClickPairsDownAndUpAndUsesMouseDownTime() {
        let down = aggregator.ingest(RawInputEvent(kind: .mouseDown(.left), tsMs: 1_000, x: 40, y: 50, modifiers: [.command], clickCount: 1))
        XCTAssertEqual(down, [.mouseDown(InputMouseDown(button: .left, tsMs: 1_000, x: 40, y: 50))])

        let up = aggregator.ingest(RawInputEvent(kind: .mouseUp(.left), tsMs: 1_085, x: 41, y: 51, modifiers: [], clickCount: 1))
        XCTAssertEqual(up.count, 1)
        guard case .event(let draft) = up[0] else { return XCTFail("expected a click event") }
        XCTAssertEqual(draft.kind, .click)
        XCTAssertEqual(draft.tsMs, 1_000, "decision time is mouse-down")
        XCTAssertEqual(draft.endTsMs, 1_085)
        XCTAssertEqual(draft.button, .left)
        XCTAssertEqual(draft.clickCount, 1)
        XCTAssertEqual(draft.modifiers, ["cmd"], "modifiers held when the button went down")
        XCTAssertEqual(draft.x, 40)
        XCTAssertEqual(draft.y, 50)
    }

    func testDoubleClickCarriesClickCount() {
        _ = aggregator.ingest(RawInputEvent(kind: .mouseDown(.left), tsMs: 2_000, x: 10, y: 10, clickCount: 2))
        let up = aggregator.ingest(RawInputEvent(kind: .mouseUp(.left), tsMs: 2_050, x: 10, y: 10, clickCount: 2))
        guard case .event(let draft) = up.first else { return XCTFail("expected click") }
        XCTAssertEqual(draft.clickCount, 2)
    }

    func testDragIsNotAClick() {
        _ = aggregator.ingest(RawInputEvent(kind: .mouseDown(.left), tsMs: 1_000, x: 10, y: 10, clickCount: 1))
        let up = aggregator.ingest(RawInputEvent(kind: .mouseUp(.left), tsMs: 1_400, x: 200, y: 10, clickCount: 1))
        XCTAssertEqual(up, [.dropped(.drag)])
    }

    func testSmallJitterStillCountsAsClick() {
        _ = aggregator.ingest(RawInputEvent(kind: .mouseDown(.right), tsMs: 1_000, x: 10, y: 10, clickCount: 1))
        let up = aggregator.ingest(RawInputEvent(kind: .mouseUp(.right), tsMs: 1_060, x: 13, y: 12, clickCount: 1))
        guard case .event(let draft) = up.first else { return XCTFail("expected click") }
        XCTAssertEqual(draft.button, .right)
    }

    func testMouseUpWithoutDownIsIgnored() {
        XCTAssertEqual(aggregator.ingest(RawInputEvent(kind: .mouseUp(.left), tsMs: 1_000, x: 1, y: 1)), [])
    }

    func testButtonsArePairedIndependently() {
        _ = aggregator.ingest(RawInputEvent(kind: .mouseDown(.left), tsMs: 1_000, x: 10, y: 10, clickCount: 1))
        _ = aggregator.ingest(RawInputEvent(kind: .mouseDown(.right), tsMs: 1_010, x: 90, y: 90, clickCount: 1))
        let rightUp = aggregator.ingest(RawInputEvent(kind: .mouseUp(.right), tsMs: 1_050, x: 90, y: 90, clickCount: 1))
        guard case .event(let draft) = rightUp.first else { return XCTFail("expected click") }
        XCTAssertEqual(draft.button, .right)
        XCTAssertEqual(draft.x, 90)
    }

    // MARK: - Scroll

    func testScrollTicksCoalesceIntoOneBurst() {
        XCTAssertEqual(aggregator.ingest(RawInputEvent(kind: .scroll(dx: 0, dy: -10), tsMs: 1_000, x: 300, y: 400)), [])
        XCTAssertEqual(aggregator.ingest(RawInputEvent(kind: .scroll(dx: 2, dy: -30), tsMs: 1_050, x: 305, y: 405)), [])
        XCTAssertEqual(aggregator.ingest(RawInputEvent(kind: .scroll(dx: 0, dy: -20), tsMs: 1_120, x: 305, y: 405)), [])
        XCTAssertEqual(aggregator.nextFlushDeadlineMs, 1_120 + InputEventAggregator.scrollBurstGapMs)

        let out = aggregator.flush(nowMs: 1_300)
        guard case .event(let draft) = out.first else { return XCTFail("expected scroll") }
        XCTAssertEqual(draft.kind, .scroll)
        XCTAssertEqual(draft.tsMs, 1_000)
        XCTAssertEqual(draft.endTsMs, 1_120)
        XCTAssertEqual(draft.scrollDx, 2)
        XCTAssertEqual(draft.scrollDy, -60)
        XCTAssertEqual(draft.x, 300, "position is where the burst started")
        XCTAssertNil(aggregator.nextFlushDeadlineMs)
    }

    func testScrollGapStartsANewBurst() {
        _ = aggregator.ingest(RawInputEvent(kind: .scroll(dx: 0, dy: -10), tsMs: 1_000, x: 1, y: 1))
        let second = aggregator.ingest(RawInputEvent(kind: .scroll(dx: 0, dy: 25), tsMs: 2_000, x: 1, y: 1))
        guard case .event(let first) = second.first else { return XCTFail("first burst should close") }
        XCTAssertEqual(first.scrollDy, -10)
        let tail = aggregator.flush(nowMs: 3_000)
        guard case .event(let next) = tail.first else { return XCTFail("second burst should close") }
        XCTAssertEqual(next.scrollDy, 25)
    }

    func testScrollThatNetsToZeroIsDiscarded() {
        _ = aggregator.ingest(RawInputEvent(kind: .scroll(dx: 0, dy: 0), tsMs: 1_000, x: 1, y: 1))
        XCTAssertEqual(aggregator.flush(nowMs: 5_000), [])
    }

    func testClickClosesOpenScrollBurstFirst() {
        _ = aggregator.ingest(RawInputEvent(kind: .scroll(dx: 0, dy: -10), tsMs: 1_000, x: 1, y: 1))
        let out = aggregator.ingest(RawInputEvent(kind: .mouseDown(.left), tsMs: 1_060, x: 5, y: 5, clickCount: 1))
        XCTAssertEqual(out.count, 2)
        guard case .event(let scroll) = out[0] else { return XCTFail("scroll should close before the click starts") }
        XCTAssertEqual(scroll.kind, .scroll)
        XCTAssertEqual(out[1], .mouseDown(InputMouseDown(button: .left, tsMs: 1_060, x: 5, y: 5)))
    }

    // MARK: - Shortcuts

    func testCommandShiftTIsASpelledOutShortcut() {
        let out = aggregator.ingest(key(17, at: 1_000, modifiers: [.command, .shift]))
        guard case .event(let draft) = out.first else { return XCTFail("expected shortcut") }
        XCTAssertEqual(draft.kind, .shortcut)
        XCTAssertEqual(draft.keyCombo, "cmd+shift+t")
        XCTAssertEqual(draft.modifiers, ["cmd", "shift"])
        XCTAssertNil(draft.typedCount)
    }

    func testControlCombosAreShortcuts() {
        let out = aggregator.ingest(key(8, at: 1_000, modifiers: [.control]))
        guard case .event(let draft) = out.first else { return XCTFail("expected shortcut") }
        XCTAssertEqual(draft.keyCombo, "ctrl+c")
    }

    func testOptionOrShiftOnlyKeysAreTypingNotShortcuts() {
        // Opt+letter and Shift+letter produce characters on most layouts, so they must not be
        // spelled out as combos.
        let option = aggregator.ingest(key(0, at: 1_000, modifiers: [.option]))
        XCTAssertEqual(option, [.typingStarted(tsMs: 1_000)])
        let shift = aggregator.ingest(key(0, at: 1_100, modifiers: [.shift]))
        XCTAssertEqual(shift, [])
        guard case .event(let draft) = aggregator.flush(nowMs: 10_000).first else { return XCTFail("expected typing") }
        XCTAssertEqual(draft.kind, .typing)
        XCTAssertEqual(draft.typedCount, 2)
        XCTAssertNil(draft.keyCombo)
    }

    func testSpecialKeysAreLoggedIndividuallyAndDoNotCountAsTyping() {
        let enter = aggregator.ingest(key(36, at: 1_000))
        guard case .event(let ret) = enter.first else { return XCTFail("expected return") }
        XCTAssertEqual(ret.keyCombo, "return")

        let shiftTab = aggregator.ingest(key(48, at: 1_100, modifiers: [.shift]))
        guard case .event(let tab) = shiftTab.first else { return XCTFail("expected tab") }
        XCTAssertEqual(tab.keyCombo, "shift+tab")

        let arrow = aggregator.ingest(key(125, at: 1_200))
        guard case .event(let down) = arrow.first else { return XCTFail("expected arrow") }
        XCTAssertEqual(down.keyCombo, "down")
        XCTAssertNil(aggregator.nextFlushDeadlineMs, "special keys never open a typing burst")
    }

    func testHeldShortcutKeyDoesNotRepeat() {
        _ = aggregator.ingest(key(30, at: 1_000, modifiers: [.command]))
        let repeated = aggregator.ingest(key(30, at: 1_030, modifiers: [.command], isRepeat: true))
        XCTAssertEqual(repeated, [])
    }

    // MARK: - Typing

    func testTypingBurstRecordsOnlyACount() {
        let first = aggregator.ingest(key(4, at: 1_000))
        XCTAssertEqual(first, [.typingStarted(tsMs: 1_000)])
        for (offset, code) in [UInt16]([14, 37, 37, 31]).enumerated() {
            XCTAssertEqual(aggregator.ingest(key(code, at: 1_100 + Int64(offset) * 100)), [])
        }
        XCTAssertEqual(aggregator.nextFlushDeadlineMs, 1_400 + InputEventAggregator.typingIdleMs)

        let closed = aggregator.flush(nowMs: 1_400 + InputEventAggregator.typingIdleMs + 1)
        guard case .event(let draft) = closed.first else { return XCTFail("expected typing") }
        XCTAssertEqual(draft.kind, .typing)
        XCTAssertEqual(draft.typedCount, 5)
        XCTAssertEqual(draft.tsMs, 1_000)
        XCTAssertEqual(draft.endTsMs, 1_400)
        XCTAssertNil(draft.keyCombo, "no key names or characters for typing")
    }

    func testTypingIdleGapSplitsBursts() {
        _ = aggregator.ingest(key(0, at: 1_000))
        _ = aggregator.ingest(key(1, at: 1_100))
        let resumed = aggregator.ingest(key(2, at: 4_000))
        XCTAssertEqual(resumed.count, 2)
        guard case .event(let earlier) = resumed[0] else { return XCTFail("old burst should close") }
        XCTAssertEqual(earlier.typedCount, 2)
        XCTAssertEqual(resumed[1], .typingStarted(tsMs: 4_000))
    }

    func testShortcutAndClickCloseTheTypingBurstFirst() {
        _ = aggregator.ingest(key(0, at: 1_000))
        _ = aggregator.ingest(key(1, at: 1_100))
        let paste = aggregator.ingest(key(9, at: 1_200, modifiers: [.command]))
        XCTAssertEqual(paste.count, 2)
        guard case .event(let typing) = paste[0], case .event(let shortcut) = paste[1] else { return XCTFail("order") }
        XCTAssertEqual(typing.kind, .typing)
        XCTAssertEqual(typing.typedCount, 2)
        XCTAssertEqual(shortcut.keyCombo, "cmd+v")

        _ = aggregator.ingest(key(0, at: 2_000))
        let click = aggregator.ingest(RawInputEvent(kind: .mouseDown(.left), tsMs: 2_100, x: 1, y: 1, clickCount: 1))
        guard case .event(let burst) = click.first else { return XCTFail("typing should close on click") }
        XCTAssertEqual(burst.kind, .typing)
        XCTAssertEqual(burst.typedCount, 1)
    }

    func testSecureInputDiscardsTheOpenTypingBurstAndRecordsNothing() {
        _ = aggregator.ingest(key(0, at: 1_000))
        _ = aggregator.ingest(key(1, at: 1_100))
        let secure = aggregator.ingest(key(2, at: 1_200, secureInput: true))
        XCTAssertEqual(secure, [.dropped(.secureInput)])
        XCTAssertEqual(aggregator.flush(nowMs: 100_000), [], "the burst typed before secure input is discarded too")
        XCTAssertNil(aggregator.nextFlushDeadlineMs)
    }

    func testSecureInputShortcutsAreNotRecorded() {
        let out = aggregator.ingest(key(9, at: 1_000, modifiers: [.command], secureInput: true))
        XCTAssertEqual(out, [.dropped(.secureInput)])
    }

    func testFinishFlushesOpenBurstsAndForgetsPendingDowns() {
        _ = aggregator.ingest(key(0, at: 1_000))
        // A scroll interleaving with typing closes the typing burst on the spot...
        let interleaved = aggregator.ingest(RawInputEvent(kind: .scroll(dx: 0, dy: 5), tsMs: 1_010, x: 1, y: 1))
        guard case .event(let typing) = interleaved.first else { return XCTFail("typing should close") }
        XCTAssertEqual(typing.kind, .typing)
        // ...and finish() flushes the scroll burst that is still open.
        let out = aggregator.finish()
        XCTAssertEqual(out.count, 1)
        guard case .event(let scroll) = out.first else { return XCTFail("scroll should flush") }
        XCTAssertEqual(scroll.kind, .scroll)
        _ = aggregator.ingest(RawInputEvent(kind: .mouseDown(.left), tsMs: 2_000, x: 1, y: 1, clickCount: 1))
        _ = aggregator.finish()
        XCTAssertEqual(aggregator.ingest(RawInputEvent(kind: .mouseUp(.left), tsMs: 2_050, x: 1, y: 1)), [])
    }

    // MARK: - Key names

    func testKeyNameTable() {
        XCTAssertEqual(InputKeyNames.combo(keyCode: 17, modifiers: [.command, .shift]), "cmd+shift+t")
        XCTAssertEqual(InputKeyNames.combo(keyCode: 49, modifiers: [.command]), "cmd+space")
        XCTAssertEqual(InputKeyNames.combo(keyCode: 122, modifiers: []), "f1")
        XCTAssertEqual(InputKeyNames.name(for: 999), "key999")
        XCTAssertEqual(InputModifiers([.shift, .option, .control, .command]).names, ["cmd", "ctrl", "opt", "shift"])
    }

    // MARK: - Helpers

    private func key(
        _ code: UInt16,
        at tsMs: Int64,
        modifiers: InputModifiers = [],
        isRepeat: Bool = false,
        secureInput: Bool = false
    ) -> RawInputEvent {
        RawInputEvent(
            kind: .keyDown(keyCode: code, isRepeat: isRepeat, secureInput: secureInput),
            tsMs: tsMs,
            modifiers: modifiers
        )
    }
}
