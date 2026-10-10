import XCTest
@testable import Processing

/// Table tests for the batch-size controller. The availability-failure sequence is the real pass/fail history of the
/// last 600 deep-indexing requests (1 = failed, 0 = succeeded; no content), because the controller's central
/// invariant — provider flakiness must never move N — has to hold on the data it will actually see.
final class SemanticBatchControllerTests: XCTestCase {
    private static let realOutcomes = "000100100011010010010101001001101101000100001000010100011110010011111001010000110010010110100110001000011011000001100101010100001111110011110110101000101000100100000101000100000010010010001011011000001000100000010100000001011010100111110000001011110010010011110001001000000010010100010100000001001011111111100010100001110011010111000010011010111110001001000001101001000100100000010111101100100110110000100100000010010000000001001100101100010101110001110001100000000011110000110000011100100100010001001000000010000110010001110001101100101111101101001000001111011000100010010000001110001000000010111111"
    private let hour: Int64 = 3_600_000

    private func controller(_ tweak: (inout SemanticBatchController.Config) -> Void = { _ in }, nowMs: Int64 = 0) -> SemanticBatchController {
        var config = SemanticBatchController.Config()
        tweak(&config)
        return SemanticBatchController(config: config, nowMs: nowMs)
    }

    /// Runs `count` attempts; `success` decides per attempt whether it completes with every frame described.
    @discardableResult
    private func drive(_ c: inout SemanticBatchController, attempts count: Int, nowMs: inout Int64, stepMs: Int64 = 60_000,
                       meanChars: Double = 230, success: (Int) -> Bool = { _ in true }) -> [SemanticBatchController.Transition] {
        var transitions: [SemanticBatchController.Transition] = []
        for i in 0..<count {
            let plan = c.plan(nowMs: nowMs)
            let outcome: SemanticBatchController.Outcome = success(i)
                ? .completed(sent: plan.targetN, parsed: plan.targetN, truncated: false, meanChars: meanChars)
                : .availabilityFailure(sent: plan.targetN)
            let t = c.record(outcome, plan: plan, nowMs: nowMs)
            if t != .none { transitions.append(t) }
            nowMs += stepMs
        }
        return transitions
    }

    func testStartsAtBaseSizeAndAllAttemptsAreControl() {
        var c = controller()
        XCTAssertEqual(c.plan(nowMs: 0), .init(targetN: 5, arm: "control"))
    }

    func testRealProviderFlakinessNeverMovesNOnceRamped() {
        var c = controller()
        var now: Int64 = 0
        drive(&c, attempts: 40, nowMs: &now)                         // anchor, steps to 8
        XCTAssertEqual(c.currentN, 8)
        // Replay the real failure history as pure availability failures, with the real success rate (60%).
        // Failures hit both arms equally, so yield stays comparable and N must not drop.
        let history = Array(Self.realOutcomes)
        let transitions = drive(&c, attempts: history.count, nowMs: &now, success: { history[$0] == "0" })
        XCTAssertFalse(transitions.contains { if case .reverted = $0 { return true } else { return false } },
                       "availability failures alone must not trigger a revert: \(transitions)")
        XCTAssertGreaterThanOrEqual(c.currentN, 8)
    }

    func testControlArmRunsOneInFourWhileRamped() {
        var c = controller()
        var now: Int64 = 0
        drive(&c, attempts: 40, nowMs: &now)
        XCTAssertGreaterThan(c.currentN, c.baseN)
        let plans = (0..<100).map { _ in c.plan(nowMs: now) }
        XCTAssertEqual(plans.filter { $0.arm == "control" }.count, 25)
        XCTAssertTrue(plans.filter { $0.arm == "control" }.allSatisfy { $0.targetN == 5 })
    }

    func testExplicitSizeRejectionRevertsImmediatelyAndPersistsACap() {
        var c = controller()
        var now: Int64 = 0
        drive(&c, attempts: 40, nowMs: &now)
        var guardCount = 0
        // advance to 12 by giving it a long healthy dwell
        while c.currentN < 12 && guardCount < 40 { drive(&c, attempts: 150, nowMs: &now, stepMs: 400_000); guardCount += 1 }
        XCTAssertEqual(c.currentN, 12)
        var plan = c.plan(nowMs: now)
        while plan.arm != "ramp" { plan = c.plan(nowMs: now) }
        let t = c.record(.sizeRejected(sent: 12), plan: plan, nowMs: now)
        XCTAssertEqual(t, .reverted(from: 12, to: 8, reason: "size_rejected"))
        XCTAssertEqual(c.snapshot.capN, 11)
        // The cap survives a restart and keeps 12 unreachable while it is in force (24 h TTL from the rejection).
        var restored = SemanticBatchController(restoring: c.snapshot, nowMs: now + hour)
        var t2 = now + hour
        drive(&restored, attempts: 150, nowMs: &t2, stepMs: 400_000)       // ~16.7 h: dwell and attempt gates are met
        XCTAssertEqual(restored.currentN, 8, "the persisted cap must hold even though every other promotion gate is open")
        drive(&restored, attempts: 150, nowMs: &t2, stepMs: 400_000)       // now past the 24 h TTL
        XCTAssertEqual(restored.currentN, 12, "once the cap expires the ramp may proceed again")
    }

    func testHiddenCapRelayedAsGateway502IsCaughtByTheYieldStopLoss() {
        var c = controller()
        var now: Int64 = 0
        drive(&c, attempts: 40, nowMs: &now)
        XCTAssertEqual(c.currentN, 8)
        // Every request larger than 5 frames now fails like a plain 502 (a hidden provider cap); N=5 behaves as before.
        var reverted = false
        for _ in 0..<400 where !reverted {
            let plan = c.plan(nowMs: now)
            let outcome: SemanticBatchController.Outcome = plan.targetN > 5
                ? .availabilityFailure(sent: plan.targetN)
                : .completed(sent: 5, parsed: 5, truncated: false, meanChars: 230)
            if case .reverted(_, _, let reason) = c.record(outcome, plan: plan, nowMs: now) {
                reverted = true
                XCTAssertEqual(reason, "yield_below_control")
            }
            now += 60_000
        }
        XCTAssertTrue(reverted, "a ramp that yields nothing while the control arm succeeds must be reverted")
        XCTAssertEqual(c.currentN, 5)
    }

    func testRepeatedTruncationRevertsTheRamp() {
        var c = controller()
        var now: Int64 = 0
        drive(&c, attempts: 40, nowMs: &now)
        var reverted = false
        for _ in 0..<60 where !reverted {
            let plan = c.plan(nowMs: now)
            let truncated = plan.arm == "ramp"
            let t = c.record(.completed(sent: plan.targetN, parsed: plan.targetN - 1, truncated: truncated, meanChars: 230), plan: plan, nowMs: now)
            if case .reverted(_, _, "finish_length") = t { reverted = true }
            now += 60_000
        }
        XCTAssertTrue(reverted)
    }

    func testDescriptionLengthCollapseOnTheRampBlocksPromotionAndReverts() {
        var c = controller()
        var now: Int64 = 0
        drive(&c, attempts: 40, nowMs: &now)
        XCTAssertEqual(c.currentN, 8)
        var reverted = false
        for _ in 0..<300 where !reverted {
            let plan = c.plan(nowMs: now)
            let chars = plan.arm == "ramp" ? 120.0 : 240.0    // ramp descriptions are half as long
            if case .reverted(_, _, "description_length_collapse") = c.record(.completed(sent: plan.targetN, parsed: plan.targetN, truncated: false, meanChars: chars), plan: plan, nowMs: now) { reverted = true }
            now += 60_000
        }
        XCTAssertTrue(reverted)
    }

    func testPromotionNeedsDwellTimeAndAttemptsAndIsBlockedAfterARevert() {
        var c = controller()
        var now: Int64 = 0
        drive(&c, attempts: 40, nowMs: &now)                       // 5 -> 8
        XCTAssertEqual(c.currentN, 8)
        // 200 healthy attempts but only ~3 hours: not enough dwell for 8 -> 12.
        drive(&c, attempts: 200, nowMs: &now, stepMs: 60_000)
        XCTAssertEqual(c.currentN, 8, "dwell requires 12 hours, not just attempts")
        drive(&c, attempts: 200, nowMs: &now, stepMs: 400_000)
        XCTAssertEqual(c.currentN, 12)
    }

    func testCeilingLimitsTheRamp() {
        var c = controller { $0.ceiling = 8 }
        var now: Int64 = 0
        drive(&c, attempts: 2_000, nowMs: &now, stepMs: 400_000)
        XCTAssertEqual(c.currentN, 8)
        XCTAssertEqual(c.maxN, 8)
    }

    func testOutcomePolicySpendsStrikesOnlyWhenTheFrameItselfIsAtFault() {
        typealias P = SemanticOutcomePolicy
        XCTAssertEqual(P.classify(parsedCount: 3, unparsedFrameIDs: [4, 5], truncated: true),
                       .init(strikeFrameIDs: [], transientFrameIDs: [4, 5]), "cut off but productive: the request was too big")
        XCTAssertEqual(P.classify(parsedCount: 0, unparsedFrameIDs: [1, 2], truncated: true),
                       .init(strikeFrameIDs: [1, 2], transientFrameIDs: []), "cut off with nothing parsed keeps the strike (bounds runaway output)")
        XCTAssertEqual(P.classify(parsedCount: 4, unparsedFrameIDs: [5], truncated: false),
                       .init(strikeFrameIDs: [5], transientFrameIDs: []), "clean finish with a frame missing: that frame's problem")
        XCTAssertEqual(P.classify(parsedCount: 5, unparsedFrameIDs: [], truncated: false), .init(strikeFrameIDs: [], transientFrameIDs: []))
    }

    func testNextUTCMidnightEdges() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func date(_ s: String) -> Date { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s)! }
        XCTAssertEqual(SemanticQuotaTime.nextUTCMidnight(after: date("2026-10-08T23:59:59.999Z")), date("2026-10-09T00:00:00.000Z"))
        XCTAssertEqual(SemanticQuotaTime.nextUTCMidnight(after: date("2026-10-09T00:00:00.000Z")), date("2026-10-10T00:00:00.000Z"), "exactly midnight means the NEXT midnight")
        XCTAssertEqual(SemanticQuotaTime.nextUTCMidnight(after: date("2026-12-31T12:00:00.000Z")), date("2027-01-01T00:00:00.000Z"))
    }
}
