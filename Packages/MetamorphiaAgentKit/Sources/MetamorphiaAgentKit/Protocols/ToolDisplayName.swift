import Foundation

/// A lookup registry mapping internal tool names (e.g., `run_applescript`)
/// to human-friendly display names (e.g., `Running AppleScript`).
///
/// Replaces Executer's `AgentLoop.friendlyNames` static dict. The app target
/// registers mappings at startup; middleware (e.g., `StreamingProgressMiddleware`)
/// reads via `ToolDisplayName.friendly(for:)`.
public enum ToolDisplayName {
    private static var registry: [String: String] = [:]
    private static let lock = NSLock()

    /// Register a single mapping.
    public static func register(_ toolName: String, friendly: String) {
        lock.lock(); defer { lock.unlock() }
        registry[toolName] = friendly
    }

    /// Register many mappings in one call.
    public static func register(_ mappings: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in mappings { registry[k] = v }
    }

    /// Get the friendly name for a tool, or `nil` if none registered.
    public static func friendly(for toolName: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return registry[toolName]
    }

    /// Get the friendly name or fall back to the raw tool name.
    public static func display(_ toolName: String) -> String {
        friendly(for: toolName) ?? toolName
    }

    /// Remove all registered mappings (used in tests).
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        registry.removeAll()
    }
}
