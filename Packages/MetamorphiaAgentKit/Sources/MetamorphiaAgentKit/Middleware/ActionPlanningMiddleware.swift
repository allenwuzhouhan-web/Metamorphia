import Foundation

/// Before executing complex requests, generates a visible step-by-step plan
/// that the LLM follows. Tracks plan progress as tools execute, marking steps
/// as completed. The plan is injected into context so the LLM stays on track
/// even after context pruning.
public final class ActionPlanningMiddleware: AgentMiddleware {
    public let name = "ActionPlanning"

    public init() {}

    // MARK: - Storage Keys

    private static let planKey = "ActionPlanning.plan"
    private static let progressKey = "ActionPlanning.progress"

    // MARK: - Plan Model

    public struct ExecutionPlan: Codable, Sendable {
        public var steps: [PlanStep]
        public let createdAt: Date
        public var currentStepIndex: Int

        public struct PlanStep: Codable, Sendable {
            public let description: String
            public let expectedTools: [String]
            public var status: StepStatus
            public var result: String?

            public enum StepStatus: String, Codable, Sendable {
                case pending
                case inProgress
                case completed
                case failed
                case skipped
            }
        }

        public var isComplete: Bool {
            steps.allSatisfy { $0.status == .completed || $0.status == .skipped }
        }

        public var completedCount: Int {
            steps.filter { $0.status == .completed }.count
        }

        public func promptSection() -> String {
            var lines = ["## Execution Plan"]
            for (i, step) in steps.enumerated() {
                let marker: String
                switch step.status {
                case .pending: marker = "[ ]"
                case .inProgress: marker = "[>]"
                case .completed: marker = "[x]"
                case .failed: marker = "[!]"
                case .skipped: marker = "[-]"
                }
                lines.append("\(marker) Step \(i + 1): \(step.description)")
                if let result = step.result {
                    lines.append("    Result: \(String(result.prefix(100)))")
                }
            }
            lines.append("Progress: \(completedCount)/\(steps.count) steps")
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Hooks

    public func beforeModelCall(_ ctx: MiddlewareContext) -> MiddlewareSignal {
        if ctx.iteration == 0 {
            let plan = generatePlan(for: ctx.command)
            if let plan = plan {
                ctx.storage[Self.planKey] = plan
                print("[ActionPlanning] Generated \(plan.steps.count)-step plan")
            }
            return .continue
        }

        guard let plan = ctx.storage[Self.planKey] as? ExecutionPlan else {
            return .continue
        }

        let section = plan.promptSection()
        let planMessage = ChatMessage(
            role: "user",
            content: "[PLAN STATUS]\n\(section)\n\nContinue with the next pending step."
        )

        if let lastUserIdx = ctx.messages.lastIndex(where: { $0.role == "user" }) {
            ctx.messages.insert(planMessage, at: lastUserIdx)
        }

        return .continue
    }

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        guard var plan = ctx.storage[Self.planKey] as? ExecutionPlan else {
            return .continue
        }

        let toolNames = Set(toolCalls.map { $0.function.name })
        let hasError = results.contains { $0.result.hasPrefix("Error") }

        if plan.currentStepIndex < plan.steps.count {
            var step = plan.steps[plan.currentStepIndex]

            let stepToolsUsed = !step.expectedTools.isEmpty
                ? step.expectedTools.contains(where: { toolNames.contains($0) })
                : true

            if stepToolsUsed {
                if hasError {
                    step.status = .failed
                    step.result = results.first(where: { $0.result.hasPrefix("Error") })?.result
                } else {
                    step.status = .completed
                    step.result = results.first.map { String($0.result.prefix(200)) }
                }
                plan.steps[plan.currentStepIndex] = step

                plan.currentStepIndex = plan.steps.firstIndex(where: { $0.status == .pending }) ?? plan.steps.count
                if plan.currentStepIndex < plan.steps.count {
                    plan.steps[plan.currentStepIndex].status = .inProgress
                }
            }
        }

        ctx.storage[Self.planKey] = plan
        return .continue
    }

    // MARK: - Plan Generation

    private func generatePlan(for command: String) -> ExecutionPlan? {
        let lower = command.lowercased()

        let conjunctions = [" and ", " then ", " after that ", " also ", " plus "]
        let hasMultipleSteps = conjunctions.contains(where: { lower.contains($0) })
        let isLongCommand = lower.count > 80

        guard hasMultipleSteps || isLongCommand else { return nil }

        var steps: [ExecutionPlan.PlanStep] = []

        var segments = [command]
        for conj in [" and then ", " then ", " and also ", " after that ", " also ", " and "] {
            segments = segments.flatMap { seg in
                seg.components(separatedBy: conj).map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }

        segments = segments.filter { !$0.isEmpty }

        if segments.count < 2 {
            segments = command.components(separatedBy: ". ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        guard segments.count >= 2 else { return nil }

        for segment in segments {
            let expectedTools = inferTools(for: segment)
            steps.append(ExecutionPlan.PlanStep(
                description: String(segment.prefix(200)),
                expectedTools: expectedTools,
                status: .pending,
                result: nil
            ))
        }

        if !steps.isEmpty {
            steps[0].status = .inProgress
        }

        return ExecutionPlan(
            steps: steps,
            createdAt: Date(),
            currentStepIndex: 0
        )
    }

    private func inferTools(for segment: String) -> [String] {
        let lower = segment.lowercased()
        var tools: [String] = []

        let toolHints: [(keywords: [String], tool: String)] = [
            (["open ", "launch ", "start "], "launch_app"),
            (["email", "mail"], "run_applescript"),
            (["calendar", "event", "meeting", "schedule"], "query_calendar_events"),
            (["file", "move", "copy", "rename", "delete", "trash"], "file_operation"),
            (["search", "google", "look up", "find online"], "search_web"),
            (["browse", "website", "web page"], "browser_task"),
            (["window", "fullscreen", "resize", "tile"], "window_control"),
            (["click", "press", "type"], "keyboard_action"),
            (["screenshot", "capture", "screen"], "capture_screen"),
            (["notion"], "notion_search"),
            (["music", "play", "song", "spotify"], "run_applescript"),
            (["create presentation", "ppt", "slides"], "create_presentation"),
            (["video", "ffmpeg"], "create_video"),
            (["reminder", "remind"], "run_applescript"),
        ]

        for hint in toolHints {
            if hint.keywords.contains(where: { lower.contains($0) }) {
                tools.append(hint.tool)
            }
        }

        return tools
    }

    // MARK: - Public API

    public static func currentPlan(from storage: [String: Any]) -> ExecutionPlan? {
        storage[planKey] as? ExecutionPlan
    }
}

// MARK: - Plan Status Tool

/// LLM-callable tool to check the current execution plan status.
public struct PlanStatusTool: ToolDefinition {
    public let name = "plan_status"
    public let description = "Check the current execution plan status. Shows which steps are completed, in progress, or pending. Use this to understand where you are in a multi-step task."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    public var storageProvider: (@Sendable () -> [String: Any])?

    public init(storageProvider: (@Sendable () -> [String: Any])? = nil) {
        self.storageProvider = storageProvider
    }

    public func execute(arguments: String) async throws -> String {
        guard let storage = storageProvider?(),
              let plan = ActionPlanningMiddleware.currentPlan(from: storage) else {
            return "No execution plan is active for the current task."
        }

        return plan.promptSection()
    }
}
