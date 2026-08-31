import Foundation

/// Thin HTTP JSON-RPC client for the WebSSH app's built-in MCP server.
///
/// WebSSH exposes an MCP server directly over HTTP at `http://localhost:1985/mcp/`
/// (protocol `2025-06-18`) when the app is running. Retrace is a native app, not a
/// stdio-based MCP client, so it talks to this endpoint directly — no bridge process
/// needed.
///
/// This client is intentionally dumb: it does not decide which tools are safe to call
/// automatically. That policy (read-only tools execute freely, `Terminal_Session_Send_Command`
/// always requires an explicit user confirmation) lives in `OpenRouterClient`'s tool-calling
/// loop and the confirmation UI — never here, so there is exactly one place that decision
/// can be made incorrectly, and it's the one under test/review for that specific concern.
public actor WebSSHMCPClient {
    public struct MCPTool: Sendable {
        public let name: String
        public let description: String
        /// Pre-serialized JSON Schema for the tool's arguments (kept as `Data`, not
        /// `[String: Any]`, so this type can be genuinely `Sendable`).
        public let inputSchemaJSON: Data

        public var inputSchema: [String: Any] {
            (try? JSONSerialization.jsonObject(with: inputSchemaJSON) as? [String: Any]) ?? [:]
        }
    }

    public enum WebSSHError: LocalizedError {
        case notRunning
        case invalidResponse(String)
        case rpcError(code: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .notRunning:
                return "WebSSH isn't running. Open WebSSH and try again."
            case .invalidResponse(let detail):
                return "Unexpected response from WebSSH: \(detail)"
            case .rpcError(let code, let message):
                return "WebSSH error (\(code)): \(message)"
            }
        }
    }

    private let baseURL = URL(string: "http://localhost:1985/mcp/")!
    private let session: URLSession
    private var nextRequestID = 1
    private var didInitialize = false

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Handshake

    private func ensureInitialized() async throws {
        guard !didInitialize else { return }

        _ = try await call(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "Retrace", "version": "1.0"]
        ])

        // MCP requires an "initialized" notification after the handshake response;
        // notifications carry no "id" and expect no reply body.
        try await sendNotification(method: "notifications/initialized", params: [:])

        didInitialize = true
    }

    // MARK: - Public API

    public func listTools() async throws -> [MCPTool] {
        try await ensureInitialized()
        let result = try await call(method: "tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else {
            throw WebSSHError.invalidResponse("missing 'tools' array")
        }
        return tools.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let description = entry["description"] as? String ?? ""
            let inputSchema = entry["inputSchema"] as? [String: Any] ?? [:]
            let inputSchemaJSON = (try? JSONSerialization.data(withJSONObject: inputSchema)) ?? Data("{}".utf8)
            return MCPTool(name: name, description: description, inputSchemaJSON: inputSchemaJSON)
        }
    }

    /// Calls a tool by name. The caller is responsible for gating dangerous tools
    /// (specifically `Terminal_Session_Send_Command`) behind user confirmation — this
    /// method executes unconditionally whatever it's asked to.
    public func callTool(name: String, arguments: [String: Any]) async throws -> String {
        try await ensureInitialized()
        let result = try await call(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])

        // MCP tool results carry a `content` array of typed blocks; concatenate any text blocks.
        if let content = result["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        // Fall back to a raw dump if the server didn't use the standard content-block shape.
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let raw = String(data: data, encoding: .utf8) {
            return raw
        }
        return ""
    }

    public func listSessions() async throws -> String {
        try await callTool(name: "Terminal_Session_List_All", arguments: [:])
    }

    public func getSession(uuid: String) async throws -> String {
        try await callTool(name: "Terminal_Session_Retrieve_One", arguments: ["sessionUUID": uuid])
    }

    /// Sends a command into a live terminal session. Callers MUST have already obtained
    /// explicit user confirmation for this exact command and session before calling this —
    /// see the class doc comment.
    public func sendCommand(sessionUUID: String, command: String, format: String = "plain") async throws -> String {
        try await callTool(name: "Terminal_Session_Send_Command", arguments: [
            "sessionUUID": sessionUUID,
            "command": command,
            "commandFormat": format
        ])
    }

    // MARK: - JSON-RPC transport

    private func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params
        ]

        let data = try await post(body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSSHError.invalidResponse("non-JSON body")
        }
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "unknown error"
            throw WebSSHError.rpcError(code: code, message: message)
        }
        guard let result = json["result"] as? [String: Any] else {
            throw WebSSHError.invalidResponse("missing 'result'")
        }
        return result
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        _ = try? await post(body: body)
    }

    private func post(body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw WebSSHError.invalidResponse("non-2xx HTTP status")
            }
            return data
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost || urlError.code == .timedOut {
            throw WebSSHError.notRunning
        }
    }
}
