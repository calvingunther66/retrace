import XCTest
import Capture
import Shared
import Database
@testable import App

/// `InputEventWriter` against a real in-memory `DatabaseManager`: events are stored, then linked to
/// real frame rows by timestamp, and the forced mouse-down frame is correlated by its exact
/// timestamp in every order capture and the writer can race in.
final class InputEventWriterTests: XCTestCase {

    private struct Fixture {
        let database: DatabaseManager
        let segmentID: Int64
        let baseMs: Int64
    }

    private func makeFixture() async throws -> Fixture {
        let database = DatabaseManager(
            databasePath: "file:input_writer_\(UUID().uuidString)?mode=memory&cache=private"
        )
        try await database.initialize()
        let segmentID = try await database.insertSegment(
            bundleID: "com.example.app", startDate: Date(), endDate: Date(),
            windowName: nil, browserUrl: nil, type: 0
        )
        return Fixture(database: database, segmentID: segmentID, baseMs: InputEvent.epochMilliseconds(Date()))
    }

    /// Inserts a frame at `baseMs + offsetMs` and returns its id and its exact stored timestamp.
    private func insertFrame(_ fixture: Fixture, offsetMs: Int64, displayID: UInt32 = 0) async throws -> (id: Int64, tsMs: Int64) {
        let date = Date(timeIntervalSince1970: Double(fixture.baseMs + offsetMs) / 1000)
        let id = try await fixture.database.insertFrame(FrameReference(
            id: FrameID(value: 0), timestamp: date, segmentID: AppSegmentID(value: fixture.segmentID),
            frameIndexInSegment: 0, metadata: FrameMetadata(displayID: displayID), source: .native
        ))
        return (id, InputEvent.epochMilliseconds(date))
    }

    private func click(_ fixture: Fixture) -> InputEvent {
        InputEvent(
            tsMs: fixture.baseMs, endTsMs: fixture.baseMs + 80, kind: .click,
            button: "left", clickCount: 1, x: 10, y: 10
        )
    }

    private func makeWriter(
        _ fixture: Fixture,
        store: InputEventWriter.Store? = nil,
        metrics: InputEventWriter.MetricsSink? = nil,
        threshold: Int = 50
    ) -> InputEventWriter {
        var configuration = InputEventWriter.Configuration()
        configuration.flushThreshold = threshold
        let now = fixture.baseMs + 60_000
        return InputEventWriter(
            store: store ?? .database(fixture.database),
            metrics: metrics,
            configuration: configuration,
            nowMs: { now }
        )
    }

    private func storedClick(_ fixture: Fixture) async throws -> InputEvent {
        let events = try await fixture.database.getInputEvents(
            sinceMs: fixture.baseMs - 1, untilMs: fixture.baseMs + 1, kinds: [.click]
        )
        return try XCTUnwrap(events.first)
    }

    // MARK: - Linking

    func testEventIsStoredThenLinkedToPreDownAndPostFrames() async throws {
        let fixture = try await makeFixture()
        let pre = try await insertFrame(fixture, offsetMs: -500)
        let down = try await insertFrame(fixture, offsetMs: 70)      // forced mouse-down capture
        let post = try await insertFrame(fixture, offsetMs: 400)     // settled frame after mouse-up
        let writer = makeWriter(fixture)

        await writer.enqueue(click(fixture))
        await writer.recordPreCapture(InputPreCaptureResult(
            requestMs: fixture.baseMs, outcome: .captured, keptFrameTimestampMs: down.tsMs
        ))
        await writer.flushNow()
        await writer.resolveNow()

        let event = try await storedClick(fixture)
        XCTAssertEqual(event.preFrameID, pre.id)
        XCTAssertEqual(event.downFrameID, down.id)
        XCTAssertEqual(event.postFrameID, post.id)
        assertWithin(event.preGapMs, of: 500, tolerance: 2)
        XCTAssertEqual(event.linkState, .resolved)
    }

    func testForcedFrameReportThatArrivesBeforeTheEventStillCorrelates() async throws {
        let fixture = try await makeFixture()
        _ = try await insertFrame(fixture, offsetMs: -500)
        let down = try await insertFrame(fixture, offsetMs: 70)
        _ = try await insertFrame(fixture, offsetMs: 400)
        let writer = makeWriter(fixture)

        // Capture reports in ~100ms; the click is still gathering accessibility context.
        await writer.recordPreCapture(InputPreCaptureResult(
            requestMs: fixture.baseMs, outcome: .captured, keptFrameTimestampMs: down.tsMs
        ))
        await writer.enqueue(click(fixture))
        await writer.flushNow()
        await writer.resolveNow()

        let stored = try await storedClick(fixture)
        XCTAssertEqual(stored.downFrameID, down.id)
    }

    func testForcedFrameReportThatArrivesAfterTheEventWasStoredCorrelates() async throws {
        let fixture = try await makeFixture()
        _ = try await insertFrame(fixture, offsetMs: -500)
        let down = try await insertFrame(fixture, offsetMs: 70)
        _ = try await insertFrame(fixture, offsetMs: 400)
        let writer = makeWriter(fixture)

        await writer.enqueue(click(fixture))
        await writer.flushNow()
        await writer.recordPreCapture(InputPreCaptureResult(
            requestMs: fixture.baseMs, outcome: .captured, keptFrameTimestampMs: down.tsMs
        ))
        await writer.resolveNow()

        let stored = try await storedClick(fixture)
        XCTAssertEqual(stored.downFrameID, down.id)
    }

    func testForcedFrameReportDuringAnInFlightInsertIsNotLost() async throws {
        let fixture = try await makeFixture()
        _ = try await insertFrame(fixture, offsetMs: -500)
        let down = try await insertFrame(fixture, offsetMs: 70)
        _ = try await insertFrame(fixture, offsetMs: 400)

        let insertStarted = AsyncSignal()
        let allowInsert = AsyncSignal()
        let real = InputEventWriter.Store.database(fixture.database)
        let slowStore = InputEventWriter.Store(
            insert: { events in
                await insertStarted.fire()
                await allowInsert.wait()
                return try await real.insert(events)
            },
            resolve: real.resolve,
            setDownFrame: real.setDownFrame
        )
        let writer = makeWriter(fixture, store: slowStore)

        await writer.enqueue(click(fixture))
        let flush = Task { await writer.flushNow() }
        await insertStarted.wait()

        // The report lands while the batch is mid-insert: the event is neither buffered nor stored.
        await writer.recordPreCapture(InputPreCaptureResult(
            requestMs: fixture.baseMs, outcome: .captured, keptFrameTimestampMs: down.tsMs
        ))
        await allowInsert.fire()
        await flush.value
        await writer.resolveNow()

        let stored = try await storedClick(fixture)
        XCTAssertEqual(stored.downFrameID, down.id)
    }

    func testDedupedOrDroppedPreCaptureLeavesNoDownFrame() async throws {
        let fixture = try await makeFixture()
        _ = try await insertFrame(fixture, offsetMs: -500)
        _ = try await insertFrame(fixture, offsetMs: 400)
        let writer = makeWriter(fixture)

        await writer.enqueue(click(fixture))
        await writer.recordPreCapture(InputPreCaptureResult(
            requestMs: fixture.baseMs, outcome: .deduped, keptFrameTimestampMs: nil
        ))
        await writer.flushNow()
        await writer.resolveNow()

        let event = try await storedClick(fixture)
        XCTAssertNil(event.downFrameTsMs)
        XCTAssertNil(event.downFrameID)
        XCTAssertNotNil(event.preFrameID, "the earlier frame is still a valid, visually identical pre frame")
    }

    // MARK: - Writing

    func testReachingTheThresholdFlushesWithoutWaitingForTheTimer() async throws {
        let fixture = try await makeFixture()
        let writer = makeWriter(fixture, threshold: 3)

        for index in 0..<3 {
            await writer.enqueue(InputEvent(tsMs: fixture.baseMs + Int64(index), kind: .scroll, scrollDy: -5))
        }

        let stored = try await fixture.database.getInputEvents(
            sinceMs: fixture.baseMs - 1, untilMs: fixture.baseMs + 100
        )
        XCTAssertEqual(stored.count, 3)
        let buffered = await writer.bufferedCountForTesting()
        XCTAssertEqual(buffered, 0)
    }

    func testFailedInsertKeepsEventsAndRetriesExactlyOnce() async throws {
        let fixture = try await makeFixture()
        let real = InputEventWriter.Store.database(fixture.database)
        let failures = Counter(remaining: 1)
        let flaky = InputEventWriter.Store(
            insert: { events in
                if await failures.consume() { throw DatabaseError.connectionFailed(underlying: "simulated") }
                return try await real.insert(events)
            },
            resolve: real.resolve,
            setDownFrame: real.setDownFrame
        )
        let writer = makeWriter(fixture, store: flaky)

        await writer.enqueue(click(fixture))
        await writer.flushNow()
        let afterFailure = await writer.bufferedCountForTesting()
        XCTAssertEqual(afterFailure, 1, "the event must survive a failed write")

        await writer.flushNow()
        let afterRetry = await writer.bufferedCountForTesting()
        XCTAssertEqual(afterRetry, 0)
        let stored = try await fixture.database.getInputEvents(sinceMs: 0, untilMs: Int64.max)
        XCTAssertEqual(stored.count, 1)
    }

    func testStopFlushesRemainingEvents() async throws {
        let fixture = try await makeFixture()
        let writer = makeWriter(fixture)
        await writer.enqueue(click(fixture))
        await writer.stop()
        let stored = try await fixture.database.getInputEvents(sinceMs: 0, untilMs: Int64.max)
        XCTAssertEqual(stored.count, 1)
    }

    // MARK: - Metrics

    func testMetricsAreAggregatedAndSilentWhenIdle() async throws {
        let fixture = try await makeFixture()
        let recorded = MetricRecorder()
        var stats = InputEventStats()
        stats.click = 4
        stats.typing = 2
        stats.droppedSecureField = 1
        let statsBox = StatsBox(stats)
        let sink = InputEventWriter.MetricsSink(
            record: { type, metadata in await recorded.append(type, metadata) },
            captureStats: { await statsBox.take() }
        )
        let writer = makeWriter(fixture, metrics: sink)

        _ = try await insertFrame(fixture, offsetMs: -500)
        _ = try await insertFrame(fixture, offsetMs: 400)
        await writer.enqueue(click(fixture))
        await writer.recordPreCapture(InputPreCaptureResult(requestMs: fixture.baseMs, outcome: .deduped, keptFrameTimestampMs: nil))
        await writer.flushNow()
        await writer.resolveNow()
        await writer.emitMetricsNow()

        let first = await recorded.entries
        XCTAssertEqual(first.map(\.type), [.inputEventLogged, .inputEventLinked])
        let logged = try XCTUnwrap(first[0].json)
        XCTAssertEqual(logged["click"], 4)
        XCTAssertEqual(logged["typing"], 2)
        XCTAssertEqual(logged["droppedSecureField"], 1)
        XCTAssertEqual(logged["preDeduped"], 1)
        let linked = try XCTUnwrap(first[1].json)
        XCTAssertEqual(linked["resolved"], 1)

        await writer.emitMetricsNow()
        let second = await recorded.entries
        XCTAssertEqual(second.count, 2, "nothing new happened, so no rows are written")
    }
}

// MARK: - Test helpers

private extension XCTestCase {
    func assertWithin(_ value: Int64?, of expected: Int64, tolerance: Int64, file: StaticString = #filePath, line: UInt = #line) {
        guard let value else { return XCTFail("nil", file: file, line: line) }
        XCTAssertLessThanOrEqual(abs(value - expected), tolerance, "\(value) vs \(expected)", file: file, line: line)
    }
}

private actor AsyncSignal {
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func fire() { fired = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor Counter {
    private var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
    func consume() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

private actor StatsBox {
    private var stats: InputEventStats
    init(_ stats: InputEventStats) { self.stats = stats }
    func take() -> InputEventStats {
        defer { stats = InputEventStats() }
        return stats
    }
}

private actor MetricRecorder {
    struct Entry {
        let type: DailyMetricsQueries.MetricType
        let json: [String: Int]?
    }
    private(set) var entries: [Entry] = []
    func append(_ type: DailyMetricsQueries.MetricType, _ metadata: String?) {
        let decoded = metadata
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] }
        entries.append(Entry(type: type, json: decoded))
    }
}
