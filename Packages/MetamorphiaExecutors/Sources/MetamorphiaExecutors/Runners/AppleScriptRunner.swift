import Foundation
import AppKit

/// Wrapper around `NSAppleScript`. macOS-only (uses AppKit), which is fine
/// because `MetamorphiaExecutors` is the AppKit-allowed framework — the package is
/// imported by the Metamorphia app target, never by `MetamorphiaAgentKit` itself.
public enum AppleScriptRunner {
    /// Dedicated serial queue for NSAppleScript. Apple Events block the calling
    /// thread until the target app replies, so they must never run on the main
    /// thread (UI hang); a single serial queue also keeps NSAppleScript off
    /// arbitrary concurrent pool threads.
    private static let queue = DispatchQueue(label: "com.metamorphia.executors.applescript")

    /// Escapes a string for safe interpolation into AppleScript double-quoted strings.
    public static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs an AppleScript expression and returns the result string, or nil on failure.
    @discardableResult
    public static func run(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let script = NSAppleScript(source: source)
                var error: NSDictionary?
                let result = script?.executeAndReturnError(&error)
                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    print("[AppleScript Error] \(message)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result?.stringValue)
            }
        }
    }

    /// Runs an AppleScript expression, throwing on error.
    public static func runThrowing(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let script = NSAppleScript(source: source)
                var error: NSDictionary?
                let result = script?.executeAndReturnError(&error)
                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: ExecutorRunnerError.appleScriptFailed(message))
                    return
                }
                if let value = result?.stringValue, !value.isEmpty {
                    continuation.resume(returning: value)
                    return
                }
                continuation.resume(returning: "ok (script executed with no return value)")
            }
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
