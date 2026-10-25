import XCTest
import CoreGraphics
import Shared
@testable import Capture

// MARK: - Fakes

private final class FakeInputTapSession: InputTapSessionControlling, @unchecked Sendable {
    let onEvent: @Sendable (RawInputEvent) -> Void
    private let lock = NSLock()
    private var _stopCount = 0
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

    init(onEvent: @escaping @Sendable (RawInputEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() async -> Bool { true }
    func stop() async { lock.lock(); _stopCount += 1; lock.unlock() }
    func emit(_ raw: RawInputEvent) { onEvent(raw) }
}

private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _session: FakeInputTapSession?
    var session: FakeInputTapSession? {
        get { lock.lock(); defer { lock.unlock() }; return _session }
        set { lock.lock(); _session = newValue; lock.unlock() }
    }
}

private actor ProviderCalls {
    private(set) var calls: [(point: CGPoint?, wantsElements: Bool)] = []
    func record(_ point: CGPoint?, _ wantsElements: Bool) { calls.append((point, wantsElements)) }
}

private struct FakeContextProvider: InputContextProviding {
    let calls = ProviderCalls()
    var delayMs: UInt64 = 0
    var make: @Sendable (CGPoint?, Bool) -> InputContext

    func context(at point: CGPoint?, wantsElements: Bool) async -> InputContext {
        await calls.record(point, wantsElements)
        if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        return make(point, wantsElements)
    }
}

private actor Collector {
    private(set) var events: [InputEvent] = []
    private(set) var downs: [InputMouseDown] = []
    private(set) var downTimes: [Date] = []

    func add(_ event: InputEvent) { events.append(event) }
    func add(_ down: InputMouseDown) { downs.append(down); downTimes.append(Date()) }
}

private func trustedContext(
    bundleID: String = "com.example.app",
    title: String? = "Doc",
    target: InputAXTarget? = InputAXTarget(role: "AXButton", title: "Share", identifier: "share-btn", x: 1398, y: 76, width: 30, height: 24),
    elements: [InputAXElement] = [],
    isPrivate: Bool? = false,
    axAvailable: Bool = true,
    focusedIsSecure: Bool = false
) -> InputContext {
    InputContext(
        displayID: 1,
        displayPixelWidth: 3024,
        displayPixelHeight: 1964,
        displayScale: 2,
        displays: [InputDisplayGeometry(id: 1, x: 0, y: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, scale: 2)],
        bundleID: bundleID,
        windowTitle: title,
        windowFrame: CGRect(x: 0, y: 25, width: 1512, height: 957),
        isPrivateWindow: isPrivate,
        axAvailable: axAvailable,
        axTarget: target,
        axElements: elements,
        focusedElementIsSecure: focusedIsSecure
    )
}

// MARK: - Monitor

final class InputEventMonitorTests: XCTestCase {

    private func makeMonitor(
        provider: FakeContextProvider,
        policy: InputPrivacyPolicy = InputPrivacyPolicy(),
        listenAccess: Bool = true,
        box: SessionBox,
        collector: Collector
    ) async -> InputEventMonitor {
        let monitor = InputEventMonitor(
            contextProvider: provider,
            policy: policy,
            dependencies: .init(
                hasListenEventAccess: { listenAccess },
                makeSession: { onEvent in
                    let session = FakeInputTapSession(onEvent: onEvent)
                    box.session = session
                    return session
                },
                nowMs: { 1_000_000 },
                autoFlush: false
            )
        )
        await monitor.setHandlers(
            onMouseDown: { await collector.add($0) },
            onEvent: { await collector.add($0) }
        )
        return monitor
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    func testStartFailsWithoutInputMonitoringPermission() async {
        let monitor = await makeMonitor(
            provider: FakeContextProvider(make: { _, _ in .empty }),
            listenAccess: false,
            box: SessionBox(),
            collector: Collector()
        )
        let started = await monitor.startMonitoring()
        XCTAssertFalse(started)
    }

    func testClickProducesEventWithContextSnapshottedAtMouseDown() async throws {
        let box = SessionBox()
        let collector = Collector()
        let elements = [InputAXElement(role: "AXButton", name: "Share", box: [1398, 76, 30, 24])]
        let provider = FakeContextProvider(make: { _, wantsElements in
            trustedContext(elements: wantsElements ? elements : [])
        })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        let started = await monitor.startMonitoring()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(box.session)

        session.emit(RawInputEvent(kind: .mouseDown(.left), tsMs: 5_000, x: 1412, y: 88, modifiers: [], clickCount: 1))

        // The pressed-state snapshot is requested on mouse-down, before the button is released.
        let snapshotted = await waitUntil { await provider.calls.calls.count == 1 }
        XCTAssertTrue(snapshotted, "context must be gathered at mouse-down")
        let call = await provider.calls.calls[0]
        XCTAssertEqual(call.point, CGPoint(x: 1412, y: 88))
        XCTAssertTrue(call.wantsElements)

        session.emit(RawInputEvent(kind: .mouseUp(.left), tsMs: 5_090, x: 1412, y: 88, modifiers: [], clickCount: 1))
        let got = await waitUntil { await collector.events.count == 1 }
        XCTAssertTrue(got)

        let collected = await collector.events
        let event = try XCTUnwrap(collected.first)
        XCTAssertEqual(event.kind, .click)
        XCTAssertEqual(event.tsMs, 5_000)
        XCTAssertEqual(event.endTsMs, 5_090)
        XCTAssertEqual(event.button, "left")
        XCTAssertEqual(event.x, 1412)
        XCTAssertEqual(event.axTarget?.identifier, "share-btn")
        XCTAssertEqual(event.axElements, elements)
        XCTAssertEqual(event.displayScale, 2)
        XCTAssertEqual(event.bundleID, "com.example.app")
        XCTAssertEqual(event.windowTitle, "Doc")
        XCTAssertEqual(event.windowWidth, 1512)
        XCTAssertEqual(event.privacyState, "ok")
        let calls = await provider.calls.calls.count
        XCTAssertEqual(calls, 1, "no second lookup at mouse-up")
        await monitor.stopMonitoring()
    }

    func testSlowAccessibilityNeverDelaysTheMouseDownCallback() async throws {
        let box = SessionBox()
        let collector = Collector()
        let provider = FakeContextProvider(delayMs: 600, make: { _, _ in trustedContext() })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        let emittedAt = Date()
        session.emit(RawInputEvent(kind: .mouseDown(.left), tsMs: 5_000, x: 10, y: 10, clickCount: 1))
        let gotDown = await waitUntil(timeout: 1) { await collector.downs.count == 1 }
        XCTAssertTrue(gotDown)
        let downTimes = await collector.downTimes
        let latency = try XCTUnwrap(downTimes.first).timeIntervalSince(emittedAt)
        XCTAssertLessThan(latency, 0.3, "mouse-down must reach capture long before 600ms of AX work finishes")
        await monitor.stopMonitoring()
    }

    func testSecureTextFieldClickIsDroppedAndCounted() async throws {
        let box = SessionBox()
        let collector = Collector()
        let provider = FakeContextProvider(make: { _, _ in
            trustedContext(target: InputAXTarget(role: "AXTextField", subrole: "AXSecureTextField"))
        })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        session.emit(RawInputEvent(kind: .mouseDown(.left), tsMs: 5_000, x: 10, y: 10, clickCount: 1))
        session.emit(RawInputEvent(kind: .mouseUp(.left), tsMs: 5_050, x: 10, y: 10, clickCount: 1))

        let counted = await waitUntil { await monitor.peekStats().droppedSecureField == 1 }
        XCTAssertTrue(counted)
        let events = await collector.events
        XCTAssertTrue(events.isEmpty)
        await monitor.stopMonitoring()
    }

    func testClickWhileAPasswordFieldIsFocusedIsDroppedAndCounted() async throws {
        let box = SessionBox()
        let collector = Collector()
        let provider = FakeContextProvider(make: { _, _ in
            trustedContext(target: InputAXTarget(role: "AXButton", title: "Sign in"), focusedIsSecure: true)
        })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        session.emit(RawInputEvent(kind: .mouseDown(.left), tsMs: 5_000, x: 10, y: 10, clickCount: 1))
        session.emit(RawInputEvent(kind: .mouseUp(.left), tsMs: 5_050, x: 10, y: 10, clickCount: 1))

        let counted = await waitUntil { await monitor.peekStats().droppedSecureField == 1 }
        XCTAssertTrue(counted)
        let events = await collector.events
        XCTAssertTrue(events.isEmpty)
        await monitor.stopMonitoring()
    }

    func testExcludedAppIsDropped() async throws {
        let box = SessionBox()
        let collector = Collector()
        let provider = FakeContextProvider(make: { _, _ in trustedContext(bundleID: "com.1password.1password") })
        let monitor = await makeMonitor(
            provider: provider,
            policy: InputPrivacyPolicy(excludedBundleIDs: ["com.1password.1password"]),
            box: box,
            collector: collector
        )
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        session.emit(RawInputEvent(kind: .keyDown(keyCode: 9, isRepeat: false, secureInput: false), tsMs: 5_000, modifiers: [.command]))

        let counted = await waitUntil { await monitor.peekStats().droppedExcluded == 1 }
        XCTAssertTrue(counted)
        let events = await collector.events
        XCTAssertTrue(events.isEmpty)
        await monitor.stopMonitoring()
    }

    func testMissingAccessibilityKeepsTheEventButFlagsIt() async throws {
        let box = SessionBox()
        let collector = Collector()
        let provider = FakeContextProvider(make: { _, _ in trustedContext(target: nil, isPrivate: nil, axAvailable: false) })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        session.emit(RawInputEvent(kind: .mouseDown(.left), tsMs: 5_000, x: 10, y: 10, clickCount: 1))
        session.emit(RawInputEvent(kind: .mouseUp(.left), tsMs: 5_050, x: 10, y: 10, clickCount: 1))

        let got = await waitUntil { await collector.events.count == 1 }
        XCTAssertTrue(got)
        let collected = await collector.events
        let event = try XCTUnwrap(collected.first)
        XCTAssertEqual(event.privacyState, InputEvent.privacyAXUnavailable)
        let stats = await monitor.peekStats()
        XCTAssertEqual(stats.unverified, 1)
        await monitor.stopMonitoring()
    }

    func testTypingBurstUsesFocusedElementAndStoresOnlyACount() async throws {
        let box = SessionBox()
        let collector = Collector()
        let field = InputAXTarget(role: "AXTextArea", identifier: "body")
        let provider = FakeContextProvider(make: { point, _ in trustedContext(target: point == nil ? field : nil) })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        for (index, code) in [UInt16]([4, 14, 37, 37, 31]).enumerated() {
            session.emit(RawInputEvent(
                kind: .keyDown(keyCode: code, isRepeat: false, secureInput: false),
                tsMs: 5_000 + Int64(index) * 80
            ))
        }
        let focusLookedUp = await waitUntil { await provider.calls.calls.count == 1 }
        XCTAssertTrue(focusLookedUp, "focused element is captured once, when the burst starts")
        let call = await provider.calls.calls[0]
        XCTAssertNil(call.point)
        XCTAssertFalse(call.wantsElements)

        // Let the pump drain, then advance the clock past the idle window.
        let drained = await waitUntil { await monitor.processedRawCountForTesting() == 5 }
        XCTAssertTrue(drained)
        await monitor.flushIdleBursts(nowMs: 5_000 + 4 * 80 + InputEventAggregator.typingIdleMs + 10)

        let got = await waitUntil { await collector.events.count == 1 }
        XCTAssertTrue(got)
        let collected = await collector.events
        let event = try XCTUnwrap(collected.first)
        XCTAssertEqual(event.kind, .typing)
        XCTAssertEqual(event.typedCount, 5)
        XCTAssertNil(event.keyCombo)
        XCTAssertEqual(event.axTarget?.identifier, "body")
        await monitor.stopMonitoring()
    }

    func testSecureInputKeystrokesRecordNothing() async throws {
        let box = SessionBox()
        let collector = Collector()
        let provider = FakeContextProvider(make: { _, _ in trustedContext() })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        session.emit(RawInputEvent(kind: .keyDown(keyCode: 0, isRepeat: false, secureInput: true), tsMs: 5_000))
        session.emit(RawInputEvent(kind: .keyDown(keyCode: 1, isRepeat: false, secureInput: true), tsMs: 5_050))

        let counted = await waitUntil { await monitor.peekStats().droppedSecureInput == 2 }
        XCTAssertTrue(counted)
        await monitor.stopMonitoring()
        let events = await collector.events
        XCTAssertTrue(events.isEmpty)
    }

    func testStopFlushesAnOpenTypingBurst() async throws {
        let box = SessionBox()
        let collector = Collector()
        let provider = FakeContextProvider(make: { _, _ in trustedContext() })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        session.emit(RawInputEvent(kind: .keyDown(keyCode: 0, isRepeat: false, secureInput: false), tsMs: 5_000))
        session.emit(RawInputEvent(kind: .keyDown(keyCode: 1, isRepeat: false, secureInput: false), tsMs: 5_060))
        await monitor.stopMonitoring()

        let events = await collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.typedCount, 2)
        XCTAssertEqual(box.session?.stopCount, 1)
    }

    func testShortcutEventCarriesSpelledOutCombo() async throws {
        let box = SessionBox()
        let collector = Collector()
        let provider = FakeContextProvider(make: { _, _ in trustedContext() })
        let monitor = await makeMonitor(provider: provider, box: box, collector: collector)
        _ = await monitor.startMonitoring()
        let session = try XCTUnwrap(box.session)

        session.emit(RawInputEvent(
            kind: .keyDown(keyCode: 17, isRepeat: false, secureInput: false),
            tsMs: 5_000,
            modifiers: [.command, .shift]
        ))
        let got = await waitUntil { await collector.events.count == 1 }
        XCTAssertTrue(got)
        let collected = await collector.events
        let event = try XCTUnwrap(collected.first)
        XCTAssertEqual(event.kind, .shortcut)
        XCTAssertEqual(event.keyCombo, "cmd+shift+t")
        XCTAssertEqual(event.modifiers, ["cmd", "shift"])
        await monitor.stopMonitoring()
    }
}

// MARK: - Privacy policy

final class InputPrivacyPolicyTests: XCTestCase {

    func testVerifiedBenignContextIsAllowed() {
        XCTAssertEqual(InputPrivacyPolicy().evaluate(trustedContext()), .allow)
    }

    func testSecureTextFieldAlwaysDrops() {
        let byRole = trustedContext(target: InputAXTarget(role: "AXSecureTextField"))
        let bySubrole = trustedContext(target: InputAXTarget(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertEqual(InputPrivacyPolicy().evaluate(byRole), .drop(.secureField))
        XCTAssertEqual(InputPrivacyPolicy().evaluate(bySubrole), .drop(.secureField))
    }

    func testEventsInRetracesOwnWindowsAreDropped() {
        var context = trustedContext()
        context.isOwnApp = true
        XCTAssertEqual(InputPrivacyPolicy().evaluate(context), .drop(.ownApp))
    }

    func testAClickElsewhereWhileAPasswordFieldHasFocusIsDropped() {
        // The pointer is on a normal button ("Sign in") but the password field still has keyboard focus.
        let context = trustedContext(
            target: InputAXTarget(role: "AXButton", title: "Sign in"),
            focusedIsSecure: true
        )
        XCTAssertFalse(context.axTarget?.isSecureTextField ?? true)
        XCTAssertEqual(InputPrivacyPolicy().evaluate(context), .drop(.secureField))
    }

    func testExcludedAppAndWindowTitlePatternsDrop() {
        let policy = InputPrivacyPolicy(
            excludedBundleIDs: ["com.bank.app"],
            redactWindowTitlePatterns: ["  Payroll ", "   "]
        )
        XCTAssertEqual(policy.evaluate(trustedContext(bundleID: "com.bank.app")), .drop(.excludedApp))
        XCTAssertEqual(policy.evaluate(trustedContext(title: "Q3 PAYROLL — Draft")), .drop(.excludedWindow))
        XCTAssertEqual(policy.evaluate(trustedContext(title: "Notes")), .allow, "blank patterns match nothing")
    }

    func testPrivateWindowDropsOnlyWhenEnabled() {
        let privateContext = trustedContext(isPrivate: true)
        XCTAssertEqual(InputPrivacyPolicy(excludePrivateWindows: true).evaluate(privateContext), .drop(.privateWindow))
        XCTAssertEqual(InputPrivacyPolicy(excludePrivateWindows: false).evaluate(privateContext), .allow)
    }

    func testUnverifiableChecksAreKeptButFlagged() {
        let noAX = trustedContext(target: nil, isPrivate: nil, axAvailable: false)
        XCTAssertEqual(
            InputPrivacyPolicy().evaluate(noAX),
            .allowUnverified(privacyState: InputEvent.privacyAXUnavailable)
        )

        let privateUnknown = trustedContext(isPrivate: nil, axAvailable: true)
        XCTAssertEqual(
            InputPrivacyPolicy().evaluate(privateUnknown),
            .allowUnverified(privacyState: InputPrivacyPolicy.privateUnknown)
        )
        XCTAssertEqual(
            InputPrivacyPolicy(excludePrivateWindows: false).evaluate(privateUnknown),
            .allow,
            "private-window state is irrelevant when private windows are not excluded"
        )
    }

    func testPolicyFollowsCaptureConfig() {
        let config = CaptureConfig(
            excludedAppBundleIDs: ["com.secret.app"],
            excludePrivateWindows: false,
            redactWindowTitlePatterns: ["vault"]
        )
        let policy = InputPrivacyPolicy(config: config)
        XCTAssertEqual(policy.excludedBundleIDs, ["com.secret.app"])
        XCTAssertFalse(policy.excludePrivateWindows)
        XCTAssertEqual(policy.evaluate(trustedContext(title: "My Vault")), .drop(.excludedWindow))
    }
}

// MARK: - Real CGEvent conversion

final class InputRawEventFactoryTests: XCTestCase {

    func testKeyDownKeepsKeyCodeAndFlagsAndNothingElse() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 17, keyDown: true))
        // Attach a character payload; it must never make it into the raw record.
        var payload = Array("hunter2".utf16)
        event.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: &payload)
        event.flags = [.maskCommand, .maskShift]

        let raw = try XCTUnwrap(InputRawEventFactory.make(type: .keyDown, event: event))

        guard case .keyDown(let keyCode, let isRepeat, _) = raw.kind else { return XCTFail("expected keyDown") }
        XCTAssertEqual(keyCode, 17)
        XCTAssertFalse(isRepeat)
        XCTAssertEqual(raw.modifiers, [.command, .shift])
        XCTAssertFalse(String(describing: raw).contains("hunter2"))
    }

    func testMouseEventsKeepPositionButtonAndClickState() throws {
        let point = CGPoint(x: 1412, y: 88)
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right
        ))
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        event.flags = [.maskControl]

        let raw = try XCTUnwrap(InputRawEventFactory.make(type: .rightMouseDown, event: event))
        XCTAssertEqual(raw.kind, .mouseDown(.right))
        XCTAssertEqual(raw.x, 1412)
        XCTAssertEqual(raw.y, 88)
        XCTAssertEqual(raw.clickCount, 2)
        XCTAssertEqual(raw.modifiers, [.control])

        let up = try XCTUnwrap(InputRawEventFactory.make(type: .rightMouseUp, event: event))
        XCTAssertEqual(up.kind, .mouseUp(.right))
    }

    func testScrollWheelDeltasAreCaptured() throws {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -30, wheel2: 12, wheel3: 0
        ))
        let raw = try XCTUnwrap(InputRawEventFactory.make(type: .scrollWheel, event: event))
        XCTAssertEqual(raw.kind, .scroll(dx: 12, dy: -30))
    }

    func testTimestampUsesTheSameClockAndTruncationAsFrames() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let before = InputEvent.epochMilliseconds(Date())
        let raw = try XCTUnwrap(InputRawEventFactory.make(type: .keyDown, event: event))
        let after = InputEvent.epochMilliseconds(Date())
        XCTAssertGreaterThanOrEqual(raw.tsMs, before)
        XCTAssertLessThanOrEqual(raw.tsMs, after)
    }

    func testIrrelevantEventTypesAreIgnored() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
        XCTAssertNil(InputRawEventFactory.make(type: .keyUp, event: event))
    }
}
