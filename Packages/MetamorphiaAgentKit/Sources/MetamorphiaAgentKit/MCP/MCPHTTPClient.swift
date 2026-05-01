import Foundation

/// MCP client using HTTP-based transports (SSE or Streamable HTTP).
/// Communicates via JSON-RPC 2.0 over HTTP POST; SSE is used for
/// server-to-client streaming when a provider speaks that dialect.
public actor MCPHTTPClient: MCPTransport {

    public enum TransportMode: Sendable {
        case sse            // Legacy: GET for SSE stream, POST for client→server messages
        case streamableHTTP // Current spec: POST returns JSON or SSE stream
    }

    public let serverName: String
    private let url: URL
    private let mode: TransportMode
    private let customHeaders: [String: String]

    // JSON-RPC state
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, any Error>] = [:]
    private var nextId = 1

    // Connection state
    private var connected = false
    private var sessionId: String?
    private var sseTask: Task<Void, Never>?
    private var ssePostEndpoint: URL?

    // URLSession with long timeouts for SSE streams
    private let sseSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300      // 5 min per-request
        config.timeoutIntervalForResource = 86400   // 24h for long-lived SSE
        return URLSession(configuration: config)
    }()

    // Reconnection
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private static let maxReconnectAttempts = 5
    private static let maxBackoffSeconds: Double = 30

    public init(name: String, url: URL, mode: TransportMode, headers: [String: String] = [:]) {
        self.serverName = name
        self.url = url
        self.mode = mode
        self.customHeaders = headers
    }

    // MARK: - MCPTransport

    public var isAlive: Bool { connected }

    public func connect() async throws {
        switch mode {
        case .sse:
            try await connectSSE()
        case .streamableHTTP:
            try await connectStreamableHTTP()
        }
    }

    public func disconnect() {
        connected = false
        sseTask?.cancel()
        sseTask = nil
        sessionId = nil
        ssePostEndpoint = nil
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
        for (_, cont) in pendingRequests {
            cont.resume(throwing: MCPError.disconnected)
        }
        pendingRequests.removeAll()
        print("[MCP-HTTP] \(serverName) disconnected")
    }

    public func ensureConnected() async throws {
        if isAlive { return }

        if connected { disconnect() }

        if reconnectAttempts >= Self.maxReconnectAttempts {
            reconnectAttempts = 0
        }

        print("[MCP-HTTP] Liveness check failed for \(serverName), reconnecting...")
        do {
            try await connect()
        } catch {
            throw MCPError.disconnected
        }
    }

    public func listTools() async throws -> [MCPToolInfo] {
        let result = try await sendRequest("tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let desc = tool["description"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            return MCPToolInfo(name: name, description: desc, inputSchema: schema)
        }
    }

    public func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await sendRequest("tools/call", params: [
            "name": name,
            "arguments": arguments
        ], timeout: 30)

        if let content = result["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                if block["type"] as? String == "text" { return block["text"] as? String }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }

        if let data = try? JSONSerialization.data(withJSONObject: result, options: []),
           let str = String(data: data, encoding: .utf8) { return str }
        return "Tool executed successfully (no text output)"
    }

    // MARK: - Streamable HTTP Transport

    private func connectStreamableHTTP() async throws {
        let initResult = try await sendStreamableHTTPRequest("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Metamorphia", "version": "1.0"]
        ])

        connected = true
        reconnectAttempts = 0
        isReconnecting = false

        sendStreamableHTTPNotification("notifications/initialized", params: [:])

        let name = (initResult["serverInfo"] as? [String: Any])?["name"] as? String ?? "unknown"
        print("[MCP-HTTP] Connected to \(name) via streamable-http")
    }

    private func sendStreamableHTTPRequest(
        _ method: String,
        params: [String: Any],
        timeout: TimeInterval = 15
    ) async throws -> [String: Any] {
        guard method == "initialize" || connected else { throw MCPError.disconnected }

        let id = nextId; nextId += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        applyHeaders(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (bytes, response) = try await sseSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }

        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionId = sid
        }

        if http.statusCode == 404 && sessionId != nil {
            sessionId = nil
            connected = false
            throw MCPError.sessionExpired
        }

        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw MCPError.httpError(statusCode: http.statusCode, body: body)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        if contentType.contains("text/event-stream") {
            return try await parseSSEForResponse(bytes: bytes, expectedId: id)
        } else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPError.invalidResponse
            }
            return extractResult(from: json)
        }
    }

    private func sendStreamableHTTPNotification(_ method: String, params: [String: Any]) {
        Task { [self] in
            let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10
            await applyHeadersAsync(&request)
            request.httpBody = body
            _ = try? await sseSession.data(for: request)
        }
    }

    // MARK: - SSE Transport (Legacy)

    private func connectSSE() async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyHeaders(&request)

        let (bytes, response) = try await sseSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MCPError.connectionFailed("SSE GET returned HTTP \(code)")
        }

        var endpointURL: URL?
        var eventType = ""
        var dataBuffer = ""

        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                dataBuffer += String(line.dropFirst(6))
            } else if line.isEmpty && !dataBuffer.isEmpty {
                if eventType == "endpoint" {
                    endpointURL = URL(string: dataBuffer, relativeTo: url)?.absoluteURL
                        ?? URL(string: dataBuffer)
                    break
                }
                processSSEData(dataBuffer)
                eventType = ""
                dataBuffer = ""
            }
        }

        guard let postURL = endpointURL else {
            throw MCPError.connectionFailed("SSE server did not provide endpoint URL")
        }
        ssePostEndpoint = postURL

        sseTask = Task { [weak self] in
            do {
                var evt = ""
                var buf = ""
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { break }
                    if line.hasPrefix("event: ") {
                        evt = String(line.dropFirst(7))
                    } else if line.hasPrefix("data: ") {
                        buf += String(line.dropFirst(6))
                    } else if line.isEmpty && !buf.isEmpty {
                        if evt.isEmpty || evt == "message" {
                            await self?.processSSEData(buf)
                        } else if evt == "error" {
                            print("[MCP-HTTP] SSE error event: \(buf)")
                        }
                        evt = ""
                        buf = ""
                    }
                }
            } catch {
                print("[MCP-HTTP] SSE stream error for \(self?.serverName ?? "?"): \(error)")
            }
            await self?.handleSSEDisconnect()
        }

        let initResult = try await sendSSERequest("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Metamorphia", "version": "1.0"]
        ])

        connected = true
        reconnectAttempts = 0
        isReconnecting = false

        sendSSENotification("notifications/initialized", params: [:])

        let name = (initResult["serverInfo"] as? [String: Any])?["name"] as? String ?? "unknown"
        print("[MCP-HTTP] Connected to \(name) via SSE")
    }

    private func sendSSERequest(
        _ method: String,
        params: [String: Any],
        timeout: TimeInterval = 15
    ) async throws -> [String: Any] {
        guard let postURL = ssePostEndpoint else { throw MCPError.disconnected }

        let id = nextId; nextId += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params
        ]

        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        applyHeaders(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (data, response) = try await sseSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPError.httpError(statusCode: http.statusCode, body: body)
        }

        if !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["jsonrpc"] != nil {
            return extractResult(from: json)
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[id] = continuation
            let timeoutTask = Task.detached { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.handleTimeout(forId: id)
            }
            self.timeoutTasks[id] = timeoutTask
        }
    }

    private func sendSSENotification(_ method: String, params: [String: Any]) {
        guard let postURL = ssePostEndpoint else { return }
        Task { [self] in
            let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
            var request = URLRequest(url: postURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10
            await applyHeadersAsync(&request)
            request.httpBody = body
            _ = try? await sseSession.data(for: request)
        }
    }

    private func handleSSEDisconnect() {
        guard connected else { return }
        print("[MCP-HTTP] SSE stream ended for \(serverName)")
        disconnect()
        Task { await attemptReconnect() }
    }

    // MARK: - Unified Request Dispatch

    private func sendRequest(
        _ method: String,
        params: [String: Any],
        timeout: TimeInterval = 15
    ) async throws -> [String: Any] {
        switch mode {
        case .streamableHTTP:
            return try await sendStreamableHTTPRequest(method, params: params, timeout: timeout)
        case .sse:
            return try await sendSSERequest(method, params: params, timeout: timeout)
        }
    }

    // MARK: - SSE Parsing

    private func parseSSEForResponse(
        bytes: URLSession.AsyncBytes,
        expectedId: Int
    ) async throws -> [String: Any] {
        var dataBuffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                dataBuffer += String(line.dropFirst(6))
            } else if line.isEmpty && !dataBuffer.isEmpty {
                if let data = dataBuffer.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let id = (json["id"] as? Int) ?? (json["id"] as? NSNumber)?.intValue
                    if id == expectedId {
                        return extractResult(from: json)
                    }
                    processJSONRPCMessage(json)
                }
                dataBuffer = ""
            }
        }
        throw MCPError.timeout
    }

    private func processSSEData(_ data: String) {
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }
        processJSONRPCMessage(json)
    }

    private func processJSONRPCMessage(_ message: [String: Any]) {
        guard let id = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue,
              let cont = pendingRequests.removeValue(forKey: id) else { return }

        timeoutTasks.removeValue(forKey: id)?.cancel()

        if let error = message["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown MCP error"
            let code = error["code"] as? Int ?? -1
            cont.resume(throwing: MCPError.serverError(code: code, message: msg))
        } else {
            let result = message["result"] as? [String: Any] ?? [:]
            cont.resume(returning: result)
        }
    }

    // MARK: - Helpers

    private func handleTimeout(forId id: Int) {
        if let cont = pendingRequests.removeValue(forKey: id) {
            timeoutTasks.removeValue(forKey: id)
            cont.resume(throwing: MCPError.timeout)
        }
    }

    private func applyHeaders(_ request: inout URLRequest) {
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sid = sessionId {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
    }

    /// Async variant that reads actor-isolated `sessionId` safely from a Task.
    private func applyHeadersAsync(_ request: inout URLRequest) async {
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sid = sessionId {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
    }

    private func extractResult(from json: [String: Any]) -> [String: Any] {
        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown"
            let code = error["code"] as? Int ?? -1
            return ["_error": true, "_code": code, "_message": msg]
        }
        return json["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Reconnection

    private func attemptReconnect() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }

        while reconnectAttempts < Self.maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = min(pow(2.0, Double(reconnectAttempts - 1)), Self.maxBackoffSeconds)
            print("[MCP-HTTP] Reconnecting \(serverName) in \(delay)s (attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts))")

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await connect()
                print("[MCP-HTTP] Reconnected \(serverName) successfully")
                return
            } catch {
                print("[MCP-HTTP] Reconnect \(serverName) attempt \(reconnectAttempts) failed: \(error.localizedDescription)")
            }
        }

        print("[MCP-HTTP] Giving up reconnecting \(serverName) after \(Self.maxReconnectAttempts) attempts")
    }
}
