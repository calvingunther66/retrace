import Foundation

/// Decides how many frames each cloud-vision indexing request carries, and detects when a larger batch is
/// hurting instead of helping. Pure value logic: no I/O, no clock — the caller passes `nowMs`.
///
/// Why this exists: every deep-indexing request used to carry exactly 5 frames, and about 43% of requests fail
/// outright (provider-side 502s that do not depend on request size). Frames per request is therefore the one
/// lever that multiplies everything else — but no batch larger than 5 had ever been sent, so nothing is known
/// about the provider's real limits (images per request, body size). The controller makes the increase safe:
///
///  * A **permanent control arm** at the base size (every `controlEvery`-th dispatch) keeps a live baseline, so
///    "is the bigger batch actually better?" is always answerable from the same hours and the same provider state.
///  * **Availability failures never move N.** HTTP 502/5xx/429, transport errors and embedded-error 200s say
///    nothing about request size (reviewed: naive halve-on-any-failure replays to *worse* than fixed N=5).
///    Only size signals do: an explicit 400/413/422 about images or payload, repeated `finish_reason == length`,
///    repeated client timeouts, and incomplete parses.
///  * A **yield stop-loss** compares frames-with-usable-descriptions per attempt between the arms using *all*
///    outcomes, which also catches a hidden size cap that the provider relays as a plain 502.
///  * Promotion needs dwell time (attempts and wall-clock), a clean parse rate, and description length that has
///    not collapsed relative to the control arm (a cheap online proxy for "long batches degrade per-frame detail").
struct SemanticBatchController: Sendable {

    // MARK: - Configuration

    struct Config: Sendable {
        /// Ascending batch sizes. The first is the base/control size.
        var steps: [Int] = [5, 8, 12]
        /// Largest size this build may use (steps above it are ignored).
        var ceiling: Int = 12
        /// While above the base size, every n-th dispatch uses the base size.
        var controlEvery: Int = 4
        var minDwellAttempts: Int = 150
        var minDwellMs: Int64 = 12 * 3_600_000
        /// Stop-loss window: both arms need at least this many attempts in the current step.
        var stopLossMinRampAttempts: Int = 100
        var stopLossMinControlAttempts: Int = 33
        /// `finish_reason == length` this often within the last `lengthWindow` ramp attempts reverts.
        var lengthLimit: Int = 2
        var lengthWindow: Int = 10
        var timeoutLimit: Int = 3
        var timeoutWindow: Int = 20
        /// Parse completeness over the last `parseWindow` completed ramp responses.
        var parseWindow: Int = 20
        var parseRevertBelow: Double = 0.90
        var parsePromoteAtLeast: Double = 0.97
        /// Mean description length, ramp vs control, over completed responses in the step.
        var lengthRatioPromoteAtLeast: Double = 0.85
        var lengthRatioRevertBelow: Double = 0.75
        var lengthRatioMinCompletions: Int = 40
        /// After any revert, no promotion for this long.
        var revertCooldownMs: Int64 = 24 * 3_600_000
        /// A size-rejection cap (N-1) stays in force this long.
        var capTTLMs: Int64 = 24 * 3_600_000

        var effectiveSteps: [Int] {
            let kept = steps.filter { $0 <= ceiling }
            return kept.isEmpty ? [steps.first ?? 5] : kept
        }
    }

    // MARK: - Inputs and outputs

    struct Plan: Sendable, Equatable {
        let targetN: Int
        /// "control" (base size) or "ramp".
        let arm: String
    }

    enum Outcome: Sendable {
        /// HTTP 200 with a parsed body.
        case completed(sent: Int, parsed: Int, truncated: Bool, meanChars: Double?)
        /// Explicit 400/413/422 about images or payload size.
        case sizeRejected(sent: Int)
        /// Client-side request timeout.
        case timedOut(sent: Int)
        /// 502/5xx/429, transport failure, or an error embedded in a 200 — says nothing about size.
        case availabilityFailure(sent: Int)
        /// Anything else that is not evidence about batch size (auth, cancellation, local errors).
        case ignored
    }

    enum Transition: Sendable, Equatable {
        case none
        case steppedUp(from: Int, to: Int)
        case reverted(from: Int, to: Int, reason: String)
    }

    /// What to persist across launches (window statistics deliberately restart, so a relaunch re-earns trust).
    struct Snapshot: Codable, Sendable, Equatable {
        var stepIndex: Int
        var capN: Int?
        var capExpiresAtMs: Int64?
        var promotionBlockedUntilMs: Int64
    }

    // MARK: - State

    private(set) var config: Config
    private(set) var stepIndex: Int
    private(set) var capN: Int?
    private(set) var capExpiresAtMs: Int64?
    private(set) var promotionBlockedUntilMs: Int64
    private var dispatchCounter = 0
    private static let maxWindowAttempts = 400
    private var stepStartedAtMs: Int64

    private struct Attempt {
        let completed: Bool
        let usable: Int
        let sent: Int
        let truncated: Bool
        let timedOut: Bool
        let meanChars: Double?
    }
    private var rampAttempts: [Attempt] = []
    private var controlAttempts: [Attempt] = []

    init(config: Config = Config(), restoring snapshot: Snapshot? = nil, nowMs: Int64) {
        self.config = config
        let steps = config.effectiveSteps
        self.stepIndex = min(max(snapshot?.stepIndex ?? 0, 0), steps.count - 1)
        self.capN = snapshot?.capN
        self.capExpiresAtMs = snapshot?.capExpiresAtMs
        self.promotionBlockedUntilMs = snapshot?.promotionBlockedUntilMs ?? 0
        self.stepStartedAtMs = nowMs
        clampToCap(nowMs: nowMs)
    }

    var baseN: Int { config.effectiveSteps[0] }
    var currentN: Int { config.effectiveSteps[stepIndex] }
    /// Largest batch worth selecting candidates for.
    var maxN: Int { config.effectiveSteps.last ?? baseN }

    var snapshot: Snapshot {
        Snapshot(stepIndex: stepIndex, capN: capN, capExpiresAtMs: capExpiresAtMs, promotionBlockedUntilMs: promotionBlockedUntilMs)
    }

    // MARK: - Planning

    mutating func plan(nowMs: Int64) -> Plan {
        clampToCap(nowMs: nowMs)
        guard currentN > baseN else { return Plan(targetN: baseN, arm: "control") }
        defer { dispatchCounter += 1 }
        let isControl = config.controlEvery > 0 && dispatchCounter % config.controlEvery == config.controlEvery - 1
        return isControl ? Plan(targetN: baseN, arm: "control") : Plan(targetN: currentN, arm: "ramp")
    }

    // MARK: - Recording

    @discardableResult
    mutating func record(_ outcome: Outcome, plan: Plan, nowMs: Int64) -> Transition {
        let isRamp = plan.arm == "ramp"
        let attempt: Attempt
        switch outcome {
        case .ignored:
            return .none
        case let .completed(sent, parsed, truncated, meanChars):
            attempt = Attempt(completed: true, usable: parsed, sent: sent, truncated: truncated, timedOut: false, meanChars: meanChars)
        case let .timedOut(sent):
            attempt = Attempt(completed: false, usable: 0, sent: sent, truncated: false, timedOut: true, meanChars: nil)
        case let .availabilityFailure(sent):
            attempt = Attempt(completed: false, usable: 0, sent: sent, truncated: false, timedOut: false, meanChars: nil)
        case let .sizeRejected(sent):
            // An explicit size rejection is conclusive on its own: revert now and remember the limit.
            guard isRamp else { return .none }
            let from = currentN
            capN = max(baseN, sent - 1)
            capExpiresAtMs = nowMs + config.capTTLMs
            return revert(nowMs: nowMs, from: from, reason: "size_rejected")
        }

        if isRamp {
            rampAttempts.append(attempt)
            if rampAttempts.count > Self.maxWindowAttempts { rampAttempts.removeFirst(rampAttempts.count - Self.maxWindowAttempts) }
        } else {
            controlAttempts.append(attempt)
            if controlAttempts.count > Self.maxWindowAttempts { controlAttempts.removeFirst(controlAttempts.count - Self.maxWindowAttempts) }
        }
        // At the base size every attempt is a control attempt. Once enough of them exist to anchor the
        // comparison, take the first step up.
        guard currentN > baseN else { return promoteFromBase(nowMs: nowMs) }
        // Only ramp-arm results can condemn the ramp; control attempts just feed the comparison.
        if isRamp, let reason = hardStopReason() {
            return revert(nowMs: nowMs, from: currentN, reason: reason)
        }
        if let reason = stopLossReason() {
            return revert(nowMs: nowMs, from: currentN, reason: reason)
        }
        return promoteIfReady(nowMs: nowMs)
    }

    // MARK: - Decisions

    private func hardStopReason() -> String? {
        let recent = rampAttempts.suffix(config.lengthWindow)
        if recent.filter({ $0.truncated }).count >= config.lengthLimit { return "finish_length" }
        let recentTimeouts = rampAttempts.suffix(config.timeoutWindow)
        if recentTimeouts.filter({ $0.timedOut }).count >= config.timeoutLimit { return "timeouts" }
        let completed = rampAttempts.filter { $0.completed }.suffix(config.parseWindow)
        if completed.count >= config.parseWindow, parseCompleteness(completed) < config.parseRevertBelow { return "parse_incomplete" }
        return nil
    }

    private func stopLossReason() -> String? {
        if rampAttempts.count >= config.stopLossMinRampAttempts, controlAttempts.count >= config.stopLossMinControlAttempts,
           yieldPerAttempt(rampAttempts) < yieldPerAttempt(controlAttempts) {
            return "yield_below_control"
        }
        let rampLengths = rampAttempts.compactMap { $0.completed ? $0.meanChars : nil }
        let controlLengths = controlAttempts.compactMap { $0.completed ? $0.meanChars : nil }
        if rampLengths.count >= config.lengthRatioMinCompletions, controlLengths.count >= config.lengthRatioMinCompletions / 2,
           let ratio = lengthRatio(ramp: rampLengths, control: controlLengths), ratio < config.lengthRatioRevertBelow {
            return "description_length_collapse"
        }
        return nil
    }

    private mutating func promoteIfReady(nowMs: Int64) -> Transition {
        let steps = config.effectiveSteps
        guard stepIndex + 1 < steps.count else { return .none }
        let next = steps[stepIndex + 1]
        if let capN, let capExpiresAtMs, nowMs < capExpiresAtMs, next > capN { return .none }
        guard nowMs >= promotionBlockedUntilMs else { return .none }
        guard rampAttempts.count >= config.minDwellAttempts,
              nowMs - stepStartedAtMs >= config.minDwellMs else { return .none }
        let completed = rampAttempts.filter { $0.completed }
        guard !completed.isEmpty, parseCompleteness(completed.suffix(config.parseWindow)) >= config.parsePromoteAtLeast else { return .none }
        let rampLengths = completed.compactMap { $0.meanChars }
        let controlLengths = controlAttempts.compactMap { $0.completed ? $0.meanChars : nil }
        if !controlLengths.isEmpty, !rampLengths.isEmpty,
           let ratio = lengthRatio(ramp: rampLengths, control: controlLengths), ratio < config.lengthRatioPromoteAtLeast { return .none }
        // A step is only trusted once the ramp has not been outperformed by the control arm.
        if controlAttempts.count >= config.stopLossMinControlAttempts,
           yieldPerAttempt(rampAttempts) < yieldPerAttempt(controlAttempts) { return .none }

        let from = currentN
        stepIndex += 1
        resetWindow(nowMs: nowMs)
        return .steppedUp(from: from, to: currentN)
    }

    private mutating func promoteFromBase(nowMs: Int64) -> Transition {
        let steps = config.effectiveSteps
        guard steps.count > 1, controlAttempts.count >= config.stopLossMinControlAttempts else { return .none }
        let next = steps[1]
        if let capN, let capExpiresAtMs, nowMs < capExpiresAtMs, next > capN { return .none }
        guard nowMs >= promotionBlockedUntilMs else { return .none }
        let from = currentN
        stepIndex = 1
        resetWindow(nowMs: nowMs)
        return .steppedUp(from: from, to: currentN)
    }

    private mutating func revert(nowMs: Int64, from: Int, reason: String) -> Transition {
        promotionBlockedUntilMs = nowMs + config.revertCooldownMs
        if stepIndex > 0 { stepIndex -= 1 }
        clampToCap(nowMs: nowMs)
        resetWindow(nowMs: nowMs)
        return .reverted(from: from, to: currentN, reason: reason)
    }

    private mutating func clampToCap(nowMs: Int64) {
        if let expires = capExpiresAtMs, nowMs >= expires {
            capN = nil
            capExpiresAtMs = nil
        }
        guard let capN else { return }
        let steps = config.effectiveSteps
        while stepIndex > 0 && steps[stepIndex] > capN { stepIndex -= 1 }
    }

    private mutating func resetWindow(nowMs: Int64) {
        rampAttempts.removeAll(keepingCapacity: true)
        controlAttempts.removeAll(keepingCapacity: true)
        stepStartedAtMs = nowMs
    }

    // MARK: - Statistics

    private func yieldPerAttempt(_ attempts: [Attempt]) -> Double {
        guard !attempts.isEmpty else { return 0 }
        return Double(attempts.reduce(0) { $0 + $1.usable }) / Double(attempts.count)
    }

    private func parseCompleteness<S: Sequence>(_ completed: S) -> Double where S.Element == Attempt {
        var sent = 0, parsed = 0
        for attempt in completed { sent += attempt.sent; parsed += attempt.usable }
        return sent == 0 ? 1 : Double(parsed) / Double(sent)
    }

    private func lengthRatio(ramp: [Double], control: [Double]) -> Double? {
        guard !ramp.isEmpty, !control.isEmpty else { return nil }
        let controlMean = control.reduce(0, +) / Double(control.count)
        guard controlMean > 0 else { return nil }
        return (ramp.reduce(0, +) / Double(ramp.count)) / controlMean
    }
}

// MARK: - Outcome policy (what happens to frames a response did not describe)

/// Separates "this frame could not be described" from "this request's output was cut off". Only the former
/// should spend one of a frame's retry attempts.
enum SemanticOutcomePolicy {
    struct Decision: Equatable {
        /// Spend a retry attempt (3 strikes → permanently failed).
        var strikeFrameIDs: [Int64]
        /// Return to pending without spending a retry attempt.
        var transientFrameIDs: [Int64]
    }

    static func classify(parsedCount: Int, unparsedFrameIDs: [Int64], truncated: Bool) -> Decision {
        guard !unparsedFrameIDs.isEmpty else { return Decision(strikeFrameIDs: [], transientFrameIDs: []) }
        // A reply that was cut off by the output limit but still produced complete entries says the REQUEST was too
        // big, not that the missing frames are undescribable. A truncated reply that produced nothing keeps the
        // strike, which bounds a runaway-generation loop.
        if truncated && parsedCount > 0 {
            return Decision(strikeFrameIDs: [], transientFrameIDs: unparsedFrameIDs)
        }
        return Decision(strikeFrameIDs: unparsedFrameIDs, transientFrameIDs: [])
    }
}

// MARK: - Quota helper

enum SemanticQuotaTime {
    /// The next 00:00 UTC strictly after `date` (OpenRouter's daily free-model counters reset at UTC midnight).
    static func nextUTCMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)!
    }
}
