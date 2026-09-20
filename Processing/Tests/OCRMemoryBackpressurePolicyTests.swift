import XCTest
import Foundation
import Shared
import Database
@testable import Processing

final class OCRMemoryBackpressurePolicyTests: XCTestCase {
    func testHysteresisPausesAndResumesAtDifferentThresholds() {
        let policy = OCRMemoryBackpressurePolicy(
            enabled: true,
            pauseThresholdBytes: 100,
            resumeThresholdBytes: 60,
            pollIntervalNs: 1_000_000_000,
            pressuredPollIntervalNs: 250_000_000
        )

        XCTAssertFalse(policy.shouldPause(footprintBytes: 99, currentlyPaused: false))
        XCTAssertTrue(policy.shouldPause(footprintBytes: 100, currentlyPaused: false))
        XCTAssertTrue(policy.shouldPause(footprintBytes: 80, currentlyPaused: true))
        XCTAssertFalse(policy.shouldPause(footprintBytes: 59, currentlyPaused: true))
    }

    func testDefaultsEnableBackpressureForReferenceDisplaySize() {
        // Stable-release-audit finding #29 (2026-09-18): this test previously
        // asserted `policy.enabled == false` by default and had been failing
        // since ae82bad. OCRMemoryBackpressurePolicy.current()
        // (FrameProcessingQueue.swift) defaults `enabled` to `true` whenever
        // `retrace.debug.ocrMemoryBackpressureEnabled` is unset, and that default
        // is the intentional side: `guard policy.enabled` (FrameProcessingQueue.swift)
        // gates the real OOM-protection backpressure ae82bad added, the defaults
        // key is a "debug" override (nowhere exposed as a Settings opt-in), and
        // defaulting a memory-safety guard to off would be an odd product choice.
        // The old assertion was the stale side; corrected here to match the
        // documented, intentional default.
        let suiteName = "OCRMemoryBackpressurePolicyTests.reference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: OCRMemoryBackpressurePolicy.referenceDisplayPixelCount
        )

        XCTAssertTrue(policy.enabled)
        XCTAssertEqual(policy.pauseThresholdBytes, OCRMemoryBackpressurePolicy.defaultPauseThresholdBytes)
        XCTAssertEqual(policy.resumeThresholdBytes, OCRMemoryBackpressurePolicy.defaultResumeThresholdBytes)
        XCTAssertEqual(policy.pollIntervalNs, 1_000_000_000)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsScaleUpForUltraWideDisplays() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.ultrawide.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: 5_120 * 1_440
        )

        XCTAssertEqual(policy.pauseThresholdBytes, 2_172 * 1024 * 1024)
        XCTAssertEqual(policy.resumeThresholdBytes, 2_028 * 1024 * 1024)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsClampResumeBelowPauseThreshold() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(900, forKey: OCRMemoryBackpressurePolicy.pauseThresholdDefaultsKey)
        defaults.set(950, forKey: OCRMemoryBackpressurePolicy.resumeThresholdDefaultsKey)
        defaults.set(false, forKey: OCRMemoryBackpressurePolicy.enabledDefaultsKey)
        defaults.set(250, forKey: OCRMemoryBackpressurePolicy.pollIntervalDefaultsKey)

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: 5_120 * 1_440
        )

        XCTAssertFalse(policy.enabled)
        XCTAssertEqual(policy.pauseThresholdBytes, 900 * 1024 * 1024)
        XCTAssertEqual(policy.resumeThresholdBytes, 899 * 1024 * 1024)
        XCTAssertEqual(policy.pollIntervalNs, 250 * 1_000_000)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPressuredPollDefaultsShorterThanNominal() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.pressuredDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: OCRMemoryBackpressurePolicy.referenceDisplayPixelCount
        )

        XCTAssertEqual(policy.pollIntervalNs, 1_000_000_000)
        XCTAssertEqual(
            policy.pressuredPollIntervalNs,
            OCRMemoryBackpressurePolicy.defaultPressuredPollIntervalNs
        )
        XCTAssertLessThan(policy.pressuredPollIntervalNs, policy.pollIntervalNs)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPressuredPollClampsToMinimumInterval() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.pressuredMin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(50, forKey: OCRMemoryBackpressurePolicy.pressuredPollIntervalDefaultsKey)

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: OCRMemoryBackpressurePolicy.referenceDisplayPixelCount
        )

        XCTAssertEqual(policy.pressuredPollIntervalNs, 100 * 1_000_000)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPressuredPollNeverExceedsNominalPoll() {
        let suiteName = "OCRMemoryBackpressurePolicyTests.pressuredCap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(200, forKey: OCRMemoryBackpressurePolicy.pollIntervalDefaultsKey)
        defaults.set(900, forKey: OCRMemoryBackpressurePolicy.pressuredPollIntervalDefaultsKey)

        let policy = OCRMemoryBackpressurePolicy.current(
            defaults: defaults,
            largestDisplayPixelCount: OCRMemoryBackpressurePolicy.referenceDisplayPixelCount
        )

        XCTAssertEqual(policy.pollIntervalNs, 200 * 1_000_000)
        XCTAssertEqual(policy.pressuredPollIntervalNs, 200 * 1_000_000)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDropOldestQueuedFramesKeepsNewest() async throws {
        let database = DatabaseManager(
            databasePath: "file:memdb_drop_oldest_\(UUID().uuidString)?mode=memory&cache=private"
        )
        try await database.initialize()

        let segmentID = try await database.insertSegment(
            bundleID: "com.test.app",
            startDate: Date(),
            endDate: Date(),
            windowName: nil,
            browserUrl: nil,
            type: 0
        )

        var frameIDs: [Int64] = []
        for index in 0..<5 {
            let reference = FrameReference(
                id: FrameID(value: 0),
                timestamp: Date(),
                segmentID: AppSegmentID(value: segmentID),
                frameIndexInSegment: index,
                metadata: FrameMetadata(),
                source: .native
            )
            let frameID = try await database.insertFrame(reference)
            try await database.updateFrameProcessingStatus(frameID: frameID, status: 0)
            try await database.enqueueFrameForProcessing(frameID: frameID)
            frameIDs.append(frameID)
            // Distinct enqueuedAt values so oldest-first ordering is deterministic.
            try await Task.sleep(for: .milliseconds(5), clock: .continuous)
        }

        let depthBefore = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depthBefore, 5)

        let dropped = try await database.dropOldestQueuedFrames(maxDepth: 3)
        XCTAssertEqual(dropped, 2)
        let depthAfter = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depthAfter, 3)

        // The two oldest enqueues were shed: the next dequeue yields the
        // third-enqueued frame.
        let next = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(next?.frameID, frameIDs[2])

        // Within budget: no-op.
        let droppedWithinBudget = try await database.dropOldestQueuedFrames(maxDepth: 10)
        XCTAssertEqual(droppedWithinBudget, 0)

        try await database.close()
    }
}
