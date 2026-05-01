import XCTest
@testable import MetamorphiaAgentKit

final class ToolRegistryRoutingTests: XCTestCase {
    struct StubTool: ToolDefinition {
        let name: String
        let description: String
        let parameters: [String: Any] = [:]

        func execute(arguments: String) async throws -> String {
            "ok"
        }
    }

    private func makeRegistry() -> ToolRegistry {
        let registry = ToolRegistry()
        registry.register([
            (
                StubTool(
                    name: "recall_memory",
                    description: "Retrieve stored facts and preferences"
                ),
                .memory
            ),
            (
                StubTool(
                    name: "store_memory",
                    description: "Store durable user facts and preferences"
                ),
                .memory
            ),
            (
                StubTool(
                    name: "find_files",
                    description: "Search local files by name"
                ),
                .fileSearch
            ),
            (
                StubTool(
                    name: "read_file",
                    description: "Read a local file"
                ),
                .fileContent
            ),
            (
                StubTool(
                    name: "search_web",
                    description: "Search the web for current information"
                ),
                .web
            ),
        ])
        return registry
    }

    private func toolNames(_ schemas: [[String: AnyCodable]]) -> Set<String> {
        Set(schemas.compactMap { schema in
            guard let function = schema["function"]?.value as? [String: AnyCodable] else {
                return nil
            }
            return function["name"]?.value as? String
        })
    }

    func testCurrentFactQuestionDoesNotExposeMemoryOrFileTools() {
        let names = toolNames(
            makeRegistry().filteredToolDefinitions(for: "Who is the current president of US?")
        )

        XCTAssertTrue(names.contains("search_web"))
        XCTAssertFalse(names.contains("recall_memory"))
        XCTAssertFalse(names.contains("store_memory"))
        XCTAssertFalse(names.contains("find_files"))
        XCTAssertFalse(names.contains("read_file"))
    }

    func testPOTUSNowQuestionExposesWebSearch() {
        let names = toolNames(
            makeRegistry().filteredToolDefinitions(for: "who's the potus now?")
        )

        XCTAssertTrue(names.contains("search_web"))
        XCTAssertFalse(names.contains("recall_memory"))
        XCTAssertFalse(names.contains("find_files"))
    }

    func testPOTUSNowQuestionExposesWebSearchForGeneralAgentPath() {
        let names = toolNames(
            makeRegistry().filteredToolDefinitions(for: "who's the potus now?", agent: .general)
        )

        XCTAssertTrue(names.contains("search_web"))
        XCTAssertFalse(names.contains("recall_memory"))
        XCTAssertFalse(names.contains("find_files"))
    }

    func testPureKnowledgeQuestionExposesNoTools() {
        let names = toolNames(
            makeRegistry().filteredToolDefinitions(for: "Explain photosynthesis in one sentence")
        )

        XCTAssertTrue(names.isEmpty)
    }

    func testExplicitMemoryQuestionExposesMemoryTools() {
        let names = toolNames(
            makeRegistry().filteredToolDefinitions(for: "What do you remember about my preferred editor?")
        )

        XCTAssertTrue(names.contains("recall_memory"))
        XCTAssertTrue(names.contains("store_memory"))
        XCTAssertFalse(names.contains("find_files"))
    }
}
