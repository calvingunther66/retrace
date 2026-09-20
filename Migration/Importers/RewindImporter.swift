import Foundation
import AVFoundation
import CoreImage
import AppKit
import Shared

/// Imports screen recording data from Rewind AI
///
/// Rewind stores data in: `AppPaths.rewindChunksPath` (default: ~/Library/Application Support/com.memoryvault.MemoryVault/chunks) or a custom path
/// Video files are organized as: YYYYMM/DD/*.mp4
///
/// Each MP4 contains frames captured at 0.5 FPS (1 frame every 2 seconds real-time),
/// but encoded at ~30 FPS. So a 2-second video contains ~60 frames representing
/// ~2 minutes of real-world time.
public actor RewindImporter: MigrationProtocol {

    // MARK: - Properties

    public let source: FrameSource = .rewind

    private let database: any DatabaseProtocol
    private let processing: any ProcessingProtocol
    private let stateStore: MigrationStateStore

    private var state: MigrationState
    private var currentProgress: MigrationProgress
    private var isCurrentlyImporting = false
    private var shouldCancel = false
    private var shouldPause = false

    private weak var delegate: MigrationDelegate?

    /// Real-time capture rate of Rewind (1 frame every 2 seconds)
    private let rewindCaptureIntervalSeconds: TimeInterval = 2.0

    /// Assumed duration each Rewind video covers in real-time (5 minutes)
    private let assumedVideoDurationMinutes: TimeInterval = 5.0

    /// Batch size for database inserts (for performance)
    private let batchSize = 50

    /// Delay between batches to avoid hogging CPU
    private let batchDelayMs: UInt64 = 100

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        processing: any ProcessingProtocol,
        stateStore: MigrationStateStore
    ) {
        self.database = database
        self.processing = processing
        self.stateStore = stateStore
        self.state = MigrationState(source: .rewind)
        self.currentProgress = MigrationProgress.initial(source: .rewind)
    }

    // MARK: - MigrationProtocol

    public var isImporting: Bool {
        isCurrentlyImporting
    }

    public var progress: MigrationProgress {
        currentProgress
    }

    public func isDataAvailable() async -> Bool {
        let chunksPath = getRewindChunksPath()
        return FileManager.default.fileExists(atPath: chunksPath.path)
    }

    public func scan() async throws -> MigrationScanResult {
        Log.info("Scanning Rewind data...", category: .app)
        updateProgress(state: .scanning)

        let chunksPath = getRewindChunksPath()
        guard FileManager.default.fileExists(atPath: chunksPath.path) else {
            throw MigrationError.sourceNotFound(path: chunksPath.path)
        }

        // Find all MP4 files
        let videoFiles = try findAllVideoFiles(in: chunksPath)
        guard !videoFiles.isEmpty else {
            throw MigrationError.noVideosFound
        }

        // Calculate statistics
        var totalSize: Int64 = 0
        var estimatedFrames = 0
        var earliestDate: Date?
        var latestDate: Date?

        for file in videoFiles {
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            } catch {
                Log.warning("Skipping unreadable file during scan: \(file.lastPathComponent): \(error.localizedDescription)", category: .app)
                continue
            }
            totalSize += (attrs[.size] as? Int64) ?? 0

            // Get creation date from file
            if let creationDate = attrs[.creationDate] as? Date {
                if earliestDate == nil || creationDate < earliestDate! {
                    earliestDate = creationDate
                }
                if latestDate == nil || creationDate > latestDate! {
                    latestDate = creationDate
                }
            }

            // Estimate frames: get video frame count
            do {
                let frameCount = try await getVideoFrameCount(at: file)
                estimatedFrames += frameCount
            } catch {
                Log.warning("Skipping frame-count estimate for \(file.lastPathComponent): \(error.localizedDescription)", category: .app)
            }
        }

        // Check already imported
        let existingState = try? await stateStore.loadState(for: .rewind)
        let alreadyImported = existingState?.processedVideoPaths.count ?? 0

        let dateRange: ClosedRange<Date>? = {
            guard let early = earliestDate, let late = latestDate else { return nil }
            return early...late
        }()

        let result = MigrationScanResult(
            source: .rewind,
            totalVideoFiles: videoFiles.count,
            totalSizeBytes: totalSize,
            estimatedFrameCount: estimatedFrames,
            dateRange: dateRange,
            alreadyImportedCount: alreadyImported
        )

        Log.info("Scan complete: \(videoFiles.count) videos, ~\(estimatedFrames) frames", category: .app)
        updateProgress(state: .idle)

        return result
    }

    public func startImport(delegate: MigrationDelegate?) async throws {
        guard !isCurrentlyImporting else {
            Log.warning("Import already in progress", category: .app)
            return
        }

        self.delegate = delegate
        isCurrentlyImporting = true
        shouldCancel = false
        shouldPause = false

        // Resume from any persisted state (completed/failed/cancelled runs included) so a
        // re-run doesn't reprocess and duplicate videos already recorded in processedVideoPaths.
        // Only start a fresh MigrationState when there's no persisted state at all.
        if let existingState = try? await stateStore.loadState(for: .rewind) {
            self.state = existingState
            Log.info("Resuming import from checkpoint (previous state: \(existingState.progressState))", category: .app)
        } else {
            self.state = MigrationState(source: .rewind)
        }

        state.progressState = .importing
        state.lastUpdatedAt = Date()
        // Clear any error message carried over from a previous failed run being resumed here -
        // otherwise a subsequent clean run still persists/reports the old failure string.
        state.errorMessage = nil
        if state.startedAt == state.lastUpdatedAt {
            // New import
        }

        do {
            try await performImport()
        } catch {
            state.progressState = .failed
            state.errorMessage = error.localizedDescription
            try? await stateStore.saveState(state)

            updateProgress(state: .failed)
            delegate?.migrationDidFail(error: error)
            isCurrentlyImporting = false
            throw error
        }

        isCurrentlyImporting = false
    }

    public func pauseImport() async {
        shouldPause = true
        Log.info("Pause requested", category: .app)
    }

    public func cancelImport() async {
        shouldCancel = true
        Log.info("Cancel requested", category: .app)
    }

    public func getState() async -> MigrationState {
        state
    }

    // MARK: - Private Implementation

    private func performImport() async throws {
        let chunksPath = getRewindChunksPath()
        let videoFiles = try findAllVideoFiles(in: chunksPath)
            .sorted { $0.path < $1.path } // Consistent ordering

        let totalVideos = videoFiles.count
        var videosProcessed = 0
        var totalFramesImported = state.totalFramesImported
        var totalFramesDeduplicated = state.totalFramesDeduplicated

        // Calculate total bytes for progress
        var totalBytes: Int64 = 0
        var bytesProcessed: Int64 = 0
        for file in videoFiles {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                totalBytes += (attrs[.size] as? Int64) ?? 0
            } catch {
                Log.warning("Skipping size estimate for unreadable file \(file.lastPathComponent): \(error.localizedDescription)", category: .app)
            }
        }

        updateProgress(
            state: .importing,
            totalVideos: totalVideos,
            totalFrames: 0, // Will update as we go
            totalBytes: totalBytes
        )

        let startTime = Date()

        for (index, videoFile) in videoFiles.enumerated() {
            // Check for pause/cancel
            if shouldCancel {
                state.progressState = .cancelled
                try await stateStore.saveState(state)
                updateProgress(state: .cancelled)
                throw MigrationError.cancelled
            }

            if shouldPause {
                state.progressState = .paused
                try await stateStore.saveState(state)
                updateProgress(state: .paused)
                Log.info("Import paused at video \(index + 1)/\(totalVideos)", category: .app)
                return
            }

            // Skip already processed files
            if state.processedVideoPaths.contains(videoFile.path) {
                videosProcessed += 1
                continue
            }

            delegate?.migrationDidStartProcessingVideo(
                at: videoFile.path,
                index: index + 1,
                total: totalVideos
            )

            do {
                let (imported, deduped) = try await processVideoFile(videoFile)
                totalFramesImported += imported
                totalFramesDeduplicated += deduped

                state.totalFramesImported = totalFramesImported
                state.totalFramesDeduplicated = totalFramesDeduplicated
                state.markVideoProcessed(videoFile.path)

                // Save checkpoint
                try await stateStore.saveState(state)

                delegate?.migrationDidFinishProcessingVideo(
                    at: videoFile.path,
                    framesImported: imported
                )

                Log.debug("Processed \(videoFile.lastPathComponent): \(imported) frames", category: .app)

            } catch {
                Log.error("Failed to process \(videoFile.lastPathComponent)", category: .app, error: error)
                delegate?.migrationDidFailProcessingVideo(at: videoFile.path, error: error)
                // Continue with next file instead of failing entire import
            }

            videosProcessed += 1

            // Update progress
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? Int64) ?? 0
            bytesProcessed += fileSize

            let elapsed = Date().timeIntervalSince(startTime)
            let rate = elapsed > 0 ? Double(videosProcessed) / elapsed : 0
            let remaining = rate > 0 ? Double(totalVideos - videosProcessed) / rate : nil

            currentProgress = MigrationProgress(
                state: .importing,
                source: .rewind,
                totalVideos: totalVideos,
                videosProcessed: videosProcessed,
                totalFrames: totalFramesImported + totalFramesDeduplicated,
                framesImported: totalFramesImported,
                framesDeduplicated: totalFramesDeduplicated,
                currentVideoPath: videoFile.path,
                bytesProcessed: bytesProcessed,
                totalBytes: totalBytes,
                startTime: startTime,
                estimatedSecondsRemaining: remaining
            )
            delegate?.migrationDidUpdateProgress(currentProgress)

            // Small delay to avoid hogging CPU
            try await Task.sleep(for: .nanoseconds(Int64(batchDelayMs * 1_000_000)), clock: .continuous)
        }

        // Complete!
        state.progressState = .completed
        try await stateStore.saveState(state)

        let duration = Date().timeIntervalSince(startTime)
        let result = MigrationResult(
            source: .rewind,
            success: true,
            videosProcessed: videosProcessed,
            framesImported: totalFramesImported,
            framesDeduplicated: totalFramesDeduplicated,
            durationSeconds: duration,
            errorMessage: nil,
            dateRange: nil // TODO: Calculate from imported data
        )

        updateProgress(state: .completed)
        delegate?.migrationDidComplete(result: result)

        Log.info("Import complete: \(totalFramesImported) frames in \(Int(duration))s", category: .app)
    }

    /// Process a single video file and import its frames
    private func processVideoFile(_ videoURL: URL) async throws -> (imported: Int, deduplicated: Int) {
        let asset = AVURLAsset(url: videoURL)

        // Get video properties
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MigrationError.videoReadError(path: videoURL.path, underlying: "No video track found")
        }

        let duration = try await asset.load(.duration)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let totalFrames = try computeFrameCount(duration: duration, frameRate: frameRate, path: videoURL.path)

        // Get file creation date for timestamp calculation
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        let creationDate = (fileAttrs[.creationDate] as? Date) ?? Date()
        let fileSizeBytes = (fileAttrs[.size] as? Int64) ?? 0

        // Calculate real-time duration this video represents
        // Each frame in Rewind was captured every 2 seconds real-time
        let realTimeDurationSeconds = Double(totalFrames) * rewindCaptureIntervalSeconds

        // Resume mid-video from the last checkpointed frame instead of always restarting at 0,
        // so a pause/crash partway through a video doesn't duplicate its already-imported frames.
        let resumingThisVideo = state.lastVideoPath == videoURL.path
        let startFrameIndex = resumingThisVideo ? (state.lastFrameIndex ?? -1) + 1 : 0

        guard startFrameIndex < totalFrames else {
            // Already fully processed (or nothing to do) - nothing new to import.
            return (0, 0)
        }

        // Insert a real segment (app session) and video row for this video before building any
        // FrameReference, so frame inserts have a valid FK target instead of the AppSegmentID(0)/
        // VideoSegmentID(0) placeholders that previously made every frame insert fail silently.
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedSize = naturalSize.applying(preferredTransform)
        let videoWidth = max(Int(abs(transformedSize.width.rounded())), 1)
        let videoHeight = max(Int(abs(transformedSize.height.rounded())), 1)
        let videoEndDate = creationDate.addingTimeInterval(realTimeDurationSeconds)

        let segmentDBID = try await database.insertSegment(
            bundleID: "com.rewind.import",
            startDate: creationDate,
            endDate: videoEndDate,
            windowName: "Imported from Rewind",
            browserUrl: nil,
            type: 0
        )
        let appSegmentID = AppSegmentID(value: segmentDBID)

        // NOTE: relativePath is documented/consumed elsewhere as relative to the native
        // AppPaths.storageRoot (readers do "\(storageRoot)/\(relativePath)"), but this video
        // physically lives under the separate Rewind chunks directory, outside that root. We
        // store the real absolute path here rather than a placeholder so the row is at least
        // traceable back to its source file; correct playback/thumbnail path resolution for
        // Rewind-imported video rows is a pre-existing gap in this importer (see the module's
        // own "needs refactoring" history) and out of scope for this FK-correctness fix.
        let placeholderVideoSegment = VideoSegment(
            id: VideoSegmentID(value: 0),
            startTime: creationDate,
            endTime: videoEndDate,
            frameCount: totalFrames,
            fileSizeBytes: fileSizeBytes,
            relativePath: videoURL.path,
            width: videoWidth,
            height: videoHeight,
            source: .rewind
        )
        let videoDBID = try await database.insertVideoSegment(placeholderVideoSegment)
        let videoSegmentID = VideoSegmentID(value: videoDBID)
        // insertVideoSegment always creates the row as unfinalised (processingState = 1, the
        // "still being written" state for live capture). Finalize it immediately since this
        // import already knows the full frame count up front, so it isn't picked up as an
        // orphaned/crashed recording by finalizeOrphanedVideos on next app startup.
        try await database.markVideoFinalized(id: videoDBID, frameCount: totalFrames, fileSize: fileSizeBytes)

        // Create image generator
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var imported = 0
        var deduplicated = 0
        var previousImageHash: String?

        // Process each frame, resuming from the checkpoint when applicable
        for frameIndex in startFrameIndex..<totalFrames {
            // Calculate the time in the video for this frame
            let videoTime = CMTime(
                seconds: Double(frameIndex) / Double(frameRate),
                preferredTimescale: 600
            )

            // Calculate the real-world timestamp for this frame
            // Distribute frames evenly across the assumed real-time duration
            let realTimeOffset = (Double(frameIndex) / Double(max(1, totalFrames - 1))) * realTimeDurationSeconds
            let frameTimestamp = creationDate.addingTimeInterval(realTimeOffset)

            do {
                // Extract frame
                let cgImage = try generator.copyCGImage(at: videoTime, actualTime: nil)

                // Simple deduplication: compare image hash
                let imageHash = computeImageHash(cgImage)
                if imageHash == previousImageHash {
                    deduplicated += 1
                    continue
                }
                previousImageHash = imageHash

                // Convert to data for processing
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                guard let tiffData = nsImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else {
                    continue
                }

                // Create CapturedFrame for processing
                let capturedFrame = CapturedFrame(
                    timestamp: frameTimestamp,
                    imageData: pngData,
                    width: cgImage.width,
                    height: cgImage.height,
                    bytesPerRow: cgImage.bytesPerRow
                )

                // Run OCR
                let extractedText = try await processing.extractText(from: capturedFrame)

                // Insert frame into database (Note: frameID will be auto-generated by database)
                // segmentID/videoID reference the real rows inserted above for this video.
                let frameRef = FrameReference(
                    id: FrameID(value: 0), // Placeholder, will be replaced by database AUTOINCREMENT
                    timestamp: frameTimestamp,
                    segmentID: appSegmentID,  // Link to app session (segment table)
                    videoID: videoSegmentID,  // Link to video chunk (video table)
                    frameIndexInSegment: frameIndex,
                    metadata: extractedText.metadata,
                    source: .rewind
                )
                let generatedFrameID = try await database.insertFrame(frameRef)

                // Index text for search (inserts into searchRanking_content)
                let document = IndexedDocument(
                    id: 0,  // Will be auto-assigned by DB
                    frameID: FrameID(value: generatedFrameID),
                    timestamp: frameTimestamp,
                    content: extractedText.fullText,
                    appName: extractedText.metadata.appName,
                    windowName: extractedText.metadata.windowName,
                    browserURL: extractedText.metadata.browserURL
                )
                let docid = try await database.insertDocument(document)

                // Insert OCR nodes (Rewind-compatible) with textOffset/textLength
                if docid > 0 && !extractedText.regions.isEmpty {
                    var currentOffset = 0
                    var nodeData: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)] = []

                    for region in extractedText.regions {
                        let textLength = region.text.count

                        nodeData.append((
                            textOffset: currentOffset,
                            textLength: textLength,
                            bounds: region.bounds,
                            windowIndex: nil
                        ))

                        currentOffset += textLength + 1  // +1 for space separator
                    }

                    try await database.insertNodes(
                        frameID: FrameID(value: generatedFrameID),
                        nodes: nodeData,
                        frameWidth: cgImage.width,
                        frameHeight: cgImage.height
                    )
                }

                // insertFrame() always inserts processingStatus = 4 ("not yet readable from video
                // file") - a state that's normally cleared by markFrameReadable() once live capture
                // confirms the frame is flushed to its video file. This importer already ran OCR
                // synchronously above, so mark it completed (2) directly; otherwise it would sit at
                // 4 forever and never surface as OCR'd, or get swept into the OCR queue expecting a
                // video file this importer doesn't write in Retrace's own managed storage.
                try await database.updateFrameProcessingStatus(frameID: generatedFrameID, status: 2)

                imported += 1

                // Update checkpoint periodically
                if imported % batchSize == 0 {
                    state.updateCheckpoint(videoPath: videoURL.path, frameIndex: frameIndex)
                    try await stateStore.saveState(state)

                    // Yield to other tasks
                    try await Task.sleep(for: .nanoseconds(Int64(batchDelayMs * 1_000_000)), clock: .continuous)
                }

            } catch {
                Log.warning("Failed to extract frame \(frameIndex): \(error.localizedDescription)", category: .app)
                // Continue with next frame
            }
        }

        return (imported, deduplicated)
    }

    /// Compute a simple perceptual hash of an image for deduplication
    private func computeImageHash(_ image: CGImage) -> String {
        // Simplified hash: resize to 8x8, convert to grayscale, compute average
        // This is a basic perceptual hash - could be improved
        let size = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()

        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return UUID().uuidString // Fallback to unique hash
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else {
            return UUID().uuidString
        }

        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size)
        var hash = ""
        let avg = (0..<(size * size)).reduce(0) { $0 + Int(pixels[$1]) } / (size * size)

        for i in 0..<(size * size) {
            hash += pixels[i] >= avg ? "1" : "0"
        }

        return hash
    }

    /// Get the path to Rewind's chunks directory
    private func getRewindChunksPath() -> URL {
        return URL(fileURLWithPath: NSString(string: AppPaths.rewindChunksPath).expandingTildeInPath)
    }

    /// Find all MP4 files recursively in a directory
    private func findAllVideoFiles(in directory: URL) throws -> [URL] {
        var files: [URL] = []

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "mp4" {
                files.append(url)
            }
        }

        return files
    }

    /// Get the frame count from a video file
    private func getVideoFrameCount(at url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return 0
        }

        let frameRate = try await track.load(.nominalFrameRate)
        return try computeFrameCount(duration: duration, frameRate: frameRate, path: url.path)
    }

    /// Compute a video's frame count from its duration and frame rate, guarding against
    /// non-finite results. A truncated chunk file, one still being written, or one with an
    /// indefinite/invalid `moov` atom can make `CMTimeGetSeconds` return `NaN`, and
    /// `Int(Double.nan)` is a fatal runtime trap rather than a throwable error - so this must
    /// be checked before the `Int` conversion, not after.
    private func computeFrameCount(duration: CMTime, frameRate: Float, path: String) throws -> Int {
        let seconds = CMTimeGetSeconds(duration)
        let rawFrameCount = seconds * Double(frameRate)
        // Guard the final result, not just `seconds`: `frameRate` itself can also be non-finite
        // on a malformed asset, and even a finite-but-huge product would still trap on `Int(...)`.
        guard rawFrameCount.isFinite, rawFrameCount >= 0, rawFrameCount < Double(Int.max) else {
            throw MigrationError.videoReadError(path: path, underlying: "Invalid or indefinite video duration")
        }
        return Int(rawFrameCount)
    }

    /// Update progress state and notify delegate
    private func updateProgress(
        state: MigrationProgressState,
        totalVideos: Int? = nil,
        totalFrames: Int? = nil,
        totalBytes: Int64? = nil
    ) {
        currentProgress = MigrationProgress(
            state: state,
            source: .rewind,
            totalVideos: totalVideos ?? currentProgress.totalVideos,
            videosProcessed: currentProgress.videosProcessed,
            totalFrames: totalFrames ?? currentProgress.totalFrames,
            framesImported: currentProgress.framesImported,
            framesDeduplicated: currentProgress.framesDeduplicated,
            currentVideoPath: currentProgress.currentVideoPath,
            bytesProcessed: currentProgress.bytesProcessed,
            totalBytes: totalBytes ?? currentProgress.totalBytes,
            startTime: currentProgress.startTime,
            estimatedSecondsRemaining: currentProgress.estimatedSecondsRemaining
        )
        delegate?.migrationDidUpdateProgress(currentProgress)
    }
}
