import XCTest
@testable import MetamorphiaAgentKit

/// Integration tests that exercise the ported middleware in realistic chains.
final class MiddlewareIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Captures progress events into an in-memory buffer so tests can assert on them.
    final class CapturingSink: AgentProgressSink, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [AgentProgressEvent] = []

        var events: [AgentProgressEvent] {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }

        func publish(_ event: AgentProgressEvent) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(event)
        }
    }

    private func makeToolCall(name: String, args: String = "{}") -> ToolCall {
        ToolCall(id: UUID().uuidString, type: "function", function: .init(name: name, arguments: args))
    }

    private func makeResult(toolName: String, result: String = "ok", success: Bool = true) -> ToolResult {
        ToolResult(
            toolName: toolName,
            toolCallId: UUID().uuidString,
            arguments: "{}",
            result: result,
            durationMs: 1.0,
            success: success
        )
    }

    private func makeResponse(toolCalls: [ToolCall] = [], text: String? = nil) -> LLMResponse {
        LLMResponse(
            text: text,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            rawMessage: ChatMessage(role: "assistant", content: text)
        )
    }

    // MARK: - LoopDetection

    func testLoopDetectionWarnsAfterThreeRepeats() {
        let chain = MiddlewareChain()
        chain.add(LoopDetectionMiddleware(warnThreshold: 3, stopThreshold: 5))

        let sameCall = makeToolCall(name: "find_files", args: #"{"path":"/tmp"}"#)

        var lastCtx: MiddlewareContext!
        for i in 0..<3 {
            lastCtx = chain.makeContext(
                messages: [], tools: [], iteration: i, maxIterations: 10, trace: nil, command: "test"
            )
            _ = chain.runAfterToolExecution(
                lastCtx,
                toolCalls: [sameCall],
                results: [makeResult(toolName: "find_files")]
            )
            chain.syncStorage(from: lastCtx)
        }

        // Warning is injected into ctx.messages, not returned as a signal — the chain
        // appends injected messages and continues so later middleware still run.
        let injected = lastCtx.messages.contains { ($0.content ?? "").contains("stuck in a loop") }
        XCTAssertTrue(injected, "expected warning message in ctx.messages after 3rd repeat")
    }

    func testLoopDetectionStopsAfterFiveRepeats() {
        let chain = MiddlewareChain()
        chain.add(LoopDetectionMiddleware(warnThreshold: 3, stopThreshold: 5))

        let sameCall = makeToolCall(name: "open_url", args: #"{"url":"https://x.com"}"#)

        var finalSignal: MiddlewareSignal = .continue
        for i in 0..<5 {
            let ctx = chain.makeContext(
                messages: [], tools: [], iteration: i, maxIterations: 10, trace: nil, command: "test"
            )
            finalSignal = chain.runAfterToolExecution(
                ctx,
                toolCalls: [sameCall],
                results: [makeResult(toolName: "open_url")]
            )
            chain.syncStorage(from: ctx)
        }

        guard case .stop(let reason) = finalSignal else {
            XCTFail("expected stop at 5th repeat, got \(finalSignal)")
            return
        }
        XCTAssertTrue(reason.contains("open_url"))
    }

    func testLoopDetectionIgnoresDifferentArguments() {
        let chain = MiddlewareChain()
        chain.add(LoopDetectionMiddleware())

        // Same tool, different paths — should not trigger.
        for i in 0..<5 {
            let ctx = chain.makeContext(
                messages: [], tools: [], iteration: i, maxIterations: 10, trace: nil, command: "t"
            )
            let call = makeToolCall(name: "find_files", args: #"{"path":"/tmp/\#(i)"}"#)
            let signal = chain.runAfterToolExecution(ctx, toolCalls: [call], results: [makeResult(toolName: "find_files")])
            chain.syncStorage(from: ctx)
            if case .stop = signal {
                XCTFail("should not stop when arguments differ")
                return
            }
        }
    }

    // MARK: - StreamingProgress with sever

    func testStreamingProgressEmitsToSink() {
        let sink = CapturingSink()
        let chain = MiddlewareChain()
        chain.add(StreamingProgressMiddleware(sink: sink))

        let ctx = chain.makeContext(
            messages: [ChatMessage(role: "user", content: "test")],
            tools: [], iteration: 0, maxIterations: 5, trace: nil, command: "test command"
        )

        _ = chain.runBeforeModel(ctx)
        _ = chain.runAfterModel(ctx, response: makeResponse(toolCalls: [makeToolCall(name: "search_web")]))
        _ = chain.runAfterToolExecution(
            ctx,
            toolCalls: [makeToolCall(name: "search_web")],
            results: [makeResult(toolName: "search_web")]
        )

        // Expected events: .started, .toolStarted(search_web), .toolCompleted(search_web, true), .milestone
        XCTAssertGreaterThanOrEqual(sink.events.count, 4)
        XCTAssertEqual(sink.events.first?.kind, .started)
        XCTAssertTrue(sink.events.contains { evt in
            if case .toolStarted(let name) = evt.kind { return name == "search_web" }
            return false
        })
        XCTAssertTrue(sink.events.contains { evt in
            if case .toolCompleted(let name, let success) = evt.kind {
                return name == "search_web" && success
            }
            return false
        })
    }

    func testStreamingProgressUsesRegisteredFriendlyNames() {
        ToolDisplayName.reset()
        ToolDisplayName.register("search_web", friendly: "Searching the web")

        let sink = CapturingSink()
        let chain = MiddlewareChain()
        chain.add(StreamingProgressMiddleware(sink: sink))

        let ctx = chain.makeContext(
            messages: [], tools: [], iteration: 0, maxIterations: 5, trace: nil, command: "c"
        )
        _ = chain.runBeforeModel(ctx)
        _ = chain.runAfterModel(ctx, response: makeResponse(toolCalls: [makeToolCall(name: "search_web")]))

        XCTAssertTrue(sink.events.contains { $0.message == "Searching the web" })

        ToolDisplayName.reset()
    }

    // MARK: - ResultSummary

    func testResultSummaryAggregatesChangesByCategory() {
        let chain = MiddlewareChain()
        chain.add(ResultSummaryMiddleware())

        let ctx = chain.makeContext(
            messages: [], tools: [], iteration: 0, maxIterations: 5, trace: nil, command: "do stuff"
        )

        _ = chain.runAfterToolExecution(ctx, toolCalls: [
            makeToolCall(name: "create_presentation"),
            makeToolCall(name: "file_operation"),
            makeToolCall(name: "search_web"),
        ], results: [
            makeResult(toolName: "create_presentation", result: "saved to /tmp/a.pptx"),
            makeResult(toolName: "file_operation", result: "moved file"),
            makeResult(toolName: "search_web"),
        ])
        chain.syncStorage(from: ctx)

        let summary = ResultSummaryMiddleware.generateSummary(from: chain.persistentStorage)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("Created"))
        XCTAssertTrue(summary!.contains("Files"))
    }

    // MARK: - ErrorRecovery

    func testErrorRecoveryInjectsAlternativeSuggestion() {
        let chain = MiddlewareChain()
        chain.add(ErrorRecoveryMiddleware())

        let ctx = chain.makeContext(
            messages: [], tools: [], iteration: 0, maxIterations: 5, trace: nil, command: "c"
        )
        _ = chain.runAfterToolExecution(
            ctx,
            toolCalls: [makeToolCall(name: "open_url")],
            results: [makeResult(toolName: "open_url", result: "Error: permission denied")]
        )

        // Recovery guidance lands in ctx.messages (the chain appends and continues).
        let injected = ctx.messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(injected.contains("Permission denied"))
        XCTAssertTrue(injected.contains("Alternative tools"))
    }

    // MARK: - ToolDependencyResolver

    func testToolDependencyResolverSuggestsPrerequisites() {
        let prereqs = ToolDependencyResolver.suggestPrerequisites(for: ["create_calendar_event"])
        XCTAssertTrue(prereqs.contains("query_calendar_events"))
    }

    // MARK: - ParallelExecutionPlanner

    func testParallelPlannerGroupsIndependentToolsIntoOneWave() {
        let planner = ParallelExecutionPlanner()
        let calls = [
            makeToolCall(name: "search_web", args: #"{"query":"foo"}"#),
            makeToolCall(name: "search_images", args: #"{"query":"bar"}"#),
            makeToolCall(name: "find_files", args: #"{"path":"/tmp"}"#),
        ]
        let plan = planner.analyzeParallelism(calls)
        XCTAssertEqual(plan.waves.count, 1)
        XCTAssertEqual(plan.waves[0].count, 3)
        XCTAssertTrue(plan.parallelizable)
    }

    func testParallelPlannerRespectsDataDependencies() {
        let planner = ParallelExecutionPlanner()
        let calls = [
            makeToolCall(name: "ffmpeg_probe", args: #"{"path":"a.mp4"}"#),
            makeToolCall(name: "ffmpeg_edit_video", args: #"{"input":"a.mp4"}"#),
        ]
        let plan = planner.analyzeParallelism(calls)
        XCTAssertEqual(plan.waves.count, 2, "probe must run before edit")
    }

    // MARK: - ConversationMemory

    func testConversationMemoryAccumulatesEvents() {
        let chain = MiddlewareChain()
        chain.add(ConversationMemoryMiddleware())

        let ctx0 = chain.makeContext(messages: [], tools: [], iteration: 0, maxIterations: 5, trace: nil, command: "c")
        _ = chain.runBeforeModel(ctx0)
        _ = chain.runAfterModel(ctx0, response: makeResponse(toolCalls: [makeToolCall(name: "search_web")], text: "Let me search"))
        _ = chain.runAfterToolExecution(ctx0, toolCalls: [makeToolCall(name: "search_web")], results: [makeResult(toolName: "search_web", result: "found")])
        chain.syncStorage(from: ctx0)

        XCTAssertGreaterThanOrEqual(ConversationMemoryMiddleware.eventCount(from: chain.persistentStorage), 2)
    }

    // MARK: - Full chain smoke

    func testFullChainDoesNotCrashOnRealisticSequence() {
        let sink = CapturingSink()
        let chain = MiddlewareChain()
        chain.add(LoopDetectionMiddleware())
        chain.add(ToolDependencyResolver())
        chain.add(ContextWindowOptimizer())
        chain.add(ResultSummaryMiddleware())
        chain.add(OutputParsingMiddleware())
        chain.add(ErrorRecoveryMiddleware())
        chain.add(ConversationGoalMiddleware())
        chain.add(MemoryNudgeMiddleware())
        chain.add(ConversationMemoryMiddleware())
        chain.add(ActionPlanningMiddleware())
        chain.add(ParallelExecutionPlanner())
        chain.add(ConversationBranchManager())
        chain.add(StreamingProgressMiddleware(sink: sink))

        for iter in 0..<3 {
            let ctx = chain.makeContext(
                messages: [ChatMessage(role: "user", content: "create a presentation and then find the output")],
                tools: [], iteration: iter, maxIterations: 5, trace: nil,
                command: "create a presentation and then find the output"
            )
            _ = chain.runBeforeModel(ctx)
            _ = chain.runAfterModel(ctx, response: makeResponse(toolCalls: [makeToolCall(name: "create_presentation")]))
            _ = chain.runAfterToolExecution(ctx, toolCalls: [makeToolCall(name: "create_presentation")],
                results: [makeResult(toolName: "create_presentation", result: "saved to /tmp/x.pptx")])
            chain.syncStorage(from: ctx)
        }

        // 13 middleware × 3 iterations × 3 hooks — if anything exploded we'd never get here.
        XCTAssertFalse(sink.events.isEmpty)
    }
}
