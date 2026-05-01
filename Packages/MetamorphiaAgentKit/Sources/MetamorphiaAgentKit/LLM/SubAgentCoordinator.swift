import Foundation

/// HostAgent-style coordinator inspired by Microsoft UFO. Decomposes complex tasks
/// into subtasks, routes each to an `AppAgent` with scoped tools, and uses a
/// `TaskBlackboard` for cross-agent data sharing.
///
/// For sequential tasks (most common): runs subtasks one-by-one so each AppAgent
/// can use results from prior steps via the blackboard.
/// For independent tasks: runs subtasks in parallel.
///
/// Includes Flash-Attention-3-inspired producer-consumer pipelining: while the
/// current wave of tasks executes (consumer), configs for the next wave of ready
/// tasks are pre-built (producer), reducing inter-task setup latency.
public final class SubAgentCoordinator: @unchecked Sendable {

    public struct SubTask: Sendable {
        public let id: String
        public let description: String
        public let targetApp: String?
        public let toolHints: [String]
        public let dependsOn: [String]
        public let hostMessage: String?

        public init(
            id: String,
            description: String,
            targetApp: String?,
            toolHints: [String],
            dependsOn: [String],
            hostMessage: String?
        ) {
            self.id = id
            self.description = description
            self.targetApp = targetApp
            self.toolHints = toolHints
            self.dependsOn = dependsOn
            self.hostMessage = hostMessage
        }
    }

    public struct SubAgentResult: Sendable {
        public let taskId: String
        public let description: String
        public let result: String
        public let success: Bool
    }

    public let blackboard = TaskBlackboard()

    public init() {}

    // MARK: - Decomposition (HostAgent Planning)

    private static let decompositionPrompt = """
    You are a HostAgent that plans multi-step tasks. Analyze this task and decompose it into subtasks.

    For EACH subtask, specify:
    - "id": unique string ID (e.g., "1", "2", "3")
    - "description": what to do (be specific and actionable)
    - "target_app": which macOS app this subtask needs (null if no specific app)
    - "tool_hints": relevant tool categories (e.g., "files", "web", "browser", "documents", "messaging", "terminal")
    - "depends_on": array of subtask IDs that must complete first (empty if independent)
    - "host_message": tips or context for the sub-agent executing this

    Rules:
    - 2-6 subtasks maximum
    - If steps need results from earlier steps, use depends_on to create a chain
    - If steps are independent, leave depends_on empty (they'll run in parallel)
    - Be specific about which app each step targets
    - If the task is too simple to decompose, output: null
    - NEVER add "web" or "browser" tool_hints for creation tasks (video, audio, documents, 3D models). These tools handle everything internally — no web search needed.

    Output ONLY a JSON array or null.
    """

    /// Ask the LLM to decompose the task into routed subtasks.
    public func decompose(
        command: String,
        service: LLMServiceProtocol
    ) async -> [SubTask]? {
        let messages = [
            ChatMessage(role: "system", content: Self.decompositionPrompt),
            ChatMessage(role: "user", content: command)
        ]

        guard let response = try? await service.sendChatRequest(
            messages: messages,
            tools: nil,
            maxTokens: 512
        ), let text = response.text else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null", trimmed.contains("[") else { return nil }

        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]") else { return nil }
        let jsonStr = String(trimmed[start...end])

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let subTasks = array.compactMap { dict -> SubTask? in
            guard let id = dict["id"] as? String,
                  let desc = dict["description"] as? String else { return nil }
            return SubTask(
                id: id,
                description: desc,
                targetApp: dict["target_app"] as? String,
                toolHints: (dict["tool_hints"] as? [String]) ?? [],
                dependsOn: (dict["depends_on"] as? [String]) ?? [],
                hostMessage: dict["host_message"] as? String
            )
        }

        return subTasks.count >= 2 ? subTasks : nil
    }

    // MARK: - Execution

    /// Producer-consumer prefetch queue for pipelining tool inputs.
    private actor PrefetchPipeline {
        private var prefetchedConfigs: [String: AppAgent.Config] = [:]

        func prefetch(task: SubAgentCoordinator.SubTask) {
            let config = AppAgent.Config(
                subtaskId: task.id,
                subtaskDescription: task.description,
                targetApp: task.targetApp,
                toolHints: task.toolHints,
                maxIterations: 8,
                maxTokens: 2048,
                hostMessage: task.hostMessage
            )
            prefetchedConfigs[task.id] = config
        }

        func consume(taskId: String) -> AppAgent.Config? {
            return prefetchedConfigs.removeValue(forKey: taskId)
        }
    }

    private let prefetchPipeline = PrefetchPipeline()

    /// Execute subtasks respecting dependency ordering. Independent subtasks run
    /// in parallel; dependent ones run sequentially. Pre-fetches next-wave configs
    /// while current wave executes (producer-consumer pipelining).
    ///
    /// `progressSink` + `treeSink` are optional — when wired, the coordinator
    /// publishes status/tree events so the notch UI can render the live
    /// Oracle → Scout/Scribe ASCII tree. AgentLoop opens the tree with the
    /// root; this method only adds/updates children.
    public func executeSubAgents(
        subTasks: [SubTask],
        service: LLMServiceProtocol,
        registry: ToolRegistry,
        trace: AgentTrace? = nil,
        progressSink: AgentProgressSink? = nil,
        treeSink: AgentTreeSink? = nil,
        onProgress: @Sendable @escaping (String, Int, Int) async -> Void
    ) async throws -> String {
        let planEntries = subTasks.map { st in
            (id: st.id, description: st.description, targetApp: st.targetApp, toolHints: st.toolHints)
        }
        await blackboard.setPlan(
            goal: subTasks.map(\.description).joined(separator: "; "),
            subtasks: planEntries
        )

        trace?.append(TraceEntry(kind: .hostAgentRouting(
            subtaskCount: subTasks.count,
            apps: subTasks.compactMap(\.targetApp)
        )))

        // Publish every subtask as a pending child of the Oracle root so the
        // UI can render the full branch up-front, then flip nodes to
        // .running/.done as they cycle through.
        for task in subTasks {
            let identity = AgentIdentityRef.from(subAgentType: SubAgentType.infer(from: task.description))
            treeSink?.nodeAdded(
                parentId: nil,
                node: AgentNodeSnapshot(id: task.id, identity: identity, state: .pending)
            )
        }

        var completed = Set<String>()
        var results: [SubAgentResult] = []
        var stepIndex = 0

        let initialReady = subTasks.filter { $0.dependsOn.isEmpty }
        for task in initialReady {
            await prefetchPipeline.prefetch(task: task)
        }

        while completed.count < subTasks.count {
            let ready = subTasks.filter { task in
                !completed.contains(task.id) &&
                task.dependsOn.allSatisfy { completed.contains($0) }
            }

            guard !ready.isEmpty else {
                print("[HostAgent] No ready tasks — possible dependency cycle")
                break
            }

            // Producer: prefetch next wave
            let nextWaveCandidates = subTasks.filter { task in
                !completed.contains(task.id) &&
                !ready.contains(where: { $0.id == task.id }) &&
                task.dependsOn.allSatisfy { dep in
                    completed.contains(dep) || ready.contains(where: { $0.id == dep })
                }
            }
            for task in nextWaveCandidates {
                await prefetchPipeline.prefetch(task: task)
            }

            if ready.count == 1 {
                let task = ready[0]
                stepIndex += 1
                let routeLabel = "Routing: \(task.description.prefix(24))"
                progressSink?.publish(AgentProgressEvent(
                    kind: .status(label: String(routeLabel.prefix(32))),
                    message: routeLabel
                ))
                treeSink?.nodeStateChanged(id: task.id, state: .running, liveStatus: nil)
                await onProgress(task.targetApp ?? task.description, stepIndex, subTasks.count)

                let result = await runAppAgent(
                    task: task,
                    service: service,
                    registry: registry,
                    trace: trace
                )
                results.append(result)
                completed.insert(task.id)
                treeSink?.nodeStateChanged(
                    id: task.id,
                    state: result.success ? .done : .failed,
                    liveStatus: nil
                )
            } else {
                for task in ready {
                    treeSink?.nodeStateChanged(id: task.id, state: .running, liveStatus: nil)
                }
                let batchResults = await withTaskGroup(of: SubAgentResult.self) { group in
                    for task in ready {
                        group.addTask {
                            await self.runAppAgent(
                                task: task,
                                service: service,
                                registry: registry,
                                trace: trace
                            )
                        }
                    }
                    var collected: [SubAgentResult] = []
                    for await result in group {
                        stepIndex += 1
                        await onProgress(result.description, stepIndex, subTasks.count)
                        collected.append(result)
                        treeSink?.nodeStateChanged(
                            id: result.taskId,
                            state: result.success ? .done : .failed,
                            liveStatus: nil
                        )
                    }
                    return collected
                }
                results.append(contentsOf: batchResults)
                for r in batchResults { completed.insert(r.taskId) }
            }
        }

        progressSink?.publish(AgentProgressEvent(
            kind: .status(label: "Merging results"),
            message: "Merging results"
        ))
        return await mergeResults(results, service: service)
    }

    // MARK: - AppAgent Dispatch

    private func runAppAgent(
        task: SubTask,
        service: LLMServiceProtocol,
        registry: ToolRegistry,
        trace: AgentTrace?
    ) async -> SubAgentResult {
        let config = await prefetchPipeline.consume(taskId: task.id) ?? AppAgent.Config(
            subtaskId: task.id,
            subtaskDescription: task.description,
            targetApp: task.targetApp,
            toolHints: task.toolHints,
            maxIterations: 8,
            maxTokens: 2048,
            hostMessage: task.hostMessage
        )

        let result = await AppAgent.execute(
            config: config,
            blackboard: blackboard,
            service: service,
            registry: registry,
            trace: trace
        )

        return SubAgentResult(
            taskId: result.subtaskId,
            description: task.description,
            result: result.output,
            success: result.success
        )
    }

    // MARK: - Result Merging

    private func mergeResults(_ results: [SubAgentResult], service: LLMServiceProtocol) async -> String {
        let sorted = results.sorted { $0.taskId < $1.taskId }

        let nonEmpty = sorted.filter { !$0.result.isEmpty && $0.result != "Done." }
        if nonEmpty.count == 1 {
            return nonEmpty[0].result
        }

        let mergeContent = sorted
            .map { "## \($0.description)\n\($0.result)" }
            .joined(separator: "\n\n")

        let mergeMessages = [
            ChatMessage(role: "system", content: "Merge these sub-task results into a single cohesive response. Be concise. Don't mention that sub-tasks were used."),
            ChatMessage(role: "user", content: mergeContent)
        ]

        if let mergeResponse = try? await service.sendChatRequest(
            messages: mergeMessages,
            tools: nil,
            maxTokens: 2048
        ), let merged = mergeResponse.text {
            return merged
        }

        return sorted.map { "**\($0.description):**\n\($0.result)" }.joined(separator: "\n\n")
    }
}
