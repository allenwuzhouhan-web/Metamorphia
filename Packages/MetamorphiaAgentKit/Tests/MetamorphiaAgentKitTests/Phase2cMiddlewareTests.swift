import XCTest
@testable import MetamorphiaAgentKit

/// Tests for the four middleware ported in Phase 2c: each depends on an injected
/// sever protocol (MemoryStore, ClipboardProvider, SessionProvider, or ToolCatalog).
final class Phase2cMiddlewareTests: XCTestCase {

    // MARK: - Helpers

    private func makeCtx(
        chain: MiddlewareChain,
        command: String,
        iteration: Int = 0,
        messages: [ChatMessage] = [ChatMessage(role: "system", content: "You are Metamorphia.")]
    ) -> MiddlewareContext {
        chain.makeContext(
            messages: messages,
            tools: [],
            iteration: iteration,
            maxIterations: 5,
            trace: nil,
            command: command
        )
    }

    private func makeToolCall(name: String, id: String = UUID().uuidString, args: String = "{}") -> ToolCall {
        ToolCall(id: id, type: "function", function: .init(name: name, arguments: args))
    }

    private func makeResult(callId: String, toolName: String, result: String = "ok") -> ToolResult {
        ToolResult(
            toolName: toolName,
            toolCallId: callId,
            arguments: "{}",
            result: result,
            durationMs: 1.0,
            success: !result.hasPrefix("Error")
        )
    }

    // MARK: - AdaptiveResponse

    func testAdaptiveResponseClassifiesTransactionalCommand() {
        let mw = AdaptiveResponseMiddleware(engagementStorageURL: nil)
        let chain = MiddlewareChain()
        chain.add(mw)

        let ctx = makeCtx(chain: chain, command: "open Xcode",
                          messages: [ChatMessage(role: "system", content: "sys"),
                                     ChatMessage(role: "user", content: "open Xcode")])
        _ = chain.runBeforeModel(ctx)

        XCTAssertEqual(ctx.storage["AdaptiveResponse.queryType"] as? String,
                       AdaptiveResponseMiddleware.QueryType.transactional.rawValue)
        let sysContent = ctx.messages.first(where: { $0.role == "system" })?.content ?? ""
        XCTAssertTrue(sysContent.contains("Execute"))
    }

    func testAdaptiveResponseClassifiesDebugging() {
        let mw = AdaptiveResponseMiddleware(engagementStorageURL: nil)
        let chain = MiddlewareChain()
        chain.add(mw)

        let ctx = makeCtx(chain: chain, command: "it's broken, why won't this compile",
                          messages: [ChatMessage(role: "system", content: "sys"),
                                     ChatMessage(role: "user", content: "it's broken, why won't this compile")])
        _ = chain.runBeforeModel(ctx)

        XCTAssertEqual(ctx.storage["AdaptiveResponse.queryType"] as? String,
                       AdaptiveResponseMiddleware.QueryType.debugging.rawValue)
    }

    func testAdaptiveResponsePersistsEngagementToDisk() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // First session: run through several interactions that increment counters.
        do {
            let mw = AdaptiveResponseMiddleware(engagementStorageURL: tempURL)
            let chain = MiddlewareChain()
            chain.add(mw)

            for i in 0..<3 {
                let ctx = makeCtx(
                    chain: chain,
                    command: "do stuff",
                    iteration: i,
                    messages: [
                        ChatMessage(role: "system", content: "sys"),
                        ChatMessage(role: "user", content: "short"),
                    ]
                )
                // Prime the prev-length so iteration > 0 tracks engagement
                ctx.storage["AdaptiveResponse.prevLength"] = 600
                _ = chain.runBeforeModel(ctx)
                chain.syncStorage(from: ctx)
            }
        }

        // File should exist now.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        // Second session reads it back without crashing — that's the interop check.
        let mw2 = AdaptiveResponseMiddleware(engagementStorageURL: tempURL)
        XCTAssertNotNil(mw2)
    }

    // MARK: - CorrectionDetector

    func testCorrectionDetectorPersistsOnStrongSignal() {
        let store = InMemoryMemoryStore()
        let mw = CorrectionDetectorMiddleware(memoryStore: store)
        let chain = MiddlewareChain()
        chain.add(mw)

        // Iteration > 0 required for correction detection path.
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "assistant", content: "I opened Safari."),
            ChatMessage(role: "user", content: "no I meant Firefox"),
        ]
        let ctx = makeCtx(chain: chain, command: "open Firefox", iteration: 1, messages: messages)
        _ = chain.runBeforeModel(ctx)

        XCTAssertEqual(store.count, 1, "strong correction signal should persist one memory record")

        let recalled = store.recall(query: "Firefox", category: .correction, limit: 5)
        XCTAssertEqual(recalled.count, 1)
        XCTAssertTrue(recalled.first?.content.contains("Firefox") ?? false)
    }

    func testCorrectionDetectorIgnoresWeakSignal() {
        let store = InMemoryMemoryStore()
        let mw = CorrectionDetectorMiddleware(memoryStore: store)
        let chain = MiddlewareChain()
        chain.add(mw)

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "assistant", content: "Done."),
            ChatMessage(role: "user", content: "thanks"),
        ]
        let ctx = makeCtx(chain: chain, command: "thanks", iteration: 1, messages: messages)
        _ = chain.runBeforeModel(ctx)

        XCTAssertEqual(store.count, 0, "no correction signal should not persist anything")
    }

    func testCorrectionDetectorInjectsPastCorrections() {
        let store = InMemoryMemoryStore()
        // Pre-seed a past correction that should match the current query via keyword overlap.
        store.add(MemoryInput(
            content: "CORRECTION: User said \"always use Safari\" — was wrong about Chrome",
            category: .correction,
            keywords: ["safari", "chrome", "browser"]
        ))

        let mw = CorrectionDetectorMiddleware(memoryStore: store)
        let chain = MiddlewareChain()
        chain.add(mw)

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are Metamorphia."),
            ChatMessage(role: "user", content: "open a browser please"),
        ]
        let ctx = makeCtx(chain: chain, command: "open a browser please", iteration: 0, messages: messages)
        _ = chain.runBeforeModel(ctx)

        let sysContent = ctx.messages.first(where: { $0.role == "system" })?.content ?? ""
        XCTAssertTrue(sysContent.contains("Past Corrections"),
                      "system message should have past-corrections section appended")
        XCTAssertTrue(sysContent.contains("Safari"))
    }

    // MARK: - ImplicitContext

    /// A clipboard stub that returns a fixed inspection, useful for focused tests.
    final class StubClipboard: ClipboardProvider, @unchecked Sendable {
        let inspection: ClipboardInspection?
        init(_ inspection: ClipboardInspection?) { self.inspection = inspection }
        func inspect() -> ClipboardInspection? { inspection }
    }

    /// A system-context stub that returns a fixed app name.
    final class StubSystemContext: SystemContextProvider, @unchecked Sendable {
        let appName: String?
        init(appName: String?) { self.appName = appName }
        func currentContext() async -> SystemContextSnapshot {
            SystemContextSnapshot(frontmostApp: appName)
        }
        var lastCapturedAppName: String? {
            get async { appName }
        }
    }

    func testImplicitContextInjectsAppOnDeicticQuery() {
        let sysCtx = StubSystemContext(appName: "Xcode")
        let clip = StubClipboard(nil)
        let mw = ImplicitContextMiddleware(
            systemContext: sysCtx,
            clipboard: clip,
            session: NullSessionProvider(),
            recentFileSearchDirs: []  // skip file scan for deterministic tests
        )
        let chain = MiddlewareChain()
        chain.add(mw)

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "base"),
            ChatMessage(role: "user", content: "fix this"),
        ]
        let ctx = makeCtx(chain: chain, command: "fix this", messages: messages)
        _ = chain.runBeforeModel(ctx)

        let sysContent = ctx.messages.first(where: { $0.role == "system" })?.content ?? ""
        XCTAssertTrue(sysContent.contains("Xcode"), "expected frontmost app to be injected; got: \(sysContent)")
        XCTAssertTrue(sysContent.contains("Current Context"))
    }

    func testImplicitContextSkipsWhenQueryIsUnambiguous() {
        let sysCtx = StubSystemContext(appName: "Xcode")
        let mw = ImplicitContextMiddleware(
            systemContext: sysCtx,
            clipboard: NullClipboardProvider(),
            session: NullSessionProvider(),
            recentFileSearchDirs: []
        )
        let chain = MiddlewareChain()
        chain.add(mw)

        // No deictic words, no vague patterns, no clipboard/screen signals,
        // and length > 40 so the short-query bonus doesn't fire.
        let unambiguous = "please create a presentation about sustainable energy"
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "base"),
            ChatMessage(role: "user", content: unambiguous),
        ]
        let ctx = makeCtx(chain: chain, command: unambiguous, messages: messages)
        _ = chain.runBeforeModel(ctx)

        let sysContent = ctx.messages.first(where: { $0.role == "system" })?.content ?? ""
        XCTAssertFalse(sysContent.contains("Current Context"),
                       "no relevance signals in the query — should skip injection")
    }

    func testImplicitContextIncludesClipboardWhenRelevant() {
        let mw = ImplicitContextMiddleware(
            systemContext: NullSystemContextProvider(),
            clipboard: StubClipboard(ClipboardInspection(kind: .file(name: "report.pdf"), changeCount: 1)),
            session: NullSessionProvider(),
            recentFileSearchDirs: []
        )
        let chain = MiddlewareChain()
        chain.add(mw)

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "base"),
            ChatMessage(role: "user", content: "what did I copy"),
        ]
        let ctx = makeCtx(chain: chain, command: "what did I copy", messages: messages)
        _ = chain.runBeforeModel(ctx)

        let sysContent = ctx.messages.first(where: { $0.role == "system" })?.content ?? ""
        XCTAssertTrue(sysContent.contains("report.pdf"))
    }

    // MARK: - DeferredToolMiddleware + SearchToolsTool + UndoLastActionTool

    /// A minimal, in-memory `ToolCatalog` stub — good enough for middleware tests.
    final class StubToolCatalog: ToolCatalog, @unchecked Sendable {
        private let lock = NSLock()
        private var deferred: [String: String]
        private var active: [String: String]
        private var invocations: [(name: String, args: String)] = []

        init(deferred: [String: String] = [:], active: [String: String] = [:]) {
            self.deferred = deferred
            self.active = active
        }

        func deferredToolSummaries() -> [ToolSummary] {
            lock.lock(); defer { lock.unlock() }
            return deferred.map { ToolSummary(name: $0.key, description: $0.value) }
                .sorted(by: { $0.name < $1.name })
        }

        func searchDeferredTools(query: String) -> [ToolSummary] {
            lock.lock(); defer { lock.unlock() }
            return deferred
                .filter { $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query) }
                .map { ToolSummary(name: $0.key, description: $0.value) }
        }

        func searchActiveTools(query: String) -> [ToolSummary] {
            lock.lock(); defer { lock.unlock() }
            return active
                .filter { $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query) }
                .map { ToolSummary(name: $0.key, description: $0.value) }
        }

        func promoteDeferred(names: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            for name in names {
                if let desc = deferred.removeValue(forKey: name) {
                    active[name] = desc
                }
            }
        }

        func activeToolNames() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(active.keys).sorted()
        }

        func singleToolSchema(_ toolName: String) -> [[String: AnyCodable]]? {
            guard active[toolName] != nil else { return nil }
            return [[
                "type": AnyCodable("function"),
                "function": AnyCodable([
                    "name": AnyCodable(toolName),
                    "description": AnyCodable(active[toolName] ?? ""),
                    "parameters": AnyCodable([:] as [String: Any])
                ] as [String: AnyCodable])
            ]]
        }

        func execute(toolName: String, arguments: String) async throws -> String {
            lock.lock()
            invocations.append((toolName, arguments))
            lock.unlock()
            return "stub executed \(toolName)"
        }

        var executedInvocations: [(name: String, args: String)] {
            lock.lock(); defer { lock.unlock() }
            return invocations
        }
    }

    func testDeferredToolMiddlewareInjectsManifest() {
        let catalog = StubToolCatalog(
            deferred: [
                "send_email": "Send an email via the Mail app",
                "notion_query": "Query a Notion database",
            ]
        )
        let mw = DeferredToolMiddleware(catalog: catalog)
        let chain = MiddlewareChain()
        chain.add(mw)

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are Metamorphia."),
            ChatMessage(role: "user", content: "hi"),
        ]
        let ctx = makeCtx(chain: chain, command: "hi", iteration: 0, messages: messages)
        _ = chain.runBeforeModel(ctx)

        let sysContent = ctx.messages.first(where: { $0.role == "system" })?.content ?? ""
        XCTAssertTrue(sysContent.contains("send_email"))
        XCTAssertTrue(sysContent.contains("notion_query"))
        XCTAssertTrue(sysContent.contains("search_tools"))
    }

    func testSearchToolsToolPromotesAndReturnsSummary() async throws {
        let catalog = StubToolCatalog(
            deferred: ["send_email": "Send an email via Mail"]
        )
        let tool = SearchToolsTool(catalog: catalog)

        let result = try await tool.execute(arguments: #"{"query":"email"}"#)
        XCTAssertTrue(result.contains("send_email"))
        XCTAssertTrue(result.contains("Loaded tools"))

        // Promotion moved the tool from deferred to active.
        XCTAssertTrue(catalog.activeToolNames().contains("send_email"))
        XCTAssertTrue(catalog.deferredToolSummaries().isEmpty)
    }

    func testDeferredToolMiddlewareRefreshesAfterPromotion() {
        let catalog = StubToolCatalog(
            deferred: ["notion_query": "Query Notion"]
        )
        let mw = DeferredToolMiddleware(catalog: catalog)
        let chain = MiddlewareChain()
        chain.add(mw)

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "base"),
            ChatMessage(role: "user", content: "hi"),
        ]
        let ctx = makeCtx(chain: chain, command: "hi", iteration: 0, messages: messages)

        // Iteration 0: inject manifest
        _ = chain.runBeforeModel(ctx)

        // Simulate search_tools call that promoted something.
        catalog.promoteDeferred(names: ["notion_query"])
        let searchCall = makeToolCall(name: "search_tools")
        let searchResult = makeResult(
            callId: searchCall.id,
            toolName: "search_tools",
            result: "Loaded tools:\n• notion_query"
        )
        _ = chain.runAfterToolExecution(ctx, toolCalls: [searchCall], results: [searchResult])

        // Active tools should now include notion_query's schema.
        XCTAssertTrue(ctx.tools.contains { schema in
            (schema["function"]?.value as? [String: AnyCodable])?["name"]?.value as? String == "notion_query"
        })
    }

    func testUndoLastActionToolExecutesInverse() async throws {
        let catalog = StubToolCatalog()
        // Build a fake persistent storage containing an undoable action.
        let inverseArgs = #"{"action":"move","path":"/tmp/b.txt","destination":"/tmp/a.txt"}"#
        let undoable = ConversationBranchManager.UndoableAction(
            toolName: "file_operation",
            arguments: #"{"action":"move","path":"/tmp/a.txt","destination":"/tmp/b.txt"}"#,
            result: "moved",
            inverseAction: .init(
                toolName: "file_operation",
                arguments: inverseArgs,
                description: "Move back to original location"
            ),
            iteration: 0
        )
        let storage: [String: Any] = ["Branch.undoStack": [undoable]]

        let tool = UndoLastActionTool(catalog: catalog, storageProvider: { storage })

        // First call without confirm: just describes what would happen.
        let preview = try await tool.execute(arguments: #"{}"#)
        XCTAssertTrue(preview.contains("Can undo"))
        XCTAssertTrue(catalog.executedInvocations.isEmpty)

        // With confirm: actually calls the catalog.
        let result = try await tool.execute(arguments: #"{"confirm":true}"#)
        XCTAssertTrue(result.contains("Undone"))
        XCTAssertEqual(catalog.executedInvocations.count, 1)
        XCTAssertEqual(catalog.executedInvocations.first?.name, "file_operation")
    }
}
