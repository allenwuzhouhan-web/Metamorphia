import Foundation
import AppKit
import MetamorphiaAgentKit

/// Launch or activate an app by name or bundle id. Preferred over AppleScript
/// `tell application "X" to activate` when you just want to bring something
/// forward.
public struct OpenAppTool: ToolDefinition {
    public let name = "open_app"
    public let description = "Launch or activate an app by name (\"Safari\") or bundle id (\"com.apple.Safari\"). Works for GUI apps. Returns success or the failure reason."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "name": JSONSchema.string(description: "App name as shown in /Applications, or a bundle id."),
            "url": JSONSchema.string(description: "Optional URL or file path to open with the app."),
            "activate": JSONSchema.boolean(description: "Bring the app to the foreground (default true)."),
        ], required: ["name"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let name = try requiredString("name", from: args)
        let urlString = optionalString("url", from: args)
        let activate = optionalBool("activate", from: args) ?? true

        // Use `/usr/bin/open` — it handles both bundle ids (`-b`) and app
        // display names (`-a`) without us having to emulate Launch Services
        // lookups. `-g` suppresses the activation flag.
        var argv: [String] = []
        if !activate { argv.append("-g") }
        if name.contains(".") && !name.hasSuffix(".app") {
            argv.append(contentsOf: ["-b", name])
        } else {
            argv.append(contentsOf: ["-a", name])
        }
        if let urlString {
            let target: String
            if urlString.hasPrefix("~") {
                target = (urlString as NSString).expandingTildeInPath
            } else {
                target = urlString
            }
            argv.append(target)
        }

        let result = try await AsyncShellRunner.run(
            executable: "/usr/bin/open",
            arguments: argv,
            timeout: 30
        )
        if result.exitCode != 0 {
            let err = result.stderr.isEmpty ? result.stdout : result.stderr
            return "Error: open exited \(result.exitCode). \(err)"
        }
        if let urlString {
            return "Opened \(urlString) in \(name)."
        }
        return activate ? "Activated \(name)." : "Launched \(name) in background."
    }
}

/// Quit an app by name. Falls back to AppleScript `quit` — which respects
/// unsaved-changes dialogs.
public struct QuitAppTool: ToolDefinition {
    public let name = "quit_app"
    public let description = "Quit a running app by name. Uses AppleScript `quit` so the app can prompt about unsaved changes. Pass `force=true` to SIGKILL instead."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "name": JSONSchema.string(description: "App name, e.g. \"Safari\"."),
            "force": JSONSchema.boolean(description: "Force-quit via SIGKILL (default false). Skips unsaved-changes dialogs."),
        ], required: ["name"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let name = try requiredString("name", from: args)
        let force = optionalBool("force", from: args) ?? false

        if force {
            // pkill matches on the process name.
            let result = try ShellRunner.run("pkill -KILL -x \(shellEscape(name)) || pkill -KILL -f \(shellEscape(name))", timeout: 5)
            if result.exitCode == 0 {
                return "Force-quit '\(name)'."
            }
            return "pkill exited \(result.exitCode) — '\(name)' may not be running."
        }

        let script = "tell application \"\(AppleScriptRunner.escape(name))\" to quit"
        do {
            _ = try AppleScriptRunner.runThrowing(script)
            return "Asked '\(name)' to quit."
        } catch {
            return "Error quitting '\(name)': \(error.localizedDescription)"
        }
    }

    private func shellEscape(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
