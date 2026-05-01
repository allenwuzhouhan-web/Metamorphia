import XCTest
@testable import MetamorphiaPerception

/// Rank 7 — OCR policy decision matrix. These tests drive the pure
/// `OCRDecision.decide(...)` helper so the 4×4 gating table is locked down
/// without involving a live screen capture. The helper is the single switch
/// that drives the pipeline's OCR branch; pinning it here means future
/// refactors of `capture()` can't quietly change gating.
final class OCRGatingTests: XCTestCase {

    // MARK: - 1. .auto policy

    func testAuto_AXSufficient_NoProfileNeed_SkipsAll() {
        let decision = OCRDecision.decide(
            policy: .auto,
            axSufficient: true,
            profileNeedsOCR: false,
            hasPendingOCR: false
        )
        XCTAssertEqual(decision, .skipAll,
                       "AX-rich app with seed says no-OCR must skip screenshot entirely")
    }

    func testAuto_AXSufficient_ProfileNeeds_SchedulesBackground() {
        let decision = OCRDecision.decide(
            policy: .auto,
            axSufficient: true,
            profileNeedsOCR: true,
            hasPendingOCR: false
        )
        XCTAssertEqual(decision, .scheduleBackground,
                       "AX-rich but profile says OCR → enrich in background")
    }

    func testAuto_AXInsufficient_NoProfileNeed_MergesPending() {
        let decision = OCRDecision.decide(
            policy: .auto,
            axSufficient: false,
            profileNeedsOCR: false,
            hasPendingOCR: true
        )
        XCTAssertEqual(decision, .mergePendingOnly,
                       "AX-thin + pending OCR waiting → fold it in now")
    }

    func testAuto_AXInsufficient_NoProfileNeed_SchedulesBackground() {
        let decision = OCRDecision.decide(
            policy: .auto,
            axSufficient: false,
            profileNeedsOCR: false,
            hasPendingOCR: false
        )
        XCTAssertEqual(decision, .scheduleBackground,
                       "AX-thin, no profile hint, no pending → schedule for next tick")
    }

    func testAuto_AXInsufficient_ProfileNeeds_SyncOCR() {
        let decision = OCRDecision.decide(
            policy: .auto,
            axSufficient: false,
            profileNeedsOCR: true,
            hasPendingOCR: false
        )
        XCTAssertEqual(decision, .syncOCR,
                       "Canvas app (AX-thin + profile says OCR) → sync OCR")
    }

    /// Extra: same scenario but with pending — sync still wins because
    /// profile-needs-OCR is a stronger signal than recycling stale pending.
    func testAuto_AXInsufficient_ProfileNeeds_WithPending_SyncOCR() {
        let decision = OCRDecision.decide(
            policy: .auto,
            axSufficient: false,
            profileNeedsOCR: true,
            hasPendingOCR: true
        )
        XCTAssertEqual(decision, .syncOCR)
    }

    // MARK: - 2. .require policy

    func testRequire_AlwaysSyncOCR() {
        for axSufficient in [true, false] {
            for profileNeedsOCR in [true, false] {
                for hasPending in [true, false] {
                    let decision = OCRDecision.decide(
                        policy: .require,
                        axSufficient: axSufficient,
                        profileNeedsOCR: profileNeedsOCR,
                        hasPendingOCR: hasPending
                    )
                    XCTAssertEqual(decision, .syncOCR,
                                   ".require must force sync OCR regardless (\(axSufficient), \(profileNeedsOCR), \(hasPending))")
                }
            }
        }
    }

    // MARK: - 3. .skip policy

    func testSkip_AlwaysSkipAll() {
        for axSufficient in [true, false] {
            for profileNeedsOCR in [true, false] {
                for hasPending in [true, false] {
                    let decision = OCRDecision.decide(
                        policy: .skip,
                        axSufficient: axSufficient,
                        profileNeedsOCR: profileNeedsOCR,
                        hasPendingOCR: hasPending
                    )
                    XCTAssertEqual(decision, .skipAll,
                                   ".skip must skip regardless (\(axSufficient), \(profileNeedsOCR), \(hasPending))")
                }
            }
        }
    }

    // MARK: - 4. .async policy

    func testAsync_AlwaysSchedulesBackground() {
        for axSufficient in [true, false] {
            for profileNeedsOCR in [true, false] {
                for hasPending in [true, false] {
                    let decision = OCRDecision.decide(
                        policy: .async,
                        axSufficient: axSufficient,
                        profileNeedsOCR: profileNeedsOCR,
                        hasPendingOCR: hasPending
                    )
                    XCTAssertEqual(decision, .scheduleBackground,
                                   ".async must schedule background regardless (\(axSufficient), \(profileNeedsOCR), \(hasPending))")
                }
            }
        }
    }

    // MARK: - 5. Protocol shim

    /// The protocol extension should route `.auto` with `forceOCR: true` through
    /// to sync OCR. We can't exercise the extension directly without a
    /// conforming type, so we check the pipeline's in-function resolution by
    /// driving the decision helper with the pre-resolved policy.
    func testForceOCR_LegacyFlag_EquivalentToRequire() {
        // Pre-Rank-7 `forceOCR: true` path maps to `.require`.
        let legacy = OCRDecision.decide(
            policy: .require,
            axSufficient: true,          // AX is plenty — legacy still forced OCR
            profileNeedsOCR: false,
            hasPendingOCR: false
        )
        XCTAssertEqual(legacy, .syncOCR,
                       "legacy forceOCR: true must remain sync OCR even on AX-rich apps")
    }
}
