import Foundation

/// A facade over the app's tool registry — lets middleware query the catalog
/// of deferred and active tools, promote deferred tools on demand, and
/// execute tools by name, without importing `ToolRegistry` directly.
///
/// Replaces direct use of `ToolRegistry.shared` inside `DeferredToolMiddleware`,
/// `SearchToolsTool`, and `UndoLastActionTool`. The app target supplies an
/// adapter that forwards calls to its concrete `ToolRegistry`.
public protocol ToolCatalog: AnyObject, Sendable {
    /// Summaries of tools that are currently deferred (not sent in the LLM tool list
    /// but known by name — promoted on demand via `promoteDeferred(names:)`).
    func deferredToolSummaries() -> [ToolSummary]

    /// Search deferred tools by keyword — matched tools are candidates for promotion.
    func searchDeferredTools(query: String) -> [ToolSummary]

    /// Search active tools by keyword.
    func searchActiveTools(query: String) -> [ToolSummary]

    /// Move tools from the deferred set to the active set. Subsequent LLM calls
    /// should include these tools' full schemas.
    func promoteDeferred(names: Set<String>)

    /// All active tool names. Used to synchronize a middleware's cached view
    /// of "what's currently active" after a promotion.
    func activeToolNames() -> [String]

    /// Fetch the OpenAI-compatible schema for a single tool by name, or `nil` if
    /// the tool isn't registered. Returned as an array to mirror the shape the
    /// LLM context expects (some tool definitions expand into multiple schemas).
    func singleToolSchema(_ toolName: String) -> [[String: AnyCodable]]?

    /// Execute a registered tool with the given JSON-encoded arguments string.
    /// Throws `MetamorphiaError.toolNotFound` if the tool is unknown.
    func execute(toolName: String, arguments: String) async throws -> String
}

/// Lightweight (name, description) pair used by catalog search/listing APIs.
public struct ToolSummary: Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// A catalog that knows about nothing — all queries return empty, all executions
/// throw `MetamorphiaError.toolNotFound`. Used in tests.
public final class NullToolCatalog: ToolCatalog, @unchecked Sendable {
    public init() {}
    public func deferredToolSummaries() -> [ToolSummary] { [] }
    public func searchDeferredTools(query: String) -> [ToolSummary] { [] }
    public func searchActiveTools(query: String) -> [ToolSummary] { [] }
    public func promoteDeferred(names: Set<String>) {}
    public func activeToolNames() -> [String] { [] }
    public func singleToolSchema(_ toolName: String) -> [[String: AnyCodable]]? { nil }
    public func execute(toolName: String, arguments: String) async throws -> String {
        throw MetamorphiaError.toolNotFound(toolName)
    }
}
