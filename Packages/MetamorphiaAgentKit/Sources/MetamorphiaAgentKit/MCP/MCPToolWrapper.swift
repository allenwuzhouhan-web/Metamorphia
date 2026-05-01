import Foundation

/// Wraps an MCP-discovered tool as a `ToolDefinition` so it can be registered
/// into the app's tool registry alongside native tools.
///
/// Naming scheme: `mcp__<serverName>__<toolName>` — the double underscore
/// prevents collisions when a server name happens to contain an underscore
/// (e.g., server "foo" + tool "bar_baz" vs server "foo_bar" + tool "baz").
/// `@unchecked Sendable` because `parameters: [String: Any]` isn't strict-Sendable;
/// it's immutable after init so sharing across tasks is safe.
public struct MCPToolWrapper: ToolDefinition, @unchecked Sendable {
    public let name: String
    public let description: String
    public let parameters: [String: Any]

    private let originalName: String
    private let serverName: String
    private let client: any MCPTransport

    public init(serverName: String, tool: MCPToolInfo, client: any MCPTransport) {
        self.originalName = tool.name
        self.serverName = serverName
        self.name = "mcp__\(serverName)__\(tool.name)"
        self.description = "\(tool.description) [MCP: \(serverName)]"
        self.parameters = tool.inputSchema
        self.client = client
    }

    public func execute(arguments: String) async throws -> String {
        // Liveness check — reconnect if the server process died
        try await client.ensureConnected()
        let args = try parseArguments(arguments)
        let rawResult = try await client.callTool(name: originalName, arguments: args)
        // MCP servers are third-party. Treat their output as untrusted data so
        // a malicious or compromised server can't inject instructions into the
        // next LLM turn. ``ExternalContentFraming`` prepends a data-only banner.
        return ExternalContentFraming.wrap(rawResult, source: "MCP server '\(serverName)'")
    }
}
