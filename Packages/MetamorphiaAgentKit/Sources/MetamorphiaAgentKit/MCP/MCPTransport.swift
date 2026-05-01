import Foundation

/// Shared MCP tool descriptor used by every transport.
/// `@unchecked Sendable` because `inputSchema` is `[String: Any]` — the dictionary
/// is immutable after `init` so it's safe to share across tasks.
public struct MCPToolInfo: @unchecked Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Abstract MCP transport. `MCPClient` (stdio) and `MCPHTTPClient` (SSE /
/// Streamable HTTP) both conform so `MCPToolWrapper` can call either
/// polymorphically.
public protocol MCPTransport: AnyObject, Sendable {
    var serverName: String { get }
    var isAlive: Bool { get async }

    func connect() async throws
    func disconnect() async
    func ensureConnected() async throws
    func listTools() async throws -> [MCPToolInfo]
    func callTool(name: String, arguments: [String: Any]) async throws -> String
}

// MARK: - Shared Errors

public enum MCPError: LocalizedError, Sendable {
    case disconnected
    case encodingError
    case serverError(code: Int, message: String)
    case timeout
    case connectionFailed(String)
    case invalidResponse
    case sessionExpired
    case httpError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: return "MCP server disconnected"
        case .encodingError: return "Failed to encode MCP message"
        case .serverError(_, let msg): return "MCP server error: \(msg)"
        case .timeout: return "MCP request timed out"
        case .connectionFailed(let msg): return "MCP connection failed: \(msg)"
        case .invalidResponse: return "Invalid MCP response"
        case .sessionExpired: return "MCP session expired"
        case .httpError(let code, let body): return "MCP HTTP error \(code): \(body)"
        }
    }
}
