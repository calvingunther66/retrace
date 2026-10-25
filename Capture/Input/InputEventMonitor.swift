import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Shared

protocol InputTapSessionControlling: AnyObject, Sendable {
    func start() async -> Bool
    func stop() async
}

/// Logs user input (clicks, scrolls, shortcuts, typing counts) as `InputEvent`s.
///
/// Pipeline: listen-only `CGEvent` tap → `RawInputEvent` stream (FIFO, stamped on the tap thread) →
/// `InputEventAggregator` → completed drafts → context lookup (display, window, accessibility) →
/// `InputPrivacyPolicy` → `onEvent`.
///
/// Two consumers keep latency where it matters: the *pump* only aggregates and fires `onMouseDown`
/// immediately (so capture can grab the pre-click frame), while a separate *completion* consumer
/// does the slow, possibly-blocking accessibility work. Slow AX therefore can never delay a
/// mouse-down.
///
/// Privacy contract: only key *codes* are read, never characters; typing is a count; events from
/// secure fields, excluded apps/windows and private windows are dropped; unverifiable events are
/// kept but flagged (`InputEvent.privacyState`).
actor InputEventMonitor {
    struct Dependencies {
        let hasListenEventAccess: @Sendable () -> Bool
        let makeSession: @Sendable (@escaping @Sendable (RawInputEvent) -> Void) -> any InputTapSessionControlling
        let nowMs: @Sendable () -> Int64
        /// Tests turn this off and call `flushIdleBursts(nowMs:)` with a fake clock.
        let autoFlush: Bool
    }

    private struct Completion: Sendable {
        let draft: InputEventDraft
        let context: Task<InputContext, Never>?
    }

    private let dependencies: Dependencies
    private let contextProvider: any InputContextProviding

    private var session: (any InputTapSessionControlling)?
    private var isRunning = false
    private var startTask: Task<Bool, Never>?

    private var aggregator = InputEventAggregator()
    private var policy: InputPrivacyPolicy
    private var stats = InputEventStats()
    private var processedRawCount = 0

    private var rawContinuation: AsyncStream<RawInputEvent>.Continuation?
    private var completionContinuation: AsyncStream<Completion>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    private var clickContexts: [Int64: Task<InputContext, Never>] = [:]
    private var typingContext: Task<InputContext, Never>?

    private var onMouseDown: (@Sendable (InputMouseDown) async -> Void)?
    private var onActionCompleted: (@Sendable (InputEventDraft) async -> Void)?
    private var onEvent: (@Sendable (InputEvent) async -> Void)?

    init(
        contextProvider: any InputContextProviding,
        policy: InputPrivacyPolicy = InputPrivacyPolicy(),
        dependencies: Dependencies = .live
    ) {
        self.contextProvider = contextProvider
        self.policy = policy
        self.dependencies = dependencies
    }

    // MARK: - Configuration

    /// - Parameters:
    ///   - onMouseDown: A button just went down; capture can grab the pre-click frame right now.
    ///   - onActionCompleted: An action just finished (before context lookup), so a settled "post"
    ///     capture can be requested without waiting on slow accessibility work.
    ///   - onEvent: A finished event that passed the privacy checks.
    func setHandlers(
        onMouseDown: (@Sendable (InputMouseDown) async -> Void)?,
        onActionCompleted: (@Sendable (InputEventDraft) async -> Void)? = nil,
        onEvent: (@Sendable (InputEvent) async -> Void)?
    ) {
        self.onMouseDown = onMouseDown
        self.onActionCompleted = onActionCompleted
        self.onEvent = onEvent
    }

    func updatePrivacyPolicy(_ policy: InputPrivacyPolicy) {
        self.policy = policy
    }

    /// Counters since the last drain; resets them.
    func drainStats() -> InputEventStats {
        defer { stats = InputEventStats() }
        return stats
    }

    /// Current counters without resetting them.
    func peekStats() -> InputEventStats {
        stats
    }

    /// True while a scroll or typing burst is waiting for its idle window. Tests use this to know the
    /// pump has consumed their synthetic events before they advance the fake clock.
    func hasOpenBurstForTesting() -> Bool {
        aggregator.nextFlushDeadlineMs != nil
    }

    /// Number of raw events the pump has fully consumed (tests only).
    func processedRawCountForTesting() -> Int {
        processedRawCount
    }

    // MARK: - Lifecycle

    func startMonitoring() async -> Bool {
        if isRunning { return true }
        if let startTask { return await startTask.value }

        guard dependencies.hasListenEventAccess() else {
            Log.warning(
                "[InputEventMonitor] Listen-event access unavailable; input event logging disabled",
                category: .capture
            )
            return false
        }

        var rawYield: AsyncStream<RawInputEvent>.Continuation!
        let rawStream = AsyncStream<RawInputEvent> { rawYield = $0 }
        var completionYield: AsyncStream<Completion>.Continuation!
        let completionStream = AsyncStream<Completion> { completionYield = $0 }
        let rawContinuation = rawYield!
        let completionContinuation = completionYield!

        let newSession = dependencies.makeSession { raw in
            rawContinuation.yield(raw)
        }

        let task = Task { await newSession.start() }
        startTask = task
        let started = await task.value
        startTask = nil

        guard started else {
            rawContinuation.finish()
            completionContinuation.finish()
            return false
        }

        session = newSession
        isRunning = true
        aggregator = InputEventAggregator()
        self.rawContinuation = rawContinuation
        self.completionContinuation = completionContinuation

        pumpTask = Task { [weak self] in
            for await raw in rawStream {
                await self?.handle(raw)
            }
        }
        completionTask = Task { [weak self] in
            for await completion in completionStream {
                await self?.complete(completion)
            }
        }
        return true
    }

    func stopMonitoring() async {
        guard isRunning || startTask != nil else { return }
        isRunning = false

        let stopping = session
        session = nil
        await stopping?.stop()

        flushTask?.cancel()
        flushTask = nil

        // Let the pump drain what the tap already delivered, then close open bursts.
        rawContinuation?.finish()
        await pumpTask?.value
        pumpTask = nil
        for output in aggregator.finish() {
            process(output)
        }
        completionContinuation?.finish()
        await completionTask?.value
        completionTask = nil

        rawContinuation = nil
        completionContinuation = nil
        clickContexts.values.forEach { $0.cancel() }
        clickContexts.removeAll()
        typingContext?.cancel()
        typingContext = nil
    }

    // MARK: - Pump

    private func handle(_ raw: RawInputEvent) {
        processedRawCount += 1
        for output in aggregator.ingest(raw) {
            process(output)
        }
        scheduleIdleFlushIfNeeded()
    }

    /// Close bursts that have gone quiet as of `nowMs`. Internal so tests can drive time.
    func flushIdleBursts(nowMs: Int64) {
        for output in aggregator.flush(nowMs: nowMs) {
            process(output)
        }
        scheduleIdleFlushIfNeeded()
    }

    private func scheduleIdleFlushIfNeeded() {
        guard dependencies.autoFlush, isRunning else { return }
        flushTask?.cancel()
        guard let deadline = aggregator.nextFlushDeadlineMs else {
            flushTask = nil
            return
        }
        let delayMs = max(50, deadline - dependencies.nowMs() + 1)
        flushTask = Task { [weak self, nowMs = dependencies.nowMs] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushIdleBursts(nowMs: nowMs())
        }
    }

    private func process(_ output: InputAggregatorOutput) {
        switch output {
        case .mouseDown(let down):
            if let onMouseDown {
                Task { await onMouseDown(down) }
            }
            // Snapshot the UI as the user saw it, before the click has any effect.
            let provider = contextProvider
            let point = CGPoint(x: down.x, y: down.y)
            clickContexts[down.tsMs] = Task { await provider.context(at: point, wantsElements: true) }
            pruneStaleClickContexts(keeping: down.tsMs)

        case .typingStarted:
            let provider = contextProvider
            typingContext = Task { await provider.context(at: nil, wantsElements: false) }

        case .event(let draft):
            if let onActionCompleted {
                Task { await onActionCompleted(draft) }
            }
            let context: Task<InputContext, Never>?
            switch draft.kind {
            case .click: context = clickContexts.removeValue(forKey: draft.tsMs)
            case .typing:
                context = typingContext
                typingContext = nil
            case .scroll, .shortcut: context = nil
            }
            completionContinuation?.yield(Completion(draft: draft, context: context))

        case .dropped(let reason):
            switch reason {
            case .drag: stats.droppedDrag += 1
            case .secureInput: stats.droppedSecureInput += 1
            }
        }
    }

    /// A drag produces a mouse-down snapshot that no click will ever claim; don't let them pile up.
    private func pruneStaleClickContexts(keeping newest: Int64) {
        guard clickContexts.count > 8 else { return }
        for key in clickContexts.keys.sorted().dropLast(4) where key != newest {
            clickContexts.removeValue(forKey: key)?.cancel()
        }
    }

    // MARK: - Completion

    private func complete(_ completion: Completion) async {
        let draft = completion.draft
        let context: InputContext
        if let task = completion.context {
            context = await task.value
        } else {
            let point = draft.x.flatMap { x in draft.y.map { CGPoint(x: x, y: $0) } }
            context = await contextProvider.context(at: point, wantsElements: false)
        }

        let privacyState: String
        switch policy.evaluate(context) {
        case .drop(let reason):
            switch reason {
            case .secureField: stats.droppedSecureField += 1
            case .ownApp, .excludedApp, .excludedWindow, .privateWindow: stats.droppedExcluded += 1
            }
            return
        case .allowUnverified(let state):
            stats.unverified += 1
            privacyState = state
        case .allow:
            privacyState = InputEvent.privacyOK
        }

        switch draft.kind {
        case .click: stats.click += 1
        case .scroll: stats.scroll += 1
        case .shortcut: stats.shortcut += 1
        case .typing: stats.typing += 1
        }

        let event = InputEventBuilder.makeEvent(draft: draft, context: context, privacyState: privacyState)
        await onEvent?(event)
    }
}

extension InputEventMonitor: CaptureInputEventMonitoring {}

extension InputEventMonitor.Dependencies {
    static let live = Self(
        hasListenEventAccess: { CGPreflightListenEventAccess() },
        makeSession: { onEvent in InputTapSession(onEvent: onEvent) },
        nowMs: { InputEvent.epochMilliseconds(Date()) },
        autoFlush: true
    )
}

// MARK: - Event tap

/// Listen-only tap on its own thread/run loop. Modeled on `MouseClickTapSession` (kept separate so
/// the production click-capture path is untouched).
///
/// The callback does the minimum: stamp time, copy position/flags/key code, yield. It never reads
/// `keyboardEventUnicodeString`.
private final class InputTapSession: InputTapSessionControlling, @unchecked Sendable {
    private let onEvent: @Sendable (RawInputEvent) -> Void
    private let stateLock = NSLock()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var isStopped = false
    private var hasStarted = false

    private static let eventTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .scrollWheel,
        .keyDown
    ]

    init(onEvent: @escaping @Sendable (RawInputEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if hasStarted, let eventTap, CFMachPortIsValid(eventTap) {
                stateLock.unlock()
                continuation.resume(returning: true)
                return
            }

            startContinuation = continuation
            isStopped = false

            let thread = Thread { [weak self] in
                self?.runEventTapThread()
            }
            thread.name = "RetraceInputEventTap"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            stateLock.unlock()

            thread.start()
        }
    }

    func stop() async {
        let continuation: CheckedContinuation<Bool, Never>?
        let runLoop: CFRunLoop?
        let source: CFRunLoopSource?
        let eventTap: CFMachPort?

        stateLock.lock()
        isStopped = true
        continuation = startContinuation
        startContinuation = nil
        runLoop = self.runLoop
        source = runLoopSource
        eventTap = self.eventTap
        self.runLoop = nil
        runLoopSource = nil
        self.eventTap = nil
        thread = nil
        hasStarted = false
        stateLock.unlock()

        continuation?.resume(returning: false)

        guard let runLoop else {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
                CFMachPortInvalidate(eventTap)
            }
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
                CFMachPortInvalidate(eventTap)
            }
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func runEventTapThread() {
        let eventMask = Self.eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let sessionPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let session = Unmanaged<InputTapSession>.fromOpaque(refcon).takeUnretainedValue()
                return session.handleEventTap(type: type, event: event)
            },
            userInfo: sessionPointer
        ) else {
            resumeStartIfNeeded(started: false)
            Log.warning("[InputEventMonitor] Failed to create input event tap", category: .capture)
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            resumeStartIfNeeded(started: false)
            Log.warning("[InputEventMonitor] Failed to create input event run loop source", category: .capture)
            return
        }

        guard let runLoop = CFRunLoopGetCurrent() else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            resumeStartIfNeeded(started: false)
            Log.warning("[InputEventMonitor] Failed to access run loop for input event tap", category: .capture)
            return
        }
        guard completeStart(eventTap: eventTap, runLoopSource: runLoopSource, runLoop: runLoop) else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            return
        }

        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        Log.info("[InputEventMonitor] Input event tap started", category: .capture)

        CFRunLoopRun()
        resetSessionStateAfterThreadExit(runLoop: runLoop)
    }

    private func completeStart(
        eventTap: CFMachPort,
        runLoopSource: CFRunLoopSource,
        runLoop: CFRunLoop
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isStopped {
            let continuation = startContinuation
            startContinuation = nil
            continuation?.resume(returning: false)
            return false
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        self.runLoop = runLoop
        hasStarted = true

        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: true)
        return true
    }

    private func resumeStartIfNeeded(started: Bool) {
        stateLock.lock()
        let continuation = startContinuation
        startContinuation = nil
        hasStarted = started
        if !started {
            thread = nil
        }
        stateLock.unlock()

        continuation?.resume(returning: started)
    }

    private func resetSessionStateAfterThreadExit(runLoop: CFRunLoop) {
        stateLock.lock()
        if self.runLoop === runLoop {
            self.runLoop = nil
            runLoopSource = nil
            eventTap = nil
            thread = nil
            hasStarted = false
        }
        stateLock.unlock()
    }

    private nonisolated func handleEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableEventTapIfPossible()
            return Unmanaged.passUnretained(event)
        }

        if let raw = InputRawEventFactory.make(type: type, event: event) {
            onEvent(raw)
        }
        return Unmanaged.passUnretained(event)
    }

    private nonisolated func reenableEventTapIfPossible() {
        stateLock.lock()
        let eventTap = self.eventTap
        let shouldEnable = !isStopped
        stateLock.unlock()

        guard shouldEnable, let eventTap, CFMachPortIsValid(eventTap) else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}

/// Converts a tap callback's `CGEvent` into a `RawInputEvent`. Internal (not private) so tests can
/// feed it real synthetic events, including key events that carry a Unicode payload, and prove the
/// payload never survives.
enum InputRawEventFactory {
    static func make(type: CGEventType, event: CGEvent) -> RawInputEvent? {
        let tsMs = InputEvent.epochMilliseconds(Date())
        let location = event.location
        let modifiers = InputModifiers(cgFlags: event.flags)
        let clickState = Int(event.getIntegerValueField(.mouseEventClickState))

        func mouse(_ kind: RawInputEvent.Kind) -> RawInputEvent {
            RawInputEvent(
                kind: kind,
                tsMs: tsMs,
                x: Double(location.x),
                y: Double(location.y),
                modifiers: modifiers,
                clickCount: clickState
            )
        }

        switch type {
        case .leftMouseDown: return mouse(.mouseDown(.left))
        case .leftMouseUp: return mouse(.mouseUp(.left))
        case .rightMouseDown: return mouse(.mouseDown(.right))
        case .rightMouseUp: return mouse(.mouseUp(.right))
        case .otherMouseDown: return mouse(.mouseDown(.other))
        case .otherMouseUp: return mouse(.mouseUp(.other))

        case .scrollWheel:
            let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            return RawInputEvent(
                kind: .scroll(dx: dx, dy: dy),
                tsMs: tsMs,
                x: Double(location.x),
                y: Double(location.y),
                modifiers: modifiers
            )

        case .keyDown:
            // Key code and flags only. The event's character payload is deliberately never read.
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return RawInputEvent(
                kind: .keyDown(keyCode: keyCode, isRepeat: isRepeat, secureInput: IsSecureEventInputEnabled()),
                tsMs: tsMs,
                modifiers: modifiers
            )

        default:
            return nil
        }
    }
}
