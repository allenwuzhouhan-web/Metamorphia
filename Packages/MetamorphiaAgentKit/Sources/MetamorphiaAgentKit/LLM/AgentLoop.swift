import Foundation

/// The multi-turn LLM agent loop: send messages, execute tool calls, repeat.
///
/// Ported from Executer as an `actor` (was `class`) with explicit `cancelInFlight()`
/// so a new `submit(...)` cleanly aborts any prior run. Middleware chain runs at
/// three points per iteration. UI state transitions flow through an injected
/// ``AgentDisplayStateSink`` (app target's `InputBarState` conforms to
/// ``AgentDisplayState``), so the package never imports the enum.
///
/// Design deviations from Executer's original:
/// - **No auto-skill recording.** The Hermes-inspired learning loop lives in
///   `MetamorphiaExecutors` / the app target's Learning subsystem; this class just
///   hands finished traces to an optional observer.
/// - **No session-store persistence.** `AgentSessionStore` has hard `@MainActor`
///   ties and is an app-target concern.
/// - **No parallel tool waves.** Tool execution is sequential here; the
///   `ParallelExecutionPlanner` middleware records groupings for observability,
///   and a future port can introduce `executeToolCallsInWaves` when the app's
///   UI tool classes are available.
public actor AgentLoop {

    // MARK: - Task Complexity

    public enum TaskComplexity: Sendable {
        case simple   // 10 tool calls, 1024 tokens
        case medium   // 30 tool calls, 2048 tokens
        case complex  // 100 tool calls, 4096 tokens
        case deep     // 300 tool calls, 8192 tokens

        public var maxIterations: Int {
            switch self {
            case .simple: return 10
            case .medium: return 30
            case .complex: return 100
            case .deep: return 300
            }
        }

        public var maxTokens: Int {
            switch self {
            case .simple: return 1024
            case .medium: return 2048
            case .complex: return 4096
            case .deep: return 8192
            }
        }

        /// Cost ceiling per complexity tier (USD). Mitigates runaway loops.
        public var costCeilingUSD: Double {
            switch self {
            case .simple: return 0.10
            case .medium: return 0.50
            case .complex: return 2.0
            case .deep: return 10.0
            }
        }
    }

    // MARK: - Outcome

    public struct Outcome: Sendable {
        public let text: String
        public let messages: [ChatMessage]
        public let toolsUsed: [String]
        public let iterations: Int
        public let trace: AgentTrace?
        public let wasCancelled: Bool
    }

    // MARK: - Dependencies

    private let service: LLMServiceProtocol
    private let registry: ToolRegistry
    private let middlewareChain: MiddlewareChain
    // Sinks are `var` so the app target can attach them after construction —
    // `AICommandViewModel` needs a reference to the `AgentLoop`, which means
    // the loop is built first and the view model second. Setters below let
    // the bootstrap wire the viewModel back in once it exists.
    private var displayStateSink: AgentDisplayStateSink?
    private var progressSink: AgentProgressSink?
    private var treeSink: AgentTreeSink?
    private let systemContext: SystemContextProvider
    private let costTracker: AgentLoopCostReader?
    private let conversationStore: ConversationStore?
    private let sessionId: String?

    /// M9: per-run override of `sessionId`. When set (by `setRunSessionId`),
    /// the loop persists the finished thread under THIS id instead of the
    /// constructor default — letting one shared loop serve both the local
    /// notch thread (nil → constructor id) and a remote phone thread.
    /// Takes effect when the loop was constructed with a `conversationStore`
    /// — MetamorphiaBootstrap injects `FileConversationStore()` at line ~578,
    /// so phone-originated runs persist and can be resumed across turns.
    private var runSessionIdOverride: String?

    /// Set a per-run session id override. Called by MetamorphiaIntentEngine /
    /// AICommandViewModel before and after each phone-originated run.
    public func setRunSessionId(_ id: String?) { self.runSessionIdOverride = id }

    /// Effective session id for persistence: per-run override wins over the
    /// constructor default.
    private var effectiveSessionId: String? { runSessionIdOverride ?? sessionId }

    /// Strong retain so auto-submissions don't lose the in-flight Task.
    private var currentTask: Task<Outcome, Never>?

    public init(
        service: LLMServiceProtocol,
        registry: ToolRegistry,
        middlewareChain: MiddlewareChain,
        displayStateSink: AgentDisplayStateSink? = nil,
        progressSink: AgentProgressSink? = nil,
        treeSink: AgentTreeSink? = nil,
        systemContext: SystemContextProvider = NullSystemContextProvider(),
        costTracker: AgentLoopCostReader? = nil,
        conversationStore: ConversationStore? = nil,
        sessionId: String? = nil
    ) {
        self.service = service
        self.registry = registry
        self.middlewareChain = middlewareChain
        self.displayStateSink = displayStateSink
        self.progressSink = progressSink
        self.treeSink = treeSink
        self.systemContext = systemContext
        self.costTracker = costTracker
        self.conversationStore = conversationStore
        self.sessionId = sessionId
    }

    // MARK: - Sink wiring (post-construction)
    //
    // The app target builds the loop first, then `AICommandViewModel`, then
    // attaches the view model back as all three sinks. These setters exist
    // solely for that wiring step — the sinks are captured into the next
    // `submit(...)`'s detached Task at the moment that call is made.

    public func setDisplayStateSink(_ sink: AgentDisplayStateSink?) {
        self.displayStateSink = sink
    }
    public func setProgressSink(_ sink: AgentProgressSink?) {
        self.progressSink = sink
    }
    public func setTreeSink(_ sink: AgentTreeSink?) {
        self.treeSink = sink
    }

    /// Merge keys into the middleware chain's persistent storage. Used by the
    /// host to pre-seed values (e.g. the M4 recall block) that a synchronous
    /// middleware will read on iteration 0.
    public func setMiddlewareStorage(_ values: [String: Any]) {
        for (k, v) in values { middlewareChain.persistentStorage[k] = v }
    }

    // MARK: - Public API

    /// Submit a new command. Cancels any in-flight run, then starts fresh.
    /// Returns the final outcome once the run completes.
    public func submit(
        command: String,
        systemPrompt: String,
        previousMessages: [ChatMessage] = [],
        agent: AgentProfile = .general,
        complexity: TaskComplexity? = nil,
        trace: AgentTrace? = nil
    ) async -> Outcome {
        cancelInFlight()

        let effective = complexity ?? Self.classifyComplexity(command)
        middlewareChain.reset()

        let task = Task.detached(priority: .userInitiated) { [
            service,
            registry,
            chain = middlewareChain,
            displayStateSink,
            progressSink,
            treeSink,
            costTracker
        ] in
            await Self.runLoop(
                command: command,
                systemPrompt: systemPrompt,
                previousMessages: previousMessages,
                agent: agent,
                complexity: effective,
                trace: trace,
                service: service,
                registry: registry,
                middlewareChain: chain,
                displayStateSink: displayStateSink,
                progressSink: progressSink,
                treeSink: treeSink,
                costTracker: costTracker
            )
        }

        currentTask = task
        let outcome = await task.value
        currentTask = nil

        // Persist the completed thread so sessions can resume across launches.
        // Failures are swallowed — a save error must never break the caller's run.
        if let store = conversationStore, let id = effectiveSessionId, !outcome.wasCancelled {
            try? await store.save(sessionId: id, messages: outcome.messages)
        }

        return outcome
    }

    /// Load persisted messages for the given session from the injected
    /// `ConversationStore`. Returns an empty array when no store is configured
    /// or no prior session exists. Used by callers that want to hydrate
    /// `previousMessages` before submitting a continuation turn.
    public func loadMessages(sessionId: String) async -> [ChatMessage] {
        guard let store = conversationStore else { return [] }
        return (try? await store.load(sessionId: sessionId)) ?? []
    }

    /// Cancel any in-flight run. The current `submit(...)` will return an
    /// outcome with `wasCancelled == true`.
    public func cancelInFlight() {
        if let t = currentTask {
            t.cancel()
            progressSink?.publish(AgentProgressEvent(kind: .cancelled, message: "Task cancelled"))
        }
        currentTask = nil
    }

    /// Is a task currently in flight?
    public var isRunning: Bool {
        currentTask != nil
    }

    // MARK: - Core Loop

    private static func runLoop(
        command: String,
        systemPrompt: String,
        previousMessages: [ChatMessage],
        agent: AgentProfile,
        complexity: TaskComplexity,
        trace: AgentTrace?,
        service: LLMServiceProtocol,
        registry: ToolRegistry,
        middlewareChain: MiddlewareChain,
        displayStateSink: AgentDisplayStateSink?,
        progressSink: AgentProgressSink?,
        treeSink: AgentTreeSink?,
        costTracker: AgentLoopCostReader? = nil
    ) async -> Outcome {
        // Strip any stale system messages carried in from `previousMessages`
        // and always re-seat the current-turn `systemPrompt` at index 0. The
        // primed prompt (IntentScorer hints, adaptive-response tier) is
        // query-specific, so a prior turn's system message is never the right
        // one for this turn. Also: a historical system message used to
        // *silently skip* the insertion, dropping priming entirely.
        var messages = previousMessages.filter { $0.role != "system" }
        messages.insert(ChatMessage(role: "system", content: systemPrompt), at: 0)
        messages.append(ChatMessage(role: "user", content: command))

        let tools = registry.filteredToolDefinitions(for: command, agent: agent)
        var toolsUsed: [String] = []
        var finalText = ""
        var iterations = 0
        let maxIters = complexity.maxIterations

        // Capture spend at task start so we can enforce a PER-TASK ceiling,
        // not cumulative daily spend. The cost tracker records globally, so we
        // diff against this snapshot every iteration.
        let spendAtStart = costTracker?.currentSpendUSD ?? 0
        let costCeiling = complexity.costCeilingUSD

        await displayStateSink?.emit(.processing)
        // Open the agent-tree display: the root "Oracle" node is always
        // present while the loop is running, and sub-agents — if
        // `SubAgentCoordinator` is wired in — join as children.
        treeSink?.treeStarted(root: .oracle)
        progressSink?.publish(AgentProgressEvent(
            kind: .status(label: "Planning"),
            message: "Planning"
        ))

        outer: for iteration in 0..<maxIters {
            iterations = iteration + 1

            if Task.isCancelled {
                finalText = "Task cancelled."
                break
            }

            // Cost-ceiling circuit breaker. Checked between iterations so the
            // most recent LLM call's usage is already recorded. We stop
            // BEFORE kicking off another round-trip that would exceed budget.
            if let tracker = costTracker, costCeiling > 0 {
                let spent = tracker.currentSpendUSD - spendAtStart
                if spent >= costCeiling {
                    finalText = String(
                        format: "Stopped: cost ceiling of $%.2f reached for this task ($%.2f spent).",
                        costCeiling, spent
                    )
                    progressSink?.publish(AgentProgressEvent(kind: .error, message: finalText))
                    trace?.append(TraceEntry(kind: .error(
                        source: "AgentLoop",
                        message: "Cost ceiling reached: \(finalText)"
                    )))
                    break
                }
            }

            // Middleware: beforeModelCall
            let ctx = middlewareChain.makeContext(
                messages: messages,
                tools: tools,
                iteration: iteration,
                maxIterations: maxIters,
                trace: trace,
                command: command
            )
            let beforeSignal = middlewareChain.runBeforeModel(ctx)
            if case .stop(let reason) = beforeSignal {
                finalText = "Stopped: \(reason)"
                messages = ctx.messages
                middlewareChain.syncStorage(from: ctx)
                break
            }
            messages = ctx.messages  // middleware may have injected

            // LLM call
            progressSink?.publish(AgentProgressEvent(
                kind: .status(label: "Thinking"),
                message: "Thinking"
            ))
            let response: LLMResponse
            var llmCallSucceeded = false
            var llmResponse: LLMResponse?
            var llmError: Error?
            for attempt in 0...2 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                }
                do {
                    var collectedResponse: LLMResponse?
                    for try await event in service.streamChatRequest(
                        messages: messages,
                        tools: ctx.tools,
                        maxTokens: complexity.maxTokens
                    ) {
                        switch event {
                        case .textDelta(let chunk):
                            progressSink?.publish(AgentProgressEvent(
                                kind: .streamingToken(chunk),
                                message: chunk
                            ))
                        case .done(let r):
                            collectedResponse = r
                        case .toolCallStart, .toolCallDelta, .toolCallComplete:
                            break
                        }
                    }
                    if let r = collectedResponse {
                        llmResponse = r
                        llmCallSucceeded = true
                        break
                    }
                } catch is CancellationError {
                    llmError = CancellationError()
                    break
                } catch {
                    if attempt < 2 && Self.isTransientError(error.localizedDescription) {
                        continue
                    }
                    llmError = error
                    break
                }
            }
            if let err = llmError {
                if err is CancellationError {
                    finalText = "Task cancelled."
                } else {
                    trace?.append(TraceEntry(kind: .error(source: "AgentLoop", message: err.localizedDescription)))
                    finalText = "Error: \(err.localizedDescription)"
                }
                break
            }
            guard llmCallSucceeded, let r = llmResponse else {
                finalText = "Error: LLM stream completed without a response."
                break
            }
            response = r

            trace?.append(TraceEntry(kind: .llmCall(
                messageCount: messages.count,
                responseLength: response.text?.count ?? 0,
                hasToolCalls: response.toolCalls != nil && !(response.toolCalls?.isEmpty ?? true),
                reasoning: response.rawMessage.reasoning_content
            )))

            // Middleware: afterModelCall
            let afterModelSignal = middlewareChain.runAfterModel(ctx, response: response)
            if case .stop(let reason) = afterModelSignal {
                finalText = response.text ?? "Stopped: \(reason)"
                messages = ctx.messages
                middlewareChain.syncStorage(from: ctx)
                break
            }
            messages = ctx.messages

            // If no tool calls, we're done — keep the text as the final answer.
            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                finalText = response.text ?? "Done."
                middlewareChain.syncStorage(from: ctx)
                break
            }

            // Append the assistant message (with tool calls) so the LLM sees its own prior turn.
            messages.append(response.rawMessage)
            ctx.messages = messages

            // Stream tool-start events.
            for call in toolCalls {
                let friendly = ToolDisplayName.display(call.function.name)
                await displayStateSink?.emit(.executing(toolName: friendly, step: iteration + 1, total: maxIters))
                progressSink?.publish(AgentProgressEvent(
                    kind: .toolStarted(name: call.function.name),
                    message: friendly
                ))
                // Short mutating status label — the 1-3 word friendly name
                // doubles as the UI's "Thinking…" replacement so the notch
                // shows real progress per tool instead of a static string.
                progressSink?.publish(AgentProgressEvent(
                    kind: .status(label: String(friendly.prefix(32))),
                    message: friendly
                ))
            }

            // Execute tool calls — parallel waves if a plan was stashed, else sequential.
            // The plan is consumed once and cleared so a stale plan from a prior
            // iteration (with different toolCalls.count) cannot index out of bounds.
            let parallelPlan = ctx.storage["ParallelExec.currentPlan"] as? ParallelExecutionPlanner.ExecutionPlan
            ctx.storage["ParallelExec.currentPlan"] = nil
            let results: [ToolResult]
            if let plan = parallelPlan,
               plan.parallelizable,
               plan.waves.allSatisfy({ $0.allSatisfy { $0 < toolCalls.count } }) {
                results = await Self.executeToolCallsInWaves(
                    toolCalls,
                    plan: plan,
                    registry: registry,
                    iteration: iteration,
                    maxIterations: maxIters,
                    command: command,
                    displayStateSink: displayStateSink,
                    progressSink: progressSink,
                    trace: trace
                )
            } else {
                results = await Self.executeToolCalls(
                    toolCalls,
                    registry: registry,
                    iteration: iteration,
                    maxIterations: maxIters,
                    command: command,
                    displayStateSink: displayStateSink,
                    progressSink: progressSink,
                    trace: trace
                )
            }

            for r in results {
                messages.append(ChatMessage(
                    role: "tool",
                    content: r.result,
                    tool_call_id: r.toolCallId
                ))
                toolsUsed.append(r.toolName)
            }
            ctx.messages = messages

            // Middleware: afterToolExecution
            let afterToolsSignal = middlewareChain.runAfterToolExecution(ctx, toolCalls: toolCalls, results: results)
            if case .stop(let reason) = afterToolsSignal {
                finalText = "Stopped: \(reason)"
                messages = ctx.messages
                middlewareChain.syncStorage(from: ctx)
                break outer
            }
            messages = ctx.messages
            middlewareChain.syncStorage(from: ctx)

            if Task.isCancelled {
                finalText = "Task cancelled."
                break
            }
        }

        trace?.endTime = Date()
        let cancelled = Task.isCancelled || finalText == "Task cancelled."

        if cancelled {
            trace?.finalOutcome = .cancelled
            await displayStateSink?.emit(.cancelled)
            progressSink?.publish(AgentProgressEvent(kind: .cancelled, message: "Task cancelled"))
        } else if finalText.hasPrefix("Error:") {
            trace?.finalOutcome = .failure(finalText)
            await displayStateSink?.emit(.error(finalText))
            progressSink?.publish(AgentProgressEvent(kind: .error, message: finalText))
        } else {
            trace?.finalOutcome = .success
            await displayStateSink?.emit(.result(finalText))
            progressSink?.publish(AgentProgressEvent(kind: .completed, message: "Task completed", progress: 1.0))
        }

        return Outcome(
            text: finalText,
            messages: messages,
            toolsUsed: toolsUsed,
            iterations: iterations,
            trace: trace,
            wasCancelled: cancelled
        )
    }

    // MARK: - Tool Execution

    /// Execute a single tool call with up to 2 retries on transient errors.
    private static func executeOneToolCall(
        _ call: ToolCall,
        registry: ToolRegistry,
        command: String,
        displayStateSink: AgentDisplayStateSink?,
        progressSink: AgentProgressSink?,
        trace: AgentTrace?
    ) async -> ToolResult {
        if Task.isCancelled {
            return ToolResult(
                toolName: call.function.name,
                toolCallId: call.id,
                arguments: call.function.arguments,
                result: "Error: cancelled",
                durationMs: 0,
                success: false
            )
        }

        if let blockReason = DocCreationGuard.blockReason(
            toolName: call.function.name,
            arguments: call.function.arguments,
            command: command,
            trace: trace
        ) {
            return ToolResult(
                toolName: call.function.name,
                toolCallId: call.id,
                arguments: call.function.arguments,
                result: blockReason,
                durationMs: 0,
                success: false
            )
        }

        let start = Date()
        for attempt in 0...2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
            do {
                let result = try await registry.execute(
                    toolName: call.function.name,
                    arguments: call.function.arguments
                )
                let durationMs = Date().timeIntervalSince(start) * 1000
                let isFailure = result.hasPrefix("Error")
                // Retry transient result-string errors before committing.
                if isFailure && attempt < 2 && Self.isTransientError(result) {
                    continue
                }
                trace?.append(TraceEntry(kind: .toolCall(
                    name: call.function.name,
                    arguments: call.function.arguments,
                    result: result,
                    durationMs: durationMs,
                    success: !isFailure
                )))
                progressSink?.publish(AgentProgressEvent(
                    kind: .toolCompleted(name: call.function.name, success: !isFailure),
                    message: ToolDisplayName.display(call.function.name)
                        + (isFailure ? " failed" : " done")
                ))
                return ToolResult(
                    toolName: call.function.name,
                    toolCallId: call.id,
                    arguments: call.function.arguments,
                    result: result,
                    durationMs: durationMs,
                    success: !isFailure
                )
            } catch is CancellationError {
                let durationMs = Date().timeIntervalSince(start) * 1000
                return ToolResult(
                    toolName: call.function.name,
                    toolCallId: call.id,
                    arguments: call.function.arguments,
                    result: "Error: cancelled",
                    durationMs: durationMs,
                    success: false
                )
            } catch {
                if attempt < 2 && Self.isTransientError(error.localizedDescription) {
                    continue
                }
                let durationMs = Date().timeIntervalSince(start) * 1000
                let errStr = "Error: \(error.localizedDescription)"
                trace?.append(TraceEntry(kind: .toolCall(
                    name: call.function.name,
                    arguments: call.function.arguments,
                    result: errStr,
                    durationMs: durationMs,
                    success: false
                )))
                progressSink?.publish(AgentProgressEvent(
                    kind: .toolCompleted(name: call.function.name, success: false),
                    message: ToolDisplayName.display(call.function.name) + " failed"
                ))
                return ToolResult(
                    toolName: call.function.name,
                    toolCallId: call.id,
                    arguments: call.function.arguments,
                    result: errStr,
                    durationMs: durationMs,
                    success: false
                )
            }
        }
        // Unreachable — loop always returns, but Swift needs a value here.
        let durationMs = Date().timeIntervalSince(start) * 1000
        return ToolResult(
            toolName: call.function.name,
            toolCallId: call.id,
            arguments: call.function.arguments,
            result: "Error: max retries exceeded",
            durationMs: durationMs,
            success: false
        )
    }

    /// Execute tool calls grouped into dependency waves. Calls within a wave run concurrently.
    private static func executeToolCallsInWaves(
        _ toolCalls: [ToolCall],
        plan: ParallelExecutionPlanner.ExecutionPlan,
        registry: ToolRegistry,
        iteration: Int,
        maxIterations: Int,
        command: String,
        displayStateSink: AgentDisplayStateSink?,
        progressSink: AgentProgressSink?,
        trace: AgentTrace?
    ) async -> [ToolResult] {
        var out: [ToolResult?] = Array(repeating: nil, count: toolCalls.count)

        for wave in plan.waves {
            await withTaskGroup(of: (Int, ToolResult).self) { group in
                for idx in wave {
                    let call = toolCalls[idx]
                    group.addTask {
                        let result = await Self.executeOneToolCall(
                            call,
                            registry: registry,
                            command: command,
                            displayStateSink: displayStateSink,
                            progressSink: progressSink,
                            trace: trace
                        )
                        return (idx, result)
                    }
                }
                for await (idx, result) in group {
                    out[idx] = result
                }
            }
        }

        return out.enumerated().map { (i, r) in
            r ?? ToolResult(
                toolName: toolCalls[i].function.name,
                toolCallId: toolCalls[i].id,
                arguments: toolCalls[i].function.arguments,
                result: "Error: missing wave result",
                durationMs: 0,
                success: false
            )
        }
    }

    /// Execute a batch of tool calls sequentially. Returns one `ToolResult` per call.
    public static func executeToolCalls(
        _ toolCalls: [ToolCall],
        registry: ToolRegistry,
        iteration: Int,
        maxIterations: Int,
        command: String = "",
        displayStateSink: AgentDisplayStateSink? = nil,
        progressSink: AgentProgressSink? = nil,
        trace: AgentTrace? = nil
    ) async -> [ToolResult] {
        var out: [ToolResult] = []
        for call in toolCalls {
            let result = await Self.executeOneToolCall(
                call,
                registry: registry,
                command: command,
                displayStateSink: displayStateSink,
                progressSink: progressSink,
                trace: trace
            )
            out.append(result)

            if Self.uiSequentialTools.contains(call.function.name),
               let delay = Self.toolDelays[call.function.name] {
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        return out
    }

    // MARK: - Transient Error Classification

    private static func isTransientError(_ s: String) -> Bool {
        let lower = s.lowercased()
        return ["network", "timeout", "rate limit", "connection reset", "temporarily unavailable"]
            .contains(where: { lower.contains($0) })
    }

    // MARK: - Complexity Classification

    public static func classifyComplexity(_ command: String) -> TaskComplexity {
        let lower = command.lowercased()

        if lower.hasPrefix("[deep research]") { return .deep }
        if lower.hasPrefix("[browser visible]") || lower.hasPrefix("[browser background]") {
            return .medium
        }

        let complexIndicators = [
            "and then", "after that", "organize", "clean up",
            "research", "investigate", "compare", "analyze",
            "set up", "configure", "build", "create a",
            "deep research", "comprehensive",
        ]
        let complexHits = complexIndicators.filter { lower.contains($0) }.count
        if complexHits >= 2 { return .complex }

        let mediumIndicators = ["create", "make", "search", "find", "write", "edit"]
        if mediumIndicators.contains(where: { lower.contains($0) }) { return .medium }

        return .simple
    }

    // MARK: - Static Constants

    /// UI tools that must execute sequentially because they depend on screen state.
    private static let uiSequentialTools: Set<String> = [
        "click", "click_element", "click_ref", "type_text", "press_key", "hotkey",
        "scroll", "drag", "move_cursor", "launch_app", "select_all_text",
        "paste_text", "browser_click_element_css", "browser_type_in_element",
    ]

    /// Per-tool delay (ns) to let UI settle before the next call.
    private static let toolDelays: [String: UInt64] = [
        "launch_app": 1_000_000_000,
        "click": 200_000_000, "click_element": 200_000_000, "click_ref": 200_000_000,
        "type_text": 200_000_000, "press_key": 200_000_000,
        "hotkey": 200_000_000, "scroll": 200_000_000,
        "move_cursor": 200_000_000,
    ]

    /// Default friendly-name map the app target should register into ``ToolDisplayName``
    /// at startup. Kept here for documentation / convenience.
    public static let defaultFriendlyNames: [String: String] = [
        "launch_app": "Opening app", "quit_app": "Closing app",
        "click": "Clicking", "click_element": "Clicking", "click_ref": "Clicking",
        "type_text": "Typing", "press_key": "Pressing key",
        "hotkey": "Shortcut", "scroll": "Scrolling",
        "move_cursor": "Moving cursor", "drag": "Dragging",
        "capture_screen": "Looking", "ocr_image": "Reading screen",
        "open_url": "Opening URL", "open_url_in_safari": "Opening Safari",
        "search_web": "Searching", "dictionary_lookup": "Looking up",
        "music_play_song": "Playing", "music_pause": "Pausing",
        "browser_task": "Browsing web", "browser_extract": "Extracting web data",
        "browser_session": "Managing browser", "browser_screenshot": "Browser screenshot",
        "notion_search": "Searching Notion", "notion_read_page": "Reading Notion page",
        "notion_create_page": "Creating Notion page", "notion_update_page": "Updating Notion page",
        "notion_append_blocks": "Writing to Notion", "notion_query_database": "Querying Notion DB",
        "ffmpeg_edit_video": "Editing video", "create_video": "Creating video",
        "create_podcast": "Creating podcast", "download_youtube": "Downloading video",
    ]

    /// Default middleware chain factory. The app target wires in its own concrete
    /// sinks + stores, then calls this to get the full stack.
    public static func makeDefaultMiddlewareChain(
        progressSink: AgentProgressSink,
        memoryStore: MemoryStore,
        systemContext: SystemContextProvider = NullSystemContextProvider(),
        clipboard: ClipboardProvider = NullClipboardProvider(),
        session: SessionProvider = NullSessionProvider(),
        toolCatalog: ToolCatalog,
        adaptiveResponseStorageURL: URL? = nil,
        interestGraph: InterestGraphStore? = nil,
        retraceRecall: @escaping @Sendable (String) async -> String? = { _ in nil }
    ) -> MiddlewareChain {
        let chain = MiddlewareChain()
        // Infrastructure
        chain.add(LoopDetectionMiddleware())
        chain.add(DeferredToolMiddleware(catalog: toolCatalog))
        // LangChain-inspired
        chain.add(ConversationMemoryMiddleware())
        chain.add(ActionPlanningMiddleware())
        chain.add(ToolDependencyResolver())
        chain.add(ErrorRecoveryMiddleware())
        chain.add(StreamingProgressMiddleware(sink: progressSink))
        chain.add(ResultSummaryMiddleware())
        chain.add(ConversationBranchManager())
        chain.add(OutputParsingMiddleware())
        chain.add(ContextWindowOptimizer())
        chain.add(ParallelExecutionPlanner())
        // Contextual understanding
        chain.add(ConversationGoalMiddleware())
        chain.add(ImplicitContextMiddleware(
            systemContext: systemContext,
            clipboard: clipboard,
            session: session
        ))
        // M4: temporal recall — injects a pre-fetched "earlier context" block
        // on iteration 0. Sits after ImplicitContext so screen/clipboard context
        // appears first; the closure is unused by the sync hook (host pre-fetches).
        chain.add(RetraceRecallMiddleware(recall: retraceRecall))
        chain.add(AdaptiveResponseMiddleware(engagementStorageURL: adaptiveResponseStorageURL))
        // Interest graph potentiation — runs before CorrectionDetector so tool
        // subjects are recorded even when the LLM gets corrected immediately after.
        if let graph = interestGraph {
            chain.add(InterestGraphPotentiator(store: graph))
        }
        chain.add(CorrectionDetectorMiddleware(memoryStore: memoryStore))
        // Learning loop
        chain.add(MemoryNudgeMiddleware())
        return chain
    }
}

