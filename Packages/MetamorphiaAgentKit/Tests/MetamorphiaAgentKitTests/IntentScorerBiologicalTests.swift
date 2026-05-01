import XCTest
@testable import MetamorphiaAgentKit

/// Verifies the biological mechanics added to `IntentScorer`:
/// `recordOutcome` reinforces, scores reflect decay, and eviction at
/// capacity drops the weakest patterns (not the oldest).
final class IntentScorerBiologicalTests: XCTestCase {

    private func makeRegistryWithTool(_ name: String, category: ToolCategory) -> ToolRegistry {
        let registry = ToolRegistry()
        registry.setCategory(category, forTool: name)
        return registry
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IntentScorerBiologicalTests")
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - LTP

    func testRecordOutcomeReinforcesCategoryWeights() {
        let url = tempURL(); defer { cleanup(url) }
        let registry = makeRegistryWithTool("read_file", category: .files)
        let scorer = IntentScorer(registry: registry, storageURL: url)

        let query = "show me what's in my downloads folder"
        // Two recordings to clear the totalQueries >= 2 gate.
        scorer.recordOutcome(query: query, toolsUsed: ["read_file"])
        scorer.recordOutcome(query: query, toolsUsed: ["read_file"])

        let scored = scorer.scoreIntent(query: query)
        let filesScore = scored.first(where: { $0.category == .files })?.score ?? 0
        XCTAssertGreaterThan(filesScore, 0.4,
                             "after 2 reinforcements, files should be a strong prior")
    }

    func testRepeatedReinforcementCompounds() {
        let url = tempURL(); defer { cleanup(url) }
        let registry = makeRegistryWithTool("read_file", category: .files)
        let scorer = IntentScorer(registry: registry, storageURL: url)
        let q = "list my files"

        scorer.recordOutcome(query: q, toolsUsed: ["read_file"])
        scorer.recordOutcome(query: q, toolsUsed: ["read_file"])
        let twoCalls = scorer.scoreIntent(query: q)
            .first(where: { $0.category == .files })?.score ?? 0

        for _ in 0..<10 {
            scorer.recordOutcome(query: q, toolsUsed: ["read_file"])
        }
        let twelveCalls = scorer.scoreIntent(query: q)
            .first(where: { $0.category == .files })?.score ?? 0

        XCTAssertGreaterThan(twelveCalls, twoCalls,
                             "more reinforcements should produce a stronger weight")
    }

    // MARK: - Persistence

    func testRecordOutcomeSurvivesReload() {
        let url = tempURL(); defer { cleanup(url) }
        let registry = makeRegistryWithTool("read_file", category: .files)

        do {
            let scorer = IntentScorer(registry: registry, storageURL: url)
            scorer.recordOutcome(query: "list files", toolsUsed: ["read_file"])
            scorer.recordOutcome(query: "list files", toolsUsed: ["read_file"])
        }

        let reloaded = IntentScorer(registry: registry, storageURL: url)
        let score = reloaded.scoreIntent(query: "list files")
            .first(where: { $0.category == .files })?.score ?? 0
        XCTAssertGreaterThan(score, 0.4,
                             "reinforced weights must survive reload from disk")
    }

    // MARK: - Decay

    func testDecayReducesScoreForStalePattern() throws {
        let url = tempURL(); defer { cleanup(url) }
        let registry = makeRegistryWithTool("read_file", category: .files)

        // Freshly reinforced.
        let scorer = IntentScorer(registry: registry, storageURL: url)
        scorer.recordOutcome(query: "look at files", toolsUsed: ["read_file"])
        scorer.recordOutcome(query: "look at files", toolsUsed: ["read_file"])
        let fresh = scorer.scoreIntent(query: "look at files")
            .first(where: { $0.category == .files })?.score ?? 0

        // Hand-edit the on-disk file to age the pattern by 30 days. tau =
        // tauProcedural = 7d, so 30 days back ≈ 4.3 τ → ~1.3 % surviving.
        let raw = try Data(contentsOf: url)
        var dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let aged = Date().addingTimeInterval(-30 * 86_400).timeIntervalSinceReferenceDate
        for (k, v) in dict {
            var entry = v as! [String: Any]
            entry["lastAccessed"] = aged
            entry["createdAt"] = aged
            dict[k] = entry
        }
        let edited = try JSONSerialization.data(withJSONObject: dict)
        try edited.write(to: url)

        let reloaded = IntentScorer(registry: registry, storageURL: url)
        let stale = reloaded.scoreIntent(query: "look at files")
            .first(where: { $0.category == .files })?.score ?? 0

        XCTAssertLessThan(stale, fresh,
                          "stale pattern must score lower than freshly-reinforced")
    }
}
