import Foundation

// MARK: - AI Visual Semantic Indexing Progress

/// Live status of the AI Visual Semantic Indexer.
public enum SemanticIndexStatus: String, Sendable, Equatable {
    case running = "Running"
    case idle = "Idle"
    case budgetExhausted = "Daily Cap Reached"
    case rateLimited = "Rate Limited"
    case error = "Error"
    case awaitingKey = "No API Key"
    case disabled = "Off"
    case restarting = "Restarting"
}

/// Snapshot of AI visual semantic-indexing progress, for the System Monitor.
public struct SemanticIndexStatistics: Sendable, Equatable {
    public static let defaultDailyVisualBudget = 600
    public static let defaultDailySearchBudget = 100

    public let indexed: Int
    public let eligibleTotal: Int
    public let backfillRequestsToday: Int
    public let dailyBackfillBudget: Int
    public let searchRequestsToday: Int
    public let dailySearchBudget: Int
    public let isEnabled: Bool
    public let status: SemanticIndexStatus
    public let statusMessage: String?
    public let failedCount: Int
    public let pendingCount: Int
    public let baselineIndexedCount: Int
    public let deepIndexedCount: Int

    public init(
        indexed: Int,
        eligibleTotal: Int,
        backfillRequestsToday: Int,
        dailyBackfillBudget: Int,
        searchRequestsToday: Int = 0,
        dailySearchBudget: Int = 100,
        isEnabled: Bool,
        status: SemanticIndexStatus = .idle,
        statusMessage: String? = nil,
        failedCount: Int = 0,
        pendingCount: Int = 0,
        baselineIndexedCount: Int = 0,
        deepIndexedCount: Int = 0
    ) {
        self.indexed = indexed
        self.eligibleTotal = eligibleTotal
        self.backfillRequestsToday = backfillRequestsToday
        self.dailyBackfillBudget = dailyBackfillBudget
        self.searchRequestsToday = searchRequestsToday
        self.dailySearchBudget = dailySearchBudget
        self.isEnabled = isEnabled
        self.status = status
        self.statusMessage = statusMessage
        self.failedCount = failedCount
        self.pendingCount = pendingCount
        self.baselineIndexedCount = baselineIndexedCount
        self.deepIndexedCount = deepIndexedCount
    }

    public var fractionComplete: Double {
        guard eligibleTotal > 0 else { return 0 }
        return min(1.0, Double(indexed) / Double(eligibleTotal))
    }
}

// MARK: - OpenRouter Search & Q&A Models

/// Represents a cited screen frame in an OpenRouter AI answer.
public struct OpenRouterCitation: Codable, Sendable, Identifiable {
    public var id: String { "\(frameID)_\(timestamp.timeIntervalSince1970)" }
    public let frameID: Int64
    public let timestamp: Date
    public let appName: String
    public let windowTitle: String?
    public let snippet: String

    public init(
        frameID: Int64,
        timestamp: Date,
        appName: String,
        windowTitle: String? = nil,
        snippet: String
    ) {
        self.frameID = frameID
        self.timestamp = timestamp
        self.appName = appName
        self.windowTitle = windowTitle
        self.snippet = snippet
    }
}

/// Represents the synthesized answer from OpenRouter with citations.
public struct OpenRouterSearchResponse: Sendable {
    public let answer: String
    public let citations: [OpenRouterCitation]
    public let modelUsed: String
    public let promptTokens: Int?
    public let completionTokens: Int?

    public init(
        answer: String,
        citations: [OpenRouterCitation],
        modelUsed: String,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.answer = answer
        self.citations = citations
        self.modelUsed = modelUsed
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// A frame candidate passed to OpenRouter prompt synthesizer.
public struct OpenRouterContextFrame: Sendable {
    public let frameID: Int64
    public let timestamp: Date
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?
    public let extractedText: String

    public init(
        frameID: Int64,
        timestamp: Date,
        appName: String,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        extractedText: String
    ) {
        self.frameID = frameID
        self.timestamp = timestamp
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.extractedText = extractedText
    }
}
