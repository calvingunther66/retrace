import Foundation

/// Bounds how many times VisionOCR will spin up a new watchdog thread for a
/// hung Vision call before giving up entirely for the rest of the process's
/// lifetime.
///
/// Context: `VisionOCR.performWithWatchdog` runs `handler.perform([request])`
/// on a dedicated `DispatchQueue` so a hang can't wedge the cooperative
/// thread pool. But that underlying call is a synchronous, uncancellable
/// call into Vision's own internal capacity-limited queue
/// (`VNControlledCapacityTasksQueue`). Once that internal queue wedges,
/// every subsequent OCR call also blocks trying to enter it -- observed in
/// production as 300+ leaked `processing.ocr.vision_watchdog` threads, each
/// still holding its retained frame image, consuming tens of GB. Cancelling
/// the request on timeout does not free the blocked thread; only abandoning
/// the attempt does, and each abandoned attempt is a permanent leak.
///
/// This breaker makes that leak bounded instead of unbounded: after
/// `threshold` *consecutive* timeouts, it trips, and every OCR call fails
/// immediately without touching Vision (no new thread, no new leak) until
/// the process restarts. A threshold of 1 would also stop the leak but risks
/// disabling OCR for the rest of the session over a single isolated slow
/// frame; requiring consecutive failures (any success resets the counter)
/// distinguishes "Vision is globally wedged" (every call hangs) from
/// "one frame was unusually slow" (rare, self-resolving).
final class OCRCircuitBreaker: @unchecked Sendable {
    private let lock = NSLock()
    private var consecutiveTimeouts = 0
    private var tripped = false

    let threshold: Int

    init(threshold: Int = 2) {
        precondition(threshold >= 1, "threshold must be at least 1")
        self.threshold = threshold
    }

    /// Whether a new Vision call is currently allowed.
    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tripped
    }

    /// Number of consecutive timeouts recorded so far (for diagnostics/logging).
    var consecutiveTimeoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return consecutiveTimeouts
    }

    /// Call after a Vision request completes (successfully or with a
    /// non-timeout error) -- resets the consecutive-timeout streak.
    func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveTimeouts = 0
    }

    /// Call after a Vision request's watchdog fires. Returns true if this
    /// call is the one that trips the breaker.
    @discardableResult
    func recordTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        consecutiveTimeouts += 1
        if consecutiveTimeouts >= threshold {
            tripped = true
        }
        return tripped
    }

    /// Restores a fresh, untripped state. Used by tests, by the user-initiated
    /// "Restart OCR" recovery action, and by
    /// `FrameProcessingQueue.attemptOCRAutoRecoveryIfEligible()` (via
    /// `VisionOCR.resetCircuitBreaker()`) once system resource pressure has been
    /// nominal for a sustained period. Deliberately never resets on a bare timer —
    /// the underlying Vision wedge this breaker guards against doesn't self-heal on
    /// its own, so retrying on a fixed schedule regardless of system state would just
    /// reproduce the original unbounded leak; gating on pressure having actually
    /// recovered is what makes the automatic retry safe.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveTimeouts = 0
        tripped = false
    }
}
