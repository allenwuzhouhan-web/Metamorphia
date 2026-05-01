import Foundation

/// Provides real-time progress events during multi-step tool execution.
/// Instead of waiting for all operations to complete, observers see intermediate
/// steps, reasoning, and partial results as they happen.
///
/// Events flow to an injected ``AgentProgressSink``. The original Executer version
/// posted to `NotificationCenter.default` with `Notification.Name("agentProgressUpdate")`;
/// that coupling is replaced with protocol injection so the package stays AppKit-free.
///
/// Tool display names come from ``ToolDisplayName`` — the app target registers friendly
/// names at startup; the middleware gracefully falls back to the raw tool name if no
/// mapping is registered.
public final class StreamingProgressMiddleware: AgentMiddleware, @unchecked Sendable {
    public let name = "StreamingProgress"

    // MARK: - Storage Keys

    private static let progressKey = "StreamingProgress.events"
    private static let startTimeKey = "StreamingProgress.startTime"

    // MARK: - Sink

    /// Where progress events are published. The app wires in a concrete sink
    /// (e.g., `AICommandViewModel`) when constructing this middleware.
    private let sink: AgentProgressSink

    public init(sink: AgentProgressSink) {
        self.sink = sink
    }

    // MARK: - Observable State

    /// Progress events emitted during the current task.
    public private(set) var currentProgress: [AgentProgressEvent] = []
    public private(set) var isActive: Bool = false
    public private(set) var currentStep: String = ""
    public private(set) var progressFraction: Double = 0.0

    private let lock = NSLock()

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        if ctx.iteration == 0 {
            lock.lock()
            currentProgress = []
            isActive = true
            currentStep = "Understanding request..."
            progressFraction = 0.0
            lock.unlock()

            ctx.storage[Self.startTimeKey] = Date()

            emit(AgentProgressEvent(
                kind: .started,
                message: "Starting: \(String(ctx.command.prefix(100)))",
                progress: 0.0
            ))
        } else {
            lock.lock()
            currentStep = "Thinking... (iteration \(ctx.iteration + 1))"
            lock.unlock()

            emit(AgentProgressEvent(
                kind: .thinking,
                message: "Processing iteration \(ctx.iteration + 1)/\(ctx.maxIterations)",
                progress: Double(ctx.iteration) / Double(ctx.maxIterations)
            ))
        }

        return .continue
    }

    public func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal {
        if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
            let names = toolCalls.map { $0.function.name }
            for name in names {
                let friendlyName = ToolDisplayName.display(name)
                lock.lock()
                currentStep = friendlyName
                lock.unlock()

                emit(AgentProgressEvent(
                    kind: .toolStarted(name: name),
                    message: friendlyName,
                    detail: toolCalls.count > 1 ? "(\(toolCalls.count) tools in batch)" : nil
                ))
            }
        }
        return .continue
    }

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        for result in results {
            let success = !result.result.hasPrefix("Error")
            let friendlyName = ToolDisplayName.display(result.toolName)

            emit(AgentProgressEvent(
                kind: .toolCompleted(name: result.toolName, success: success),
                message: success ? "\(friendlyName) done" : "\(friendlyName) failed",
                detail: success ? nil : String(result.result.prefix(100)),
                progress: Double(ctx.iteration + 1) / Double(ctx.maxIterations)
            ))
        }

        let completedSteps = results.count
        let progress = Double(ctx.iteration + 1) / Double(ctx.maxIterations)

        lock.lock()
        progressFraction = progress
        lock.unlock()

        emit(AgentProgressEvent(
            kind: .milestone(step: ctx.iteration + 1, total: ctx.maxIterations),
            message: "Step \(ctx.iteration + 1)/\(ctx.maxIterations) complete (\(completedSteps) tools executed)",
            progress: progress
        ))

        return .continue
    }

    // MARK: - Event Emission

    private func emit(_ event: AgentProgressEvent) {
        lock.lock()
        currentProgress.append(event)
        if currentProgress.count > 100 {
            currentProgress = Array(currentProgress.suffix(100))
        }
        lock.unlock()

        sink.publish(event)
    }

    /// Mark execution as complete.
    public func markComplete() {
        lock.lock()
        isActive = false
        currentStep = "Done"
        progressFraction = 1.0
        lock.unlock()

        emit(AgentProgressEvent(
            kind: .completed,
            message: "Task completed",
            progress: 1.0
        ))
    }

    /// Mark execution as cancelled by a fresh submission or explicit cancel.
    public func markCancelled() {
        lock.lock()
        isActive = false
        currentStep = "Cancelled"
        lock.unlock()

        emit(AgentProgressEvent(
            kind: .cancelled,
            message: "Task cancelled"
        ))
    }

    /// Reset state for a new execution.
    public func reset() {
        lock.lock()
        currentProgress = []
        isActive = false
        currentStep = ""
        progressFraction = 0.0
        lock.unlock()
    }
}
