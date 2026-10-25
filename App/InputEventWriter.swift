import Foundation
import Capture
import Database
import Shared

/// Persists input events and links them to the frames around them.
///
/// Capture hands over finished events and, separately, the exact timestamp of the frame forced on
/// mouse-down. Frame ids only exist after the capture pipeline inserts the row, and dedup can drop
/// frames, so events are written first and linked later by timestamp (see
/// `InputEventQueries.resolveLinks`). Everything here runs off the main thread.
actor InputEventWriter {

    struct Configuration: Sendable {
        var flushInterval: TimeInterval = 2
        var flushThreshold = 50
        var resolveInterval: TimeInterval = 5
        var metricInterval: TimeInterval = 60
        /// Hard cap if the database stays unavailable; oldest events are dropped first.
        var maxBuffered = 1_000
        var recentlyFlushedLimit = 256
        /// Forced-frame reports that never found their event are forgotten after this long.
        var staleDownFrameMs: Int64 = 60_000
    }

    /// Database operations, as closures so failures can be injected in tests.
    struct Store: Sendable {
        var insert: @Sendable ([InputEvent]) async throws -> [Int64]
        var resolve: @Sendable (_ nowMs: Int64) async throws -> InputEventLinkSummary
        var setDownFrame: @Sendable (_ eventTsMs: Int64, _ frameTsMs: Int64) async throws -> Bool

        static func database(_ database: DatabaseManager) -> Store {
            Store(
                insert: { try await database.insertInputEvents($0) },
                resolve: { try await database.resolveInputEventLinks(nowMs: $0) },
                setDownFrame: { try await database.setInputEventDownFrameTimestamp(eventTsMs: $0, frameTsMs: $1) }
            )
        }
    }

    struct MetricsSink: Sendable {
        var record: @Sendable (_ type: DailyMetricsQueries.MetricType, _ metadata: String?) async -> Void
        var captureStats: @Sendable () async -> InputEventStats
    }

    private let store: Store
    private let metrics: MetricsSink?
    private let configuration: Configuration
    private let nowMs: @Sendable () -> Int64

    private var buffer: [InputEvent] = []
    private var isFlushing = false
    private var loopTask: Task<Void, Never>?

    /// Forced-frame timestamps whose click is in flight or has not arrived yet.
    private var pendingDownFrames: [Int64: Int64] = [:]
    /// Click `tsMs` values already stored, so a late report becomes a DB update.
    private var recentlyFlushed: [Int64] = []
    private var recentlyFlushedSet = Set<Int64>()

    private var linkTotals = InputEventLinkSummary()
    private var preCaptureCounts: [InputPreCaptureOutcome: Int] = [:]
    private var lastResolveMs: Int64 = 0
    private var lastMetricMs: Int64 = 0

    init(
        store: Store,
        metrics: MetricsSink? = nil,
        configuration: Configuration = Configuration(),
        nowMs: @escaping @Sendable () -> Int64 = { InputEvent.epochMilliseconds(Date()) }
    ) {
        self.store = store
        self.metrics = metrics
        self.configuration = configuration
        self.nowMs = nowMs
        let start = nowMs()
        self.lastResolveMs = start
        self.lastMetricMs = start
    }

    // MARK: - Lifecycle

    func start() {
        guard loopTask == nil else { return }
        let interval = configuration.flushInterval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    /// Flush what is buffered, run a last link pass, and stop the background loop.
    func stop() async {
        loopTask?.cancel()
        loopTask = nil
        await flushNow()
        await resolveNow()
        await emitMetricsNow()
    }

    private func tick() async {
        await flushNow()
        let now = nowMs()
        if now - lastResolveMs >= Int64(configuration.resolveInterval * 1000) {
            await resolveNow()
        }
        if now - lastMetricMs >= Int64(configuration.metricInterval * 1000) {
            await emitMetricsNow()
        }
    }

    // MARK: - Intake

    func enqueue(_ event: InputEvent) async {
        var event = event
        if event.kind == .click, let frameTs = pendingDownFrames.removeValue(forKey: event.tsMs) {
            event.downFrameTsMs = frameTs
        }
        buffer.append(event)
        if buffer.count > configuration.maxBuffered {
            buffer.removeFirst(buffer.count - configuration.maxBuffered)
            Log.warning("[InputEventWriter] Buffer overflow; dropped oldest input events", category: .app)
        }
        if buffer.count >= configuration.flushThreshold {
            await flushNow()
        }
    }

    /// Capture reports the stored timestamp of the frame it forced on mouse-down.
    func recordPreCapture(_ result: InputPreCaptureResult) async {
        preCaptureCounts[result.outcome, default: 0] += 1
        guard result.outcome == .captured, let frameTs = result.keptFrameTimestampMs else { return }

        if let index = buffer.firstIndex(where: { $0.kind == .click && $0.tsMs == result.requestMs }) {
            buffer[index].downFrameTsMs = frameTs
        } else if recentlyFlushedSet.contains(result.requestMs) {
            _ = try? await store.setDownFrame(result.requestMs, frameTs)
        } else {
            // The click has not arrived yet (it is still gathering accessibility context), or its
            // insert is in flight. Applied as soon as it is stored.
            pendingDownFrames[result.requestMs] = frameTs
            pruneStaleDownFrames()
        }
    }

    // MARK: - Writing

    func flushNow() async {
        guard !isFlushing, !buffer.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        do {
            _ = try await store.insert(batch)
        } catch {
            Log.error("[InputEventWriter] Failed to store \(batch.count) input events; will retry: \(error)", category: .app)
            buffer.insert(contentsOf: batch, at: 0)
            if buffer.count > configuration.maxBuffered {
                buffer.removeFirst(buffer.count - configuration.maxBuffered)
            }
            return
        }

        for event in batch where event.kind == .click {
            rememberFlushed(event.tsMs)
            // A forced-frame report that landed while this insert was in flight.
            if let frameTs = pendingDownFrames.removeValue(forKey: event.tsMs), event.downFrameTsMs == nil {
                _ = try? await store.setDownFrame(event.tsMs, frameTs)
            }
        }
    }

    private func rememberFlushed(_ tsMs: Int64) {
        guard recentlyFlushedSet.insert(tsMs).inserted else { return }
        recentlyFlushed.append(tsMs)
        if recentlyFlushed.count > configuration.recentlyFlushedLimit {
            recentlyFlushedSet.remove(recentlyFlushed.removeFirst())
        }
    }

    private func pruneStaleDownFrames() {
        let cutoff = nowMs() - configuration.staleDownFrameMs
        pendingDownFrames = pendingDownFrames.filter { $0.key >= cutoff }
    }

    // MARK: - Linking

    @discardableResult
    func resolveNow() async -> InputEventLinkSummary {
        lastResolveMs = nowMs()
        do {
            let summary = try await store.resolve(lastResolveMs)
            linkTotals.resolved += summary.resolved
            linkTotals.gaveUp += summary.gaveUp
            linkTotals.redacted += summary.redacted
            linkTotals.preMissing += summary.preMissing
            linkTotals.postMissing += summary.postMissing
            linkTotals.stillPending = summary.stillPending
            return summary
        } catch {
            Log.error("[InputEventWriter] Failed to resolve input event links: \(error)", category: .app)
            return InputEventLinkSummary()
        }
    }

    // MARK: - Metrics

    /// Emit aggregated counters (at most one row per metric per interval, and none when idle).
    func emitMetricsNow() async {
        lastMetricMs = nowMs()
        guard let metrics else { return }

        let stats = await metrics.captureStats()
        let preCounts = preCaptureCounts
        preCaptureCounts.removeAll()
        if !stats.isEmpty || !preCounts.isEmpty {
            await metrics.record(.inputEventLogged, Self.json([
                "click": stats.click,
                "scroll": stats.scroll,
                "shortcut": stats.shortcut,
                "typing": stats.typing,
                "unverified": stats.unverified,
                "droppedDrag": stats.droppedDrag,
                "droppedSecureInput": stats.droppedSecureInput,
                "droppedSecureField": stats.droppedSecureField,
                "droppedExcluded": stats.droppedExcluded,
                "preCaptured": preCounts[.captured] ?? 0,
                "preDeduped": preCounts[.deduped] ?? 0,
                "preDropped": preCounts[.dropped] ?? 0,
                "preFailed": preCounts[.failed] ?? 0
            ]))
        }

        let totals = linkTotals
        linkTotals = InputEventLinkSummary()
        if totals.resolved + totals.gaveUp + totals.redacted + totals.preMissing + totals.postMissing > 0 {
            await metrics.record(.inputEventLinked, Self.json([
                "resolved": totals.resolved,
                "gaveUp": totals.gaveUp,
                "stillPending": totals.stillPending,
                "redacted": totals.redacted,
                "preMissing": totals.preMissing,
                "postMissing": totals.postMissing
            ]))
        }
    }

    private static func json(_ payload: [String: Int]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Testing

    func bufferedCountForTesting() -> Int { buffer.count }
}
