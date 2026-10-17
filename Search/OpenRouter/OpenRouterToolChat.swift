import Foundation

/// One tool call requested by the model.
public struct OpenRouterToolCall: @unchecked Sendable {
    public let id: String
    public let name: String
    public let arguments: [String: Any]
    /// The call exactly as the API returned it (echoed back in the assistant message).
    let raw: [String: Any]
}

/// One assistant turn from a tool-enabled chat completion.
public struct OpenRouterToolTurn: @unchecked Sendable {
    public let content: String
    public let toolCalls: [OpenRouterToolCall]
    public let finishReason: String?
    public let promptTokens: Int?
    public let completionTokens: Int?

    /// The assistant message to append to the transcript before sending tool results.
    var transcriptMessage: [String: Any] {
        var m: [String: Any] = ["role": "assistant", "content": content]
        if !toolCalls.isEmpty { m["tool_calls"] = toolCalls.map(\.raw) }
        return m
    }
}

extension OpenRouterClient {
    /// One non-streaming chat completion with function-calling tools (OpenAI-compatible `tools` / `tool_calls`).
    public func chatWithTools(
        messages: [[String: Any]],
        tools: [[String: Any]],
        allowTools: Bool = true,
        apiKey: String,
        model: String,
        maxTokens: Int = 1_500,
        timeout: TimeInterval = 90
    ) async throws -> OpenRouterToolTurn {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "OpenRouterClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API Key not configured."])
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("https://retrace.app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Retrace AI Search", forHTTPHeaderField: "X-Title")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": tools,
            "tool_choice": allowTools ? "auto" : "none",
            "temperature": 0.1,
            "max_tokens": maxTokens
        ]
        if !allowTools { payload["tool_choice"] = "none" }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenRouterClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid network response from OpenRouter"])
        }
        guard http.statusCode == 200 else {
            throw NSError(domain: "OpenRouterClient", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: Self.friendlyError(statusCode: http.statusCode, parsedMessage: Self.parseErrorMessage(from: data), model: model)
            ])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw Self.unparseableCompletionError(data: data, model: model)
        }
        let content = (message["content"] as? String) ?? ""
        var calls: [OpenRouterToolCall] = []
        for raw in (message["tool_calls"] as? [[String: Any]]) ?? [] {
            guard let id = raw["id"] as? String,
                  let fn = raw["function"] as? [String: Any],
                  let name = fn["name"] as? String else { continue }
            let argString = (fn["arguments"] as? String) ?? "{}"
            let args = (try? JSONSerialization.jsonObject(with: Data(argString.utf8))) as? [String: Any] ?? [:]
            calls.append(OpenRouterToolCall(id: id, name: name, arguments: args, raw: raw))
        }
        let usage = json["usage"] as? [String: Any]
        return OpenRouterToolTurn(
            content: content, toolCalls: calls, finishReason: choice["finish_reason"] as? String,
            promptTokens: usage?["prompt_tokens"] as? Int, completionTokens: usage?["completion_tokens"] as? Int
        )
    }
}
