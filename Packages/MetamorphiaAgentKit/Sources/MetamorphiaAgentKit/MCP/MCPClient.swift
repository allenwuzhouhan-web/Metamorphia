import Foundation

/// Lightweight MCP (Model Context Protocol) client using stdio transport.
///
/// Connects to MCP servers as child processes and communicates via JSON-RPC 2.0,
/// either Content-Length framed (spec-compliant) or raw newline-delimited JSON
/// (for servers like the Go-based github-mcp-server that don't respect framing).
///
/// Auto-detects framing from the first response, with a one-shot lock so the
/// mode doesn't flip mid-flight. Handles process death with exponential-backoff
/// reconnect (max 5 attempts, 30s cap).
public actor MCPClient: MCPTransport {
    public let serverName: String
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutHandle: FileHandle?
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, any Error>] = [:]
    private var nextId = 1
    private var readBuffer = Data()
    private var connected = false
    private var readTask: Task<Void, Never>?
    /// Raw JSON-RPC (newline-delimited) mode instead of Content-Length framed.
    /// Locked once detected so auto-detection can't flip it mid-flight.
    private var rawJsonMode = false
    private var rawJsonModeLocked = false

    // Reconnection state
    private var lastCommand: String?
    private var lastArgs: [String]?
    private var lastEnv: [String: String]?
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private static let maxReconnectAttempts = 5
    private static let maxBackoffSeconds: Double = 30

    public init(name: String) {
        self.serverName = name
    }

    // MARK: - MCPTransport Conformance

    public var isAlive: Bool {
        connected && (process?.isRunning == true)
    }

    /// Protocol-required no-arg connect — uses stored params from last connect.
    public func connect() async throws {
        guard let command = lastCommand, let args = lastArgs else {
            throw MCPError.connectionFailed("No stored connection params for stdio server \(serverName)")
        }
        try await connect(command: command, args: args, env: lastEnv ?? [:])
    }

    // MARK: - Connection

    public func connect(command: String, args: [String], env: [String: String] = [:]) async throws {
        self.lastCommand = command
        self.lastArgs = args
        self.lastEnv = env

        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + args
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        var procEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { procEnv[k] = v }
        // Ensure node / npx can be found
        procEnv["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(procEnv["PATH"] ?? "")"
        proc.environment = procEnv

        try proc.run()
        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.connected = true

        proc.terminationHandler = { [weak self] terminatedProc in
            guard let self = self else { return }
            Task {
                await self.handleProcessTermination(exitCode: terminatedProc.terminationStatus)
            }
        }

        let handle = stdoutPipe.fileHandleForReading
        readTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty {
                    await self?.handleDisconnect()
                    break
                }
                await self?.handleData(data)
                try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms — prevent tight loop on bursts
            }
        }

        // MCP initialize handshake — try Content-Length framing first.
        let initParams: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Metamorphia", "version": "1.0"]
        ]

        let initResult: [String: Any]
        do {
            initResult = try await sendRequest("initialize", params: initParams, timeout: 8)
        } catch let error where !rawJsonMode && (error is MCPError) {
            // Framing timed out — server likely expects raw JSON. Restart in that mode.
            print("[MCP] \(serverName): Content-Length framing timed out, restarting in raw JSON mode")
            disconnect()

            rawJsonMode = true
            rawJsonModeLocked = true
            let proc2 = Process()
            let stdinPipe2 = Pipe()
            let stdoutPipe2 = Pipe()
            let stderrPipe2 = Pipe()
            proc2.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc2.arguments = [command] + args
            proc2.standardInput = stdinPipe2
            proc2.standardOutput = stdoutPipe2
            proc2.standardError = stderrPipe2
            proc2.environment = procEnv
            try proc2.run()
            self.process = proc2
            self.stdin = stdinPipe2.fileHandleForWriting
            self.stdoutHandle = stdoutPipe2.fileHandleForReading
            self.connected = true

            proc2.terminationHandler = { [weak self] terminatedProc in
                guard let self = self else { return }
                Task { await self.handleProcessTermination(exitCode: terminatedProc.terminationStatus) }
            }

            let handle2 = stdoutPipe2.fileHandleForReading
            readTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    let data = handle2.availableData
                    if data.isEmpty {
                        await self?.handleDisconnect()
                        break
                    }
                    await self?.handleData(data)
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }

            initResult = try await sendRequest("initialize", params: initParams, timeout: 15)
        }

        sendNotification("notifications/initialized", params: [:])

        self.reconnectAttempts = 0
        self.isReconnecting = false

        let serverInfo = (initResult["serverInfo"] as? [String: Any])?["name"] as? String ?? "unknown"
        print("[MCP] Connected to \(serverInfo)")
    }

    public func disconnect() {
        connected = false
        stdoutHandle?.closeFile()
        stdoutHandle = nil
        readTask?.cancel()
        readTask = nil
        stdin?.closeFile()
        stdin = nil
        process?.terminate()
        process = nil
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPError.disconnected)
        }
        pendingRequests.removeAll()
    }

    // MARK: - MCP Operations

    public func listTools() async throws -> [MCPToolInfo] {
        let result = try await sendRequest("tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else {
            return []
        }
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
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: result, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "Tool executed successfully (no text output)"
    }

    // MARK: - JSON-RPC 2.0 Transport

    private func sendRequest(_ method: String, params: [String: Any], timeout: TimeInterval = 15) async throws -> [String: Any] {
        guard connected, stdin != nil else { throw MCPError.disconnected }

        let id = nextId
        nextId += 1

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let messageData = try JSONSerialization.data(withJSONObject: message)

        guard let pipe = stdin, process?.isRunning == true else {
            throw MCPError.disconnected
        }
        do {
            if rawJsonMode {
                try pipe.write(contentsOf: messageData)
                try pipe.write(contentsOf: Data("\n".utf8))
            } else {
                let header = "Content-Length: \(messageData.count)\r\n\r\n"
                guard let headerData = header.data(using: .utf8) else {
                    throw MCPError.encodingError
                }
                try pipe.write(contentsOf: headerData)
                try pipe.write(contentsOf: messageData)
            }
        } catch {
            throw MCPError.disconnected
        }

        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[id] = continuation

            let timeoutTask = Task.detached { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.handleTimeout(forId: id)
            }
            self.timeoutTasks[id] = timeoutTask
        }
        return result
    }

    private func handleTimeout(forId id: Int) {
        if let cont = pendingRequests.removeValue(forKey: id) {
            timeoutTasks.removeValue(forKey: id)
            cont.resume(throwing: MCPError.timeout)
        }
    }

    private func sendNotification(_ method: String, params: [String: Any]) {
        guard connected, let pipe = stdin, process?.isRunning == true else { return }
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        if rawJsonMode {
            try? pipe.write(contentsOf: data)
            try? pipe.write(contentsOf: Data("\n".utf8))
        } else {
            let header = "Content-Length: \(data.count)\r\n\r\n"
            if let headerData = header.data(using: .utf8) {
                try? pipe.write(contentsOf: headerData)
                try? pipe.write(contentsOf: data)
            }
        }
    }

    // MARK: - Response Parsing

    private func handleData(_ data: Data) {
        readBuffer.append(data)

        // Auto-detect framing from first response (once, then locked).
        if !rawJsonMode && !rawJsonModeLocked {
            let trimmed = readBuffer.drop(while: { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 })
            if let first = trimmed.first, first == UInt8(ascii: "{") {
                rawJsonMode = true
                rawJsonModeLocked = true
                print("[MCP] \(serverName): auto-detected raw JSON mode (no Content-Length framing)")
            } else if let first = trimmed.first, first == UInt8(ascii: "C") {
                rawJsonModeLocked = true
            }
        }

        while let message = extractMessage() {
            processMessage(message)
        }
    }

    private func extractMessage() -> [String: Any]? {
        rawJsonMode ? extractRawJsonMessage() : extractContentLengthMessage()
    }

    private func extractContentLengthMessage() -> [String: Any]? {
        guard let headerEnd = readBuffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = readBuffer[readBuffer.startIndex..<headerEnd.lowerBound]
        guard let headerStr = String(data: headerData, encoding: .utf8),
              let lengthLine = headerStr.split(separator: "\r\n").first(where: { $0.hasPrefix("Content-Length:") }),
              let length = Int(lengthLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
        else { return nil }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = readBuffer.index(bodyStart, offsetBy: length, limitedBy: readBuffer.endIndex)
        guard let end = bodyEnd, end <= readBuffer.endIndex else { return nil }

        let bodyData = readBuffer[bodyStart..<end]
        readBuffer = Data(readBuffer[end...])

        return (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
    }

    private func extractRawJsonMessage() -> [String: Any]? {
        while let first = readBuffer.first, (first == 0x0A || first == 0x0D || first == 0x20) {
            readBuffer.removeFirst()
        }
        guard !readBuffer.isEmpty else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var endIndex: Data.Index?

        for i in readBuffer.indices {
            let byte = readBuffer[i]
            if escaped {
                escaped = false
                continue
            }
            if byte == UInt8(ascii: "\\") && inString {
                escaped = true
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = !inString
                continue
            }
            if inString { continue }
            if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    endIndex = readBuffer.index(after: i)
                    break
                }
            }
        }

        guard let end = endIndex else { return nil }
        let jsonData = readBuffer[readBuffer.startIndex..<end]
        var trimEnd = end
        while trimEnd < readBuffer.endIndex {
            let b = readBuffer[trimEnd]
            guard b == 0x0A || b == 0x0D || b == 0x20 else { break }
            trimEnd = readBuffer.index(after: trimEnd)
        }
        readBuffer = Data(readBuffer[trimEnd...])

        return (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
    }

    private func processMessage(_ message: [String: Any]) {
        if let id = (message["id"] as? Int) ?? (message["id"] as? NSNumber)?.intValue,
           let continuation = pendingRequests.removeValue(forKey: id) {
            timeoutTasks.removeValue(forKey: id)?.cancel()

            if let error = message["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unknown MCP error"
                let code = error["code"] as? Int ?? -1
                continuation.resume(throwing: MCPError.serverError(code: code, message: msg))
            } else {
                let result = message["result"] as? [String: Any] ?? [:]
                continuation.resume(returning: result)
            }
        }
    }

    private func handleDisconnect() {
        guard connected else { return }
        connected = false
        stdin?.closeFile()
        stdin = nil
        process = nil
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPError.disconnected)
        }
        pendingRequests.removeAll()
        print("[MCP] Server \(serverName) disconnected")
    }

    // MARK: - Process Termination & Reconnection

    private func handleProcessTermination(exitCode: Int32) {
        let wasConnected = connected
        if connected {
            connected = false
            readTask?.cancel()
            readTask = nil
            stdoutHandle?.closeFile()
            stdoutHandle = nil
            stdin?.closeFile()
            stdin = nil
            process = nil
            for (_, task) in timeoutTasks { task.cancel() }
            timeoutTasks.removeAll()
            for (_, continuation) in pendingRequests {
                continuation.resume(throwing: MCPError.disconnected)
            }
            pendingRequests.removeAll()
        }

        if wasConnected {
            print("[MCP] Server \(serverName) process terminated (exit code \(exitCode)), scheduling reconnect")
            Task { await attemptReconnect() }
        }
    }

    private func attemptReconnect() async {
        guard !isReconnecting else { return }
        guard let command = lastCommand, let args = lastArgs else {
            print("[MCP] Cannot reconnect \(serverName): no stored connection params")
            return
        }

        isReconnecting = true
        defer { isReconnecting = false }

        while reconnectAttempts < Self.maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = min(pow(2.0, Double(reconnectAttempts - 1)), Self.maxBackoffSeconds)
            print("[MCP] Reconnecting \(serverName) in \(delay)s (attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts))")

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await connect(command: command, args: args, env: lastEnv ?? [:])
                print("[MCP] Reconnected \(serverName) successfully")
                return
            } catch {
                print("[MCP] Reconnect \(serverName) attempt \(reconnectAttempts) failed: \(error.localizedDescription)")
            }
        }

        print("[MCP] Giving up reconnecting \(serverName) after \(Self.maxReconnectAttempts) attempts")
    }

    // MARK: - Liveness Check

    public func ensureConnected() async throws {
        if isAlive { return }

        guard let command = lastCommand, let args = lastArgs else {
            throw MCPError.disconnected
        }

        if connected {
            handleDisconnect()
        }

        if reconnectAttempts >= Self.maxReconnectAttempts {
            reconnectAttempts = 0
        }

        print("[MCP] Liveness check failed for \(serverName), reconnecting...")
        do {
            try await connect(command: command, args: args, env: lastEnv ?? [:])
        } catch {
            throw MCPError.disconnected
        }
    }
}
