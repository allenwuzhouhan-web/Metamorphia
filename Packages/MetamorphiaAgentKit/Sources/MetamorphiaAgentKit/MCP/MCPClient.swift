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
    /// Drains stdout chunks in arrival order into the actor (a single consumer
    /// preserves FIFO ordering that separately-spawned Tasks would not).
    private var readPump: Task<Void, Never>?
    private var readContinuation: AsyncStream<Data>.Continuation?
    /// Raw JSON-RPC (newline-delimited) mode instead of Content-Length framed.
    /// Locked once detected so auto-detection can't flip it mid-flight.
    private var rawJsonMode = false
    private var rawJsonModeLocked = false

    /// Brace-scan state for raw-JSON framing, carried across stdout chunks so a
    /// still-streaming large message is examined byte-by-byte exactly once
    /// (O(n)) instead of re-scanning the whole buffer from the start each chunk
    /// (O(n^2)). `rawScanOffset` counts bytes already examined from the current
    /// buffer start; reset after a complete frame is consumed.
    private var rawScanDepth = 0
    private var rawScanInString = false
    private var rawScanEscaped = false
    private var rawScanOffset = 0

    // Reconnection state
    private var lastCommand: String?
    private var lastArgs: [String]?
    private var lastEnv: [String: String]?
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private static let maxReconnectAttempts = 5
    private static let maxBackoffSeconds: Double = 30
    /// Hard cap on a single JSON-RPC frame (32 MB). A larger declared Content-Length
    /// or an unbounded never-terminated frame is treated as a protocol error rather
    /// than allowed to exhaust memory.
    private static let maxFrameBytes = 32 * 1024 * 1024

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

        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + args
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // stderr is diagnostic only; discard it so a chatty server can't fill
        // the OS pipe buffer (~64KB) and block on its next write.
        proc.standardError = FileHandle.nullDevice

        // SECURITY: do NOT pass the full parent environment to a third-party MCP
        // server — that would leak the user's API keys, tokens, and secrets to an
        // untrusted child process. Build a minimal allowlist of process-neutral
        // vars plus only the server's own explicitly configured env.
        let procEnv = Self.minimalChildEnvironment(serverEnv: env)
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

        startReading(on: stdoutPipe.fileHandleForReading)

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
            #if DEBUG
            print("[MCP] \(serverName): Content-Length framing timed out, restarting in raw JSON mode")
            #endif
            disconnect()

            rawJsonMode = true
            rawJsonModeLocked = true
            let proc2 = Process()
            let stdinPipe2 = Pipe()
            let stdoutPipe2 = Pipe()
            proc2.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc2.arguments = [command] + args
            proc2.standardInput = stdinPipe2
            proc2.standardOutput = stdoutPipe2
            // stderr is diagnostic only; discard it so a chatty server can't fill
            // the OS pipe buffer and block on its next write.
            proc2.standardError = FileHandle.nullDevice
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

            startReading(on: stdoutPipe2.fileHandleForReading)

            initResult = try await sendRequest("initialize", params: initParams, timeout: 15)
        }

        sendNotification("notifications/initialized", params: [:])

        self.reconnectAttempts = 0
        self.isReconnecting = false

        let serverInfo = (initResult["serverInfo"] as? [String: Any])?["name"] as? String ?? "unknown"
        #if DEBUG
        print("[MCP] Connected to \(serverInfo)")
        #endif
    }

    /// Build a minimal, allowlisted environment for an MCP child process.
    ///
    /// Passing `ProcessInfo.processInfo.environment` wholesale leaks every secret
    /// the host process holds (API keys, OAuth tokens) into an untrusted third-party
    /// server. Instead we forward only a small set of process-neutral variables plus
    /// whatever the server itself declared via its own config.
    private static func minimalChildEnvironment(serverEnv: [String: String]) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        let allowlist = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SHELL", "TERM", "TZ"]
        var env: [String: String] = [:]
        for key in allowlist {
            if let value = parent[key] { env[key] = value }
        }
        // Ensure node / npx can be found without inheriting the parent PATH verbatim.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // The server's own explicitly configured env wins — it may legitimately
        // need a scoped token the user supplied for THIS server.
        for (k, v) in serverEnv { env[k] = v }
        return env
    }

    public func disconnect() {
        connected = false
        stopReading()
        stdoutHandle?.closeFile()
        stdoutHandle = nil
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

    // MARK: - Reader

    /// Drives the stdout reader without occupying a Swift cooperative-pool thread.
    /// The readability handler runs on a Foundation-managed dispatch source thread
    /// and only yields the captured bytes into an AsyncStream; a single consumer
    /// task drains them in arrival order back inside the actor.
    private func startReading(on handle: FileHandle) {
        stopReading()
        // Fresh stdout stream — clear any partial-frame scan state so a stale
        // offset from a torn-down connection can't desync the new buffer.
        rawScanDepth = 0
        rawScanInString = false
        rawScanEscaped = false
        rawScanOffset = 0
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        readContinuation = continuation
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        readPump = Task { [weak self] in
            for await data in stream {
                await self?.handleData(data)
            }
            await self?.handleDisconnect()
        }
    }

    /// Tears down the active reader (handler + stream + consumer).
    private func stopReading() {
        stdoutHandle?.readabilityHandler = nil
        readContinuation?.finish()
        readContinuation = nil
        readPump?.cancel()
        readPump = nil
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

        // Guard against a malformed / never-terminated frame growing the buffer
        // without bound. If we've accumulated more than a full max-frame and still
        // can't extract a message below, the stream is corrupt — drop it and reset.
        if readBuffer.count > Self.maxFrameBytes * 2 {
            print("[MCP] \(serverName): read buffer exceeded \(Self.maxFrameBytes * 2) bytes without a complete frame; resetting stream")
            readBuffer.removeAll(keepingCapacity: false)
            return
        }

        // Auto-detect framing from first response (once, then locked).
        if !rawJsonMode && !rawJsonModeLocked {
            let trimmed = readBuffer.drop(while: { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 })
            if let first = trimmed.first, first == UInt8(ascii: "{") {
                rawJsonMode = true
                rawJsonModeLocked = true
                #if DEBUG
                print("[MCP] \(serverName): auto-detected raw JSON mode (no Content-Length framing)")
                #endif
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

        // Reject absurd or negative declared lengths before attempting to read the
        // body — an attacker-controlled Content-Length could otherwise drive an
        // unbounded read / memory exhaustion.
        guard length >= 0, length <= Self.maxFrameBytes else {
            print("[MCP] \(serverName): rejecting frame with Content-Length \(length) (max \(Self.maxFrameBytes)); resetting stream")
            readBuffer.removeAll(keepingCapacity: false)
            return nil
        }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = readBuffer.index(bodyStart, offsetBy: length, limitedBy: readBuffer.endIndex)
        guard let end = bodyEnd, end <= readBuffer.endIndex else { return nil }

        let bodyData = readBuffer[bodyStart..<end]
        readBuffer = Data(readBuffer[end...])

        return (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
    }

    private func extractRawJsonMessage() -> [String: Any]? {
        // Only trim leading whitespace when no frame scan is in progress; once a
        // frame has started the leading byte is "{", so trimming mid-scan would
        // be a no-op anyway and would otherwise invalidate the persisted offset.
        if rawScanOffset == 0 {
            while let first = readBuffer.first, (first == 0x0A || first == 0x0D || first == 0x20) {
                readBuffer.removeFirst()
            }
        }
        guard !readBuffer.isEmpty else { return nil }

        var endIndex: Data.Index?

        // Resume the brace scan where the previous chunk left off so each byte is
        // examined exactly once across the lifetime of a streaming message.
        var i = readBuffer.index(readBuffer.startIndex, offsetBy: rawScanOffset)
        while i < readBuffer.endIndex {
            let byte = readBuffer[i]
            if rawScanEscaped {
                rawScanEscaped = false
            } else if byte == UInt8(ascii: "\\") && rawScanInString {
                rawScanEscaped = true
            } else if byte == UInt8(ascii: "\"") {
                rawScanInString = !rawScanInString
            } else if !rawScanInString {
                if byte == UInt8(ascii: "{") {
                    rawScanDepth += 1
                } else if byte == UInt8(ascii: "}") {
                    rawScanDepth -= 1
                    if rawScanDepth == 0 {
                        endIndex = readBuffer.index(after: i)
                        break
                    }
                }
            }
            i = readBuffer.index(after: i)
        }

        guard let end = endIndex else {
            // Partial message: record how far we scanned so the next chunk resumes
            // here instead of rescanning the whole accumulated buffer.
            rawScanOffset = readBuffer.count
            return nil
        }
        let jsonData = readBuffer[readBuffer.startIndex..<end]
        var trimEnd = end
        while trimEnd < readBuffer.endIndex {
            let b = readBuffer[trimEnd]
            guard b == 0x0A || b == 0x0D || b == 0x20 else { break }
            trimEnd = readBuffer.index(after: trimEnd)
        }
        readBuffer = Data(readBuffer[trimEnd...])
        // Frame consumed — reset scan state for the next message.
        rawScanDepth = 0
        rawScanInString = false
        rawScanEscaped = false
        rawScanOffset = 0

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
        stopReading()
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
        print("[MCP] Server \(serverName) disconnected")
    }

    // MARK: - Process Termination & Reconnection

    private func handleProcessTermination(exitCode: Int32) {
        let wasConnected = connected
        if connected {
            connected = false
            stopReading()
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

        #if DEBUG
        print("[MCP] Liveness check failed for \(serverName), reconnecting...")
        #endif
        do {
            try await connect(command: command, args: args, env: lastEnv ?? [:])
        } catch {
            throw MCPError.disconnected
        }
    }
}
