import Foundation

/// Errors thrown by the agent loop, tool registry, LLM services, and MCP client.
///
/// Renamed from Executer's `ExecuterError` during the MetamorphiaAgentKit extraction.
/// App-target code that used `ExecuterError` should switch to `MetamorphiaError`.
public enum MetamorphiaError: LocalizedError {
    case appleScript(String)
    case shellCommand(String)
    case toolNotFound(String)
    case invalidArguments(String)
    case permissionDenied(String)
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .appleScript(let msg): return "AppleScript error: \(msg)"
        case .shellCommand(let msg): return "Shell error: \(msg)"
        case .toolNotFound(let name): return "Unknown tool: \(name)"
        case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
        case .permissionDenied(let msg): return "Permission denied: \(msg)"
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
