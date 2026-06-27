import Foundation
import AppKit

/// Wrapper around `NSAppleScript`. macOS-only (uses AppKit), which is fine
/// because `MetamorphiaExecutors` is the AppKit-allowed framework — the package is
/// imported by the Metamorphia app target, never by `MetamorphiaAgentKit` itself.
public enum AppleScriptRunner {
    /// Escapes a string for safe interpolation into AppleScript double-quoted strings.
    public static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs an AppleScript expression and returns the result string, or nil on failure.
    /// `NSAppleScript` must execute on the main thread, so the work is marshalled
    /// onto the main actor.
    @discardableResult
    public static func run(_ source: String) async -> String? {
        await MainActor.run {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            if let error = error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                print("[AppleScript Error] \(message)")
                return nil
            }
            return result?.stringValue
        }
    }

    /// Runs an AppleScript expression, throwing on error.
    /// `NSAppleScript` must execute on the main thread, so the work is marshalled
    /// onto the main actor.
    public static func runThrowing(_ source: String) async throws -> String {
        try await MainActor.run {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            if let error = error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                throw ExecutorRunnerError.appleScriptFailed(message)
            }
            if let value = result?.stringValue, !value.isEmpty {
                return value
            }
            return "ok (script executed with no return value)"
        }
    }
}

public enum ExecutorRunnerError: LocalizedError {
    case appleScriptFailed(String)
    case shellFailed(exitCode: Int32, stderr: String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let msg): return "AppleScript error: \(msg)"
        case .shellFailed(let code, let stderr): return "Shell command exited \(code): \(stderr)"
        case .timedOut: return "Command timed out"
        }
    }
}
