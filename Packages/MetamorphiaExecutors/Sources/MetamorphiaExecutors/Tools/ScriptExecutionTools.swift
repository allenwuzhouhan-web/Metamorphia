import Foundation
import MetamorphiaAgentKit

/// Helpers shared by `run_python` / `run_node` / `run_ruby`.
///
/// Every runner writes the user-provided source to a UUID-named file in the
/// system temp directory, then exec's the interpreter with that path as an
/// argument. This avoids shell escaping entirely — the source can contain
/// quotes, backticks, heredocs, anything.
enum ScriptExecution {
    /// Formats an AsyncShellRunner result into the string returned to the LLM.
    /// Separates stdout/stderr and always includes the exit code; if the
    /// process timed out, that's surfaced prominently.
    static func formatResult(_ result: AsyncShellRunner.Result, interpreter: String) -> String {
        if result.timedOut {
            var out = "\(interpreter) timed out.\n"
            if !result.stdout.isEmpty { out += "\nstdout:\n\(result.stdout)\n" }
            if !result.stderr.isEmpty { out += "\nstderr:\n\(result.stderr)" }
            return out
        }
        if result.exitCode == 0 {
            return result.stdout.isEmpty ? "(no output; exit 0)" : result.stdout
        }
        var out = "exit \(result.exitCode)"
        if !result.stdout.isEmpty { out += "\n\nstdout:\n\(result.stdout)" }
        if !result.stderr.isEmpty { out += "\n\nstderr:\n\(result.stderr)" }
        return out
    }

    /// Write `source` to a UUID-named temp file with the given extension and
    /// return the path. Caller is responsible for deleting (or leaving in temp,
    /// which macOS GCs periodically).
    static func writeTempScript(source: String, extension ext: String) throws -> String {
        let fileName = "metamorphia-\(UUID().uuidString).\(ext)"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(fileName)
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Resolve an interpreter path — either the user-supplied absolute path,
    /// or a `which`-lookup fallback. Returns `nil` if nothing is found.
    static func resolveInterpreter(preferred: String?, fallback: String) -> String {
        if let preferred, !preferred.isEmpty { return preferred }
        // Common macOS locations, checked in order.
        let candidates = [
            "/opt/homebrew/bin/\(fallback)",          // Apple Silicon Homebrew
            "/usr/local/bin/\(fallback)",             // Intel Homebrew
            "/usr/bin/\(fallback)",                   // System (python3, ruby on macOS)
            "/run/current-system/sw/bin/\(fallback)", // nix-darwin
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: invoke via /usr/bin/env so PATH kicks in.
        return fallback
    }

    /// Shared execute implementation — write source, exec interpreter, format result.
    static func execute(
        args: [String: Any],
        extension ext: String,
        interpreterName: String,
        interpreterFallback: String,
        extraArgs: [String] = []
    ) async throws -> String {
        guard let source = args["code"] as? String, !source.isEmpty else {
            throw MetamorphiaError.invalidArguments("Missing required parameter: code")
        }
        let scriptPath = try writeTempScript(source: source, extension: ext)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        let interpreter = resolveInterpreter(preferred: args["interpreter"] as? String, fallback: interpreterFallback)
        let timeout = (args["timeout_seconds"] as? Int) ?? 60
        let cwd = (args["working_directory"] as? String).map { ($0 as NSString).expandingTildeInPath }

        var env: [String: String]?
        if let extra = args["env"] as? [String: String] {
            env = extra
        }

        // Launch via /usr/bin/env when the resolved path is bare (no "/"), so
        // PATH resolution still works.
        let executable: String
        let executableArgs: [String]
        if interpreter.contains("/") {
            executable = interpreter
            executableArgs = extraArgs + [scriptPath]
        } else {
            executable = "/usr/bin/env"
            executableArgs = [interpreter] + extraArgs + [scriptPath]
        }

        let result = try await AsyncShellRunner.run(
            executable: executable,
            arguments: executableArgs,
            environment: env,
            workingDirectory: cwd,
            timeout: timeout
        )
        return formatResult(result, interpreter: interpreterName)
    }
}

/// Run a Python script. The source is written to a temp file and executed
/// against `python3` (or a user-specified interpreter).
public struct RunPythonTool: ToolDefinition {
    public let name = "run_python"
    public let description = "Execute a Python 3 script. The `code` is written to a temp file and run with python3. Returns stdout on success, or stdout + stderr + exit code on failure. Use for data processing, API calls, file transforms, anything beyond shell one-liners."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "code": JSONSchema.string(description: "Python source. Can be multi-line; no escaping needed. Include imports at the top."),
            "interpreter": JSONSchema.string(description: "Absolute path to a Python interpreter. Default: auto-detected python3."),
            "working_directory": JSONSchema.string(description: "Directory to run in (supports ~). Default: temp dir."),
            "timeout_seconds": JSONSchema.integer(description: "Kill after N seconds (default 60, max 1800).", minimum: 1, maximum: 1800),
        ], required: ["code"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        return try await ScriptExecution.execute(
            args: args,
            extension: "py",
            interpreterName: "python3",
            interpreterFallback: "python3"
        )
    }
}

/// Run a Node.js script.
public struct RunNodeTool: ToolDefinition {
    public let name = "run_node"
    public let description = "Execute a Node.js (JavaScript) script. The `code` is written to a temp .js file and run with node. Use for JSON transforms, async/await workflows, fetch API calls, anything where Node's stdlib helps."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "code": JSONSchema.string(description: "JavaScript (Node) source. Top-level await works in modern Node."),
            "interpreter": JSONSchema.string(description: "Absolute path to node. Default: auto-detected node."),
            "working_directory": JSONSchema.string(description: "Directory to run in (supports ~)."),
            "timeout_seconds": JSONSchema.integer(description: "Kill after N seconds (default 60, max 1800).", minimum: 1, maximum: 1800),
        ], required: ["code"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        return try await ScriptExecution.execute(
            args: args,
            extension: "mjs",
            interpreterName: "node",
            interpreterFallback: "node"
        )
    }
}

/// Run a Ruby script. macOS ships a `/usr/bin/ruby` but it's an old 2.6 stub;
/// if the user has a Homebrew ruby, we'll find it via the preference order in
/// `ScriptExecution.resolveInterpreter`.
public struct RunRubyTool: ToolDefinition {
    public let name = "run_ruby"
    public let description = "Execute a Ruby script. The `code` is written to a temp .rb file and run with ruby. Handy for text processing, regex-heavy transforms, and anything where Ruby's one-liner style wins."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "code": JSONSchema.string(description: "Ruby source."),
            "interpreter": JSONSchema.string(description: "Absolute path to ruby. Default: auto-detected ruby."),
            "working_directory": JSONSchema.string(description: "Directory to run in (supports ~)."),
            "timeout_seconds": JSONSchema.integer(description: "Kill after N seconds (default 60, max 1800).", minimum: 1, maximum: 1800),
        ], required: ["code"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        return try await ScriptExecution.execute(
            args: args,
            extension: "rb",
            interpreterName: "ruby",
            interpreterFallback: "ruby"
        )
    }
}
