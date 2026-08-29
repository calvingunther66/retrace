import Foundation

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
