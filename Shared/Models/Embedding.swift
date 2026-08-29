import Foundation

// MARK: - Embedding Types

/// Type of text being embedded (affects Nomic model prefix)
public enum EmbeddingTextType: Sendable {
    case document  // For indexing documents (prepends "search_document: ")
    case query     // For search queries (prepends "search_query: ")
}

/// Configuration for embedding model
public struct EmbeddingConfig: Sendable {
    /// Path to the GGUF model file
    public let modelPath: String

    /// Context window size (tokens)
    public let contextSize: Int

    /// Number of GPU layers to offload (-1 = all, 0 = CPU only)
    public let gpuLayers: Int

    /// Batch size for processing
    public let batchSize: Int

    /// Enable Metal acceleration (Apple Silicon)
    public let useMetalAcceleration: Bool

    public init(
        modelPath: String,
        contextSize: Int = 8192,
        gpuLayers: Int = -1,  // Default: offload all to GPU
        batchSize: Int = 512,
        useMetalAcceleration: Bool = true
    ) {
        self.modelPath = modelPath
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.batchSize = batchSize
        self.useMetalAcceleration = useMetalAcceleration
    }

    /// Default configuration for Nomic Embed v1.5
    public static let nomicEmbed = EmbeddingConfig(
        modelPath: AppPaths.modelsPath + "/nomic-embed-text-v1.5.Q4_K_M.gguf",
        contextSize: 8192,
        gpuLayers: -1,
        batchSize: 512,
        useMetalAcceleration: true
    )
}

/// Errors specific to embedding operations
public enum EmbeddingError: Error, Sendable {
    case modelNotFound(path: String)
    case modelLoadFailed(underlying: String)
    case contextLengthExceeded(tokens: Int, maxTokens: Int)
    case embeddingFailed(underlying: String)
    case normalizationFailed
    case invalidVector
    case modelNotLoaded

    public var localizedDescription: String {
        switch self {
        case .modelNotFound(let path):
            return "Embedding model not found at path: \(path)"
        case .modelLoadFailed(let error):
            return "Failed to load embedding model: \(error)"
        case .contextLengthExceeded(let tokens, let maxTokens):
            return "Text exceeds context length: \(tokens) > \(maxTokens) tokens"
        case .embeddingFailed(let error):
            return "Failed to generate embedding: \(error)"
        case .normalizationFailed:
            return "Failed to normalize embedding vector"
        case .invalidVector:
            return "Invalid embedding vector returned"
        case .modelNotLoaded:
            return "Embedding model is not loaded"
        }
    }
}

// MARK: - Hybrid Search Configuration

public struct HybridSearchConfig: Sendable {
    /// Weight for FTS results (0-1)
    public let ftsWeight: Double

    /// Weight for semantic results (0-1)
    public let semanticWeight: Double

    /// RRF k parameter (higher = more conservative fusion)
    public let rrf_k: Int

    public init(
        ftsWeight: Double = 0.6,
        semanticWeight: Double = 0.4,
        rrf_k: Int = 60
    ) {
        self.ftsWeight = ftsWeight
        self.semanticWeight = semanticWeight
        self.rrf_k = rrf_k
    }

    public static let `default` = HybridSearchConfig(
        ftsWeight: 0.6,
        semanticWeight: 0.4,
        rrf_k: 60
    )

    public static let ftsHeavy = HybridSearchConfig(
        ftsWeight: 0.8,
        semanticWeight: 0.2,
        rrf_k: 60
    )

    public static let semanticHeavy = HybridSearchConfig(
        ftsWeight: 0.3,
        semanticWeight: 0.7,
        rrf_k: 60
    )
}

/// A semantic search result with similarity score
public struct SemanticSearchResult: Sendable, Identifiable {
    public let frameID: FrameID
    public let similarity: Float
    public let appName: String?
    public let windowTitle: String?
    public let timestamp: Date?
    public let snippet: String?

    public var id: Int64 { frameID.value }

    public init(
        frameID: FrameID,
        similarity: Float,
        appName: String? = nil,
        windowTitle: String? = nil,
        timestamp: Date? = nil,
        snippet: String? = nil
    ) {
        self.frameID = frameID
        self.similarity = similarity
        self.appName = appName
        self.windowTitle = windowTitle
        self.timestamp = timestamp
        self.snippet = snippet
    }
}
