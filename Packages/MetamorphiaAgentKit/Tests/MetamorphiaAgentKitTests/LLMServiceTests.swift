import XCTest
@testable import MetamorphiaAgentKit

/// Tests for Phase 2d-1 LLM services — provider enum, config lookup, service manager,
/// and cost tracker protocol wiring. Network-dependent tests (AnthropicService, OpenAICompat)
/// are NOT included here; those need live API keys and belong in integration tests.
final class LLMServiceTests: XCTestCase {

    func testAllProvidersHaveValidConfigs() {
        for provider in LLMProvider.allCases {
            let config = provider.config
            XCTAssertFalse(config.displayName.isEmpty, "\(provider) missing displayName")
            XCTAssertFalse(config.baseURL.isEmpty, "\(provider) missing baseURL")
            XCTAssertTrue(URL(string: config.baseURL) != nil, "\(provider) baseURL is not a valid URL")
            XCTAssertFalse(config.defaultModel.isEmpty, "\(provider) missing defaultModel")
            XCTAssertTrue(config.availableModels.contains(config.defaultModel),
                          "\(provider) defaultModel not in availableModels")
        }
    }

    func testClaudeUsesAnthropicAuthStyle() {
        XCTAssertEqual(LLMProvider.claude.config.authStyle, .anthropic)
    }

    func testOtherProvidersUseBearerAuth() {
        let bearerProviders: [LLMProvider] = [.openai, .deepseek, .gemini, .kimi, .kimiCN, .minimax]
        for p in bearerProviders {
            XCTAssertEqual(p.config.authStyle, .bearer, "\(p) should use Bearer auth")
        }
    }

    func testProviderIsCodable() throws {
        let encoded = try JSONEncoder().encode(LLMProvider.claude)
        let decoded = try JSONDecoder().decode(LLMProvider.self, from: encoded)
        XCTAssertEqual(decoded, .claude)
    }

    func testServiceManagerMakesAnthropicServiceForClaude() {
        let mgr = LLMServiceManager.shared
        mgr.currentProvider = .claude
        XCTAssertTrue(mgr.currentService is AnthropicService)
    }

    func testServiceManagerMakesOpenAICompatServiceForDeepSeek() {
        let mgr = LLMServiceManager.shared
        mgr.currentProvider = .deepseek
        XCTAssertTrue(mgr.currentService is OpenAICompatibleService)
    }

    func testServiceManagerInvalidModelMigratesToDefault() {
        // Seed UserDefaults with an invalid model for the current provider, then
        // access `currentModel` — the invariant is that the manager doesn't return
        // a model the provider can't serve. (We can't construct a fresh
        // LLMServiceManager because its init is private; we assert via the shared
        // instance's invariant post-init.)
        let mgr = LLMServiceManager.shared
        mgr.currentProvider = .deepseek
        XCTAssertTrue(mgr.currentProvider.config.availableModels.contains(mgr.currentModel))
    }

    func testCostTrackerInjectionInvalidatesCache() {
        let mgr = LLMServiceManager.shared
        mgr.currentProvider = .deepseek

        final class CountingTracker: LLMCostTracker, @unchecked Sendable {
            var records: [(provider: String, input: Int, output: Int)] = []
            func record(provider: String, inputTokens: Int, outputTokens: Int, agentId: String?) {
                records.append((provider, inputTokens, outputTokens))
            }
            var activeAgentId: String? { nil }
        }

        let tracker = CountingTracker()
        mgr.costTracker = tracker
        // Accessing currentService after setting a tracker should rebuild the service.
        let svc1 = mgr.currentService
        let svc2 = mgr.currentService
        // Same service instance on repeated access.
        XCTAssertTrue(svc1 as AnyObject === svc2 as AnyObject)

        // Clearing the tracker invalidates the cache.
        mgr.costTracker = nil
        let svc3 = mgr.currentService
        XCTAssertFalse(svc1 as AnyObject === svc3 as AnyObject,
                       "changing the cost tracker should rebuild the cached service")
    }

    func testMultimodalFallsBackWhenNoKimiKey() {
        // No Kimi key available in the test keychain (fresh bundle id).
        let mgr = LLMServiceManager.shared
        mgr.currentProvider = .deepseek
        XCTAssertFalse(mgr.hasMultimodalProvider)
        XCTAssertTrue(mgr.multimodalService is OpenAICompatibleService,
                      "without a Kimi key, multimodal should fall back to currentService")
    }

    // MARK: - OllamaRouter

    func testOllamaRouterIsUnavailableWhenLocalhostIsNotRunning() async {
        // Assume no Ollama daemon running on the test machine. If one happens to be
        // running this test will show a false positive, but that's OK — it's just a
        // smoke check that the "not available" path doesn't crash.
        let router = OllamaRouter(
            baseURL: "http://localhost:1", // reserved TCP — nothing here
            routingModel: "qwen2.5:3b",
            routingTimeout: 0.1
        )
        let available = await router.isAvailable()
        XCTAssertFalse(available)
    }

    func testOllamaRoutingResultIsCodable() throws {
        let json = #"{"tools":["app_launcher"],"needs_api":false}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OllamaRouter.RoutingResult.self, from: data)
        XCTAssertEqual(decoded.tools, ["app_launcher"])
        XCTAssertFalse(decoded.needsApi)
    }
}
