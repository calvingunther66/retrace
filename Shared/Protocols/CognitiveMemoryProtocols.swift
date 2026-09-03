import Foundation

// MARK: - Cognitive Storyboard Types

/// A structured storyboard context frame with episode & entity context
public struct CognitiveStoryboardFrame: Codable, Sendable, Identifiable {
    public let frameID: Int64
    public let timestamp: Date
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?
    public let summaryText: String
    public let isKeyframe: Bool
    public let episodeTitle: String?
    public let entities: [String]

    public var id: Int64 { frameID }

    public init(
        frameID: Int64,
        timestamp: Date,
        appName: String,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        summaryText: String,
        isKeyframe: Bool = true,
        episodeTitle: String? = nil,
        entities: [String] = []
    ) {
        self.frameID = frameID
        self.timestamp = timestamp
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.summaryText = summaryText
        self.isKeyframe = isKeyframe
        self.episodeTitle = episodeTitle
        self.entities = entities
    }
}

/// An episodic storyboard context assembled for AI reasoning
public struct CognitiveStoryboardContext: Codable, Sendable {
    public let query: String
    public let episodes: [CognitiveEpisode]
    public let frames: [CognitiveStoryboardFrame]
    public let relatedEntities: [MemoryEntity]
    public let assembledPromptText: String

    public init(
        query: String,
        episodes: [CognitiveEpisode],
        frames: [CognitiveStoryboardFrame],
        relatedEntities: [MemoryEntity],
        assembledPromptText: String
    ) {
        self.query = query
        self.episodes = episodes
        self.frames = frames
        self.relatedEntities = relatedEntities
        self.assembledPromptText = assembledPromptText
    }
}

// MARK: - Cognitive Sessionizer Protocol

/// Frame candidate for cognitive episode clustering
public struct PendingCognitiveFrame: Sendable {
    public let frameID: Int64
    public let timestamp: Date
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?
    public let ocrText: String
    public let perceptualHash: UInt64?

    public init(
        frameID: Int64,
        timestamp: Date,
        appName: String,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        ocrText: String,
        perceptualHash: UInt64? = nil
    ) {
        self.frameID = frameID
        self.timestamp = timestamp
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.ocrText = ocrText
        self.perceptualHash = perceptualHash
    }
}

/// Clusters multi-app activity into cognitive task episodes and identifies keyframes
public protocol CognitiveSessionizerProtocol: Actor {
    /// Ingests a stream of pending frames and updates cognitive episodes
    func clusterFrames(_ candidates: [PendingCognitiveFrame]) async throws -> [CognitiveEpisode]

    /// Retrieves the episode for a specific frame
    func getEpisode(for frameID: FrameID) async throws -> CognitiveEpisode?

    /// Retrieves episodes in a date range
    func getEpisodes(from startDate: Date, to endDate: Date, limit: Int) async throws -> [CognitiveEpisode]
}

// MARK: - Entity Mesh Protocol

/// Extracts entities and navigates the knowledge graph
public protocol EntityMeshProtocol: Actor {
    /// Extracts entities from text and context and updates graph mentions/edges
    func harvestEntities(
        from text: String,
        appName: String?,
        windowTitle: String?,
        browserURL: String?,
        frameID: Int64,
        episodeID: Int64?
    ) async throws -> [MemoryEntity]

    /// Finds entities that strongly co-occur with the given entity
    func findAssociatedEntities(for entityID: Int64, limit: Int) async throws -> [(entity: MemoryEntity, weight: Double)]

    /// Finds frame IDs that mention a given normalized entity value
    func findFramesForEntity(normalizedValue: String, limit: Int) async throws -> [Int64]
}

// MARK: - Accelerated Vector Engine Protocol

/// High-performance SIMD/BLAS vector engine for dense semantic search
public protocol AcceleratedVectorEngineProtocol: Actor {
    var vectorCount: Int { get }
    func initialize() async throws
    func addVector(frameID: FrameID, vector: [Float]) async throws
    func removeVector(frameID: FrameID) async throws
    func searchNearest(queryVector: [Float], limit: Int) async throws -> [(frameID: FrameID, similarity: Float)]
    func clear() async throws
}

// MARK: - Cognitive Reasoner Protocol

/// Orchestrates multi-hop associative retrieval and reasoning for "Ask AI"
public protocol CognitiveReasonerProtocol: Actor {
    /// Plans and retrieves context across episodes, temporal neighbors, and entity graph
    func planAndRetrieveContext(query: String, maxFrames: Int) async throws -> CognitiveStoryboardContext

    /// Streams an intelligent synthesized response using the retrieved storyboard context
    func streamAnswer(
        query: String,
        context: CognitiveStoryboardContext,
        apiKey: String,
        model: String,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error>
}
