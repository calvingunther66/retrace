import XCTest
import Foundation
import CoreGraphics
import Shared
import Database
@testable import Processing

private actor DeferredBoundNoopSearch: SearchProtocol {
    func initialize(config: SearchConfig) async throws {}

    func search(query: SearchQuery) async throws -> SearchResults {
        SearchResults(query: query, results: [], searchTimeMs: 0)
    }

    func search(text: String, limit: Int) async throws -> SearchResults {
        SearchResults(
            query: SearchQuery(text: text, limit: limit),
            results: [], searchTimeMs: 0
        )
    }

    func getSuggestions(prefix: String, limit: Int) async throws -> [String] {
        []
    }

    func index(text: ExtractedText, segmentId: Int64, frameId: Int64) async throws -> Int64 {
        0
    }

    func removeFromIndex(frameID: FrameID) async throws {}

    func rebuildIndex() async throws {}

    func getStatistics() async -> SearchStatistics {
        SearchStatistics(totalDocuments: 0, totalSearches: 0, averageSearchTimeMs: 0)
    }
}

private actor DeferredBoundNoopProcessing: ProcessingProtocol {
    private var config = ProcessingConfig.default

    func initialize(config: ProcessingConfig) async throws {
        self.config = config
    }

    func extractText(from frame: CapturedFrame) async throws -> ExtractedText {
        ExtractedText(frameID: FrameID(value: 0), timestamp: Date(), regions: [])
    }

    func extractTextViaOCR(from frame: CapturedFrame) async throws -> [TextRegion] {
        []
    }

    func extractTextViaAccessibility() async throws -> [TextRegion] {
        []
    }

    func updateConfig(_ config: ProcessingConfig) async {
        self.config = config
    }

    func getConfig() async -> ProcessingConfig {
        config
    }
}

private actor DeferredBoundStubSegmentWriter: SegmentWriter {
    let segmentID = VideoSegmentID(value: 0)
    let frameCount = 0
    let startTime = Date(timeIntervalSince1970: 0)
    let relativePath = "segments/test"
    let frameWidth = 0
    let frameHeight = 0
    let currentFileSize: Int64 = 0
    let hasFragmentWritten = false
    let framesFlushedToDisk = 0

    func appendFrame(_ frame: CapturedFrame) async throws {}

    func finalize() async throws -> VideoSegment {
        VideoSegment(
            id: segmentID,
            startTime: startTime,
            endTime: startTime,
            frameCount: frameCount,
            fileSizeBytes: currentFileSize,
            relativePath: relativePath,
            width: frameWidth,
            height: frameHeight
        )
    }

    func cancel() async throws {}
}

/// Storage whose WAL never yields a frame: the post-restart poison case where a
/// non-finalized video's WAL segment was quarantined or lost, so the source can
/// never become readable no matter how often the worker re-enqueues.
private actor NeverReadableWALStorage: StorageProtocol {
    func initialize(config: StorageConfig) async throws {}

    func createSegmentWriter() async throws -> SegmentWriter {
        DeferredBoundStubSegmentWriter()
    }

    func readFrame(segmentID: VideoSegmentID, frameIndex: Int) async throws -> Data {
        Data()
    }

    func getSegmentPath(id: VideoSegmentID) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(id.stringValue)
    }

    func deleteSegment(id: VideoSegmentID) async throws {}

    func segmentExists(id: VideoSegmentID) async throws -> Bool {
        false
    }

    func countFramesInSegment(id: VideoSegmentID) async throws -> Int {
        0
    }

    func readFrameFromWAL(
        segmentID: VideoSegmentID,
        frameID: Int64,
        fallbackFrameIndex: Int
    ) async throws -> CapturedFrame? {
        nil
    }

    func applySegmentRewrite(
        segmentID: VideoSegmentID,
        plan: SegmentRewritePlan,
        secret: String?
    ) async throws {}

    func recoverInterruptedSegmentRewrites() async throws -> [SegmentRewriteRecoveryAction] {
        []
    }

    func finishInterruptedSegmentRewriteRecovery(segmentID: VideoSegmentID) async throws {}

    func isVideoValid(id: VideoSegmentID) async throws -> Bool {
        false
    }

    func getTotalStorageUsed(includeRewind: Bool) async throws -> Int64 {
        0
    }

    func getStorageUsedForDateRange(from startDate: Date, to endDate: Date) async throws -> Int64 {
        0
    }

    func getAvailableDiskSpace() async throws -> Int64 {
        0
    }

    func cleanupOldSegments(olderThan date: Date) async throws -> [VideoSegmentID] {
        []
    }

    func getStorageDirectory() -> URL {
        FileManager.default.temporaryDirectory
    }
}

final class DeferredRequeueBoundTests: XCTestCase {
    private var database: DatabaseManager!
    private var queue: FrameProcessingQueue!

    override func setUp() async throws {
        let uniqueDBPath = "file:memdb_processing_deferred_\(UUID().uuidString)?mode=memory&cache=private"
        database = DatabaseManager(databasePath: uniqueDBPath)
        try await database.initialize()

        queue = FrameProcessingQueue(
            database: database,
            storage: NeverReadableWALStorage(),
            processing: DeferredBoundNoopProcessing(),
            search: DeferredBoundNoopSearch(),
            config: ProcessingQueueConfig(
                workerCount: 1,
                maxRetryAttempts: 3,
                maxQueueSize: 1000,
                retryableRewriteRetryDelayNs: 50_000_000,
                maxDeferredAttempts: 3
            )
        )
    }

    override func tearDown() async throws {
        await queue.stopWorkers()
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        try await database.close()
        database = nil
        queue = nil
    }

    func testFrameWithNeverReadableSourceFailsInsteadOfSpinningForever() async throws {
        // Non-finalized video (processingState=1, still being written): the worker must
        // read the frame from WAL, which never yields it.
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let insertedVideoID = try await database.insertVideoSegment(
            VideoSegment(
                id: VideoSegmentID(value: 0),
                startTime: timestamp,
                endTime: timestamp.addingTimeInterval(120),
                frameCount: 1,
                fileSizeBytes: 1_024,
                relativePath: "segments/1700000000000",
                width: 1_000,
                height: 1_000,
                source: .native
            )
        )
        let segmentID = try await database.insertSegment(
            bundleID: "com.apple.Safari",
            startDate: timestamp,
            endDate: timestamp.addingTimeInterval(120),
            windowName: "Example",
            browserUrl: "https://example.com/articles/current",
            type: 0
        )
        let insertedFrameID = try await database.insertFrame(
            FrameReference(
                id: FrameID(value: 0),
                timestamp: timestamp,
                segmentID: AppSegmentID(value: segmentID),
                videoID: VideoSegmentID(value: insertedVideoID),
                frameIndexInSegment: 0,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    browserURL: "https://example.com/articles/current",
                    displayID: 1
                ),
                source: .native
            )
        )

        // Fresh inserts land as "not yet readable" (status 4); mark pending so the
        // worker will pick the frame up.
        try await database.updateFrameProcessingStatus(
            frameID: insertedFrameID,
            status: FrameProcessingStatus.pending.rawValue
        )

        try await queue.enqueue(frameID: insertedFrameID)
        await queue.startWorkers()

        // The worker must give up (status failed = 3) instead of re-enqueueing forever.
        var finalStatus: Int?
        for _ in 0..<150 {
            let statuses = try await database.getFrameProcessingStatuses(frameIDs: [insertedFrameID])
            if statuses[insertedFrameID] == FrameProcessingStatus.failed.rawValue {
                finalStatus = statuses[insertedFrameID]
                break
            }
            try await Task.sleep(for: .milliseconds(200), clock: .continuous)
        }
        XCTAssertEqual(finalStatus, FrameProcessingStatus.failed.rawValue)

        // The poison frame must be gone from the queue: nothing left to spin on.
        let remainingDepth = try await queue.getQueueDepth()
        XCTAssertEqual(remainingDepth, 0)
    }
}
