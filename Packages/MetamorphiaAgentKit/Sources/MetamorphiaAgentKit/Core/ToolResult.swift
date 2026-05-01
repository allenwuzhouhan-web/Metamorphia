import Foundation

/// Result of a single tool execution within the agent loop.
///
/// Replaces `AgentLoop.ToolResult` from Executer so middleware can reference
/// the type without depending on `AgentLoop` itself (broken circular dep).
public struct ToolResult: Sendable {
    public let toolName: String
    public let toolCallId: String
    public let arguments: String
    public let result: String
    public let durationMs: Double
    public let success: Bool

    public init(
        toolName: String,
        toolCallId: String,
        arguments: String,
        result: String,
        durationMs: Double,
        success: Bool
    ) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.arguments = arguments
        self.result = result
        self.durationMs = durationMs
        self.success = success
    }

    /// Convenience check: the string prefix convention Executer uses for failures.
    public var isFailure: Bool {
        result.hasPrefix("Error")
    }
}
