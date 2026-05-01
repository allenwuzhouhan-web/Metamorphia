import XCTest
@testable import MetamorphiaAgentKit

/// Verifies the biological-memory primitives (LTP saturation, exponential
/// decay, eviction threshold, Potentiated extension methods).
final class SynapticMemoryTests: XCTestCase {

    // MARK: - SynapticStrength

    func testInitClampsOutOfRangeValues() {
        XCTAssertEqual(SynapticStrength(-0.5).value, 0.0)
        XCTAssertEqual(SynapticStrength(1.7).value, 1.0)
        XCTAssertEqual(SynapticStrength(0.42).value, 0.42, accuracy: 1e-12)
    }

    func testReinforceSaturatesNearOne() {
        var s = SynapticStrength(0.0)
        for _ in 0..<1000 {
            s.reinforce(delta: 0.1)
        }
        XCTAssertGreaterThan(s.value, 0.95, "1000 reinforcements should approach 1.0")
        XCTAssertLessThanOrEqual(s.value, 1.0, "must never exceed 1.0")
    }

    func testReinforceMovesFasterFarFromOne() {
        var low = SynapticStrength(0.2)
        var high = SynapticStrength(0.9)
        let delta = 0.05
        let lowBefore = low.value
        let highBefore = high.value
        low.reinforce(delta: delta)
        high.reinforce(delta: delta)
        let lowGain = low.value - lowBefore
        let highGain = high.value - highBefore
        XCTAssertGreaterThan(lowGain, highGain,
                             "headroom-scaled LTP must move further from baseline")
    }

    func testReinforceZeroOrNegativeDeltaIsNoop() {
        var s = SynapticStrength(0.4)
        s.reinforce(delta: 0.0)
        XCTAssertEqual(s.value, 0.4)
        s.reinforce(delta: -0.1)
        XCTAssertEqual(s.value, 0.4)
    }

    func testDecayAtOneTauHitsOneOverE() {
        var s = SynapticStrength(1.0)
        let tau: TimeInterval = 86_400
        s.decay(elapsed: tau, tau: tau)
        XCTAssertEqual(s.value, 1.0 / M_E, accuracy: 1e-9)
    }

    func testDecayIsNoopForNonPositiveArgs() {
        var s = SynapticStrength(0.6)
        s.decay(elapsed: 0, tau: 100)
        XCTAssertEqual(s.value, 0.6)
        s.decay(elapsed: 100, tau: 0)
        XCTAssertEqual(s.value, 0.6)
        s.decay(elapsed: -100, tau: 100)
        XCTAssertEqual(s.value, 0.6)
    }

    func testEvictionThresholdBoundary() {
        XCTAssertTrue(SynapticStrength(0.04).isEligibleForEviction)
        XCTAssertFalse(SynapticStrength(0.06).isEligibleForEviction)
        XCTAssertFalse(SynapticStrength(SynapseDefaults.evictionThreshold).isEligibleForEviction)
    }

    func testCodableRoundTripClampsCorruptedDiskValues() throws {
        let bogus = "1.7".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SynapticStrength.self, from: bogus)
        XCTAssertEqual(decoded.value, 1.0, "decoded value must be clamped to [0, 1]")
        let encoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(SynapticStrength.self, from: encoded)
        XCTAssertEqual(again.value, 1.0)
    }

    // MARK: - Potentiated

    private struct Probe: Potentiated {
        var strength: SynapticStrength
        var lastAccessed: Date
        var accessCount: Int
        let createdAt: Date
        static var decayTau: TimeInterval { 86_400 }
    }

    func testLazilyDecayUpdatesStrengthAndLastAccessed() {
        let past = Date().addingTimeInterval(-86_400)
        var p = Probe(strength: SynapticStrength(1.0), lastAccessed: past,
                      accessCount: 0, createdAt: past)
        let now = Date()
        p.lazilyDecay(now: now)
        XCTAssertEqual(p.strength.value, 1.0 / M_E, accuracy: 1e-3)
        XCTAssertEqual(p.lastAccessed.timeIntervalSince(now), 0, accuracy: 1e-6)
    }

    func testReinforceOnRecallBoostsAndCounts() {
        var p = Probe(strength: SynapticStrength(0.5), lastAccessed: Date(),
                      accessCount: 3, createdAt: Date())
        p.reinforceOnRecall(delta: 0.05)
        XCTAssertGreaterThan(p.strength.value, 0.5)
        XCTAssertEqual(p.accessCount, 4)
    }
}
