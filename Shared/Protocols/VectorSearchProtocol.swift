import Foundation

// MARK: - Embedding Protocol

public struct EmbeddingModelInfo: Sendable, Equatable {
    public let name: String
    public let version: String
    public let dimensions: Int
    public let maxTokens: Int

    public init(name: String, version: String, dimensions: Int, maxTokens: Int) {
        self.name = name
        self.version = version
        self.dimensions = dimensions
        self.maxTokens = maxTokens
    }
}

public protocol EmbeddingProtocol: Actor {
    var isModelLoaded: Bool { get }
    var modelInfo: EmbeddingModelInfo { get }
    func loadModel() async throws
    func unloadModel() async
    func embed(text: String) async throws -> [Float]
    func embed(text: String, type: EmbeddingTextType) async throws -> [Float]
}

// MARK: - Vector Store Protocol

public protocol VectorStoreProtocol: Actor {
    var vectorCount: Int { get }
    func initialize() async throws
    func addVector(frameID: FrameID, vector: [Float]) async throws
    func removeVector(frameID: FrameID) async throws
    func findNearest(to queryVector: [Float], limit: Int) async throws -> [(frameID: FrameID, similarity: Float)]
    func clear() async throws
}
