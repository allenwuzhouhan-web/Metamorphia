import Foundation
import AppKit

/// Per-app UI profiles. Tracks AX coverage, element counts, structural fingerprints.
/// Auto-created on first encounter, user-refinable via `computer profile <app>`.
public enum AppProfile {

    /// Build a profile from a live screen capture.
    public static func buildFromCapture(map: ScreenMap) -> AppProfileRecord? {
        guard let bundleID = map.focusedApp.bundleID else { return nil }

        // Count roles
        var roleDist: [String: Int] = [:]
        for el in map.elements {
            roleDist[el.role.rawValue, default: 0] += 1
        }
        let roleJSON = (try? JSONSerialization.data(withJSONObject: roleDist))
            .flatMap { String(data: $0, encoding: .utf8) }

        // Menu bar items
        let menuItems = map.elements
            .filter { $0.role == .menuBarItem }
            .map { $0.label }
        let menuJSON = (try? JSONSerialization.data(withJSONObject: menuItems))
            .flatMap { String(data: $0, encoding: .utf8) }

        // Toolbar signature: sorted labels of toolbar children
        let toolbarItems = map.elements
            .filter { $0.role == .toolbarItem || ($0.role == .button && $0.depth <= 3) }
            .prefix(10)
            .map { $0.label }
            .sorted()
        let toolbarSig = toolbarItems.joined(separator: "|")

        // Structural hash
        let structHash = computeStructuralHash(elements: map.elements)

        // Get app version from bundle
        let appVersion = bundleID.isEmpty ? nil : getAppVersion(bundleID: bundleID)

        return AppProfileRecord(
            bundleID: bundleID,
            appName: map.focusedApp.name,
            appVersion: appVersion,
            needsOCR: map.metadata.ocrUsed,
            axCoveragePct: map.metadata.axCoveragePercent,
            elementCountAvg: map.metadata.elementCount,
            interactiveCountAvg: map.metadata.interactiveCount,
            structuralHash: structHash,
            roleDistributionJSON: roleJSON,
            toolbarSignature: toolbarSig.isEmpty ? nil : toolbarSig,
            menuBarItemsJSON: menuJSON,
            customRolesJSON: nil,
            elementAliasesJSON: nil,
            lastProfiled: Date(),
            profiledBy: "auto",
            profileVersion: 1
        )
    }

    /// Auto-profile on capture: save profile if it's new or stale.
    public static func autoProfile(map: ScreenMap, db: ElementDatabase) {
        guard let bundleID = map.focusedApp.bundleID else { return }

        // Check if we already have a recent profile
        if let existing = db.getAppProfile(bundleID: bundleID) {
            let age = Date().timeIntervalSince(existing.lastProfiled)
            guard age > 3600 else { return } // Don't re-profile within 1 hour
        }

        guard let profile = buildFromCapture(map: map) else { return }
        db.saveAppProfile(profile)
    }

    /// Check if an app needs OCR based on stored profile.
    public static func needsOCR(bundleID: String, db: ElementDatabase) -> Bool {
        db.getAppProfile(bundleID: bundleID)?.needsOCR ?? false
    }

    // MARK: - Structural Hash

    /// Compute a structural fingerprint from elements for drift detection.
    public static func computeStructuralHash(elements: [ScreenElement]) -> String {
        var hash: UInt64 = 5381
        // Hash the role distribution (sorted)
        var roleCounts: [String: Int] = [:]
        for el in elements {
            roleCounts[el.role.rawValue, default: 0] += 1
        }
        for (role, count) in roleCounts.sorted(by: { $0.key < $1.key }) {
            for byte in role.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }
            hash = ((hash &<< 5) &+ hash) &+ UInt64(count)
        }
        return String(hash, radix: 16)
    }

    // MARK: - Helpers

    private static func getAppVersion(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
