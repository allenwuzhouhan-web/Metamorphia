import Foundation

/// Synchronous shell runner with pipe-safe output capture and timeout.
///
/// CRITICAL: reads stdout/stderr BEFORE `waitUntilExit()` to avoid deadlock when
/// the combined output exceeds the ~64KB pipe buffer. Calling `waitUntilExit()`
/// first while the process is blocked writing to a full pipe = livelock.
public enum ShellRunner {
    public struct Output: Sendable {
        public let stdout: String
        public let exitCode: Int32

        public init(stdout: String, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    /// Run a shell command via `/bin/zsh -c`. Times out after `timeout` seconds.
    public static func run(_ command: String, timeout: TimeInterval = 30) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let timeoutWork = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()

        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 && !errorOutput.isEmpty {
            let combined = output.isEmpty ? errorOutput : "\(output)\n\(errorOutput)"
            return Output(stdout: combined, exitCode: process.terminationStatus)
        }

        return Output(stdout: output, exitCode: process.terminationStatus)
    }
}

/// Async shell runner with proper pipe handling and SIGTERM timeout.
public enum AsyncShellRunner {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let timedOut: Bool

        public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
            self.timedOut = timedOut
        }
    }

    /// Run an executable asynchronously. Pipe-safe (reads pipes before waitUntilExit).
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: Int = 60
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var env = ProcessInfo.processInfo.environment
                if let extra = environment {
                    env.merge(extra) { _, new in new }
                }
                process.environment = env

                if let dir = workingDirectory {
                    let expanded = NSString(string: dir).expandingTildeInPath
                    process.currentDirectoryURL = URL(fileURLWithPath: expanded)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                var didTimeOut = false
                let timeoutWork = DispatchWorkItem {
                    if process.isRunning {
                        didTimeOut = true
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWork)

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeoutWork.cancel()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                continuation.resume(returning: Result(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus,
                    timedOut: didTimeOut
                ))
            }
        }
    }
}
