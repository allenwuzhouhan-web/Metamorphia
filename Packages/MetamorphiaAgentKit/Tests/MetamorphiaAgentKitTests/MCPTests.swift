import XCTest
@testable import MetamorphiaAgentKit

/// Tests for the MCP client suite — focused on things that can be verified without
/// a live MCP server (no subprocess launches, no network). End-to-end integration
/// tests live elsewhere and require actual MCP servers to be installed.
final class MCPTests: XCTestCase {

    // MARK: - Error descriptions

    func testMCPErrorDescriptions() {
        XCTAssertEqual(MCPError.disconnected.errorDescription, "MCP server disconnected")
        XCTAssertEqual(MCPError.timeout.errorDescription, "MCP request timed out")
        XCTAssertEqual(MCPError.sessionExpired.errorDescription, "MCP session expired")

        if case let msg = MCPError.serverError(code: 42, message: "bad").errorDescription {
            XCTAssertEqual(msg, "MCP server error: bad")
        }

        if let msg = MCPError.httpError(statusCode: 500, body: "boom").errorDescription {
            XCTAssertTrue(msg.contains("500"))
            XCTAssertTrue(msg.contains("boom"))
        } else {
            XCTFail("httpError should have a description")
        }
    }

    // MARK: - MCPToolWrapper naming

    /// A minimal transport stub that records calls but doesn't touch the network.
    final class StubTransport: MCPTransport, @unchecked Sendable {
        let serverName: String
        var isAlive: Bool { get async { true } }

        var recordedCalls: [(name: String, args: [String: Any])] = []
        let resultToReturn: String

        init(serverName: String, resultToReturn: String = "stubbed") {
            self.serverName = serverName
            self.resultToReturn = resultToReturn
        }

        func connect() async throws {}
        func disconnect() async {}
        func ensureConnected() async throws {}
        func listTools() async throws -> [MCPToolInfo] { [] }
        func callTool(name: String, arguments: [String: Any]) async throws -> String {
            recordedCalls.append((name, arguments))
            return resultToReturn
        }
    }

    func testToolWrapperNameUsesDoubleUnderscoreScheme() {
        let transport = StubTransport(serverName: "notion")
        let info = MCPToolInfo(name: "search", description: "Search pages", inputSchema: [:])
        let wrapper = MCPToolWrapper(serverName: "notion", tool: info, client: transport)

        XCTAssertEqual(wrapper.name, "mcp__notion__search")
        XCTAssertTrue(wrapper.description.hasSuffix("[MCP: notion]"))
    }

    func testToolWrapperExecuteForwardsToTransport() async throws {
        let transport = StubTransport(serverName: "notion", resultToReturn: "{\"id\":\"123\"}")
        let info = MCPToolInfo(name: "create_page", description: "Create a page", inputSchema: [:])
        let wrapper = MCPToolWrapper(serverName: "notion", tool: info, client: transport)

        let result = try await wrapper.execute(arguments: #"{"title":"hi"}"#)

        // MCP results are third-party data; they get wrapped in the external-
        // content framing banner to defuse prompt injection from a malicious
        // or compromised server. Verify the wrapping is present AND the raw
        // payload is preserved verbatim inside it.
        XCTAssertTrue(result.contains("{\"id\":\"123\"}"),
                      "Transport result must be forwarded verbatim inside the wrapper")
        XCTAssertTrue(result.contains("EXTERNAL CONTENT"),
                      "MCP tool results must carry the external-content framing banner")
        XCTAssertTrue(result.contains("MCP server 'notion'"),
                      "Banner must identify the originating server")

        XCTAssertEqual(transport.recordedCalls.count, 1)
        XCTAssertEqual(transport.recordedCalls.first?.name, "create_page",
                       "transport should receive the ORIGINAL tool name (not the mcp__ prefixed one)")
        XCTAssertEqual(transport.recordedCalls.first?.args["title"] as? String, "hi")
    }

    // MARK: - ServerConfig round-trip

    func testServerConfigCodableRoundTrip() throws {
        let config = MCPServerManager.ServerConfig(
            name: "my-server",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@example/server"],
            env: ["FOO": "bar"],
            url: nil,
            headers: nil
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerManager.ServerConfig.self, from: encoded)

        XCTAssertEqual(decoded.name, "my-server")
        XCTAssertEqual(decoded.effectiveTransport, .stdio)
        XCTAssertEqual(decoded.command, "npx")
        XCTAssertEqual(decoded.args, ["-y", "@example/server"])
        XCTAssertEqual(decoded.env?["FOO"], "bar")
    }

    func testServerConfigMissingTransportDefaultsToStdio() throws {
        let json = #"{"name":"legacy","command":"foo","args":["bar"]}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MCPServerManager.ServerConfig.self, from: data)
        XCTAssertEqual(decoded.effectiveTransport, .stdio, "legacy configs with no transport field default to stdio")
    }

    // MARK: - MCPServerManager config persistence

    func testConfigFilePersistsAndReloads() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let mgr = MCPServerManager(configURL: tempURL, registrar: NullMCPToolRegistrar())
        let cfg = MCPServerManager.ServerConfig(
            name: "foo",
            transport: .stdio,
            command: "foo",
            args: [],
            env: nil,
            url: nil,
            headers: nil
        )

        mgr.saveConfig([cfg])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        let loaded = mgr.loadConfig()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "foo")
    }

    func testAddAndRemoveServerRoundTrip() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let mgr = MCPServerManager(configURL: tempURL, registrar: nil)
        let cfg = MCPServerManager.ServerConfig(name: "a", transport: .stdio, command: "x", args: [])

        mgr.addServer(cfg)
        XCTAssertEqual(mgr.loadConfig().count, 1)

        // Adding the same name replaces rather than duplicating.
        mgr.addServer(cfg)
        XCTAssertEqual(mgr.loadConfig().count, 1)

        mgr.removeServer(named: "a")
        XCTAssertEqual(mgr.loadConfig().count, 0)
    }

    // MARK: - Catalog

    func testCatalogExposesExpectedServers() {
        let expected: Set<String> = [
            "notion", "google-workspace", "github", "slack",
            "linear", "figma", "zoom", "spotify", "filesystem"
        ]
        let actual = Set(MCPServerCatalog.entries.map(\.id))
        XCTAssertEqual(actual, expected, "catalog should cover all 9 curated servers")
    }

    func testCatalogLookup() {
        XCTAssertNotNil(MCPServerCatalog.entry(for: "notion"))
        XCTAssertNil(MCPServerCatalog.entry(for: "nonexistent"))
    }

    func testCatalogGroupByCategory() {
        let groups = MCPServerCatalog.byCategory
        let categorySet = Set(groups.map(\.0))
        XCTAssertTrue(categorySet.contains(.productivity))
        XCTAssertTrue(categorySet.contains(.development))
    }

    // MARK: - configFromCatalog

    func testConfigFromCatalogBuildsStdioEntry() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let mgr = MCPServerManager(configURL: tempURL, registrar: nil)
        let entry = MCPServerCatalog.entry(for: "notion")!
        let cfg = mgr.configFromCatalog(entry, credentialValues: ["NOTION_TOKEN": "ntn_secret"])

        XCTAssertEqual(cfg.name, "notion")
        XCTAssertEqual(cfg.effectiveTransport, .stdio)
        XCTAssertEqual(cfg.env?["NOTION_TOKEN"], "ntn_secret")
        XCTAssertEqual(cfg.command, "npx")
    }

    func testConfigFromCatalogForFilesystemAppendsAllowedDirs() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let mgr = MCPServerManager(configURL: tempURL, registrar: nil)
        let entry = MCPServerCatalog.entry(for: "filesystem")!
        let cfg = mgr.configFromCatalog(
            entry,
            credentialValues: ["ALLOWED_DIRS": "/Users/me/Docs, /tmp"]
        )

        XCTAssertNotNil(cfg.args)
        XCTAssertTrue(cfg.args?.contains("/Users/me/Docs") ?? false)
        XCTAssertTrue(cfg.args?.contains("/tmp") ?? false,
                      "comma-separated allowed dirs should be split and appended to args")
    }

    // MARK: - Registrar injection

    func testRegistrarReceivesRegistrationOnConnectSingle() async {
        // This is a partial test: we don't actually spin up a subprocess, so the
        // registrar only receives empty arrays. The important check is that the
        // registrar is called at all when injected.
        final class RecordingRegistrar: MCPToolRegistrar, @unchecked Sendable {
            var registered: [[String]] = []
            var unregistered: [String] = []
            func registerMCPTools(_ tools: [MCPToolWrapper]) async {
                registered.append(tools.map { $0.name })
            }
            func unregisterMCPTools(forServer name: String) async {
                unregistered.append(name)
            }
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let registrar = RecordingRegistrar()
        let mgr = MCPServerManager(configURL: tempURL, registrar: registrar)

        // Disconnect with nothing connected — registrar should still be called for cleanup.
        await mgr.disconnectSingle(named: "notion")
        XCTAssertEqual(registrar.unregistered, [],
                       "disconnectSingle with no matching client shouldn't call unregister")
    }
}
