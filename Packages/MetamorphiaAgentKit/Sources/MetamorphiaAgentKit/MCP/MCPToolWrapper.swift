import Foundation

/// Wraps an MCP-discovered tool as a `ToolDefinition` so it can be registered
/// into the app's tool registry alongside native tools.
///
/// Naming scheme: `mcp__<serverName>__<toolName>` — the double underscore
/// prevents collisions when a server name happens to contain an underscore
/// (e.g., server "foo" + tool "bar_baz" vs server "foo_bar" + tool "baz").
/// `@unchecked Sendable` because `parameters: [String: Any]` isn't strict-Sendable;
/// it's immutable after init so sharing across tasks is safe.
///
/// IMPORTANT: This wrapper must only ever be invoked through ``ToolRegistry/execute``,
/// which is the single choke point that consults the injected ``ToolSafetyGate``
/// before any tool runs. As defense-in-depth against an accidental direct call,
/// the wrapper also accepts an optional `safetyGate` and re-checks permission
/// itself when one is supplied.
public struct MCPToolWrapper: ToolDefinition, @unchecked Sendable {
    public let name: String
    public let description: String
    public let parameters: [String: Any]

    private let originalName: String
    private let serverName: String
    private let client: any MCPTransport
    private let safetyGate: ToolSafetyGate?

    public init(serverName: String, tool: MCPToolInfo, client: any MCPTransport, safetyGate: ToolSafetyGate? = nil) {
        self.originalName = tool.name
        self.serverName = serverName
        self.name = "mcp__\(serverName)__\(tool.name)"
        self.description = "\(tool.description) [MCP: \(serverName)]"
        self.parameters = tool.inputSchema
        self.client = client
        self.safetyGate = safetyGate
    }

    public func execute(arguments: String) async throws -> String {
        // Defense-in-depth: if a gate was wired directly into the wrapper, consult
        // it before touching the third-party server. The registry remains the
        // primary choke point; this only closes the direct-invocation bypass.
        if let gate = safetyGate {
            if case .deny(let reason) = await gate.checkPermission(toolName: name, arguments: arguments) {
                return "Error: Tool '\(name)' was blocked. \(reason)"
            }
        }
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
