import Foundation

/// Detects when an app's UI has changed significantly since last profiled.
/// Compares structural fingerprints and role distributions.
public enum DriftDetector {

    // MARK: - Drift Report

    public struct DriftReport: Sendable {
        public let appBundleID: String
        public let severity: DriftSeverity
        public let changes: [DriftChange]
        public let summary: String

        public init(appBundleID: String, severity: DriftSeverity, changes: [DriftChange], summary: String) {
            self.appBundleID = appBundleID
            self.severity = severity
            self.changes = changes
            self.summary = summary
        }
    }

    public enum DriftSeverity: Int, Comparable, Sendable {
        case none = 0
        case minor = 1       // 1-2 elements changed
        case moderate = 2    // toolbar changed, 10-20% element count shift
        case major = 3       // role distribution changed significantly

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum DriftChange: Sendable {
        case elementCountChanged(old: Int, new: Int)
        case roleDistributionChanged(role: String, old: Int, new: Int)
        case toolbarChanged(old: String, new: String)
        case menuBarChanged(removed: [String], added: [String])
        case structuralHashChanged
    }

    // MARK: - Detection

    /// Detect drift between a stored app profile and the current screen state.
    public static func detect(currentMap: ScreenMap, storedProfile: AppProfileRecord) -> DriftReport {
        var changes: [DriftChange] = []

        // Element count delta
        let currentCount = currentMap.metadata.elementCount
        let storedCount = storedProfile.elementCountAvg ?? 0
        if storedCount > 0 {
            let delta = abs(currentCount - storedCount)
            let pct = Float(delta) / Float(max(1, storedCount))
            if pct > 0.15 {
                changes.append(.elementCountChanged(old: storedCount, new: currentCount))
            }
        }

        // Role distribution changes
        if let storedJSON = storedProfile.roleDistributionJSON,
           let storedData = storedJSON.data(using: .utf8),
           let storedDist = try? JSONSerialization.jsonObject(with: storedData) as? [String: Int] {

            var currentDist: [String: Int] = [:]
            for el in currentMap.elements {
                currentDist[el.role.rawValue, default: 0] += 1
            }

            let allRoles = Set(storedDist.keys).union(currentDist.keys)
            for role in allRoles {
                let oldCount = storedDist[role] ?? 0
                let newCount = currentDist[role] ?? 0
                if abs(oldCount - newCount) > 3 {
                    changes.append(.roleDistributionChanged(role: role, old: oldCount, new: newCount))
                }
            }
        }

        // Toolbar signature
        if let storedToolbar = storedProfile.toolbarSignature {
            let currentToolbar = buildToolbarSignature(from: currentMap)
            if let current = currentToolbar, current != storedToolbar {
                changes.append(.toolbarChanged(old: storedToolbar, new: current))
            }
        }

        // Menu bar items
        if let storedMenuJSON = storedProfile.menuBarItemsJSON,
           let storedData = storedMenuJSON.data(using: .utf8),
           let storedItems = try? JSONSerialization.jsonObject(with: storedData) as? [String] {
            let currentItems = currentMap.elements
                .filter { $0.role == .menuBarItem }
                .map { $0.label }
            let removed = Set(storedItems).subtracting(currentItems)
            let added = Set(currentItems).subtracting(storedItems)
            if !removed.isEmpty || !added.isEmpty {
                changes.append(.menuBarChanged(removed: Array(removed), added: Array(added)))
            }
        }

        // Structural hash
        if let storedHash = storedProfile.structuralHash {
            let currentHash = AppProfile.computeStructuralHash(elements: currentMap.elements)
            if currentHash != storedHash {
                changes.append(.structuralHashChanged)
            }
        }

        // Classify severity
        let severity = classifySeverity(changes: changes, currentCount: currentMap.metadata.elementCount, storedCount: storedProfile.elementCountAvg ?? 0)

        // Build summary
        let summary = buildSummary(changes: changes, severity: severity, appName: storedProfile.appName)

        return DriftReport(
            appBundleID: storedProfile.bundleID,
            severity: severity,
            changes: changes,
            summary: summary
        )
    }

    /// Handle drift: adapt profiles, reduce confidence, warn if needed.
    public static func handleDrift(_ report: DriftReport, db: ElementDatabase) {
        switch report.severity {
        case .none:
            break

        case .minor:
            // Silently adapt: reduce confidence slightly
            db.reduceConfidence(appBundleID: report.appBundleID, factor: 0.9)

        case .moderate:
            // Adapt + log warning
            db.reduceConfidence(appBundleID: report.appBundleID, factor: 0.7)
            print("[DriftDetector] Moderate UI change in \(report.appBundleID): \(report.summary)")

        case .major:
            // Strong warning, significant confidence reduction
            db.reduceConfidence(appBundleID: report.appBundleID, factor: 0.4)
            print("[DriftDetector] MAJOR UI change in \(report.appBundleID): \(report.summary)")
        }
    }

    // MARK: - Helpers

    private static func buildToolbarSignature(from map: ScreenMap) -> String? {
        let items = map.elements
            .filter { $0.role == .toolbarItem || ($0.role == .button && $0.depth <= 3) }
            .prefix(10)
            .map { $0.label }
            .sorted()
        let sig = items.joined(separator: "|")
        return sig.isEmpty ? nil : sig
    }

    private static func classifySeverity(changes: [DriftChange], currentCount: Int, storedCount: Int) -> DriftSeverity {
        if changes.isEmpty { return .none }

        let countPct = storedCount > 0 ? Float(abs(currentCount - storedCount)) / Float(storedCount) : 0

        let hasToolbarChange = changes.contains(where: {
            if case .toolbarChanged = $0 { return true }; return false
        })
        let hasMenuChange = changes.contains(where: {
            if case .menuBarChanged = $0 { return true }; return false
        })

        if countPct > 0.3 || (hasToolbarChange && hasMenuChange) || changes.count > 5 {
            return .major
        }
        if countPct > 0.15 || hasToolbarChange || changes.count > 2 {
            return .moderate
        }
        return .minor
    }

    private static func buildSummary(changes: [DriftChange], severity: DriftSeverity, appName: String) -> String {
        if changes.isEmpty { return "No drift detected in \(appName)" }

        var parts: [String] = ["\(appName) UI drift (\(severity)):"]
        for change in changes.prefix(3) {
            switch change {
            case .elementCountChanged(let old, let new):
                parts.append("elements: \(old) → \(new)")
            case .roleDistributionChanged(let role, let old, let new):
                parts.append("\(role): \(old) → \(new)")
            case .toolbarChanged:
                parts.append("toolbar changed")
            case .menuBarChanged(let removed, let added):
                if !removed.isEmpty { parts.append("menu removed: \(removed.joined(separator: ", "))") }
                if !added.isEmpty { parts.append("menu added: \(added.joined(separator: ", "))") }
            case .structuralHashChanged:
                parts.append("structural fingerprint changed")
            }
        }
        return parts.joined(separator: "; ")
    }
}
