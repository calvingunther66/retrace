import Foundation
import AppKit
import ImageIO
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
    private let entityMesh: EntityMeshManager
    private let cognitiveSessionizer: CognitiveSessionizer
    private let vectorEngine: AcceleratedVectorEngine
    // Deliberately NOT `.allowAll` by default — see `hasReceivedPolicySync` below. The actual
    // policy value here doesn't matter until that flag is true, since `processNextBatch`
    // refuses to dispatch anything before then.
    private var appFilterPolicy: AppFilterPolicy = .allowAll

    // `AppCoordinator.applyPowerSettings()` computes the real exclusion policy from settings
    // and calls `updateAppFilterPolicy`, but that happens only after `ServiceContainer`
    // constructs and starts this actor — there's a real window at app launch where the loop
    // could run a batch against the still-default `.allowAll` policy, uploading screenshots
    // from apps the user excluded from OCR before the exclusion list ever reaches this actor.
    // Refusing to dispatch until the first sync closes that window without needing
    // `ServiceContainer` to duplicate `AppCoordinator`'s settings-parsing logic just to pass an
    // initial value into the constructor.
    private var hasReceivedPolicySync = false

    private var loopTask: Task<Void, Never>?
    private var isRunning = false
    public private(set) var currentStatus: SemanticIndexStatus = .idle
    public private(set) var currentStatusMessage: String? = nil

    /// Live-toggle read from UserDefaults every loop iteration, so flipping this in Settings
    /// takes effect without an app restart (there's no push notification wiring the way
    /// `FrameProcessingQueue.ocrEnabled` gets pushed via `updatePowerConfig`, so this polls).
    private var isEnabled: Bool {
        let defaults = UserDefaults(suiteName: OpenRouterCredentialsManager.settingsSuiteName) ?? .standard
        return defaults.bool(forKey: OpenRouterCredentialsManager.semanticIndexingEnabledDefaultsKey)
    }

    private let batchSize = 5
    /// Single source of truth for the backfill request budget — also read by
    /// `AppCoordinator.getSemanticIndexStatistics()` for the System Monitor readout, so that
    /// display can never drift from what actually governs throttling here.
    public static let dailyBackfillBudget = 600
    private let freshLaneWindow: TimeInterval = 72 * 3600
    private let idlePollInterval: Duration = .seconds(30)
    // OpenRouter's free-tier shared pool caps at 20 requests/minute across ALL free models a
    // key uses (including interactive "Ask AI" calls happening concurrently) — 4s keeps this
    // indexer's own contribution to ~15/min, leaving headroom rather than sitting at the edge.
    private let interBatchDelay: Duration = .seconds(4)

    public init(
        database: DatabaseManager,
        storage: StorageManager,
        openRouterClient: OpenRouterClient = OpenRouterClient(),
        entityMesh: EntityMeshManager? = nil,
        cognitiveSessionizer: CognitiveSessionizer? = nil,
        vectorEngine: AcceleratedVectorEngine? = nil
    ) {
        self.database = database
        self.storage = storage
        self.openRouterClient = openRouterClient
        self.entityMesh = entityMesh ?? EntityMeshManager(database: database)
        self.cognitiveSessionizer = cognitiveSessionizer ?? CognitiveSessionizer(database: database)
        self.vectorEngine = vectorEngine ?? AcceleratedVectorEngine(database: database)
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
                case .emptyQueue, .budgetExhausted, .disabled, .noAPIKey, .awaitingPolicySync:
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
        currentStatus = .idle
        currentStatusMessage = nil
        Log.info("[SemanticIndexer] Stopped", category: .processing)
    }

    /// Returns current status snapshot for System Monitor & UI readout.
    public func getStatusInfo() -> (status: SemanticIndexStatus, message: String?) {
        guard isEnabled else {
            return (.disabled, nil)
        }
        return (currentStatus, currentStatusMessage)
    }

    /// Interrupts any running batch or sleep backoff, resets stalled & retryable frames in SQLite,
    /// cleans up dangling requests, and immediately launches a fresh indexing cycle.
    @discardableResult
    public func forceRestart(resetFailedFrames: Bool = true) async -> (resetFrameCount: Int, cleanedRequestCount: Int) {
        Log.info("[SemanticIndexer] Force restart requested", category: .processing)
        currentStatus = .restarting
        currentStatusMessage = "Restarting indexer and resetting backlog..."

        // 1. Cancel active loop
        loopTask?.cancel()
        loopTask = nil
        isRunning = false

        // 2. Clean up database state
        var resetCount = 0
        var cleanedCount = 0
        if resetFailedFrames {
            resetCount = (try? await database.resetStalledAndFailedSemanticFrames(includePermanentlyFailed: false)) ?? 0
        }
        cleanedCount = (try? await database.cleanDanglingDispatchedSemanticRequests()) ?? 0

        Log.info(
            "[SemanticIndexer] Reset \(resetCount) stalled frames and \(cleanedCount) dangling requests",
            category: .processing
        )

        // 3. Restart loop immediately
        await start()

        return (resetFrameCount: resetCount, cleanedRequestCount: cleanedCount)
    }

    public func updateAppFilterPolicy(_ policy: AppFilterPolicy) {
        appFilterPolicy = policy
        hasReceivedPolicySync = true
    }

    // MARK: - Batch processing

    private enum BatchOutcome {
        case processed(count: Int)
        case emptyQueue
        case budgetExhausted
        case disabled
        case noAPIKey
        case awaitingPolicySync
        case rateLimited(retryAfterSeconds: Int)
        case error(String)
    }

    private let appleFoundationModelService = AppleFoundationModelService.shared

    private func processNextBatch() async -> BatchOutcome {
        guard isEnabled else {
            currentStatus = .disabled
            currentStatusMessage = nil
            Log.debug("[SemanticIndexer] Skipping cycle: disabled in Settings", category: .processing)
            return .disabled
        }
        // Never dispatch before the real app-exclusion policy has arrived from
        // AppCoordinator — see `hasReceivedPolicySync`'s doc comment.
        guard hasReceivedPolicySync else {
            currentStatus = .idle
            currentStatusMessage = "Awaiting policy sync"
            Log.debug("[SemanticIndexer] Skipping cycle: awaiting first app-filter policy sync", category: .processing)
            return .awaitingPolicySync
        }

        let apiKey = OpenRouterCredentialsManager.getAPIKey() ?? ""
        guard !apiKey.isEmpty else {
            currentStatus = .awaitingKey
            currentStatusMessage = "OpenRouter API Key not configured"
            Log.warning("[SemanticIndexer] Skipping cycle: no OpenRouter API key found in Keychain", category: .processing)
            return .noAPIKey
        }

        let model = Self.readIndexingModel()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let freshCutoffMs = nowMs - Int64(freshLaneWindow * 1000)

        // Stage 1: Fast on-device baseline sweep using Apple Foundation Models / NaturalLanguage
        await processBaselineStage(nowMs: nowMs)

        // Stage 2: Deep visual indexing via vision LLM, strictly governed by daily request budget
        do {
            let dailyRemaining = try await remainingDailyBudgetToday(nowMs: nowMs)
            guard dailyRemaining >= 1 else {
                currentStatus = .budgetExhausted
                currentStatusMessage = "Daily request limit (\(Self.dailyBackfillBudget)) reached · Resets at UTC midnight"
                Log.info("[SemanticIndexer] Daily budget exhausted (\(Self.dailyBackfillBudget) requests used today)", category: .processing)
                return .budgetExhausted
            }

            let candidates = try await database.selectPendingSemanticFrames(
                limit: batchSize * 2, // headroom in case some get filtered out below
                freshCutoffMs: freshCutoffMs
            )

            guard !candidates.isEmpty else {
                currentStatus = .idle
                currentStatusMessage = "All eligible frames indexed"
                Log.debug("[SemanticIndexer] Skipping cycle: no pending frames match selection criteria", category: .processing)
                return .emptyQueue
            }

            var lane: String?
            var batch: [SemanticIndexQueries.PendingFrame] = []

            for candidate in candidates {
                guard appFilterPolicy.allows(bundleID: candidate.bundleID) else {
                    try await database.markSemanticFramesSkipped([candidate.frameID])
                    continue
                }

                let candidateLane = candidate.createdAtMs >= freshCutoffMs ? "fresh" : "backfill"
                if let lane, candidateLane != lane {
                    continue // wrong lane for this batch — leave it for a later cycle
                }

                lane = candidateLane
                batch.append(candidate)
                if batch.count >= batchSize { break }
            }

            guard let resolvedLane = lane, !batch.isEmpty else {
                currentStatus = .idle
                currentStatusMessage = "No pending frames match selection"
                return .emptyQueue
            }

            // Sort batch chronologically (oldest to newest) so the vision model sees the
            // true forward temporal progression of the user's workflow.
            let sortedBatch = batch.sorted { $0.createdAtMs < $1.createdAtMs }

            currentStatus = .running
            currentStatusMessage = "Deep indexing \(sortedBatch.count) frames..."

            return await dispatch(batch: sortedBatch, lane: resolvedLane, model: model, apiKey: apiKey)
        } catch {
            currentStatus = .error
            currentStatusMessage = error.localizedDescription
            Log.error("[SemanticIndexer] Batch selection failed: \(error.localizedDescription)", category: .processing)
            return .error(error.localizedDescription)
        }
    }

    /// Stage 1: Fast image-free on-device baseline indexing using Apple Foundation Models & NaturalLanguage.
    /// Operates purely on OCR text and window metadata without network calls or vision token spend.
    private func processBaselineStage(nowMs: Int64) async {
        guard let pendingFrames = try? await database.selectPendingBaselineSemanticFrames(limit: 50),
              !pendingFrames.isEmpty else {
            return
        }

        for frame in pendingFrames {
            guard appFilterPolicy.allows(bundleID: frame.bundleID) else {
                try? await database.markSemanticFramesSkipped([frame.frameID])
                continue
            }

            let ocrData = try? await database.getOCRTextForFrame(frameID: frame.frameID)

            let baselineDesc = await appleFoundationModelService.generateBaselineSemanticDescription(
                appName: frame.bundleID,
                windowTitle: frame.windowName ?? ocrData?.title,
                browserURL: frame.browserUrl ?? ocrData?.chromeText,
                ocrText: ocrData?.mainText ?? ""
            )

            let finalDesc = baselineDesc ?? "App: \(frame.bundleID ?? "System")"
            try? await database.writeBaselineSemanticDescription(
                frameID: frame.frameID,
                description: finalDesc,
                indexedAtMs: nowMs
            )

            // Stage 1 Cognitive Memory System Integration
            // 1. Harvest entities into Knowledge Mesh
            _ = try? await entityMesh.harvestEntities(
                from: ocrData?.mainText ?? "",
                appName: frame.bundleID,
                windowTitle: frame.windowName ?? ocrData?.title,
                browserURL: frame.browserUrl ?? ocrData?.chromeText,
                frameID: frame.frameID,
                episodeID: nil
            )

            // 2. Cluster into cognitive episodes and score keyframe salience
            let pending = PendingCognitiveFrame(
                frameID: frame.frameID,
                timestamp: Date(timeIntervalSince1970: Double(frame.createdAtMs) / 1000.0),
                appName: frame.bundleID ?? "Unknown",
                windowTitle: frame.windowName ?? ocrData?.title,
                browserURL: frame.browserUrl ?? ocrData?.chromeText,
                ocrText: ocrData?.mainText ?? ""
            )
            _ = try? await cognitiveSessionizer.clusterFrames([pending])

            // 3. Generate on-device dense vector embedding
            let embedding = await vectorEngine.embedTextOnDevice(finalDesc)
            try? await vectorEngine.addVector(frameID: FrameID(value: frame.frameID), vector: embedding)
        }
    }

    private func remainingDailyBudgetToday(nowMs: Int64) async throws -> Int {
        let utcCalendar = { () -> Calendar in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal
        }()
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let dayStart = utcCalendar.startOfDay(for: now)
        let dayStartMs = Int64(dayStart.timeIntervalSince1970 * 1000)

        // Visual indexing ONLY counts its own requests (lane != 'search') so direct timeline searches never consume this budget
        let usedToday = try await database.countVisualIndexingSemanticRequestsToday(utcDayStartMs: dayStartMs)
        return max(0, Self.dailyBackfillBudget - usedToday)
    }

    private func dispatch(
        batch: [SemanticIndexQueries.PendingFrame],
        lane: String,
        model: String,
        apiKey: String
    ) async -> BatchOutcome {
        var frameInputs: [OpenRouterClient.SemanticFrameInput] = []
        let baseTimeMs = batch.first?.createdAtMs ?? 0

        for frame in batch {
            do {
                let jpeg = try await extractDownscaledJPEG(for: frame)
                let deltaSeconds = max(0, (frame.createdAtMs - baseTimeMs) / 1000)
                let timeDesc = "+\(deltaSeconds)s"
                frameInputs.append(OpenRouterClient.SemanticFrameInput(
                    frameID: frame.frameID,
                    jpegData: jpeg,
                    appName: frame.bundleID,
                    windowTitle: frame.windowName,
                    browserURL: frame.browserUrl,
                    relativeTimeDescription: timeDesc
                ))
            } catch {
                Log.warning(
                    "[SemanticIndexer] Failed to extract frame \(frame.frameID): \(error.localizedDescription)",
                    category: .processing
                )
                try? await database.markSemanticFramesFailed([frame.frameID], permanently: false)
            }
        }

        guard !frameInputs.isEmpty else { return .emptyQueue }

        let requestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let requestRowID: Int64
        do {
            requestRowID = try await database.recordSemanticIndexDispatch(
                frameIDs: frameInputs.map(\.frameID),
                lane: lane,
                requestedAtMs: requestedAtMs
            )
        } catch {
            currentStatus = .error
            currentStatusMessage = "Failed to record dispatch: \(error.localizedDescription)"
            Log.error("[SemanticIndexer] Failed to record dispatch: \(error.localizedDescription)", category: .processing)
            return .error(error.localizedDescription)
        }

        // Tracks which frames actually committed a description (each `writeSemanticDescription`
        // call commits its own transaction) so a throw partway through the loop below only
        // reconsiders the frames that never got written — see the catch block.
        var writtenFrameIDs: [Int64] = []
        do {
            let (parsed, unparsedFrameIDs) = try await openRouterClient.describeFrames(
                frames: frameInputs,
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
                writtenFrameIDs.append(result.frameID)

                // Update vector embedding with deep visual affordances
                let deepVec = await vectorEngine.embedTextOnDevice(result.description)
                try? await vectorEngine.addVector(frameID: FrameID(value: result.frameID), vector: deepVec)
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

            currentStatus = .running
            currentStatusMessage = "Indexed \(parsed.count) frames (lane=\(lane))"

            Log.info(
                "[SemanticIndexer] Batch complete: \(parsed.count) described, \(unparsedFrameIDs.count) unparsed (lane=\(lane))",
                category: .processing
            )
            try? await database.recordMetricEvent(
                metricType: .semanticIndexBatchOutcome,
                metadata: "{\"outcome\":\"\(outcomeStatus)\",\"lane\":\"\(lane)\",\"count\":\(parsed.count)}"
            )
            return .processed(count: parsed.count)
        } catch {
            // A cancelled task (app quit mid-batch, `stop()` racing an in-flight request) is not
            // a per-frame failure — the frames never got a real chance to succeed or fail against
            // the API. Leave their status untouched so they're simply reselected next launch,
            // rather than spending a retry attempt; three quits that happen to race the same
            // frames would otherwise strand them at `semanticStatus = 8` forever.
            let isCancellation = Task.isCancelled
                || error is CancellationError
                || (error as NSError).code == NSURLErrorCancelled
            if isCancellation {
                Log.debug("[SemanticIndexer] Batch cancelled mid-dispatch — leaving unwritten frames pending", category: .processing)
                try? await database.updateSemanticIndexRequestOutcome(
                    requestRowID: requestRowID,
                    status: "cancelled",
                    httpStatus: 0,
                    errorMessage: "cancelled"
                )
                return .error("cancelled")
            }

            let nsError = error as NSError
            let isTransient = Self.isTransientError(nsError)
            // Only frames that never committed a description need to be reconsidered — anything
            // in `writtenFrameIDs` already durably committed its own transaction (status=2)
            // before this frame threw; reverting it to pending would have the next cycle's
            // `writeDescriptionUnguarded` delete a still-valid description and re-spend a
            // daily-budget slot re-describing something already correctly indexed.
            let unwrittenFrameIDs = frameInputs.map(\.frameID).filter { !writtenFrameIDs.contains($0) }
            if !unwrittenFrameIDs.isEmpty {
                if isTransient {
                    // Rate limits, 5xx, and transport failures are lane/API-wide, not a property
                    // of these specific frames — reset to pending without spending a retry
                    // attempt, so a blip doesn't permanently strand frames that had the bad luck
                    // to be in-flight during it (see markTransientRetry's doc comment).
                    try? await database.markSemanticFramesTransientRetry(unwrittenFrameIDs)
                } else {
                    try? await database.markSemanticFramesFailed(unwrittenFrameIDs, permanently: false)
                }
            }
            try? await database.updateSemanticIndexRequestOutcome(
                requestRowID: requestRowID,
                status: "failed",
                httpStatus: nsError.code,
                errorMessage: nsError.localizedDescription
            )
            try? await database.recordMetricEvent(
                metricType: .semanticIndexBatchOutcome,
                metadata: "{\"outcome\":\"failed\",\"lane\":\"\(lane)\",\"transient\":\(isTransient)}"
            )

            if nsError.code == 429 {
                let desc = nsError.localizedDescription
                let isDailyQuota = desc.contains("free-models-per-day") || desc.contains("per-day") || desc.contains("quota")
                let retrySeconds = isDailyQuota ? 300 : 30
                currentStatus = .rateLimited
                currentStatusMessage = isDailyQuota
                    ? "OpenRouter free model daily limit reached. Switch model in Settings or wait."
                    : "Rate limited by OpenRouter (429). Retrying shortly..."

                Log.warning("[SemanticIndexer] Rate limited (\(isDailyQuota ? "daily quota" : "burst")): \(desc)", category: .processing)
                return .rateLimited(retryAfterSeconds: retrySeconds)
            }

            currentStatus = .error
            currentStatusMessage = nsError.localizedDescription
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

    /// `NSImage.lockFocus()`/`unlockFocus()` manipulate per-thread `NSGraphicsContext` state and
    /// are main-thread-only by AppKit convention — this runs on `SemanticIndexer`'s (non-main)
    /// actor executor, so it deliberately avoids them in favor of `CGImageSource`/
    /// `CGImageDestination`, which are documented thread-safe and never touch
    /// `NSGraphicsContext`. Off-main `lockFocus` use is a known source of sporadic blank/
    /// corrupted output — here that would silently ship a corrupted frame to OpenRouter, get a
    /// plausible-sounding hallucinated description back, and write it into `semanticRanking` as
    /// if it were real, permanently poisoning search for that frame while still burning budget.
    private static func downscale(_ jpegData: Data, maxLongEdge: CGFloat, quality: CGFloat) throws -> Data {
        // Per-image pool: ImageIO creates autoreleased temporaries per
        // thumbnail/encode that would otherwise accumulate on the indexer.
        try autoreleasepool {
            // Never let ImageIO retain decoded surfaces behind our back; the
            // caller holds only the re-encoded JPEG. MaxPixelSize stays exactly
            // the needed long edge (no upscaling below it), so output is unchanged.
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(jpegData as CFData, sourceOptions as CFDictionary) else {
                throw ProcessingError.invalidVideoPath(path: "undecodable JPEG")
            }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge),
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw ProcessingError.invalidVideoPath(path: "failed to downscale JPEG")
            }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
                throw ProcessingError.invalidVideoPath(path: "failed to re-encode downscaled JPEG")
            }
            let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ProcessingError.invalidVideoPath(path: "failed to re-encode downscaled JPEG")
            }
            return output as Data
        }
    }

    // MARK: - Settings

    private static func readIndexingModel() -> String {
        let defaults = UserDefaults(suiteName: OpenRouterCredentialsManager.settingsSuiteName) ?? .standard
        let stored = defaults.string(forKey: OpenRouterCredentialsManager.indexingModelDefaultsKey)
        // Defensively reject the Settings UI's "custom" picker sentinel (and empty strings) —
        // it must never be sent to OpenRouter as a literal model slug. The Settings UI itself
        // is now fixed to never persist the sentinel, but this guard means a stale/corrupted
        // default can't silently burn through the daily budget on requests doomed to 400/404.
        guard let stored, !stored.isEmpty, stored != "custom" else {
            return OpenRouterCredentialsManager.defaultIndexingModel
        }
        return stored
    }

    // MARK: - Error Classification

    /// Rate limits, 5xx, and network-transport failures say nothing about whether the specific
    /// frames in this batch are processable — they're conditions of the API/network at that
    /// moment. Distinguishing them from genuine per-batch failures lets the caller retry without
    /// spending one of the frame's 3 retry attempts on bad luck.
    private static func isTransientError(_ error: NSError) -> Bool {
        if error.domain == "OpenRouterClient" {
            return error.code == 429 || (500...599).contains(error.code)
        }
        if error.domain == NSURLErrorDomain {
            let transientCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorDNSLookupFailed
            ]
            return transientCodes.contains(error.code)
        }
        return false
    }
}
