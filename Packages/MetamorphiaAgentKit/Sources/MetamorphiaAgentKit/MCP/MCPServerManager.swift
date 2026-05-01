import Foundation

/// Manages multiple MCP server connections and their discovered tools.
/// Actor-isolated so the client map and discovered-tool list can't race.
///
/// Sever changes vs. Executer:
/// - No `static let shared` singleton — the app target constructs one with its
///   Metamorphia-specific config URL.
/// - `ToolRegistry.shared.registerMCPTools/unregisterMCPTools` → optional
///   ``MCPToolRegistrar`` protocol injected at init. If `nil`, discovered tools
///   are still tracked on the manager but not pushed anywhere.
public actor MCPServerManager {

    // MARK: - Public Types

    public enum ServerStatus: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(toolCount: Int)
        case error(String)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public enum TransportType: String, Codable, Sendable {
        case stdio
        case sse
        case streamableHTTP = "streamable-http"
    }

    public struct ServerConfig: Codable, Sendable {
        public let name: String
        public let transport: TransportType?  // nil = stdio (backward compat)

        // stdio fields
        public let command: String?
        public let args: [String]?
        public let env: [String: String]?

        // HTTP fields
        public let url: String?
        public let headers: [String: String]?

        public var effectiveTransport: TransportType {
            transport ?? .stdio
        }

        public init(
            name: String,
            transport: TransportType? = nil,
            command: String? = nil,
            args: [String]? = nil,
            env: [String: String]? = nil,
            url: String? = nil,
            headers: [String: String]? = nil
        ) {
            self.name = name
            self.transport = transport
            self.command = command
            self.args = args
            self.env = env
            self.url = url
            self.headers = headers
        }
    }

    public struct Config: Codable, Sendable {
        public let servers: [ServerConfig]

        public init(servers: [ServerConfig]) {
            self.servers = servers
        }
    }

    // MARK: - State

    private var clients: [String: any MCPTransport] = [:]
    private var discoveredTools: [MCPToolWrapper] = []
    public let configURL: URL
    public let registrar: MCPToolRegistrar?

    public private(set) var serverStatuses: [String: ServerStatus] = [:]

    // MARK: - Init

    public init(configURL: URL, registrar: MCPToolRegistrar? = nil) {
        self.configURL = configURL
        self.registrar = registrar
    }

    // MARK: - Lifecycle

    /// Connect to all configured servers and discover their tools.
    public func connectAll() async {
        await shutdownAll()

        let configs = loadConfig()
        if configs.isEmpty {
            print("[MCP] No servers configured at \(configURL.path)")
            return
        }

        for config in configs {
            await connectServer(config)
        }

        print("[MCP] Connected \(clients.count) server(s), discovered \(discoveredTools.count) tool(s)")
    }

    /// Every tool discovered so far (for registration into the app's tool registry).
    public func getDiscoveredTools() -> [MCPToolWrapper] { discoveredTools }

    public func shutdownAll() async {
        for (name, client) in clients {
            await client.disconnect()
            print("[MCP] Disconnected \(name)")
        }
        clients.removeAll()
        discoveredTools.removeAll()
        serverStatuses.removeAll()
    }

    public var connectedServers: [String] { Array(clients.keys) }
    public var toolNames: [String] { discoveredTools.map { $0.name } }

    // MARK: - Single Server Connect / Disconnect (runtime)

    /// Connect a single server, persist its config, register its tools. Returns new tool count.
    @discardableResult
    public func connectSingle(_ config: ServerConfig) async -> Int {
        await disconnectSingle(named: config.name)
        addServer(config)
        await connectServer(config)

        let newTools = discoveredTools.filter { $0.name.hasPrefix("mcp__\(config.name)__") }
        if !newTools.isEmpty {
            await registrar?.registerMCPTools(newTools)
        }
        return newTools.count
    }

    public func disconnectSingle(named name: String) async {
        if let client = clients[name] {
            await client.disconnect()
            clients.removeValue(forKey: name)
            discoveredTools.removeAll { $0.name.hasPrefix("mcp__\(name)__") }
            await registrar?.unregisterMCPTools(forServer: name)
            print("[MCP] Disconnected \(name)")
        }
        serverStatuses[name] = .disconnected
    }

    public func removeSingle(named name: String) async {
        await disconnectSingle(named: name)
        removeServer(named: name)
        serverStatuses.removeValue(forKey: name)
    }

    /// Hot-reload: disconnect all and reconnect from persisted config.
    public func reconnectAll() async {
        await shutdownAll()
        await connectAll()
        let tools = getDiscoveredTools()
        if !tools.isEmpty {
            await registrar?.registerMCPTools(tools)
        }
    }

    public func isConnected(_ name: String) -> Bool {
        serverStatuses[name]?.isConnected ?? false
    }

    public func status(for name: String) -> ServerStatus {
        serverStatuses[name] ?? .disconnected
    }

    public func allStatuses() -> [String: ServerStatus] { serverStatuses }

    public func toolCount(for serverName: String) -> Int {
        discoveredTools.filter { $0.name.hasPrefix("mcp__\(serverName)__") }.count
    }

    // MARK: - Server Management

    private func connectServer(_ config: ServerConfig) async {
        serverStatuses[config.name] = .connecting
        let client: any MCPTransport

        switch config.effectiveTransport {
        case .stdio:
            guard let command = config.command, let args = config.args else {
                print("[MCP] stdio server \(config.name) missing command/args")
                serverStatuses[config.name] = .error("Missing command/args")
                return
            }
            let stdioClient = MCPClient(name: config.name)
            do {
                try await stdioClient.connect(command: command, args: args, env: config.env ?? [:])
            } catch {
                print("[MCP] Failed to connect stdio \(config.name): \(error.localizedDescription)")
                await stdioClient.disconnect()
                serverStatuses[config.name] = .error(error.localizedDescription)
                return
            }
            client = stdioClient

        case .sse:
            guard let urlStr = config.url, let url = URL(string: urlStr) else {
                print("[MCP] SSE server \(config.name) missing/invalid url")
                serverStatuses[config.name] = .error("Missing/invalid URL")
                return
            }
            let httpClient = MCPHTTPClient(
                name: config.name, url: url,
                mode: .sse, headers: config.headers ?? [:]
            )
            do {
                try await httpClient.connect()
            } catch {
                print("[MCP] Failed to connect SSE \(config.name): \(error.localizedDescription)")
                await httpClient.disconnect()
                serverStatuses[config.name] = .error(error.localizedDescription)
                return
            }
            client = httpClient

        case .streamableHTTP:
            guard let urlStr = config.url, let url = URL(string: urlStr) else {
                print("[MCP] streamable-http server \(config.name) missing/invalid url")
                serverStatuses[config.name] = .error("Missing/invalid URL")
                return
            }
            let httpClient = MCPHTTPClient(
                name: config.name, url: url,
                mode: .streamableHTTP, headers: config.headers ?? [:]
            )
            do {
                try await httpClient.connect()
            } catch {
                print("[MCP] Failed to connect streamable-http \(config.name): \(error.localizedDescription)")
                await httpClient.disconnect()
                serverStatuses[config.name] = .error(error.localizedDescription)
                return
            }
            client = httpClient
        }

        do {
            let tools = try await client.listTools()
            let wrappers = tools.map { MCPToolWrapper(serverName: config.name, tool: $0, client: client) }
            clients[config.name] = client
            discoveredTools.append(contentsOf: wrappers)
            serverStatuses[config.name] = .connected(toolCount: tools.count)

            print("[MCP] \(config.name) [\(config.effectiveTransport)]: discovered \(tools.count) tools")
            for t in tools {
                print("[MCP]   - \(t.name): \(t.description.prefix(60))")
            }
        } catch {
            print("[MCP] Failed to discover tools for \(config.name): \(error.localizedDescription)")
            await client.disconnect()
            serverStatuses[config.name] = .error("Tool discovery failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Config (nonisolated — file-only, configURL is immutable)

    /// Marker prefix stored in the on-disk JSON in place of sensitive env /
    /// header values. At load time, each marker is swapped for the real value
    /// pulled from the Keychain. At save time, any plaintext value is moved
    /// into the Keychain and replaced with its marker on disk.
    ///
    /// This means the config JSON file no longer contains bearer tokens,
    /// database URLs with embedded passwords, or API keys — only references.
    private static let keychainSentinelPrefix = "__kc__:"

    public nonisolated func loadConfig() -> [ServerConfig] {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [] }
        let raw: [ServerConfig]
        do {
            let data = try Data(contentsOf: configURL)
            raw = try JSONDecoder().decode(Config.self, from: data).servers
        } catch {
            print("[MCP] Config error: \(error)")
            return []
        }

        // One-time migration: any plaintext secret found in the on-disk file
        // gets moved into the Keychain and the file is re-written with the
        // sentinel form. Idempotent — if everything is already a sentinel, no
        // work is done.
        let needsMigration = raw.contains { hasPlaintextSecrets($0) }
        if needsMigration {
            print("[MCP] Migrating plaintext secrets to Keychain")
            saveConfig(raw)
        }

        // After (or skipping) migration, the canonical on-disk form always has
        // sentinels. Reload and resolve.
        let persisted = needsMigration ? (try? JSONDecoder().decode(
            Config.self,
            from: (try? Data(contentsOf: configURL)) ?? Data()
        ).servers) ?? raw : raw

        return persisted.map { revealSecrets($0) }
    }

    public nonisolated func saveConfig(_ servers: [ServerConfig]) {
        let hidden = servers.map { hideSecrets($0) }
        let config = Config(servers: hidden)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: configURL)
        }
    }

    public nonisolated func addServer(_ server: ServerConfig) {
        var configs = loadConfig()
        configs.removeAll { $0.name == server.name }
        configs.append(server)
        saveConfig(configs)
    }

    public nonisolated func removeServer(named name: String) {
        var configs = loadConfig()
        if let toRemove = configs.first(where: { $0.name == name }) {
            deleteSecrets(for: toRemove)
        }
        configs.removeAll { $0.name == name }
        saveConfig(configs)
    }

    // MARK: - Secret Migration Helpers

    private nonisolated func hasPlaintextSecrets(_ server: ServerConfig) -> Bool {
        let env = server.env ?? [:]
        let headers = server.headers ?? [:]
        for (_, v) in env where !v.isEmpty && !v.hasPrefix(Self.keychainSentinelPrefix) { return true }
        for (_, v) in headers where !v.isEmpty && !v.hasPrefix(Self.keychainSentinelPrefix) { return true }
        return false
    }

    /// Replace plaintext env + header values with Keychain sentinels. Idempotent.
    private nonisolated func hideSecrets(_ server: ServerConfig) -> ServerConfig {
        var env = server.env ?? [:]
        var headers = server.headers ?? [:]

        for (key, value) in env {
            guard !value.hasPrefix(Self.keychainSentinelPrefix) else { continue }
            guard !value.isEmpty else { continue }
            let kcKey = Self.keychainKey(server: server.name, kind: "env", key: key)
            KeychainHelper.save(key: kcKey, data: Data(value.utf8))
            env[key] = Self.keychainSentinelPrefix + kcKey
        }
        for (key, value) in headers {
            guard !value.hasPrefix(Self.keychainSentinelPrefix) else { continue }
            guard !value.isEmpty else { continue }
            let kcKey = Self.keychainKey(server: server.name, kind: "header", key: key)
            KeychainHelper.save(key: kcKey, data: Data(value.utf8))
            headers[key] = Self.keychainSentinelPrefix + kcKey
        }

        return ServerConfig(
            name: server.name,
            transport: server.transport,
            command: server.command,
            args: server.args,
            env: env.isEmpty ? nil : env,
            url: server.url,
            headers: headers.isEmpty ? nil : headers
        )
    }

    /// Replace Keychain sentinels with the real values loaded from Keychain.
    /// A missing Keychain entry resolves to an empty string so the downstream
    /// MCP client fails a clean authentication rather than sending a literal
    /// `__kc__:...` as the auth token.
    private nonisolated func revealSecrets(_ server: ServerConfig) -> ServerConfig {
        let resolve: (String) -> String = { value in
            guard value.hasPrefix(Self.keychainSentinelPrefix) else { return value }
            let kcKey = String(value.dropFirst(Self.keychainSentinelPrefix.count))
            guard let data = KeychainHelper.load(key: kcKey),
                  let real = String(data: data, encoding: .utf8) else { return "" }
            return real
        }

        let env = (server.env ?? [:]).mapValues(resolve)
        let headers = (server.headers ?? [:]).mapValues(resolve)

        return ServerConfig(
            name: server.name,
            transport: server.transport,
            command: server.command,
            args: server.args,
            env: env.isEmpty ? nil : env,
            url: server.url,
            headers: headers.isEmpty ? nil : headers
        )
    }

    private nonisolated func deleteSecrets(for server: ServerConfig) {
        var allValues: [String] = []
        allValues.append(contentsOf: (server.env ?? [:]).values)
        allValues.append(contentsOf: (server.headers ?? [:]).values)
        for value in allValues where value.hasPrefix(Self.keychainSentinelPrefix) {
            let kcKey = String(value.dropFirst(Self.keychainSentinelPrefix.count))
            KeychainHelper.delete(key: kcKey)
        }
    }

    private static func keychainKey(server: String, kind: String, key: String) -> String {
        // Sanitize: Keychain keys are free-form but we keep them predictable
        // and filesystem-safe so logging them (if ever needed) is harmless.
        let safeServer = server.replacingOccurrences(of: "/", with: "_")
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return "mcp_\(safeServer)_\(kind)_\(safeKey)"
    }

    // MARK: - Catalog Helpers

    /// Build a ServerConfig from a catalog entry and user-provided credential values.
    public nonisolated func configFromCatalog(
        _ entry: MCPCatalogEntry,
        credentialValues: [String: String]
    ) -> ServerConfig {
        var env: [String: String] = [:]
        var headers: [String: String] = [:]

        for cred in entry.credentials {
            guard let value = credentialValues[cred.id], !value.isEmpty else { continue }
            if cred.isHeader {
                headers[cred.id] = value
            } else {
                env[cred.id] = value
            }
        }

        // Filesystem server: append allowed dirs to args
        var args = entry.args ?? []
        if entry.id == "filesystem", let dirs = credentialValues["ALLOWED_DIRS"] {
            let paths = dirs.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            args.append(contentsOf: paths)
        }

        return ServerConfig(
            name: entry.id,
            transport: entry.transport,
            command: entry.command,
            args: args.isEmpty ? nil : args,
            env: env.isEmpty ? nil : env,
            url: entry.url,
            headers: headers.isEmpty ? nil : headers
        )
    }
}
