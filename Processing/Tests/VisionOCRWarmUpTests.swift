import XCTest
import Vision
@testable import Processing

/// Covers the cold-start gate that keeps a slow first `.accurate` Vision call (on-device
/// model compile) from being mistaken for a wedge by the 20s watchdog / circuit breaker.
final class VisionOCRWarmUpTests: XCTestCase {
    private actor ProbeCounter {
        private(set) var runs = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false

        func begin() { runs += 1 }

        func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { gate = $0 }
        }

        func release() {
            released = true
            gate?.resume()
            gate = nil
        }
    }

    func testConcurrentCallersShareOneProbeAndAllObserveItsOutcome() async {
        let warmUp = VisionOCRWarmUp()
        let counter = ProbeCounter()

        let results = await withTaskGroup(of: VisionOCRWarmUp.Outcome.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await warmUp.ensureWarm(key: "en-US") {
                        await counter.begin()
                        await counter.waitForRelease()
                        return .warm
                    }
                }
            }
            // Let every caller pile onto the in-flight probe before it completes.
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(warmUp.isWarming)
            await counter.release()

            var collected: [VisionOCRWarmUp.Outcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        XCTAssertEqual(results, Array(repeating: .warm, count: 5))
        let runs = await counter.runs
        XCTAssertEqual(runs, 1, "a cold start must run exactly one compile, not one per worker")
        XCTAssertFalse(warmUp.isWarming)
    }

    func testWarmModelSkipsProbeOnLaterCalls() async {
        let warmUp = VisionOCRWarmUp()
        let counter = ProbeCounter()
        await counter.release()

        for _ in 0..<3 {
            let outcome = await warmUp.ensureWarm(key: "en-US") {
                await counter.begin()
                return .warm
            }
            XCTAssertEqual(outcome, .warm)
        }
        let runs = await counter.runs
        XCTAssertEqual(runs, 1)
    }

    func testFailedOutcomeIsStickyUntilResetThenReprobes() async {
        let warmUp = VisionOCRWarmUp()
        let counter = ProbeCounter()

        let first = await warmUp.ensureWarm(key: "en-US") {
            await counter.begin()
            return .failed
        }
        let second = await warmUp.ensureWarm(key: "en-US") {
            await counter.begin()
            return .warm
        }
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(second, .failed, "a failed warm-up must not silently re-run (each attempt can leak a thread)")
        var runs = await counter.runs
        XCTAssertEqual(runs, 1)

        warmUp.reset()
        let afterReset = await warmUp.ensureWarm(key: "en-US") {
            await counter.begin()
            return .warm
        }
        XCTAssertEqual(afterReset, .warm)
        runs = await counter.runs
        XCTAssertEqual(runs, 2)
    }

    func testResetDuringFlightDiscardsStaleOutcome() async {
        let warmUp = VisionOCRWarmUp()
        let counter = ProbeCounter()

        let stale = Task {
            await warmUp.ensureWarm(key: "en-US") {
                await counter.begin()
                await counter.waitForRelease()
                return .failed
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        warmUp.reset()
        await counter.release()
        _ = await stale.value

        // The reset happened while the first probe was running, so its `.failed` must not
        // poison the fresh state: the next caller runs its own probe.
        let fresh = await warmUp.ensureWarm(key: "en-US") { .warm }
        XCTAssertEqual(fresh, .warm)
    }

    func testDifferentLanguageSetsWarmIndependently() async {
        let warmUp = VisionOCRWarmUp()
        let english = await warmUp.ensureWarm(key: "en-US") { .warm }
        let german = await warmUp.ensureWarm(key: "de-DE") { .failed }
        XCTAssertEqual(english, .warm)
        XCTAssertEqual(german, .failed)
    }

    func testBreakerTripOpensImmediatelyAndResetClosesIt() {
        let breaker = OCRCircuitBreaker(threshold: 2)
        XCTAssertFalse(breaker.isOpen)
        breaker.trip()
        XCTAssertTrue(breaker.isOpen)
        breaker.reset()
        XCTAssertFalse(breaker.isOpen)
    }

    /// Real Vision, real rendered pixels: proves the probe image actually contains
    /// recognizable text (a blank probe would warm nothing). Uses `.fast`, which doesn't
    /// need the Neural Engine compile, so this stays quick on a cold binary.
    func testProbeImageContainsRecognizableText() throws {
        let image = try XCTUnwrap(VisionOCR.makeWarmUpImage())
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .lowercased()
        XCTAssertTrue(text.contains("retrace"), "expected probe text to be readable, got: \(text)")
    }
}
