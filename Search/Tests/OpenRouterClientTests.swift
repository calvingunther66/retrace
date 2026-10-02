import XCTest
@testable import Search

/// Covers `OpenRouterClient.unparseableCompletionError`, which classifies HTTP 200 responses
/// whose body doesn't match the expected chat-completion shape — a case OpenRouter's free-tier
/// pool hits often enough in production (see `semantic_index_requests`) that a wrong
/// classification here silently downgrades a real rate limit into a generic 30s retry.
final class OpenRouterClientTests: XCTestCase {
    func testEmbeddedErrorObjectSurfacesItsOwnCode() throws {
        let body = #"{"error": {"code": 429, "message": "Rate limit exceeded: free-models-per-day"}}"#
        let data = try XCTUnwrap(body.data(using: .utf8))

        let error = OpenRouterClient.unparseableCompletionError(data: data, model: "some/model")

        XCTAssertEqual(error.domain, "OpenRouterClient")
        XCTAssertEqual(error.code, 429)
        XCTAssertTrue(error.localizedDescription.contains("free-models-per-day"))
    }

    func testEmbeddedErrorWithoutCodeDefaultsTo500() throws {
        let body = #"{"error": {"message": "upstream provider failure"}}"#
        let data = try XCTUnwrap(body.data(using: .utf8))

        let error = OpenRouterClient.unparseableCompletionError(data: data, model: nil)

        XCTAssertEqual(error.code, 500)
        XCTAssertTrue(error.localizedDescription.contains("upstream provider failure"))
    }

    func testMissingChoicesWithNoErrorObjectFallsBackToGenericMessage() throws {
        let body = #"{"id": "gen-123", "choices": []}"#
        let data = try XCTUnwrap(body.data(using: .utf8))

        let error = OpenRouterClient.unparseableCompletionError(data: data, model: "some/model")

        XCTAssertEqual(error.domain, "OpenRouterClient")
        XCTAssertEqual(error.code, 500)
        XCTAssertEqual(error.localizedDescription, "Failed to parse OpenRouter completion response")
    }

    func testNonJSONBodyFallsBackToGenericMessageWithoutThrowing() throws {
        let data = try XCTUnwrap("not json at all".data(using: .utf8))

        let error = OpenRouterClient.unparseableCompletionError(data: data, model: nil)

        XCTAssertEqual(error.code, 500)
        XCTAssertEqual(error.localizedDescription, "Failed to parse OpenRouter completion response")
    }
}
