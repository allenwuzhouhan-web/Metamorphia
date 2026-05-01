import Foundation

/// When multiple independent tools are requested, identifies which ones can run
/// in parallel vs. which have data dependencies that require sequential execution.
/// Builds a mini dependency DAG per iteration and groups tools into waves.
public final class ParallelExecutionPlanner: AgentMiddleware {
    public let name = "ParallelExecution"

    public init() {}

    // MARK: - Storage Keys

    private static let statsKey = "ParallelExec.stats"
    private static let suggestionsKey = "ParallelExec.suggestions"

    // MARK: - Statistics

    public struct ExecutionStats {
        public var totalToolCalls: Int = 0
        public var parallelBatches: Int = 0
        public var sequentialCalls: Int = 0
        public var estimatedTimeSaved: Double = 0  // seconds
        public var waveHistory: [[String]] = []

        public var parallelizationRate: Double {
            guard totalToolCalls > 0 else { return 0 }
            return Double(totalToolCalls - sequentialCalls) / Double(totalToolCalls)
        }

        public init() {}
    }

    // MARK: - Dependency Analysis

    public struct ExecutionPlan {
        public let waves: [[Int]]
        public let dependencies: [(from: Int, to: Int)]
        public let parallelizable: Bool

        public var waveCount: Int { waves.count }
    }

    // MARK: - Hooks

    public func afterModelCall(_ ctx: MiddlewareContext, response: LLMResponse) -> MiddlewareSignal {
        guard let toolCalls = response.toolCalls, toolCalls.count > 1 else {
            return .continue
        }

        let plan = analyzeParallelism(toolCalls)

        if plan.parallelizable && plan.waveCount < toolCalls.count {
            ctx.storage["ParallelExec.currentPlan"] = plan

            let waveDescs = plan.waves.map { wave in
                wave.map { toolCalls[$0].function.name }.joined(separator: " + ")
            }
            print("[ParallelExec] Planned \(plan.waveCount) waves: \(waveDescs.joined(separator: " -> "))")
        }

        return .continue
    }

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        var stats = ctx.storage[Self.statsKey] as? ExecutionStats ?? ExecutionStats()

        stats.totalToolCalls += toolCalls.count

        if toolCalls.count > 1 {
            stats.parallelBatches += 1
            stats.waveHistory.append(toolCalls.map { $0.function.name })
            stats.estimatedTimeSaved += Double(toolCalls.count - 1) * 1.0
        } else {
            stats.sequentialCalls += 1
        }

        if ctx.iteration > 0 && stats.sequentialCalls > 3 {
            let suggestion = checkForMissedParallelism(ctx: ctx, stats: stats)
            if let suggestion = suggestion {
                ctx.storage[Self.suggestionsKey] = suggestion
            }
        }

        ctx.storage[Self.statsKey] = stats
        return .continue
    }

    // MARK: - Parallelism Analysis

    public func analyzeParallelism(_ toolCalls: [ToolCall]) -> ExecutionPlan {
        let count = toolCalls.count
        var dependencies: [(from: Int, to: Int)] = []

        for i in 0..<count {
            for j in (i+1)..<count {
                if hasDependency(toolCalls[i], toolCalls[j]) {
                    dependencies.append((from: i, to: j))
                }
            }
        }

        var inDegree = Array(repeating: 0, count: count)
        var adjacency = Array(repeating: [Int](), count: count)

        for dep in dependencies {
            adjacency[dep.from].append(dep.to)
            inDegree[dep.to] += 1
        }

        var waves: [[Int]] = []
        var remaining = Set(0..<count)

        while !remaining.isEmpty {
            let ready = remaining.filter { inDegree[$0] == 0 }
            if ready.isEmpty {
                waves.append(Array(remaining))
                break
            }

            waves.append(Array(ready).sorted())

            for node in ready {
                remaining.remove(node)
                for neighbor in adjacency[node] {
                    inDegree[neighbor] -= 1
                }
            }
        }

        let parallelizable = waves.contains { $0.count > 1 }
        return ExecutionPlan(waves: waves, dependencies: dependencies, parallelizable: parallelizable)
    }

    // MARK: - Dependency Detection

    private func hasDependency(_ a: ToolCall, _ b: ToolCall) -> Bool {
        let aName = a.function.name
        let bName = b.function.name
        let bArgs = b.function.arguments.lowercased()

        let uiTools: Set<String> = [
            "click", "click_element", "click_ref", "type_text", "press_key",
            "hotkey", "scroll", "drag", "move_cursor", "launch_app",
        ]
        if uiTools.contains(aName) && uiTools.contains(bName) {
            return true
        }

        if sameApp(a, b) {
            return true
        }

        let outputTypes: [String: [String]] = [
            "find_files": ["path", "file_path", "file"],
            "search_web": ["url", "link"],
            "notion_search": ["page_id", "database_id"],
            "query_calendar_events": ["event_id"],
            "capture_screen": ["image", "screenshot"],
            "ffmpeg_probe": ["duration", "codec"],
        ]

        if let aOutputKeys = outputTypes[aName] {
            for key in aOutputKeys where bArgs.contains(key) {
                return true
            }
        }

        let staticDeps: [String: Set<String>] = [
            "notion_update_page": ["notion_search", "notion_read_page"],
            "notion_append_blocks": ["notion_search"],
            "create_calendar_event": ["query_calendar_events"],
            "ffmpeg_edit_video": ["ffmpeg_probe"],
            "browser_task": ["search_web"],
        ]
        if let deps = staticDeps[bName], deps.contains(aName) {
            return true
        }

        return false
    }

    private func sameApp(_ a: ToolCall, _ b: ToolCall) -> Bool {
        func extractApp(_ args: String) -> String? {
            guard let data = args.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return dict["app_name"] as? String ?? dict["app"] as? String
        }

        if let appA = extractApp(a.function.arguments),
           let appB = extractApp(b.function.arguments) {
            return appA.lowercased() == appB.lowercased()
        }
        return false
    }

    // MARK: - Missed Parallelism Detection

    private func checkForMissedParallelism(ctx: MiddlewareContext, stats: ExecutionStats) -> String? {
        let recentWaves = stats.waveHistory.suffix(5)

        let singleWaves = recentWaves.filter { $0.count == 1 }
        if singleWaves.count >= 3 {
            return "Consider calling multiple independent tools in a single response for faster execution."
        }

        return nil
    }

    // MARK: - Public API

    public static func executionStats(from storage: [String: Any]) -> ExecutionStats? {
        storage[statsKey] as? ExecutionStats
    }

    public static func suggestions(from storage: [String: Any]) -> String? {
        storage[suggestionsKey] as? String
    }
}

// MARK: - Execution Stats Tool

/// LLM-callable tool that reports parallel execution statistics for the current session.
public struct ExecutionStatsTool: ToolDefinition {
    public let name = "execution_stats"
    public let description = "Get execution performance statistics for the current session. Shows how many tools ran in parallel vs. sequentially, estimated time saved, and optimization suggestions."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    public var storageProvider: (@Sendable () -> [String: Any])?

    public init(storageProvider: (@Sendable () -> [String: Any])? = nil) {
        self.storageProvider = storageProvider
    }

    public func execute(arguments: String) async throws -> String {
        guard let storage = storageProvider?() else {
            return "No execution statistics available yet."
        }

        guard let stats = ParallelExecutionPlanner.executionStats(from: storage) else {
            return "No tools have been executed in this session yet."
        }

        var result = "Execution Statistics:\n\n"
        result += "Total tool calls: \(stats.totalToolCalls)\n"
        result += "Parallel batches: \(stats.parallelBatches)\n"
        result += "Sequential calls: \(stats.sequentialCalls)\n"
        result += "Parallelization rate: \(String(format: "%.0f%%", stats.parallelizationRate * 100))\n"
        result += "Estimated time saved: \(String(format: "%.1f", stats.estimatedTimeSaved))s\n"

        if !stats.waveHistory.isEmpty {
            result += "\nRecent execution waves:\n"
            for (i, wave) in stats.waveHistory.suffix(5).enumerated() {
                result += "  Wave \(i + 1): \(wave.joined(separator: " + "))\n"
            }
        }

        if let suggestion = ParallelExecutionPlanner.suggestions(from: storage) {
            result += "\nSuggestion: \(suggestion)"
        }

        return result
    }
}
