import AppKit
import Foundation
import MachO
import os

/// Times every main run-loop iteration and, via a watcher thread, samples the main thread's stack while an
/// iteration is overrunning.
///
/// One iteration = `afterWaiting` → `beforeWaiting`. A first-in-line beforeWaiting observer splits it into:
///  - `src_ms`    event handlers / timers / blocks / main-queue work
///  - `commit_ms` the beforeWaiting phase: AppKit layout + display, SwiftUI updates, Core Animation commit
///  - `post_ms`   always 0 (kept so older traces and the analyzer stay compatible)
final class HitchMonitor: @unchecked Sendable {
    /// Iterations at least this long are written as `hitch` records and get stack samples.
    static let hitchThresholdMs: Double = 20

    private struct IterationState {
        var startNanos: UInt64 = 0      // 0 = main is idle (waiting)
        var id: UInt64 = 0
        var preCommitNanos: UInt64 = 0
        var postCommitNanos: UInt64 = 0
    }

    static let bucketBounds: [Double] = [1, 2, 4, 8, 16.7, 33, 50, 100, 250, 1000]

    /// Per-second iteration statistics, drained by `ProcessSampler`.
    struct FrameStats {
        var iterations = 0
        var commits = 0
        var hitches = 0
        var over16ms = 0
        var maxMs = 0.0
        var maxCommitMs = 0.0
        var totalMs = 0.0
        var histogram = [Int](repeating: 0, count: HitchMonitor.bucketBounds.count + 1)

        var p95Ms: Double {
            guard iterations > 0 else { return 0 }
            let rank = Int((Double(iterations) * 0.95).rounded(.up))
            var seen = 0
            for (i, n) in histogram.enumerated() {
                seen += n
                if seen >= rank { return i < HitchMonitor.bucketBounds.count ? HitchMonitor.bucketBounds[i] : maxMs }
            }
            return maxMs
        }
    }

    private weak var diagnostics: UIDiagnostics?
    private let iteration = OSAllocatedUnfairLock(initialState: IterationState())
    private let frameStats = OSAllocatedUnfairLock(initialState: FrameStats())
    private var observers: [CFRunLoopObserver] = []
    private var watcher: Thread?
    private let stopFlag = OSAllocatedUnfairLock(initialState: false)

    /// The main thread's mach port, shared with `ProcessSampler` for main-thread CPU accounting.
    private(set) var mainPort: mach_port_t = 0

    init(diagnostics: UIDiagnostics) {
        self.diagnostics = diagnostics
    }

    func start() {
        precondition(Thread.isMainThread)
        let target = StackSampler.Target.currentThread()
        mainPort = target.port

        let rl = CFRunLoopGetMain()

        func add(order: CFIndex, activities: CFRunLoopActivity, _ handler: @escaping () -> Void) {
            guard let observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, activities.rawValue, true, order, { _, _ in handler() }
            ) else { return }
            CFRunLoopAddObserver(rl, observer, .commonModes)
            observers.append(observer)
        }

        add(order: 0, activities: [.entry, .afterWaiting]) { [weak self] in self?.iterationBegan() }
        // First beforeWaiting observer: everything between here and the last one is AppKit layout/display,
        // SwiftUI graph updates and the Core Animation commit.
        add(order: CFIndex(Int32.min), activities: [.beforeWaiting, .exit]) { [weak self] in self?.markCommit(pre: true) }
        add(order: CFIndex(Int32.max), activities: [.beforeWaiting, .exit]) { [weak self] in self?.iterationEnded() }

        let thread = Thread { [weak self] in self?.watchLoop(target: target) }
        thread.name = "io.retrace.ui-diagnostics.hitch-watcher"
        thread.qualityOfService = .userInteractive   // must run even while the main thread is saturating cores
        thread.start()
        watcher = thread
    }

    func stop() {
        stopFlag.withLock { $0 = true }
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
    }

    func drainFrameStats() -> FrameStats {
        frameStats.withLock { stats in
            let out = stats
            stats = FrameStats()
            return out
        }
    }

    // MARK: - Run-loop callbacks (main thread)

    private func iterationBegan() {
        let now = DispatchTime.now().uptimeNanoseconds
        iteration.withLock {
            $0.id &+= 1
            $0.startNanos = now
            $0.preCommitNanos = 0
            $0.postCommitNanos = 0
        }
    }

    private func markCommit(pre: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        iteration.withLock { if pre { $0.preCommitNanos = now } else { $0.postCommitNanos = now } }
    }

    private func iterationEnded() {
        let now = DispatchTime.now().uptimeNanoseconds
        let state = iteration.withLock { s -> IterationState in
            let copy = s
            s.startNanos = 0
            return copy
        }
        guard state.startNanos != 0 else { return }

        let totalMs = Double(now &- state.startNanos) / 1_000_000
        var srcMs = totalMs
        var commitMs = 0.0
        let postMs = 0.0
        if state.preCommitNanos >= state.startNanos, state.preCommitNanos != 0 {
            srcMs = Double(state.preCommitNanos &- state.startNanos) / 1_000_000
            commitMs = Double(now &- state.preCommitNanos) / 1_000_000
        }

        let commitFinal = commitMs
        frameStats.withLock { s in
            s.iterations += 1
            s.totalMs += totalMs
            s.maxMs = max(s.maxMs, totalMs)
            s.maxCommitMs = max(s.maxCommitMs, commitFinal)
            if commitFinal >= 1 { s.commits += 1 }
            if totalMs > 16.7 { s.over16ms += 1 }
            if totalMs >= Self.hitchThresholdMs { s.hitches += 1 }
            let bucket = Self.bucketBounds.firstIndex { totalMs < $0 } ?? Self.bucketBounds.count
            s.histogram[bucket] += 1
        }

        guard totalMs >= Self.hitchThresholdMs, let diagnostics else { return }
        var fields: [String: Any] = [
            "iter": state.id,
            "ms": round1(totalMs),
            "src_ms": round1(srcMs),
            "commit_ms": round1(commitMs),
            "post_ms": round1(postMs),
            "mode": CFRunLoopCopyCurrentMode(CFRunLoopGetMain())?.rawValue ?? "?",
            "active": NSApp?.isActive ?? false,
        ]
        if let input = diagnostics.lastInput(within: 2) { fields["last_input"] = input }
        if let keyWindow = NSApp?.keyWindow {
            fields["key_window"] = "\(type(of: keyWindow)) \"\(keyWindow.title)\""
        }
        diagnostics.emit("hitch", fields)
    }

    // MARK: - Watcher thread

    private func watchLoop(target: StackSampler.Target) {
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: StackSampler.maxFrames)
        defer { buffer.deallocate() }
        let symbolicator = StackSampler.Symbolicator()

        var currentID: UInt64 = 0
        var samplesTaken = 0
        var nextDueMs = Self.hitchThresholdMs

        while !stopFlag.withLock({ $0 }) {
            let (start, id) = iteration.withLock { ($0.startNanos, $0.id) }
            guard start != 0 else {
                usleep(8_000)
                continue
            }
            if id != currentID {
                currentID = id
                samplesTaken = 0
                nextDueMs = Self.hitchThresholdMs
            }
            let ageMs = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            if ageMs >= nextDueMs {
                let count = StackSampler.captureRaw(of: target, into: buffer, capacity: StackSampler.maxFrames)
                if count > 0 {
                    let frames = symbolicator.resolve(UnsafeBufferPointer(start: buffer, count: count))
                    diagnostics?.emit("stack", ["iter": id, "age_ms": round1(ageMs), "frames": frames])
                }
                samplesTaken += 1
                // Dense while it's fresh, then back off so a multi-second stall can't flood the trace.
                let interval: Double = samplesTaken < 40 ? 10 : (samplesTaken < 100 ? 100 : 500)
                nextDueMs = ageMs + interval
            }
            usleep(4_000)
        }
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
