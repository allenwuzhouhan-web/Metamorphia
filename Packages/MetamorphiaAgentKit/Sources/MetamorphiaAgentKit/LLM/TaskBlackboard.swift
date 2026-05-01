import Foundation

/// Session-scoped shared state for cross-app task coordination.
///
/// Inspired by UFO's Blackboard pattern — accumulates subtask results, shared data,
/// and context so sub-agents can share information across app boundaries.
///
/// The HostAgent writes the plan and monitors progress. AppAgents read their subtask,
/// write their results, and read shared data from prior steps.
public actor TaskBlackboard {

    // MARK: - Types

    public struct SubTaskEntry: Sendable {
        public let id: String
        public let description: String
        public let targetApp: String?
        public let toolHints: [String]
        public var status: SubTaskStatus
        public var result: String?
        public var sharedData: [String: String]
        public let startTime: Date
        public var endTime: Date?

        public init(
            id: String,
            description: String,
            targetApp: String?,
            toolHints: [String],
            status: SubTaskStatus,
            result: String?,
            sharedData: [String: String],
            startTime: Date,
            endTime: Date?
        ) {
            self.id = id
            self.description = description
            self.targetApp = targetApp
            self.toolHints = toolHints
            self.status = status
            self.result = result
            self.sharedData = sharedData
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    public enum SubTaskStatus: String, Sendable {
        case pending, running, completed, failed
    }

    public struct PlanSnapshot: Sendable {
        public let goal: String
        public let subtasks: [SubTaskEntry]
        public let createdAt: Date
    }

    // MARK: - State

    public private(set) var goal: String = ""
    public private(set) var plan: [SubTaskEntry] = []
    public private(set) var sharedData: [String: String] = [:]
    public private(set) var screenshots: [(app: String, path: String, timestamp: Date)] = []
    public private(set) var trajectory: [(agent: String, action: String, result: String, timestamp: Date)] = []
    private var createdAt = Date()

    public init() {}

    // MARK: - Plan Management

    public func setPlan(
        goal: String,
        subtasks: [(id: String, description: String, targetApp: String?, toolHints: [String])]
    ) {
        self.goal = goal
        self.createdAt = Date()
        self.plan = subtasks.map { st in
            SubTaskEntry(
                id: st.id,
                description: st.description,
                targetApp: st.targetApp,
                toolHints: st.toolHints,
                status: .pending,
                result: nil,
                sharedData: [:],
                startTime: Date(),
                endTime: nil
            )
        }
        self.sharedData = [:]
        self.screenshots = []
        self.trajectory = []
    }

    public func nextPendingSubTask() -> SubTaskEntry? {
        plan.first { $0.status == .pending }
    }

    public func markRunning(id: String) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[idx].status = .running
    }

    public func completeSubTask(id: String, result: String, sharedData: [String: String] = [:]) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[idx].status = .completed
        plan[idx].result = result
        plan[idx].endTime = Date()
        plan[idx].sharedData = sharedData

        for (key, value) in sharedData {
            self.sharedData[key] = value
        }
    }

    public func failSubTask(id: String, reason: String) {
        guard let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[idx].status = .failed
        plan[idx].result = reason
        plan[idx].endTime = Date()
    }

    // MARK: - Shared Data

    public func setSharedData(key: String, value: String) {
        sharedData[key] = value
    }

    public func getSharedData(key: String) -> String? {
        sharedData[key]
    }

    // MARK: - Trajectory (action log)

    public func recordAction(agent: String, action: String, result: String) {
        trajectory.append((agent: agent, action: action, result: result, timestamp: Date()))
        if trajectory.count > 100 {
            trajectory = Array(trajectory.suffix(80))
        }
    }

    public func addScreenshot(app: String, path: String) {
        screenshots.append((app: app, path: path, timestamp: Date()))
        if screenshots.count > 20 {
            screenshots = Array(screenshots.suffix(15))
        }
    }

    // MARK: - Context for LLM Injection

    public func contextForSubTask(id: String) -> String {
        var lines: [String] = []

        lines.append("## Task Context (Blackboard)")
        lines.append("Overall goal: \(goal)")

        let completed = plan.filter { $0.status == .completed }
        if !completed.isEmpty {
            lines.append("\nCompleted steps:")
            for st in completed {
                lines.append("- \(st.description): \(st.result ?? "done")")
            }
        }

        if !sharedData.isEmpty {
            lines.append("\nShared data from prior steps:")
            for (key, value) in sharedData {
                let preview = value.count > 500 ? String(value.prefix(500)) + "..." : value
                lines.append("- \(key): \(preview)")
            }
        }

        if let current = plan.first(where: { $0.id == id }) {
            lines.append("\nYour subtask: \(current.description)")
            if let app = current.targetApp {
                lines.append("Target app: \(app)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Status

    public var isComplete: Bool {
        !plan.isEmpty && plan.allSatisfy { $0.status == .completed || $0.status == .failed }
    }

    public var progress: Double {
        guard !plan.isEmpty else { return 0 }
        let done = plan.filter { $0.status == .completed || $0.status == .failed }.count
        return Double(done) / Double(plan.count)
    }

    public func snapshot() -> PlanSnapshot {
        PlanSnapshot(goal: goal, subtasks: plan, createdAt: createdAt)
    }

    public func reset() {
        goal = ""
        plan = []
        sharedData = [:]
        screenshots = []
        trajectory = []
        createdAt = Date()
    }
}
