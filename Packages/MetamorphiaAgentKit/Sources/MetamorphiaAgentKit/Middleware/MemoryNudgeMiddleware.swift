import Foundation

/// Periodically nudges the agent to reflect on what's worth remembering.
///
/// Inspired by Hermes Agent's memory nudging system — instead of only consolidating
/// when approaching the limit, this middleware proactively asks the LLM to extract
/// durable knowledge from the conversation at regular intervals.
///
/// Triggers:
///   - Every N iterations (default 2) during multi-step tasks
///   - After error recovery (the fix is worth remembering)
///   - When user provides corrections (highest-value learning signal)
///
/// The nudge injects a reflection prompt that the LLM responds to by calling
/// the memory tool. This is invisible to the user.
public final class MemoryNudgeMiddleware: AgentMiddleware {
    public let name = "MemoryNudge"

    /// How often to nudge (every N iterations).
    private let nudgeInterval: Int

    public init(nudgeInterval: Int = 2) {
        self.nudgeInterval = nudgeInterval
    }

    private static let lastNudgeKey = "memoryNudge.lastIteration"
    private static let correctionDetectedKey = "memoryNudge.correctionDetected"

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        let iteration = ctx.iteration
        let lastNudge = ctx.storage[Self.lastNudgeKey] as? Int ?? 0
        let correctionDetected = ctx.storage[Self.correctionDetectedKey] as? Bool ?? false

        let shouldNudge: Bool
        if correctionDetected {
            shouldNudge = true
            ctx.storage[Self.correctionDetectedKey] = false
        } else if iteration > 0 && (iteration - lastNudge) >= nudgeInterval {
            shouldNudge = true
        } else {
            shouldNudge = false
        }

        guard shouldNudge else { return .continue }

        ctx.storage[Self.lastNudgeKey] = iteration

        let nudgeMessage = ChatMessage(
            role: "system",
            content: """
            [Memory reflection] Before continuing, briefly consider: has the user revealed any preferences, \
            corrections, or facts worth remembering for future sessions? If so, use the memory tool to save them \
            (category: preference, correction, or fact). If nothing notable, continue with the task.
            """
        )

        ctx.messages.append(nudgeMessage)
        return .continue
    }

    public func afterToolExecution(_ ctx: MiddlewareContext, toolCalls: [ToolCall], results: [ToolResult]) -> MiddlewareSignal {
        for msg in ctx.messages.suffix(3) where msg.role == "user" {
            let lower = msg.content?.lowercased() ?? ""
            let correctionSignals = [
                "no, ", "not that", "wrong", "don't ", "stop ", "actually ",
                "i meant", "that's not", "incorrect", "instead ", "i said",
            ]
            if correctionSignals.contains(where: { lower.contains($0) }) {
                ctx.storage[Self.correctionDetectedKey] = true
                break
            }
        }
        return .continue
    }
}
