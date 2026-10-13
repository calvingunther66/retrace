import XCTest
@testable import Capture

/// Regression tests for the AX-callback use-after-free that crashed Retrace twice (Oct 6 SIGSEGV in
/// `swift_getObjectType`, Oct 8 SIGTRAP in `DefaultActorImpl::tryLock`, both under
/// `DisplaySwitchMonitor.setupAXObserverForFrontmostApp()`).
///
/// The callback used to receive an UNRETAINED pointer to a heap wrapper that the actor freed whenever the observer was
/// replaced; a queued or leaked observer then dereferenced freed memory. The callback now receives an integer token
/// that is never dereferenced, so every "late callback" shape below must be inert.
final class DisplaySwitchAXRegistryTests: XCTestCase {

    func testLiveTokenResolvesAndUnregisteredTokenResolvesToNothing() async {
        let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        let token = DisplaySwitchAXRegistry.shared.register(monitor)
        XCTAssertNotEqual(token, 0, "0 is reserved for 'no observer'")
        XCTAssertNotNil(DisplaySwitchAXRegistry.shared.monitor(for: token))

        DisplaySwitchAXRegistry.shared.unregister(token)
        XCTAssertNil(DisplaySwitchAXRegistry.shared.monitor(for: token), "a torn-down observer's late callback must find nothing")
    }

    func testTokensAreUniqueAcrossRegistrations() {
        let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        let tokens = (0..<500).map { _ in DisplaySwitchAXRegistry.shared.register(monitor) }
        defer { tokens.forEach { DisplaySwitchAXRegistry.shared.unregister($0) } }
        XCTAssertEqual(Set(tokens).count, tokens.count)
    }

    func testRegistryDoesNotKeepADeallocatedMonitorAlive() {
        var token: UInt = 0
        autoreleasepool {
            let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
            token = DisplaySwitchAXRegistry.shared.register(monitor)
            XCTAssertNotNil(DisplaySwitchAXRegistry.shared.monitor(for: token))
        }
        XCTAssertNil(DisplaySwitchAXRegistry.shared.monitor(for: token), "weak reference: a freed monitor must not be reachable")
        DisplaySwitchAXRegistry.shared.unregister(token)
    }

    func testCallbackWithNilGarbageAndStaleRefconsIsInert() {
        // These are exactly the refcon shapes the old code would have dereferenced as a pointer.
        DisplaySwitchAXRegistry.dispatch(refcon: nil)
        DisplaySwitchAXRegistry.dispatch(refcon: UnsafeMutableRawPointer(bitPattern: 0xDEAD_BEEF))
        DisplaySwitchAXRegistry.dispatch(refcon: UnsafeMutableRawPointer(bitPattern: UInt.max))
        let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        let token = DisplaySwitchAXRegistry.shared.register(monitor)
        DisplaySwitchAXRegistry.shared.unregister(token)
        DisplaySwitchAXRegistry.dispatch(refcon: UnsafeMutableRawPointer(bitPattern: token))
    }

    func testStaleTokenNeverReachesTheWindowChangeCallback() async throws {
        let monitor = DisplaySwitchMonitor(displayMonitor: DisplayMonitor())
        let fired = FiredFlag()
        monitor.onWindowChange = { _ in await fired.set() }

        // No observer is installed (token 0 == axToken), and a leftover token from a replaced observer is nonzero.
        await monitor.handleWindowChangeFromAX(token: 0)
        await monitor.handleWindowChangeFromAX(token: 41)
        let didFire = await fired.value
        XCTAssertFalse(didFire, "notifications from a replaced or removed observer must be dropped")
    }

    private actor FiredFlag {
        private(set) var value = false
        func set() { value = true }
    }
}
