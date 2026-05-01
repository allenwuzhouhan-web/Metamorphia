import XCTest
@testable import MetamorphiaPerception

/// Rank 7 — bootstrap profile seeder. These tests cover the idempotency,
/// user-profile protection, and default OCR classification for the two seed
/// lists. Uses in-memory `ElementDatabase` so the host machine's real profile
/// store is never touched.
final class AppProfileSeedsTests: XCTestCase {

    // MARK: - 1. Installation

    func testSeeds_installInEmptyDatabase_AllEntriesPresent() {
        let db = ElementDatabase(inMemory: true)

        AppProfileSeeds.installIfNeeded(into: db)

        for seed in AppProfileSeeds.axRichApps {
            let record = db.getAppProfile(bundleID: seed.bundleID)
            XCTAssertNotNil(record, "axRich seed missing: \(seed.bundleID)")
            XCTAssertEqual(record?.appName, seed.name)
            XCTAssertEqual(record?.profiledBy, AppProfileSeeds.seedVersion)
            XCTAssertEqual(record?.needsOCR, false, "axRich must be needsOCR=false: \(seed.bundleID)")
        }
        for seed in AppProfileSeeds.ocrRequiredApps {
            let record = db.getAppProfile(bundleID: seed.bundleID)
            XCTAssertNotNil(record, "ocrRequired seed missing: \(seed.bundleID)")
            XCTAssertEqual(record?.appName, seed.name)
            XCTAssertEqual(record?.profiledBy, AppProfileSeeds.seedVersion)
            XCTAssertEqual(record?.needsOCR, true, "ocrRequired must be needsOCR=true: \(seed.bundleID)")
        }
    }

    // MARK: - 2. Idempotency

    func testSeeds_installTwice_Idempotent() {
        let db = ElementDatabase(inMemory: true)

        AppProfileSeeds.installIfNeeded(into: db)
        let stats1 = db.stats()

        // Second install should not create duplicates or bump profile_version
        // since the short-circuit skips rows already tagged with seedVersion.
        AppProfileSeeds.installIfNeeded(into: db)
        let stats2 = db.stats()

        XCTAssertEqual(stats1.appProfileCount, stats2.appProfileCount,
                       "second install should not add rows")

        // Pick one to verify profile_version didn't bump on the no-op path.
        let safariV1 = db.getAppProfile(bundleID: "com.apple.Safari")?.profileVersion
        AppProfileSeeds.installIfNeeded(into: db)
        let safariV2 = db.getAppProfile(bundleID: "com.apple.Safari")?.profileVersion
        XCTAssertEqual(safariV1, safariV2,
                       "profile_version must not advance on idempotent re-install")
    }

    // MARK: - 3. User-profile protection

    func testSeeds_doesNotClobberUserProfile() {
        let db = ElementDatabase(inMemory: true)

        let userProfile = AppProfileRecord(
            bundleID: "com.apple.Safari",
            appName: "Safari (user-customized)",
            appVersion: "18.0",
            needsOCR: true,                      // user says YES OCR (seed says no)
            axCoveragePct: 0.50,
            elementCountAvg: 120,
            interactiveCountAvg: 40,
            structuralHash: "deadbeef",
            roleDistributionJSON: nil,
            toolbarSignature: nil,
            menuBarItemsJSON: nil,
            customRolesJSON: nil,
            elementAliasesJSON: nil,
            lastProfiled: Date(),
            profiledBy: "user",
            profileVersion: 1
        )
        db.saveAppProfile(userProfile)

        AppProfileSeeds.installIfNeeded(into: db)

        let after = db.getAppProfile(bundleID: "com.apple.Safari")
        XCTAssertEqual(after?.profiledBy, "user", "user profile must survive seed install")
        XCTAssertEqual(after?.needsOCR, true, "user's needsOCR override must survive")
        XCTAssertEqual(after?.appName, "Safari (user-customized)")
    }

    /// Auto-profiles (built from live captures) also win over seeds — live data
    /// is a better signal than our seed guess on this particular machine.
    func testSeeds_doesNotClobberAutoProfile() {
        let db = ElementDatabase(inMemory: true)

        let autoProfile = AppProfileRecord(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            appVersion: "18.0",
            needsOCR: true,                       // auto inference from live capture
            axCoveragePct: 0.40,
            elementCountAvg: 80,
            interactiveCountAvg: 20,
            structuralHash: nil,
            roleDistributionJSON: nil,
            toolbarSignature: nil,
            menuBarItemsJSON: nil,
            customRolesJSON: nil,
            elementAliasesJSON: nil,
            lastProfiled: Date(),
            profiledBy: "auto",
            profileVersion: 2
        )
        db.saveAppProfile(autoProfile)

        AppProfileSeeds.installIfNeeded(into: db)

        let after = db.getAppProfile(bundleID: "com.apple.Safari")
        XCTAssertEqual(after?.profiledBy, "auto", "auto profile must survive seed install")
        XCTAssertEqual(after?.needsOCR, true)
    }

    // MARK: - 4. Classification

    func testSeeds_axRichHaveNeedsOCRFalse() {
        for seed in AppProfileSeeds.axRichApps {
            // Spot-check via the seed lookup helper too, which powers
            // `appProfileIsOCRRequired` when no DB profile exists.
            let lookup = AppProfileSeeds.seedFor(bundleID: seed.bundleID)
            XCTAssertNotNil(lookup, "axRich seed lookup missing: \(seed.bundleID)")
            XCTAssertFalse(lookup?.needsOCR ?? true, "axRich must be needsOCR=false: \(seed.bundleID)")
        }
    }

    func testSeeds_canvasAppsHaveNeedsOCRTrue() {
        for seed in AppProfileSeeds.ocrRequiredApps {
            let lookup = AppProfileSeeds.seedFor(bundleID: seed.bundleID)
            XCTAssertNotNil(lookup, "ocrRequired seed lookup missing: \(seed.bundleID)")
            XCTAssertTrue(lookup?.needsOCR ?? false, "ocrRequired must be needsOCR=true: \(seed.bundleID)")
        }
    }

    // MARK: - 5. Uniqueness

    func testSeeds_bundleIDsAreUnique() {
        var seen: Set<String> = []
        var duplicates: [String] = []

        for seed in AppProfileSeeds.axRichApps {
            if !seen.insert(seed.bundleID).inserted {
                duplicates.append(seed.bundleID)
            }
        }
        for seed in AppProfileSeeds.ocrRequiredApps {
            if !seen.insert(seed.bundleID).inserted {
                duplicates.append(seed.bundleID)
            }
        }

        XCTAssertTrue(duplicates.isEmpty,
                      "duplicate bundle IDs across seed lists: \(duplicates)")
    }

    // MARK: - 6. Ax coverage plausibility

    func testSeeds_axCoverageInValidRange() {
        for seed in AppProfileSeeds.axRichApps + AppProfileSeeds.ocrRequiredApps {
            XCTAssertGreaterThanOrEqual(seed.axCoverage, 0.0, "\(seed.bundleID)")
            XCTAssertLessThanOrEqual(seed.axCoverage, 1.0, "\(seed.bundleID)")
        }
    }
}
