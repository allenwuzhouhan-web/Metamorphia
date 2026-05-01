import Foundation

/// When a tool fails, this middleware:
/// 1. Captures the error and analyzes what went wrong
/// 2. Looks up recovery strategies (alternative tools, parameter fixes)
/// 3. Injects recovery guidance into the conversation
/// 4. Tracks error patterns to prevent repeated failures
public final class ErrorRecoveryMiddleware: AgentMiddleware {
    public let name = "ErrorRecovery"

    public init() {}

    // MARK: - Storage Keys

    private static let errorsKey = "ErrorRecovery.errors"
    private static let recoveriesKey = "ErrorRecovery.recoveries"
    private static let failedToolsKey = "ErrorRecovery.failedTools"

    // MARK: - Error Record

    public struct ErrorRecord {
        public let toolName: String
        public let errorMessage: String
        public let iteration: Int
        public let strategy: RecoveryStrategy?
    }

    public enum RecoveryStrategy: String {
        case alternativeTool
        case fixParameters
        case prerequisite
        case permissionFix
        case retry
        case skip
        case escalate
    }

    // MARK: - Recovery Maps

    private static let alternatives: [String: [String]] = [
        "launch_app": ["run_applescript"],
        "open_url": ["browser_task", "run_applescript"],
        "file_operation": ["run_script", "run_applescript"],
        "window_control": ["run_applescript"],
        "keyboard_action": ["run_applescript"],
        "find_files": ["run_script"],
        "browser_task": ["run_script"],
        "search_web": ["browser_task"],
        "create_calendar_event": ["run_applescript"],
        "query_calendar_events": ["run_applescript"],
    ]

    private static let errorPatterns: [(pattern: String, strategy: RecoveryStrategy, guidance: String)] = [
        ("not allowed", .permissionFix,
         "This tool needs additional permissions. Try using run_applescript as an alternative, or use a different approach."),
        ("permission denied", .permissionFix,
         "Permission denied. Try using run_applescript or run_script with appropriate privileges."),
        ("not authorized", .permissionFix,
         "Authorization required. Use an alternative tool or approach."),
        ("application not found", .alternativeTool,
         "The application wasn't found. Check the exact app name or use a different approach."),
        ("not running", .alternativeTool,
         "The app isn't running. Launch it first with launch_app, then retry."),
        ("connection invalid", .prerequisite,
         "The target app needs to be running first. Use launch_app to start it."),
        ("no such file", .fixParameters,
         "File not found at the specified path. Use find_files to locate it first."),
        ("file exists", .fixParameters,
         "A file already exists at that location. Use a different name or path."),
        ("directory not found", .fixParameters,
         "Directory doesn't exist. Create it first with file_operation action=create_folder."),
        ("network error", .retry,
         "Network issue. Retry the request."),
        ("timeout", .retry,
         "Request timed out. Retry or try a simpler request."),
        ("rate limit", .retry,
         "Rate limited. Wait a moment and retry."),
        ("invalid argument", .fixParameters,
         "Invalid arguments. Check the parameter format and try again."),
        ("missing required", .fixParameters,
         "Missing required parameter. Check the tool's requirements."),
        ("no calendar access", .permissionFix,
         "Calendar access not granted. Use run_applescript with Calendar tell block instead."),
        ("chrome not installed", .alternativeTool,
         "Chrome not available. Use Safari via run_applescript or open_url instead."),
        ("browser session", .prerequisite,
         "Browser session expired or not started. Initialize a new browser_task session."),
    ]

    // MARK: - Hooks

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        var errors = ctx.storage[Self.errorsKey] as? [ErrorRecord] ?? []
        var failedTools = ctx.storage[Self.failedToolsKey] as? Set<String> ?? []
        var recoveryMessages: [ChatMessage] = []

        for result in results where result.result.hasPrefix("Error") {
            let errorMsg = result.result
            let strategy = analyzeError(toolName: result.toolName, error: errorMsg)

            errors.append(ErrorRecord(
                toolName: result.toolName,
                errorMessage: String(errorMsg.prefix(300)),
                iteration: ctx.iteration,
                strategy: strategy.strategy
            ))
            failedTools.insert(result.toolName)

            var guidance = "[Error Recovery] \(result.toolName) failed: \(String(errorMsg.prefix(150)))\n"
            guidance += "Suggestion: \(strategy.guidance)\n"

            if let alternatives = Self.alternatives[result.toolName], !alternatives.isEmpty {
                let available = alternatives.filter { !failedTools.contains($0) }
                if !available.isEmpty {
                    guidance += "Alternative tools: \(available.joined(separator: ", "))\n"
                }
            }

            if errors.count <= 3 {
                recoveryMessages.append(ChatMessage(role: "user", content: guidance))
            }

            print("[ErrorRecovery] \(result.toolName) failed — strategy: \(strategy.strategy.rawValue)")
        }

        ctx.storage[Self.errorsKey] = errors
        ctx.storage[Self.failedToolsKey] = failedTools

        if !recoveryMessages.isEmpty {
            return .injectMessages(recoveryMessages)
        }

        return .continue
    }

    // MARK: - Error Analysis

    private func analyzeError(toolName: String, error: String) -> (strategy: RecoveryStrategy, guidance: String) {
        let lower = error.lowercased()

        for pattern in Self.errorPatterns {
            if lower.contains(pattern.pattern) {
                return (pattern.strategy, pattern.guidance)
            }
        }

        if Self.alternatives[toolName] != nil {
            return (.alternativeTool, "This tool failed. Try one of the alternative tools available for this task.")
        }

        return (.escalate, "This tool encountered an unexpected error. Try a completely different approach to accomplish the same goal.")
    }

    // MARK: - Public API

    public static func sessionErrors(from storage: [String: Any]) -> [ErrorRecord] {
        storage[errorsKey] as? [ErrorRecord] ?? []
    }

    public static func hasToolFailed(_ toolName: String, in storage: [String: Any]) -> Bool {
        (storage[failedToolsKey] as? Set<String>)?.contains(toolName) ?? false
    }
}
