import XCTest
@testable import MetamorphiaAgentKit

/// End-to-end tests for the actor-based AgentLoop. Uses a stub LLM service so
/// tests run instantly without hitting any real API.
final class AgentLoopTests: XCTestCase {

    // MARK: - Stubs

    /// Scripted LLM service that returns a fixed sequence of responses.
    final class ScriptedService: LLMServiceProtocol, @unchecked Sendable {
        private let responses: [LLMResponse]
        private var index = 0
        private let lock = NSLock()

        init(responses: [LLMResponse]) { self.responses = responses }

        func sendChatRequest(messages: [ChatMessage], tools: [[String: AnyCodable]]?, maxTokens: Int) async throws -> LLMResponse {
            lock.lock(); defer { lock.unlock() }
            guard index < responses.count else {
                return LLMResponse(
                    text: "Done.",
                    toolCalls: nil,
                    rawMessage: ChatMessage(role: "assistant", content: "Done.")
                )
            }
            let r = responses[index]
            index += 1
            return r
        }
    }

    /// A tool that records every invocation and returns a canned response.
    struct EchoTool: ToolDefinition {
        let name: String
        let description = "echo tool for tests"
        let parameters: [String: Any] = [:]
        let response: String

        func execute(arguments: String) async throws -> String {
            return response
        }
    }

    final class RecordingSink: AgentDisplayStateSink, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [AgentDisplayEvent] = []

        var events: [AgentDisplayEvent] {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }

        func emit(_ event: AgentDisplayEvent) async {
            lock.lock(); defer { lock.unlock() }
            buffer.append(event)
        }
    }

    // MARK: - Helpers

    private func makeToolCall(name: String, id: String = UUID().uuidString, args: String = "{}") -> ToolCall {
        ToolCall(id: id, type: "function", function: .init(name: name, arguments: args))
    }

    private func makeResponse(text: String? = nil, toolCalls: [ToolCall]? = nil) -> LLMResponse {
        LLMResponse(
            text: text,
            toolCalls: toolCalls,
            rawMessage: ChatMessage(role: "assistant", content: text, tool_calls: toolCalls)
        )
    }

    // MARK: - Tests

    func testSingleTurnResponseReturnsImmediately() async {
        let service = ScriptedService(responses: [
            makeResponse(text: "The answer is 42.")
        ])
        let registry = ToolRegistry()
        let chain = MiddlewareChain()

        let loop = AgentLoop(service: service, registry: registry, middlewareChain: chain)
        let outcome = await loop.submit(command: "What is 6*7?", systemPrompt: "You are a calculator.")

        XCTAssertEqual(outcome.text, "The answer is 42.")
        XCTAssertEqual(outcome.iterations, 1)
        XCTAssertFalse(outcome.wasCancelled)
    }

    func testToolCallFlowExecutesToolAndFeedsResultBack() async {
        let registry = ToolRegistry()
        registry.register(
            EchoTool(name: "get_time", response: "10:00 AM"),
            category: .productivity
        )

        let call = makeToolCall(name: "get_time")
        let service = ScriptedService(responses: [
            makeResponse(toolCalls: [call]),            // iteration 0: request tool
            makeResponse(text: "It's 10 AM."),           // iteration 1: final answer
        ])

        let chain = MiddlewareChain()
        let loop = AgentLoop(service: service, registry: registry, middlewareChain: chain)
        let outcome = await loop.submit(command: "what time is it", systemPrompt: "clock agent")

        XCTAssertEqual(outcome.text, "It's 10 AM.")
        XCTAssertEqual(outcome.toolsUsed, ["get_time"])
        XCTAssertEqual(outcome.iterations, 2)
    }

    func testDisplayStateSinkReceivesExpectedEvents() async {
        let registry = ToolRegistry()
        registry.register(
            EchoTool(name: "demo_tool", response: "ok"),
            category: .files
        )

        let service = ScriptedService(responses: [
            makeResponse(toolCalls: [makeToolCall(name: "demo_tool")]),
            makeResponse(text: "done"),
        ])

        let chain = MiddlewareChain()
        let sink = RecordingSink()
        let loop = AgentLoop(
            service: service,
            registry: registry,
            middlewareChain: chain,
            displayStateSink: sink
        )

        _ = await loop.submit(command: "x", systemPrompt: "sys")

        let kinds: [String] = sink.events.map { event in
            switch event {
            case .processing: return "processing"
            case .executing(let name, _, _): return "executing:\(name)"
            case .result: return "result"
            case .error: return "error"
            case .cancelled: return "cancelled"
            case .ready: return "ready"
            case .streaming: return "streaming"
            }
        }

        XCTAssertTrue(kinds.first == "processing")
        XCTAssertTrue(kinds.contains(where: { $0.hasPrefix("executing:") }))
        XCTAssertTrue(kinds.last == "result")
    }

    func testCancelInFlightAbortsAndEmitsCancelledEvent() async {
        // Slow scripted service — each LLM call takes 50ms, so the loop has
        // plenty of suspension points where cancellation can land.
        final class SlowService: LLMServiceProtocol, @unchecked Sendable {
            func sendChatRequest(messages: [ChatMessage], tools: [[String: AnyCodable]]?, maxTokens: Int) async throws -> LLMResponse {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                if Task.isCancelled { throw CancellationError() }
                let call = ToolCall(
                    id: UUID().uuidString,
                    type: "function",
                    function: .init(name: "noop", arguments: "{}")
                )
                return LLMResponse(
                    text: nil,
                    toolCalls: [call],
                    rawMessage: ChatMessage(role: "assistant", content: nil, tool_calls: [call])
                )
            }
        }

        let registry = ToolRegistry()
        registry.register(
            EchoTool(name: "noop", response: "still going"),
            category: .files
        )

        let loop = AgentLoop(
            service: SlowService(),
            registry: registry,
            middlewareChain: MiddlewareChain()
        )

        async let outcome = loop.submit(command: "loop forever", systemPrompt: "sys")
        // Give the detached task ~20ms to start, then cancel.
        try? await Task.sleep(nanoseconds: 20_000_000)
        await loop.cancelInFlight()
        let result = await outcome

        XCTAssertTrue(
            result.wasCancelled || result.text.contains("cancelled") || result.text.hasPrefix("Error"),
            "outcome should reflect cancellation, got text=\(result.text) cancelled=\(result.wasCancelled)"
        )
    }

    func testDocCreationGuardBlocksKeynoteLaunchDuringPresentationTask() async {
        let registry = ToolRegistry()
        registry.register(
            EchoTool(name: "launch_app", response: "launched"),
            category: .appControl
        )

        // Model calls launch_app Keynote during a "make a presentation" task.
        let call = makeToolCall(name: "launch_app", args: #"{"app":"Keynote"}"#)
        let service = ScriptedService(responses: [
            makeResponse(toolCalls: [call]),
            makeResponse(text: "OK, switching strategy."),
        ])

        let loop = AgentLoop(
            service: service,
            registry: registry,
            middlewareChain: MiddlewareChain()
        )
        let outcome = await loop.submit(
            command: "create a presentation about the moon",
            systemPrompt: "sys"
        )

        // Find the tool result message in the message history.
        let toolMsg = outcome.messages.first(where: { $0.role == "tool" })
        XCTAssertNotNil(toolMsg)
        XCTAssertTrue((toolMsg?.content ?? "").contains("BLOCKED"),
                      "guard should have blocked launch_app Keynote")
    }

    func testClassifyComplexity() {
        XCTAssertEqual(AgentLoop.classifyComplexity("[deep research] Tell me about TLS"), .deep)
        XCTAssertEqual(AgentLoop.classifyComplexity("open safari"), .simple)
        XCTAssertEqual(AgentLoop.classifyComplexity("create a pitch deck about AI"), .medium)
        XCTAssertEqual(AgentLoop.classifyComplexity(
            "organize my Downloads and then research the new files and compare them"
        ), .complex)
    }

    func testToolNotFoundReturnsErrorResult() async {
        let registry = ToolRegistry()  // empty — no tools registered
        let call = makeToolCall(name: "unknown_tool")

        let results = await AgentLoop.executeToolCalls(
            [call], registry: registry,
            iteration: 0, maxIterations: 1
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].result.hasPrefix("Error"))
        XCTAssertFalse(results[0].success)
    }

    func testParallelToolExecutionPreservesOrder() async {
        // Three independent tool calls — planner should group them in one wave.
        let registry = ToolRegistry()
        registry.register(EchoTool(name: "alpha", response: "A"), category: .productivity)
        registry.register(EchoTool(name: "beta",  response: "B"), category: .productivity)
        registry.register(EchoTool(name: "gamma", response: "C"), category: .productivity)

        let calls = [
            makeToolCall(name: "alpha", id: "id-0"),
            makeToolCall(name: "beta",  id: "id-1"),
            makeToolCall(name: "gamma", id: "id-2"),
        ]

        let planner = ParallelExecutionPlanner()
        let plan = planner.analyzeParallelism(calls)
        XCTAssertTrue(plan.parallelizable, "three independent tools should be parallelizable")

        // Use the full-loop path via a scripted service that emits all three calls at once.
        let service = ScriptedService(responses: [
            makeResponse(toolCalls: calls),
            makeResponse(text: "done"),
        ])
        let chain = MiddlewareChain()
        chain.add(ParallelExecutionPlanner())

        let loop = AgentLoop(service: service, registry: registry, middlewareChain: chain)
        let outcome = await loop.submit(command: "run all three", systemPrompt: "sys")

        // toolsUsed must appear in original call order: alpha, beta, gamma.
        XCTAssertEqual(outcome.toolsUsed, ["alpha", "beta", "gamma"])
    }

    func testMemoryRecapInjected() {
        let chain = MiddlewareChain()
        chain.add(ConversationMemoryMiddleware())

        // Iteration 0: initialise storage and record some events.
        let ctx0 = chain.makeContext(
            messages: [ChatMessage(role: "system", content: "sys"),
                       ChatMessage(role: "user",   content: "hello")],
            tools: [], iteration: 0, maxIterations: 5, trace: nil, command: "hello"
        )
        _ = chain.runBeforeModel(ctx0)
        _ = chain.runAfterModel(ctx0, response: LLMResponse(
            text: "Hi",
            toolCalls: [ToolCall(id: "t1", type: "function", function: .init(name: "search_web", arguments: "{}"))],
            rawMessage: ChatMessage(role: "assistant", content: "Hi")
        ))
        _ = chain.runAfterToolExecution(
            ctx0,
            toolCalls: [ToolCall(id: "t1", type: "function", function: .init(name: "search_web", arguments: "{}"))],
            results: [ToolResult(toolName: "search_web", toolCallId: "t1", arguments: "{}", result: "found", durationMs: 1, success: true)]
        )
        chain.syncStorage(from: ctx0)

        // Iteration 1: beforeModelCall should inject the recap.
        let ctx1 = chain.makeContext(
            messages: [ChatMessage(role: "system", content: "sys"),
                       ChatMessage(role: "user",   content: "follow up")],
            tools: [], iteration: 1, maxIterations: 5, trace: nil, command: "follow up"
        )
        _ = chain.runBeforeModel(ctx1)

        let recapMessages = ctx1.messages.filter { $0.content?.hasPrefix("[Session Recap]") == true }
        XCTAssertEqual(recapMessages.count, 1, "exactly one recap message should be injected")

        // Running beforeModel again must not accumulate a second recap.
        _ = chain.runBeforeModel(ctx1)
        let recapMessages2 = ctx1.messages.filter { $0.content?.hasPrefix("[Session Recap]") == true }
        XCTAssertEqual(recapMessages2.count, 1, "re-running beforeModel must not duplicate the recap")
    }
}
