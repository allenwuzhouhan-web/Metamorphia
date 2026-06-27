import Foundation
import MetamorphiaAgentKit

/// General-purpose AppleScript tool. The single primitive that replaces ~50 thin-
/// wrapper AppleScript tools — the LLM writes the AppleScript directly instead
/// of calling specialized wrappers.
///
/// In Executer's CLAUDE.md this is documented as the foundational tool for
/// macOS automation: app control (Music, Safari, Finder), system settings
/// (volume, brightness, dark mode, Wi-Fi, Bluetooth, DND), power (lock, sleep,
/// shutdown), notifications, and speech.
public struct RunAppleScriptTool: ToolDefinition {
    public let name = "run_applescript"
    public let description = "Execute an AppleScript expression. Use for macOS automation: controlling apps (Music, Safari, Finder, System Events), system settings (volume, brightness, dark mode, Wi-Fi, Bluetooth, DND), power management (lock, sleep, shutdown, restart), notifications, and speech. Returns the script's result string."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "script": JSONSchema.string(description: "The AppleScript source code to execute. Use 'tell application \"X\" to ...' for app control. For system settings, use 'tell application \"System Events\"'."),
        ], required: ["script"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let script = try requiredString("script", from: args)
        return try await AppleScriptRunner.runThrowing(script)
    }
}

/// Lightweight shell-command tool. Wraps `ShellRunner` for the common case.
public struct RunShellCommandTool: ToolDefinition {
    public let name = "run_shell_command"
    public let description = "Execute a shell command via /bin/zsh. Use for system queries (df, ps, ls, find), file operations, and tool invocations (brew, npm, python). Returns combined stdout+stderr."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "command": JSONSchema.string(description: "The shell command to execute"),
            "timeout_seconds": JSONSchema.integer(
                description: "Max seconds to wait before terminating (default 30)",
                minimum: 1, maximum: 600
            ),
        ], required: ["command"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let command = try requiredString("command", from: args)
        let timeout = TimeInterval(optionalInt("timeout_seconds", from: args) ?? 30)

        let result = try ShellRunner.run(command, timeout: timeout)
        if result.exitCode != 0 {
            return "Error: command exited with code \(result.exitCode)\n\(result.stdout)"
        }
        return result.stdout
    }
}
