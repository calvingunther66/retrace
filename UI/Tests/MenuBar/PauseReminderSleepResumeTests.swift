import XCTest
@testable import Retrace

@MainActor
final class PauseReminderSleepResumeTests: XCTestCase {
    // MARK: - SleepResumeState

    func testResumePendingSurvivesRepeatedSleepMarks() {
        let state = SleepResumeState()
        state.markResumePending()
        // Dark-wake cycles deliver extra willSleep notifications while capture is already stopped.
        state.markResumePending()
        XCTAssertTrue(state.isResumePending)
    }

    func testSuccessfulResumeClearsPendingWithoutFailure() {
        let state = SleepResumeState()
        state.markResumePending()
        state.finishResume(succeeded: true)

        XCTAssertFalse(state.isResumePending)
        XCTAssertFalse(state.consumeResumeFailure())
    }

    func testFailedResumeReportsFailureExactlyOnce() {
        let state = SleepResumeState()
        state.markResumePending()
        state.finishResume(succeeded: false)

        XCTAssertFalse(state.isResumePending)
        XCTAssertTrue(state.consumeResumeFailure())
        XCTAssertFalse(state.consumeResumeFailure())
    }

    func testNewSleepDiscardsStaleFailure() {
        let state = SleepResumeState()
        state.markResumePending()
        state.finishResume(succeeded: false)
        state.markResumePending()

        XCTAssertFalse(state.consumeResumeFailure())
    }

    // MARK: - Reminder decisions

    func testNoReminderStartsWhenWakeResumeSucceeds() {
        // Sleep stop -> suppression window -> capture is back: leaving the window must not arm a timer.
        XCTAssertFalse(PauseReminderManager.shouldStartOffReminder(leaving: .sleepResume, isCapturing: true))
    }

    func testReminderStartsAfterSleepResumeWindowIfStillNotCapturing() {
        XCTAssertTrue(PauseReminderManager.shouldStartOffReminder(leaving: .sleepResume, isCapturing: false))
    }

    func testFailedWakeResumeShowsReminderImmediately() {
        XCTAssertTrue(
            PauseReminderManager.shouldShowImmediateReminderAfterFailedResume(
                resumeFailed: true,
                isCapturing: false,
                isPausedState: false
            )
        )
    }

    func testSuccessfulOrUserPausedWakeDoesNotShowImmediateReminder() {
        XCTAssertFalse(
            PauseReminderManager.shouldShowImmediateReminderAfterFailedResume(
                resumeFailed: false,
                isCapturing: true,
                isPausedState: false
            )
        )
        XCTAssertFalse(
            PauseReminderManager.shouldShowImmediateReminderAfterFailedResume(
                resumeFailed: true,
                isCapturing: false,
                isPausedState: true
            )
        )
        // Someone else (e.g. the panel's Resume button) already restarted capture.
        XCTAssertFalse(
            PauseReminderManager.shouldShowImmediateReminderAfterFailedResume(
                resumeFailed: true,
                isCapturing: true,
                isPausedState: false
            )
        )
    }

    func testManualStopAndPauseBehaviorIsUnchanged() {
        // User stopped recording themselves (no suppression window): the normal capturing -> off path handles it.
        XCTAssertFalse(PauseReminderManager.shouldStartOffReminder(leaving: .none, isCapturing: false))
        XCTAssertFalse(PauseReminderManager.shouldStartOffReminder(leaving: .onboarding, isCapturing: false))
        // Timed pause ending while still off keeps starting the reminder as before.
        XCTAssertTrue(PauseReminderManager.shouldStartOffReminder(leaving: .paused, isCapturing: false))
        XCTAssertFalse(PauseReminderManager.shouldStartOffReminder(leaving: .paused, isCapturing: true))
    }
}
