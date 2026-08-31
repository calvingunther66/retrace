import Foundation
import AppKit
import Shared
import Database
import Storage
import Search

/// Background actor that describes screenshots with a vision-capable LLM (via OpenRouter)
/// and writes the descriptions into a searchable FTS5 index, so search can match on visual
/// content (icons, diagrams, photos, layout) that OCR text alone never captures.
///
/// Runs a single serial polling loop (like `RetentionManager`, not `FrameProcessingQueue`'s
/// worker pool — a daily request budget serializes throughput regardless of concurrency).
///
/// Two independent lanes, each with its own budget:
///  - **Fresh lane**: frames captured within the last 72 hours. Uncapped by the daily counter,
///    naturally bounded by actual capture volume.
///  - **Backfill lane**: everything older. Capped at `dailyBackfillBudget` (default 600)
///    requests/day, tracked via the `semantic_index_requests` table (a DB row, not
///    UserDefaults, so a crash mid-request still counts against the day's budget).
public actor SemanticIndexer {
    private let database: DatabaseManager
    private let storage: StorageManager
    private let openRouterClient: OpenRouterClient
    private var appFilterPolicy: AppFilterPolicy = .allowAll

    private var loopTask: Task<Void, Never>?
    private var isRunning = false

    /// Live-toggle read from UserDefaults every loop iteration, so flipping this in Settings
    /// takes effect without an app restart (there's no push notification wiring the way
    /// `FrameProcessingQueue.ocrEnabled` gets pushed via `updatePowerConfig`, so this polls).
    private var isEnabled: Bool {
        let defaults = UserDefaults(suiteName: OpenRouterCredentialsManager.settingsSuiteName)
        return defaults?.bool(forKey: OpenRouterCredentialsManager.semanticIndexingEnabledDefaultsKey) ?? false
    }

    private let batchSize = 5
    private let dailyBackfillBudget = 600
    private let freshLaneWindow: TimeInterval = 72 * 3600
    private let idlePollInterval: Duration = .seconds(30)
    // OpenRouter's free-tier shared pool caps at 20 requests/minute across ALL free models a
    // key uses (including interactive "Ask AI" calls happening concurrently) — 4s keeps this
    // indexer's own contribution to ~15/min, leaving headroom rather than sitting at the edge.
    private let interBatchDelay: Duration = .seconds(4)

    public init(
        database: DatabaseManager,
        storage: StorageManager,
        openRouterClient: OpenRouterClient = OpenRouterClient()
    ) {
        self.database = database
        self.storage = storage
        self.openRouterClient = openRouterClient
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !isRunning else {
            Log.warning("[SemanticIndexer] Already running", category: .processing)
            return
        }
        isRunning = true
        Log.info("[SemanticIndexer] Started", category: .processing)

        loopTask = Task {
            while !Task.isCancelled {
                let outcome = await self.processNextBatch()
                let delay: Duration
                switch outcome {
                case .processed:
                    delay = self.interBatchDelay
                case .emptyQueue, .budgetExhausted, .disabled, .noAPIKey:
                    delay = self.idlePollInterval
                case .rateLimited(let retryAfterSeconds):
                    delay = .seconds(max(retryAfterSeconds, 5))
                case .error:
                    delay = self.idlePollInterval
                }
                try? await Task.sleep(for: delay, clock: .continuous)
            }
        }
    }

    public func stop() async {
        guard isRunning else { return }
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        Log.info("[SemanticIndexer] Stopped", category: .processing)
    }

    public func updateAppFilterPolicy(_ policy: AppFilterPolicy) {
        appFilterPolicy = policy
    }

    // MARK: - Batch processing

    private enum BatchOutcome {
        case processed(count: Int)
        case emptyQueue
        case budgetExhausted
        case disabled
        case noAPIKey
        case rateLimited(retryAfterSeconds: Int)
        case error(String)
    }

    private func processNextBatch() async -> BatchOutcome {
        guard isEnabled else { return .disabled }

        let apiKey = OpenRouterCredentialsManager.getAPIKey() ?? ""
        guard !apiKey.isEmpty else { return .noAPIKey }

        let model = Self.readIndexingModel()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let freshCutoffMs = nowMs - Int64(freshLaneWindow * 1000)

        do {
            let backfillRemaining = try await remainingBackfillBudgetToday(nowMs: nowMs)
            let candidates = try await database.selectPendingSemanticFrames(
                limit: batchSize * 2, // headroom in case some get filtered out below
                freshCutoffMs: freshCutoffMs
            )

            guard !candidates.isEmpty else { return .emptyQueue }

            // Determine the batch's lane from the FIRST eligible (non-app-filtered) candidate,
            // then take ONLY same-lane candidates for this batch. A batch must never mix lanes:
            // it's written to `semantic_index_requests` with a single `lane` value, and
            // `countBackfillSemanticRequestsToday` only counts rows labeled "backfill" — a
            // mixed batch labeled "fresh" would let backfill frames escape the daily cap
            // entirely, defeating the whole point of a separate, bounded backfill budget.
            var lane: String?
            var batch: [SemanticIndexQueries.PendingFrame] = []
            var backfillBudgetExhausted = false

            for candidate in candidates {
                guard appFilterPolicy.allows(bundleID: candidate.bundleID) else {
                    try await database.markSemanticFramesSkipped([candidate.frameID])
                    continue
                }

                let candidateLane = candidate.createdAtMs >= freshCutoffMs ? "fresh" : "backfill"
                if let lane, candidateLane != lane {
                    continue // wrong lane for this batch — leave it for a later cycle
                }

                if candidateLane == "backfill" {
                    guard backfillRemaining > batch.count else {
                        backfillBudgetExhausted = true
                        continue
                    }
                }

                lane = candidateLane
                batch.append(candidate)
                if batch.count >= batchSize { break }
            }

            guard let resolvedLane = lane, !batch.isEmpty else {
                return backfillBudgetExhausted ? .budgetExhausted : .emptyQueue
            }

            return await dispatch(batch: batch, lane: resolvedLane, model: model, apiKey: apiKey)
        } catch {
            Log.error("[SemanticIndexer] Batch selection failed: \(error.localizedDescription)", category: .processing)
            return .error(error.localizedDescription)
        }
    }

    private func remainingBackfillBudgetToday(nowMs: Int64) async throws -> Int {
        let utcCalendar = { () -> Calendar in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal
        }()
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let dayStart = utcCalendar.startOfDay(for: now)
        let dayStartMs = Int64(dayStart.timeIntervalSince1970 * 1000)

        let usedToday = try await database.countBackfillSemanticRequestsToday(utcDayStartMs: dayStartMs)
        return max(0, dailyBackfillBudget - usedToday)
    }

    private func dispatch(
        batch: [SemanticIndexQueries.PendingFrame],
        lane: String,
        model: String,
        apiKey: String
    ) async -> BatchOutcome {
        var images: [(frameID: Int64, jpegData: Data)] = []

        for frame in batch {
            do {
                let jpeg = try await extractDownscaledJPEG(for: frame)
                images.append((frameID: frame.frameID, jpegData: jpeg))
            } catch {
                Log.warning(
                    "[SemanticIndexer] Failed to extract frame \(frame.frameID): \(error.localizedDescription)",
                    category: .processing
                )
                try? await database.markSemanticFramesFailed([frame.frameID], permanently: false)
            }
        }

        guard !images.isEmpty else { return .emptyQueue }

        let requestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let requestRowID: Int64
        do {
            requestRowID = try await database.recordSemanticIndexDispatch(
                frameIDs: images.map(\.frameID),
                lane: lane,
                requestedAtMs: requestedAtMs
            )
        } catch {
            Log.error("[SemanticIndexer] Failed to record dispatch: \(error.localizedDescription)", category: .processing)
            return .error(error.localizedDescription)
        }

        do {
            let (parsed, unparsedFrameIDs) = try await openRouterClient.describeFrames(
                images: images,
                apiKey: apiKey,
                model: model
            )

            let indexedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            for result in parsed {
                try await database.writeSemanticDescription(
                    frameID: result.frameID,
                    description: result.description,
                    indexedAtMs: indexedAtMs
                )
            }
            if !unparsedFrameIDs.isEmpty {
                try await database.markSemanticFramesRetryPending(unparsedFrameIDs)
            }

            let outcomeStatus = unparsedFrameIDs.isEmpty ? "success" : "partial"
            try await database.updateSemanticIndexRequestOutcome(
                requestRowID: requestRowID,
                status: outcomeStatus,
                httpStatus: 200,
                errorMessage: nil
            )

            Log.info(
                "[SemanticIndexer] Batch complete: \(parsed.count) described, \(unparsedFrameIDs.count) unparsed (lane=\(lane))",
                category: .processing
            )
            return .processed(count: parsed.count)
        } catch {
            let nsError = error as NSError
            try? await database.markSemanticFramesFailed(images.map(\.frameID), permanently: false)
            try? await database.updateSemanticIndexRequestOutcome(
                requestRowID: requestRowID,
                status: "failed",
                httpStatus: nsError.code,
                errorMessage: nsError.localizedDescription
            )

            if nsError.code == 429 {
                Log.warning("[SemanticIndexer] Rate limited: \(nsError.localizedDescription)", category: .processing)
                return .rateLimited(retryAfterSeconds: 30)
            }
            Log.error("[SemanticIndexer] Dispatch failed: \(nsError.localizedDescription)", category: .processing)
            return .error(nsError.localizedDescription)
        }
    }

    // MARK: - Frame extraction

    private func extractDownscaledJPEG(for frame: SemanticIndexQueries.PendingFrame) async throws -> Data {
        guard let frameWithInfo = try await database.getFrameWithVideoInfoByID(id: FrameID(value: frame.frameID)) else {
            throw ProcessingError.invalidVideoPath(path: "frame \(frame.frameID) not found")
        }
        guard let videoSegment = try await database.getVideoSegment(id: frameWithInfo.frame.videoID) else {
            throw ProcessingError.invalidVideoPath(path: "video \(frameWithInfo.frame.videoID.value) not found")
        }
        let actualSegmentID = try Self.parseActualSegmentID(from: videoSegment.relativePath)
        let fullResJPEG = try await storage.readFrame(
            segmentID: actualSegmentID,
            frameIndex: frameWithInfo.frame.frameIndexInSegment
        )
        return try Self.downscale(fullResJPEG, maxLongEdge: 1280, quality: 0.6)
    }

    private static func parseActualSegmentID(from relativePath: String) throws -> VideoSegmentID {
        let pathComponents = relativePath.split(separator: "/")
        guard let lastComponent = pathComponents.last,
              let actualSegmentID = Int64(lastComponent) else {
            throw ProcessingError.invalidVideoPath(path: relativePath)
        }
        return VideoSegmentID(value: actualSegmentID)
    }

    private static func downscale(_ jpegData: Data, maxLongEdge: CGFloat, quality: CGFloat) throws -> Data {
        guard let image = NSImage(data: jpegData) else {
            throw ProcessingError.invalidVideoPath(path: "undecodable JPEG")
        }
        let size = image.size
        let longEdge = max(size.width, size.height)
        let scale = longEdge > maxLongEdge ? maxLongEdge / longEdge : 1.0
        let targetSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw ProcessingError.invalidVideoPath(path: "failed to re-encode downscaled JPEG")
        }
        return jpeg
    }

    // MARK: - Settings

    private static func readIndexingModel() -> String {
        let defaults = UserDefaults(suiteName: OpenRouterCredentialsManager.settingsSuiteName)
        return defaults?.string(forKey: OpenRouterCredentialsManager.indexingModelDefaultsKey)
            ?? "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free"
    }
}
