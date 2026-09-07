import AppKit
import Darwin
import XCTest
@testable import Retrace

@MainActor
final class QuitConfirmationPresentationTests: XCTestCase {
    func testDashboardCloseSideEffectsRunWhenAppIsNotTerminating() {
        XCTAssertTrue(
            DashboardWindowController.shouldPerformCloseSideEffects(
                isApplicationTerminating: false
            )
        )
    }

    func testDashboardCloseSideEffectsSkipWhenAppIsTerminating() {
        XCTAssertFalse(
            DashboardWindowController.shouldPerformCloseSideEffects(
                isApplicationTerminating: true
            )
        )
    }

    func testPreferredQuitConfirmationAnchorWindowPrefersVisibleKeyWindow() {
        let keyWindow = StubQuitConfirmationWindow(isVisible: true)
        let mainWindow = StubQuitConfirmationWindow(isVisible: true)

        let anchor = AppDelegate.preferredQuitConfirmationAnchorWindow(
            keyWindow: keyWindow,
            mainWindow: mainWindow
        )

        XCTAssertTrue(anchor === keyWindow)
    }

    func testPreferredQuitConfirmationAnchorWindowFallsBackToVisibleMainWindow() {
        let hiddenKeyWindow = StubQuitConfirmationWindow(isVisible: false)
        let mainWindow = StubQuitConfirmationWindow(isVisible: true)

        let anchor = AppDelegate.preferredQuitConfirmationAnchorWindow(
            keyWindow: hiddenKeyWindow,
            mainWindow: mainWindow
        )

        XCTAssertTrue(anchor === mainWindow)
    }

    func testPreferredQuitConfirmationAnchorWindowRejectsMiniaturizedWindow() {
        let miniaturizedWindow = StubQuitConfirmationWindow(isVisible: true, isMiniaturized: true)

        let anchor = AppDelegate.preferredQuitConfirmationAnchorWindow(
            keyWindow: nil,
            mainWindow: miniaturizedWindow
        )

        XCTAssertNil(anchor)
    }

    func testQuitConfirmationAlertDoesNotOfferDontAskAgain() {
        let alert = AppDelegate.makeQuitConfirmationAlert(applicationIcon: nil)

        XCTAssertFalse(alert.showsSuppressionButton)
        XCTAssertEqual(alert.buttons.map(\.title), [
            "Quit Retrace",
            "Run Retrace in Background",
            "Cancel"
        ])
    }

    func testFreshLaunchActivatesExistingInstanceWhenMatchingRunningAppExistsEvenIfLockWasAcquired() {
        XCTAssertEqual(
            AppDelegate.launchGateAction(
                mode: .fresh,
                lockResult: .acquired(descriptor: 42, attempts: 1),
                matchingRunningAppDetected: true
            ),
            .activateExistingInstanceAndExitDuplicate
        )
    }

    func testFreshLaunchActivatesExistingInstanceWhenLockIsHeldByAnotherProcess() {
        XCTAssertEqual(
            AppDelegate.launchGateAction(
                mode: .fresh,
                lockResult: .failedHeldByAnotherProcess(attempts: 1),
                matchingRunningAppDetected: false
            ),
            .activateExistingInstanceAndExitDuplicate
        )
    }

    func testRelaunchContinuesAfterLockError() {
        XCTAssertEqual(
            AppDelegate.launchGateAction(
                mode: .relaunch,
                lockResult: .failedError(code: EIO, attempts: 30),
                matchingRunningAppDetected: true
            ),
            .continueLaunch
        )
    }

    func testRelaunchActivatesExistingInstanceWhenLockIsHeldByAnotherProcess() {
        XCTAssertEqual(
            AppDelegate.launchGateAction(
                mode: .relaunch,
                lockResult: .failedHeldByAnotherProcess(attempts: 30),
                matchingRunningAppDetected: false
            ),
            .activateExistingInstanceAndExitDuplicate
        )
    }

    func testFreshLaunchActivatesExistingInstanceWhenLockErrorOccursAndMatchExists() {
        XCTAssertEqual(
            AppDelegate.launchGateAction(
                mode: .fresh,
                lockResult: .failedError(code: EIO, attempts: 1),
                matchingRunningAppDetected: true
            ),
            .activateExistingInstanceAndExitDuplicate
        )
    }

    func testFreshLaunchFailsClosedWhenLockErrorOccursWithoutMatch() {
        XCTAssertEqual(
            AppDelegate.launchGateAction(
                mode: .fresh,
                lockResult: .failedError(code: EIO, attempts: 1),
                matchingRunningAppDetected: false
            ),
            .exitDueToLockFailure
        )
    }

    func testTerminateActionFlushesImmediatelyWhenFlushInProgress() {
        XCTAssertEqual(
            AppDelegate.terminateAction(
                systemIsPoweringOff: true,
                isTerminationFlushInProgress: true,
                isTerminationDecisionInProgress: false,
                bypassQuitConfirmationPromptOnce: false
            ),
            .terminateNow
        )
    }

    func testTerminateActionBypassesConfirmationForSystemPowerOff() {
        XCTAssertEqual(
            AppDelegate.terminateAction(
                systemIsPoweringOff: true,
                isTerminationFlushInProgress: false,
                isTerminationDecisionInProgress: false,
                bypassQuitConfirmationPromptOnce: false
            ),
            .flushForSystemPowerOff
        )
    }

    func testTerminateActionPrefersPowerOffOverPendingDecision() {
        XCTAssertEqual(
            AppDelegate.terminateAction(
                systemIsPoweringOff: true,
                isTerminationFlushInProgress: false,
                isTerminationDecisionInProgress: true,
                bypassQuitConfirmationPromptOnce: false
            ),
            .flushForSystemPowerOff
        )
    }

    func testTerminateActionWaitsForInFlightDecision() {
        XCTAssertEqual(
            AppDelegate.terminateAction(
                systemIsPoweringOff: false,
                isTerminationFlushInProgress: false,
                isTerminationDecisionInProgress: true,
                bypassQuitConfirmationPromptOnce: false
            ),
            .waitForInFlightDecision
        )
    }

    func testTerminateActionFlushesWhenBypassRequestedOnce() {
        XCTAssertEqual(
            AppDelegate.terminateAction(
                systemIsPoweringOff: false,
                isTerminationFlushInProgress: false,
                isTerminationDecisionInProgress: false,
                bypassQuitConfirmationPromptOnce: true
            ),
            .flushSkippingConfirmation
        )
    }

    func testTerminateActionPresentsConfirmationByDefault() {
        XCTAssertEqual(
            AppDelegate.terminateAction(
                systemIsPoweringOff: false,
                isTerminationFlushInProgress: false,
                isTerminationDecisionInProgress: false,
                bypassQuitConfirmationPromptOnce: false
            ),
            .presentConfirmation
        )
    }
}

private final class StubQuitConfirmationWindow: NSWindow {
    private let stubVisible: Bool
    private let stubMiniaturized: Bool

    init(isVisible: Bool, isMiniaturized: Bool = false) {
        self.stubVisible = isVisible
        self.stubMiniaturized = isMiniaturized
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    override var isVisible: Bool {
        stubVisible
    }

    override var isMiniaturized: Bool {
        stubMiniaturized
    }
}
