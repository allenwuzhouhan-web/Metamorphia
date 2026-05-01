import Combine
import XCTest
@testable import MetamorphiaAgentKit

/// Guard-behavior tests for `ProposalLoop`. Every guard is verified in
/// isolation via the injected attention-score / budget-tier closures so
/// the loop can be driven hermetically — no AttentionModel, no
/// PerceptionBudget, no main actor.
final class ProposalLoopGuardsTests: XCTestCase {

    // MARK: - Attention band

    func testGuard_attentionBelowLowerBound_noEmission() async {
        let received = try? await runProposalFlow(attention: 0.4, budget: 3)
        XCTAssertNil(received, "below-band attention must suppress")
    }

    func testGuard_attentionAboveUpperBound_noEmission() async {
        let received = try? await runProposalFlow(attention: 0.95, budget: 3)
        XCTAssertNil(received, "above-band attention must suppress")
    }

    func testGuard_attentionInBetweenTasksBand_emits() async throws {
        let received = await runProposalFlow(attention: 0.7, budget: 3)
        let proposal = try XCTUnwrap(received)
        XCTAssertEqual(proposal.goal, .pasteLink)
    }

    // MARK: - Budget tier

    func testGuard_budgetParked_noEmission() async {
        let received = try? await runProposalFlow(attention: 0.7, budget: 0)
        XCTAssertNil(received, "parked budget must suppress")
    }

    func testGuard_budgetMinimal_noEmission() async {
        let received = try? await runProposalFlow(attention: 0.7, budget: 1)
        XCTAssertNil(received, "minimal budget must suppress (below .reduced)")
    }

    func testGuard_budgetReduced_emits() async throws {
        // tier == 2 is the minimum allowed — lock this boundary in.
        let received = await runProposalFlow(attention: 0.7, budget: 2)
        let proposal = try XCTUnwrap(received)
        XCTAssertEqual(proposal.goal, .pasteLink)
    }

    // MARK: - Helpers

    /// Construct a loop + stream, emit a clipboardCopied(.url) → focusChanged
    /// pair to a paste-friendly bundle (Slack), and await the publisher's
    /// first emission (or its absence).
    private func runProposalFlow(
        attention: Double,
        budget: Int
    ) async -> Proposal? {
        let stream = ActivityStream(gate: AlwaysOnGate())
        let loop = ProposalLoop()
        await loop.start(
            stream: stream,
            attentionScore: { attention },
            budgetTier: { budget }
        )

        let expectation = XCTestExpectation(description: "proposal")
        var received: Proposal?
        var bag: Set<AnyCancellable> = []
        loop.proposalsPublisher
            .sink { p in
                received = p
                expectation.fulfill()
            }
            .store(in: &bag)

        // Emit the paste-link shape.
        let base = Date()
        await stream.emit(.clipboardCopied(
            kind: .url, byteCount: 42, origin: .local,
            at: base
        ))
        await stream.emit(.focusChanged(
            bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
            windowTitle: "Compose",
            pid: 1234, at: base.addingTimeInterval(1)
        ))

        // Short bounded wait — fine for CI, the loop hops once per event.
        _ = await XCTWaiter().fulfillment(of: [expectation], timeout: 0.5)
        bag.removeAll()
        return received
    }
}
