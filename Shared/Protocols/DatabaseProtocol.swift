import Foundation
import CoreGraphics

// MARK: - Database Protocol

/// Core database operations for frame and text storage
/// Owner: DATABASE agent
///
/// Thread Safety: Implementations must be actors to ensure serialized database access
public protocol DatabaseProtocol: Actor {

    // MARK: - Lifecycle

    /// Initialize the database, run migrations if needed
    func initialize() async throws

    /// Close the database connection gracefully
    func close() async throws

    // MARK: - Frame Operations

    /// Insert a new frame reference and return the auto-generated ID
    func insertFrame(_ frame: FrameReference) async throws -> Int64

    /// Get a frame by ID
    func getFrame(id: FrameID) async throws -> FrameReference?

    /// Get frames in a time range
    func getFrames(from startDate: Date, to endDate: Date, limit: Int) async throws -> [FrameReference]

    /// Get frames before a timestamp (for infinite scroll - loading older frames)
    /// Returns frames in descending order (newest of the older batch first)
    func getFramesBefore(timestamp: Date, limit: Int) async throws -> [FrameReference]

    /// Get frames after a timestamp (for infinite scroll - loading newer frames)
    /// Returns frames in ascending order (oldest of the newer batch first)
    func getFramesAfter(timestamp: Date, limit: Int) async throws -> [FrameReference]

    /// Get frames for a specific app
    func getFrames(appBundleID: String, limit: Int, offset: Int) async throws -> [FrameReference]

    /// Delete frames older than a date
    func deleteFrames(olderThan date: Date) async throws -> Int

    /// Delete a single frame by ID
    func deleteFrame(id: FrameID) async throws

    /// Get total frame count
    func getFrameCount() async throws -> Int

    /// Check if a frame exists at the given timestamp (to the second)
    func frameExistsAtTimestamp(_ timestamp: Date) async throws -> Bool

    /// Get frame ID at the given timestamp (to the second), returns nil if not found
    func getFrameIDAtTimestamp(_ timestamp: Date) async throws -> Int64?

    /// Update frame's videoId and videoFrameIndex after video encoding
    func updateFrameVideoLink(frameID: FrameID, videoID: VideoSegmentID, frameIndex: Int) async throws

    /// Persist optional per-frame metadata JSON payload.
    func updateFrameMetadata(frameID: FrameID, metadataJSON: String?) async throws

    /// Read per-frame metadata JSON payload.
    func getFrameMetadata(frameID: FrameID) async throws -> String?

    /// Get processing status for multiple frames in a single query
    /// Returns dictionary of frameID -> processingStatus
    /// 0=pending, 1=processing, 2=completed, 3=failed, 4=not yet readable,
    /// 5=rewrite pending, 6=rewrite processing, 7=rewrite completed, 8=rewrite failed
    func getFrameProcessingStatuses(frameIDs: [Int64]) async throws -> [Int64: Int]

    /// Mark frame as readable from video file (processingStatus 4 -> 0)
    /// Called when frame is confirmed to be written to video file
    func markFrameReadable(frameID: Int64) async throws

    /// Update frame's processing status
    /// - Parameters:
    ///   - frameID: The frame ID to update
    ///   - status: The new processing status
    ///     0=pending, 1=processing, 2=completed, 3=failed, 4=not yet readable,
    ///     5=rewrite pending, 6=rewrite processing, 7=rewrite completed, 8=rewrite failed
    func updateFrameProcessingStatus(frameID: Int64, status: Int) async throws

    /// Get a frame joined with its owning video segment's metadata
    func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo?

    // MARK: - Video Segment Operations (Video Files)

    /// Insert a new video segment (150-frame video chunk) and return the auto-generated ID
    func insertVideoSegment(_ segment: VideoSegment) async throws -> Int64

    /// Get video segment by ID
    func getVideoSegment(id: VideoSegmentID) async throws -> VideoSegment?

    /// Find a video segment by the final path component of its relative path.
    func findVideoSegment(relativePathStem: String) async throws -> VideoSegment?

    /// Get video segment containing a specific timestamp
    func getVideoSegment(containingTimestamp date: Date) async throws -> VideoSegment?

    /// Get all video segments in a time range
    func getVideoSegments(from startDate: Date, to endDate: Date) async throws -> [VideoSegment]

    /// Delete a video segment and its associated frames
    func deleteVideoSegment(id: VideoSegmentID) async throws

    /// Get total storage used by all video segments
    func getTotalStorageBytes() async throws -> Int64

    // MARK: - Unfinalised Video Operations (Multi-Resolution Support)

    /// Get an unfinalised video matching the given resolution
    /// Returns nil if no unfinalised video exists for this resolution
    /// Used to resume writing to an existing video when a frame with matching resolution comes in
    func getUnfinalisedVideoByResolution(width: Int, height: Int) async throws -> UnfinalisedVideo?

    /// Get all unfinalised videos (for recovery on app startup)
    func getAllUnfinalisedVideos() async throws -> [UnfinalisedVideo]

    /// Mark a video as finalized (complete, no more frames will be added)
    /// Also updates uploadedAt timestamp and fileSize
    func markVideoFinalized(id: Int64, frameCount: Int, fileSize: Int64) async throws

    /// Finalize all orphaned videos (processingState=1) that have no active WAL session
    /// Called during app startup after WAL recovery to clean up videos from dev restarts or crashes
    /// Returns the number of videos finalized
    func finalizeOrphanedVideos(activeVideoIDs: Set<Int64>) async throws -> Int

    /// Update video segment with current frame count
    func updateVideoSegment(id: Int64, width: Int, height: Int, fileSize: Int64, frameCount: Int) async throws

    // MARK: - Text/Document Operations

    /// Insert extracted text for indexing
    func insertDocument(_ document: IndexedDocument) async throws -> Int64

    /// Update an existing document
    func updateDocument(id: Int64, content: String) async throws

    /// Delete a document
    func deleteDocument(id: Int64) async throws

    /// Get document by frame ID
    func getDocument(frameID: FrameID) async throws -> IndexedDocument?

    // MARK: - Segment Operations (App Focus Sessions - Rewind Compatible)

    /// Insert a new segment (app focus session)
    func insertSegment(
        bundleID: String,
        startDate: Date,
        endDate: Date,
        windowName: String?,
        browserUrl: String?,
        type: Int
    ) async throws -> Int64

    /// Update a segment's end date
    func updateSegmentEndDate(id: Int64, endDate: Date) async throws

    /// Get segment by ID
    func getSegment(id: Int64) async throws -> Segment?

    /// Get all segments in a time range
    func getSegments(from startDate: Date, to endDate: Date) async throws -> [Segment]

    /// Get the most recent segment
    func getMostRecentSegment() async throws -> Segment?

    /// Get segments for a specific app
    func getSegments(bundleID: String, limit: Int) async throws -> [Segment]

    /// Get segments for a specific app within a time range with pagination
    func getSegments(
        bundleID: String,
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        offset: Int
    ) async throws -> [Segment]

    /// Delete a segment
    func deleteSegment(id: Int64) async throws

    // MARK: - OCR Node Operations (Rewind-compatible)

    /// Insert OCR nodes for a frame with text already in searchRanking_content
    /// Nodes must have textOffset/textLength that reference the FTS content
    func insertNodes(
        frameID: FrameID,
        nodes: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)],
        frameWidth: Int,
        frameHeight: Int
    ) async throws

    /// Get all OCR nodes for a frame (without text extraction)
    /// Returns nodes with denormalized pixel coordinates
    func getNodes(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [OCRNode]

    /// Get OCR nodes with their text extracted from searchRanking_content
    /// Returns array of (node, text) tuples
    func getNodesWithText(frameID: FrameID, frameWidth: Int, frameHeight: Int) async throws -> [(node: OCRNode, text: String)]

    /// Delete all OCR nodes for a frame
    func deleteNodes(frameID: FrameID) async throws

    // MARK: - FTS Content Operations (Rewind-compatible)

    /// Index a frame's OCR text into searchRanking_content and doc_segment
    /// This is the Rewind-compatible pattern:
    /// 1. INSERT INTO searchRanking_content (c0, c1, c2) → get docid
    /// 2. INSERT INTO doc_segment (docid, segmentId, frameId)
    ///
    /// - Parameters:
    ///   - mainText: Main OCR text (c0) - concatenated text from all nodes
    ///   - chromeText: UI chrome text (c1) - status bar, menu bar text (optional)
    ///   - windowTitle: Window title (c2) - from app metadata
    ///   - segmentId: Segment ID for the app focus session
    ///   - frameId: Frame ID for the screenshot
    /// - Returns: The docid for reference by nodes
    func indexFrameText(
        mainText: String,
        chromeText: String?,
        windowTitle: String?,
        segmentId: Int64,
        frameId: Int64
    ) async throws -> Int64

    /// Get the docid for a frame (for node text extraction)
    func getDocidForFrame(frameId: Int64) async throws -> Int64?

    /// Get FTS content by docid
    func getFTSContent(docid: Int64) async throws -> (mainText: String, chromeText: String?, windowTitle: String?)?

    /// Delete FTS content for a frame
    func deleteFTSContent(frameId: Int64) async throws

    /// Get a frame's OCR text content (main text, chrome text, window title) by frame ID
    func getOCRTextForFrame(frameID: Int64) async throws -> (mainText: String, chromeText: String?, title: String?)?

    // MARK: - Statistics

    /// Get database statistics
    func getStatistics() async throws -> DatabaseStatistics

    // MARK: - Cognitive Memory System Operations (Episodes, Entities, Vectors)

    /// Insert a new cognitive episode and return its auto-generated ID
    func insertCognitiveEpisode(_ episode: CognitiveEpisode) async throws -> Int64

    /// Update an existing cognitive episode's mutable fields
    func updateCognitiveEpisode(
        episodeId: Int64,
        endTime: Date,
        title: String?,
        summary: String?,
        primaryAppBundleID: String?,
        keyframeIDs: [Int64]
    ) async throws

    /// Get a cognitive episode by ID
    func getCognitiveEpisode(id: Int64) async throws -> CognitiveEpisode?

    /// Get the most recently created cognitive episode (for resuming clustering on restart)
    func getLatestCognitiveEpisode() async throws -> CognitiveEpisode?

    /// Get the cognitive episode a given frame belongs to, if any
    func getCognitiveEpisodeForFrame(frameId: Int64) async throws -> CognitiveEpisode?

    /// Get cognitive episodes overlapping a time range
    func getCognitiveEpisodes(from startDate: Date, to endDate: Date, limit: Int) async throws -> [CognitiveEpisode]

    /// Link a frame to a cognitive episode, recording its salience score and keyframe status
    func linkFrameToEpisode(episodeId: Int64, frameId: Int64, salienceScore: Double, isKeyframe: Bool) async throws

    /// Get the keyframe IDs recorded for a cognitive episode
    func getKeyframesForEpisode(episodeId: Int64) async throws -> [Int64]

    /// Insert or update a memory entity (file/URL/ticket/person/etc.) keyed by its normalized value
    func upsertMemoryEntity(
        entityType: String,
        normalizedValue: String,
        displayName: String,
        timestamp: Date
    ) async throws -> Int64

    /// Find a memory entity by its exact normalized value
    func findMemoryEntity(normalizedValue: String) async throws -> MemoryEntity?

    /// Find memory entities, optionally filtered by type and/or normalized-value prefix
    func findMemoryEntities(type: String?, prefix: String?, limit: Int) async throws -> [MemoryEntity]

    /// Record that an entity was mentioned in a given frame
    func recordEntityMention(entityId: Int64, frameId: Int64, confidence: Double) async throws

    /// Get all memory entities mentioned in a given frame
    func getEntitiesForFrame(frameId: Int64) async throws -> [MemoryEntity]

    /// Get frame IDs that mention a given entity
    func getFramesForEntity(entityId: Int64, limit: Int) async throws -> [Int64]

    /// Record a co-occurrence edge between two entities seen together in the same frame
    func recordEntityCoOccurrence(sourceEntityId: Int64, targetEntityId: Int64, timestamp: Date) async throws

    /// Get entities most strongly associated (by co-occurrence weight) with a given entity
    func getAssociatedEntities(sourceEntityId: Int64, limit: Int) async throws -> [(entity: MemoryEntity, weight: Double)]

    /// Record where a frame's dense vector lives in the on-disk vector buffer
    func recordKeyframeVectorMetadata(
        frameId: Int64,
        vectorOffset: Int,
        dimensions: Int,
        modelName: String,
        createdAt: Date
    ) async throws

    /// Get metadata (frame ID, buffer offset, dimensions) for every stored keyframe vector
    func getAllKeyframeVectorMetadata() async throws -> [(frameId: Int64, offset: Int, dimensions: Int)]
}

// MARK: - Default (Unimplemented) Cognitive Memory Operations
//
// These defaults exist purely so pre-existing `DatabaseProtocol` conformers written before the
// Cognitive Memory System (e.g. test doubles that only need frame/segment/FTS behavior) don't
// have to grow ~20 unrelated stub methods just to keep compiling. `DatabaseManager` overrides
// every one of these with a real implementation; a conformer that actually needs CMS behavior
// should do the same rather than rely on these defaults.
extension DatabaseProtocol {
    public func getFrameWithVideoInfoByID(id: FrameID) async throws -> FrameWithVideoInfo? { nil }

    public func getOCRTextForFrame(frameID: Int64) async throws -> (mainText: String, chromeText: String?, title: String?)? { nil }

    public func insertCognitiveEpisode(_ episode: CognitiveEpisode) async throws -> Int64 {
        throw DatabaseError.queryExecutionFailed("insertCognitiveEpisode not implemented by this DatabaseProtocol conformer")
    }

    public func updateCognitiveEpisode(
        episodeId: Int64,
        endTime: Date,
        title: String?,
        summary: String?,
        primaryAppBundleID: String?,
        keyframeIDs: [Int64]
    ) async throws {
        throw DatabaseError.queryExecutionFailed("updateCognitiveEpisode not implemented by this DatabaseProtocol conformer")
    }

    public func getCognitiveEpisode(id: Int64) async throws -> CognitiveEpisode? { nil }

    public func getLatestCognitiveEpisode() async throws -> CognitiveEpisode? { nil }

    public func getCognitiveEpisodeForFrame(frameId: Int64) async throws -> CognitiveEpisode? { nil }

    public func getCognitiveEpisodes(from startDate: Date, to endDate: Date, limit: Int) async throws -> [CognitiveEpisode] { [] }

    public func linkFrameToEpisode(episodeId: Int64, frameId: Int64, salienceScore: Double, isKeyframe: Bool) async throws {
        throw DatabaseError.queryExecutionFailed("linkFrameToEpisode not implemented by this DatabaseProtocol conformer")
    }

    public func getKeyframesForEpisode(episodeId: Int64) async throws -> [Int64] { [] }

    public func upsertMemoryEntity(
        entityType: String,
        normalizedValue: String,
        displayName: String,
        timestamp: Date
    ) async throws -> Int64 {
        throw DatabaseError.queryExecutionFailed("upsertMemoryEntity not implemented by this DatabaseProtocol conformer")
    }

    public func findMemoryEntity(normalizedValue: String) async throws -> MemoryEntity? { nil }

    public func findMemoryEntities(type: String?, prefix: String?, limit: Int) async throws -> [MemoryEntity] { [] }

    public func recordEntityMention(entityId: Int64, frameId: Int64, confidence: Double) async throws {
        throw DatabaseError.queryExecutionFailed("recordEntityMention not implemented by this DatabaseProtocol conformer")
    }

    public func getEntitiesForFrame(frameId: Int64) async throws -> [MemoryEntity] { [] }

    public func getFramesForEntity(entityId: Int64, limit: Int) async throws -> [Int64] { [] }

    public func recordEntityCoOccurrence(sourceEntityId: Int64, targetEntityId: Int64, timestamp: Date) async throws {
        throw DatabaseError.queryExecutionFailed("recordEntityCoOccurrence not implemented by this DatabaseProtocol conformer")
    }

    public func getAssociatedEntities(sourceEntityId: Int64, limit: Int) async throws -> [(entity: MemoryEntity, weight: Double)] { [] }

    public func recordKeyframeVectorMetadata(
        frameId: Int64,
        vectorOffset: Int,
        dimensions: Int,
        modelName: String,
        createdAt: Date
    ) async throws {
        throw DatabaseError.queryExecutionFailed("recordKeyframeVectorMetadata not implemented by this DatabaseProtocol conformer")
    }

    public func getAllKeyframeVectorMetadata() async throws -> [(frameId: Int64, offset: Int, dimensions: Int)] { [] }
}

// MARK: - FTS Protocol

/// Full-text search operations (separate for clarity)
/// Owner: DATABASE agent
public protocol FTSProtocol: Actor {

    /// Search the FTS index with a query string
    func search(query: String, limit: Int, offset: Int) async throws -> [FTSMatch]

    /// Search with filters
    func search(
        query: String,
        filters: SearchFilters,
        limit: Int,
        offset: Int
    ) async throws -> [FTSMatch]

    /// Get match count for a query (for pagination)
    func getMatchCount(query: String, filters: SearchFilters) async throws -> Int

    /// Search the AI-generated visual-description index (separate from OCR text search).
    func searchSemantic(
        query: String,
        filters: SearchFilters,
        limit: Int,
        offset: Int
    ) async throws -> [FTSMatch]

    /// Number of indexed OCR documents matching `query` (FTS only, no joins) — used to find words so common
    /// (e.g. "window" in every macOS menu bar) that they carry no search signal. Nil if unsupported.
    func documentFrequency(query: String) async throws -> Int?

    /// Rebuild the FTS index (maintenance operation)
    func rebuildIndex() async throws

    /// Optimize the FTS index
    func optimizeIndex() async throws
}

extension FTSProtocol {
    public func documentFrequency(query: String) async throws -> Int? { nil }
}

// MARK: - Supporting Types

/// A match from the FTS index
public struct FTSMatch: Sendable {
    public let documentID: Int64
    public let frameID: FrameID
    public let timestamp: Date
    public let snippet: String      // Highlighted snippet from FTS
    public let rank: Double         // FTS relevance rank
    public let appName: String?
    public let windowName: String?
    public let videoID: VideoSegmentID
    public let frameIndex: Int

    public init(
        documentID: Int64,
        frameID: FrameID,
        timestamp: Date,
        snippet: String,
        rank: Double,
        appName: String? = nil,
        windowName: String? = nil,
        videoID: VideoSegmentID,
        frameIndex: Int
    ) {
        self.documentID = documentID
        self.frameID = frameID
        self.timestamp = timestamp
        self.snippet = snippet
        self.rank = rank
        self.appName = appName
        self.windowName = windowName
        self.videoID = videoID
        self.frameIndex = frameIndex
    }
}

/// Database statistics
public struct DatabaseStatistics: Sendable {
    public let frameCount: Int
    public let segmentCount: Int
    public let documentCount: Int
    public let databaseSizeBytes: Int64
    public let oldestFrameDate: Date?
    public let newestFrameDate: Date?

    public init(
        frameCount: Int,
        segmentCount: Int,
        documentCount: Int,
        databaseSizeBytes: Int64,
        oldestFrameDate: Date?,
        newestFrameDate: Date?
    ) {
        self.frameCount = frameCount
        self.segmentCount = segmentCount
        self.documentCount = documentCount
        self.databaseSizeBytes = databaseSizeBytes
        self.oldestFrameDate = oldestFrameDate
        self.newestFrameDate = newestFrameDate
    }
}

// MARK: - OCR Node Model

/// Represents an OCR text bounding box from the Rewind-compatible node table
/// References text stored in searchRanking_content via textOffset/textLength
public struct OCRNode: Sendable, Equatable, Identifiable {
    /// Database row ID
    public let id: Int64?

    /// Reading order index (0, 1, 2, ...)
    /// Determines the sequence for text selection and concatenation
    public let nodeOrder: Int

    /// Character offset into searchRanking_content.c0
    /// Points to where this node's text starts in the full-text string
    public let textOffset: Int

    /// Length of text in characters
    /// How many characters from textOffset belong to this node
    public let textLength: Int

    /// Bounding box in pixel coordinates
    /// Denormalized from the 0.0-1.0 stored values
    public let bounds: CGRect

    /// Which window (0 = primary, nil = single window)
    /// Used for multi-window text separation
    public let windowIndex: Int?

    /// Whether this node's on-screen pixels were redacted/scrambled.
    /// Derived from whether a protected OCR payload exists for the node.
    public let isRedacted: Bool

    public init(
        id: Int64? = nil,
        nodeOrder: Int,
        textOffset: Int,
        textLength: Int,
        bounds: CGRect,
        windowIndex: Int? = nil,
        isRedacted: Bool = false
    ) {
        self.id = id
        self.nodeOrder = nodeOrder
        self.textOffset = textOffset
        self.textLength = textLength
        self.bounds = bounds
        self.windowIndex = windowIndex
        self.isRedacted = isRedacted
    }

    /// X coordinate in pixels
    public var x: Int { Int(bounds.origin.x) }

    /// Y coordinate in pixels
    public var y: Int { Int(bounds.origin.y) }

    /// Width in pixels
    public var width: Int { Int(bounds.width) }

    /// Height in pixels
    public var height: Int { Int(bounds.height) }

    /// Center point of the node
    public var center: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Whether this node contains a given point
    public func contains(_ point: CGPoint) -> Bool {
        bounds.contains(point)
    }

    /// Whether this node intersects with another
    public func intersects(_ other: OCRNode) -> Bool {
        bounds.intersects(other.bounds)
    }
}

/// OCR Node with normalized coordinates (0.0-1.0) and text content
/// Used for text selection UI layer - compatible with both Rewind and Retrace data
public struct OCRNodeWithText: Identifiable, Equatable, Sendable {
    /// Primary key for stored OCR nodes.
    /// Live OCR uses a transient in-memory identifier.
    public let id: Int
    /// Reading order within the frame.
    public let nodeOrder: Int
    /// The frame ID this node belongs to (for debugging frame offset issues)
    public let frameId: Int64
    /// Normalized X coordinate (0.0-1.0)
    public let x: CGFloat
    /// Normalized Y coordinate (0.0-1.0)
    public let y: CGFloat
    /// Normalized width (0.0-1.0)
    public let width: CGFloat
    /// Normalized height (0.0-1.0)
    public let height: CGFloat
    /// The text content of this node
    public let text: String
    /// Stored protected OCR text for redacted nodes, read from node.encryptedText.
    public let encryptedText: String?
    /// Whether this node was redacted in storage.
    public let isRedacted: Bool

    public init(
        id: Int,
        nodeOrder: Int? = nil,
        frameId: Int64,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        text: String,
        encryptedText: String? = nil,
        isRedacted: Bool = false
    ) {
        self.id = id
        self.nodeOrder = nodeOrder ?? id
        self.frameId = frameId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.encryptedText = encryptedText
        self.isRedacted = isRedacted
    }

    public func replacingText(_ text: String) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            nodeOrder: nodeOrder,
            frameId: frameId,
            x: x,
            y: y,
            width: width,
            height: height,
            text: text,
            encryptedText: encryptedText,
            isRedacted: isRedacted
        )
    }
}
