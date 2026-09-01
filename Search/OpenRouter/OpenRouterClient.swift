import Foundation
import Shared

/// HTTP Client for OpenRouter API (OpenAI-compatible chat completions endpoint).
public final class OpenRouterClient: Sendable {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Error Parsing

    /// Extracts the human-readable error message from an OpenRouter JSON error response.
    /// OpenRouter returns: `{"error": {"code": 429, "message": "...", "metadata": {...}}}`
    private static func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    /// Builds a user-friendly error description for a given HTTP status code and optional parsed message.
    private static func friendlyError(statusCode: Int, parsedMessage: String?, model: String? = nil) -> String {
        let modelHint = model.map { " (\($0))" } ?? ""
        switch statusCode {
        case 401:
            return "Invalid API key. Please check your OpenRouter key and try again."
        case 402:
            return "Insufficient credits on your OpenRouter account. Add credits at openrouter.ai/credits."
        case 403:
            return "Access denied. Your API key may not have permission for this model\(modelHint)."
        case 429:
            let detail = parsedMessage ?? "The selected model\(modelHint) is temporarily overloaded."
            return "Rate limited — \(detail) Try again in a moment or switch to a different model."
        case 502, 503:
            return "The upstream model provider\(modelHint) is temporarily unavailable. Try again shortly or select a different model."
        case 408:
            return "Request timed out. The model\(modelHint) may be overloaded — try again or switch models."
        default:
            if let parsed = parsedMessage, !parsed.isEmpty {
                return "OpenRouter error (\(statusCode)): \(parsed)"
            }
            return "OpenRouter returned an unexpected error (HTTP \(statusCode))."
        }
    }

    // MARK: - Validation

    /// Tests whether the provided API key and model work correctly.
    public func testConnection(apiKey: String, model: String) async throws -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw NSError(domain: "OpenRouterClient", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "API key is empty. Please enter your OpenRouter API key."
            ])
        }

        // Allow one retry on rate limit (429) with a short backoff
        for attempt in 0..<2 {
            var request = URLRequest(url: baseURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.setValue("https://retrace.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Retrace AI Search", forHTTPHeaderField: "X-Title")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15

            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "user", "content": "ping"]
                ],
                "max_tokens": 5
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            if httpResponse.statusCode == 200 {
                return true
            }

            // On 429, retry once after a short backoff
            if httpResponse.statusCode == 429, attempt == 0 {
                Log.info("[OpenRouter] Test connection rate-limited (429), retrying in 2s...", category: .search)
                try await Task.sleep(for: .seconds(2), clock: .continuous)
                continue
            }

            let parsedMessage = Self.parseErrorMessage(from: data)
            let friendly = Self.friendlyError(statusCode: httpResponse.statusCode, parsedMessage: parsedMessage, model: model)
            throw NSError(domain: "OpenRouterClient", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: friendly
            ])
        }

        return false
    }

    // MARK: - Granular Search & Q&A Synthesis

    /// Generates a synthesized answer with citations across the provided context frames.
    public func answerQuery(
        query: String,
        contextFrames: [OpenRouterContextFrame],
        apiKey: String,
        model: String,
        temperature: Double = 0.2
    ) async throws -> OpenRouterSearchResponse {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw NSError(domain: "OpenRouterClient", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "OpenRouter API Key not configured. Please add your key in Settings."
            ])
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://retrace.app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Retrace AI Search", forHTTPHeaderField: "X-Title")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let systemPrompt = """
        You are Retrace AI, an intelligent personal memory assistant that helps users find and understand what they saw on their screen.
        You will be provided with timestamped OCR extracts and window contexts from the user's recorded screen history.

        Instructions:
        1. Answer the user's query accurately and concisely based strictly on the provided context.
        2. Reference specific evidence using the exact citation format: [Frame #<ID>] (e.g. [Frame #1042]).
        3. If mentioning when something happened, include the human-readable date and time from the context.
        4. If the context does not contain enough information to answer the question, clearly say so.
        5. Format your output nicely using clean Markdown with bold keywords and bullet points where helpful.
        """

        let userPrompt = buildPrompt(query: query, contextFrames: contextFrames)

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": temperature,
            "max_tokens": 1500
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenRouterClient", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Invalid network response from OpenRouter"
            ])
        }

        guard httpResponse.statusCode == 200 else {
            let parsedMessage = Self.parseErrorMessage(from: data)
            let friendly = Self.friendlyError(statusCode: httpResponse.statusCode, parsedMessage: parsedMessage, model: model)
            throw NSError(domain: "OpenRouterClient", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: friendly
            ])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "OpenRouterClient", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to parse OpenRouter completion response"
            ])
        }

        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int
        let completionTokens = usage?["completion_tokens"] as? Int

        // Extract citations from the response
        let citations = Self.extractCitations(from: content, contextFrames: contextFrames)

        return OpenRouterSearchResponse(
            answer: content,
            citations: citations,
            modelUsed: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }

    // MARK: - Streaming Q&A

    /// Streams the synthesized answer token-by-token.
    public func streamAnswerQuery(
        query: String,
        contextFrames: [OpenRouterContextFrame],
        apiKey: String,
        model: String,
        temperature: Double = 0.2
    ) -> AsyncThrowingStream<String, Error> {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return AsyncThrowingStream { continuation in
            guard !trimmedKey.isEmpty else {
                continuation.finish(throwing: NSError(domain: "OpenRouterClient", code: 401, userInfo: [
                    NSLocalizedDescriptionKey: "OpenRouter API Key not configured. Please add your key in Settings."
                ]))
                return
            }

            var request = URLRequest(url: self.baseURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.setValue("https://retrace.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Retrace AI Search", forHTTPHeaderField: "X-Title")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60

            let systemPrompt = """
            You are Retrace AI, an intelligent personal memory assistant that helps users find and understand what they saw on their screen.
            You will be provided with timestamped OCR extracts and window contexts from the user's recorded screen history.

            Instructions:
            1. Answer the user's query accurately and concisely based strictly on the provided context.
            2. Reference specific evidence using the exact citation format: [Frame #<ID>] (e.g. [Frame #1042]).
            3. If mentioning when something happened, include the human-readable date and time from the context.
            4. If the context does not contain enough information to answer the question, clearly say so.
            5. Format your output nicely using clean Markdown with bold keywords and bullet points where helpful.
            """

            let userPrompt = self.buildPrompt(query: query, contextFrames: contextFrames)

            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": temperature,
                "max_tokens": 1500,
                "stream": true
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            Task {
                do {
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: NSError(domain: "OpenRouterClient", code: 500, userInfo: [
                            NSLocalizedDescriptionKey: "Invalid network response"
                        ]))
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        // Collect error body from stream for proper error parsing
                        var errorBodyChunks: [UInt8] = []
                        for try await byte in bytes {
                            errorBodyChunks.append(byte)
                            if errorBodyChunks.count > 4096 { break } // Cap error body read
                        }
                        let errorData = Data(errorBodyChunks)
                        let parsedMessage = OpenRouterClient.parseErrorMessage(from: errorData)
                        let friendly = OpenRouterClient.friendlyError(
                            statusCode: httpResponse.statusCode,
                            parsedMessage: parsedMessage,
                            model: model
                        )
                        continuation.finish(throwing: NSError(domain: "OpenRouterClient", code: httpResponse.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: friendly
                        ]))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let dataStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        if dataStr == "[DONE]" { break }

                        guard let data = dataStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let chunk = delta["content"] as? String else {
                            continue
                        }

                        continuation.yield(chunk)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt(query: String, contextFrames: [OpenRouterContextFrame]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        var prompt = "User Query: \"\(query)\"\n\nContextual Screen Records:\n\n"

        if contextFrames.isEmpty {
            prompt += "(No matching screen records found for this query in local database)\n"
            return prompt
        }

        for (idx, frame) in contextFrames.enumerated() {
            let timestampStr = formatter.string(from: frame.timestamp)
            prompt += "--- Record \(idx + 1) [Frame #\(frame.frameID)] ---\n"
            prompt += "Time: \(timestampStr)\n"
            prompt += "Application: \(frame.appName)\n"
            if let windowTitle = frame.windowTitle, !windowTitle.isEmpty {
                prompt += "Window: \(windowTitle)\n"
            }
            if let browserURL = frame.browserURL, !browserURL.isEmpty {
                prompt += "URL: \(browserURL)\n"
            }
            // Truncate individual frame text if excessively long
            let textPreview = frame.extractedText.count > 1500
                ? String(frame.extractedText.prefix(1500)) + "..."
                : frame.extractedText
            prompt += "Screen Text:\n\(textPreview)\n\n"
        }

        prompt += "Please synthesize a direct, clear answer to the user query citing the relevant [Frame #<ID>] tags."
        return prompt
    }

    public nonisolated static func extractCitations(from text: String, contextFrames: [OpenRouterContextFrame]) -> [OpenRouterCitation] {
        var citations: [OpenRouterCitation] = []
        let frameMap = Dictionary(uniqueKeysWithValues: contextFrames.map { ($0.frameID, $0) })

        // Match patterns like [Frame #1234] or Frame #1234
        let pattern = #"(?:\[Frame\s*#?|Frame\s*#)(\d+)\]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return citations
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var seenIDs = Set<Int64>()

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let idString = nsText.substring(with: match.range(at: 1))
            if let frameID = Int64(idString), let frame = frameMap[frameID], !seenIDs.contains(frameID) {
                seenIDs.insert(frameID)
                let snippet = String(frame.extractedText.prefix(150))
                citations.append(OpenRouterCitation(
                    frameID: frameID,
                    timestamp: frame.timestamp,
                    appName: frame.appName,
                    windowTitle: frame.windowTitle,
                    snippet: snippet
                ))
            }
        }

        return citations
    }

    // MARK: - Visual Semantic Indexing (batched vision requests)

    public struct SemanticDescriptionResult: Sendable {
        public let frameID: Int64
        public let description: String
    }

    /// Sends up to N screenshots in a single chat-completion request to a vision-capable model
    /// and returns a description per image, matched back to `frameID` by position (not by
    /// trusting the model to echo an arbitrary numeric ID correctly).
    ///
    /// Never throws for a partially-parseable response — images the model dropped or
    /// mis-formatted come back in `unparsedFrameIDs` instead, so the caller can commit the
    /// descriptions that did parse (the request's cost against the daily budget is sunk either way).
    public func describeFrames(
        images: [(frameID: Int64, jpegData: Data)],
        apiKey: String,
        model: String,
        temperature: Double = 0.2
    ) async throws -> (parsed: [SemanticDescriptionResult], unparsedFrameIDs: [Int64]) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw NSError(domain: "OpenRouterClient", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "OpenRouter API Key not configured. Please add your key in Settings."
            ])
        }
        guard !images.isEmpty else {
            return (parsed: [], unparsedFrameIDs: [])
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://retrace.app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Retrace AI Search", forHTTPHeaderField: "X-Title")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        let promptText = """
            You will be shown \(images.count) screenshots, labeled Image 1 through Image \(images.count), in order.
            For each image, write ONE dense sentence (max 40 words) describing what is visually shown: \
            the application/website, on-screen content, notable icons, diagrams, images, or layout. \
            Do not describe browser chrome or window frames. If an image is mostly plain text, focus on \
            visual structure (tables, charts, buttons, thumbnails) rather than restating prose.

            Respond with ONLY a JSON array, no other text, no markdown fences:
            [{"image": 1, "description": "..."}, {"image": 2, "description": "..."}, ...]
            """

        var contentParts: [[String: Any]] = [["type": "text", "text": promptText]]
        for image in images {
            let base64 = image.jpegData.base64EncodedString()
            contentParts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
            ])
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": contentParts]
            ],
            "temperature": temperature,
            "max_tokens": 900,
            // This model family defaults reasoning ON and counts reasoning tokens against
            // max_tokens. Verified empirically: with reasoning on, a 5-image batch of real
            // screenshots can burn the entire token budget on the reasoning trace before ever
            // emitting content, producing `finish_reason: "length"` and empty/truncated JSON —
            // silently stalling every frame. Disabling it (in `supported_parameters` for this
            // model) makes the response deterministic and keeps completion cost tiny.
            "reasoning": ["enabled": false]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenRouterClient", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Invalid network response from OpenRouter"
            ])
        }

        guard httpResponse.statusCode == 200 else {
            let parsedMessage = Self.parseErrorMessage(from: data)
            let friendly = Self.friendlyError(statusCode: httpResponse.statusCode, parsedMessage: parsedMessage, model: model)
            throw NSError(domain: "OpenRouterClient", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: friendly
            ])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw NSError(domain: "OpenRouterClient", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to parse OpenRouter completion response"
            ])
        }

        let rawContent = (message["content"] as? String) ?? (message["reasoning"] as? String) ?? ""
        let descriptionsByPosition = Self.parseDescriptions(from: rawContent)

        var parsed: [SemanticDescriptionResult] = []
        var unparsedFrameIDs: [Int64] = []
        for (index, image) in images.enumerated() {
            let position = index + 1
            if let description = descriptionsByPosition[position], !description.isEmpty {
                parsed.append(SemanticDescriptionResult(frameID: image.frameID, description: description))
            } else {
                unparsedFrameIDs.append(image.frameID)
            }
        }

        return (parsed: parsed, unparsedFrameIDs: unparsedFrameIDs)
    }

    /// Strips reasoning-model `<think>` traces, then finds the LAST balanced-bracket JSON
    /// array in the text (reasoning models "think out loud" before their final answer, so
    /// the last well-formed array is more reliable than the first).
    private static func parseDescriptions(from rawContent: String) -> [Int: String] {
        var text = rawContent
        if let thinkRange = text.range(of: "<think>"),
           let thinkEndRange = text.range(of: "</think>", range: thinkRange.upperBound..<text.endIndex) {
            text.removeSubrange(thinkRange.lowerBound..<thinkEndRange.upperBound)
        }

        guard let arrayText = lastBalancedJSONArray(in: text),
              let data = arrayText.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var result: [Int: String] = [:]
        for entry in entries {
            guard let image = entry["image"] as? Int,
                  let description = entry["description"] as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            result[image] = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Scans for the last top-level `[...]` array with balanced brackets, ignoring brackets
    /// inside string literals so a description containing `[` or `]` doesn't break scanning.
    private static func lastBalancedJSONArray(in text: String) -> String? {
        let chars = Array(text)
        var lastMatch: String?
        var index = 0

        while index < chars.count {
            if chars[index] == "[" {
                var depth = 0
                var inString = false
                var escaped = false
                var end: Int?

                var scan = index
                while scan < chars.count {
                    let c = chars[scan]
                    if inString {
                        if escaped {
                            escaped = false
                        } else if c == "\\" {
                            escaped = true
                        } else if c == "\"" {
                            inString = false
                        }
                    } else {
                        if c == "\"" { inString = true }
                        else if c == "[" { depth += 1 }
                        else if c == "]" {
                            depth -= 1
                            if depth == 0 {
                                end = scan
                                break
                            }
                        }
                    }
                    scan += 1
                }

                if let end {
                    lastMatch = String(chars[index...end])
                    index = end + 1
                    continue
                }
            }
            index += 1
        }

        return lastMatch
    }
}
