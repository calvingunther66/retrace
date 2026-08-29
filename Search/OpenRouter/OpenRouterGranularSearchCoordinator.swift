import Foundation
import Shared

/// Coordinator that orchestrates FTS/semantic candidate frame retrieval and OpenRouter synthesis.
public actor OpenRouterGranularSearchCoordinator {
    private let client: OpenRouterClient

    public init(client: OpenRouterClient = OpenRouterClient()) {
        self.client = client
    }

    /// Performs granular AI search over the provided context frames.
    public func performGranularSearch(
        query: String,
        candidateFrames: [OpenRouterContextFrame],
        config: OpenRouterConfig? = nil
    ) async throws -> OpenRouterSearchResponse {
        let activeConfig = config ?? OpenRouterConfig.default
        let apiKey = OpenRouterCredentialsManager.getAPIKey() ?? ""

        let limitedFrames = Array(candidateFrames.prefix(activeConfig.maxContextFrames))

        return try await client.answerQuery(
            query: query,
            contextFrames: limitedFrames,
            apiKey: apiKey,
            model: activeConfig.model,
            temperature: activeConfig.temperature
        )
    }

    /// Streams granular AI search tokens.
    public func streamGranularSearch(
        query: String,
        candidateFrames: [OpenRouterContextFrame],
        config: OpenRouterConfig? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let activeConfig = config ?? OpenRouterConfig.default
        let apiKey = OpenRouterCredentialsManager.getAPIKey() ?? ""
        let limitedFrames = Array(candidateFrames.prefix(activeConfig.maxContextFrames))

        return client.streamAnswerQuery(
            query: query,
            contextFrames: limitedFrames,
            apiKey: apiKey,
            model: activeConfig.model,
            temperature: activeConfig.temperature
        )
    }
}
