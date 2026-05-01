import Foundation
import CoreGraphics

/// Two-tier screen change detection: fast dHash comparison + element-set diffing.
public enum ChangeDetector {

    // MARK: - Screen Diff

    /// Describes what changed between two snapshots.
    public struct ScreenDiff: Sendable {
        public let hasMajorChange: Bool
        public let appSwitched: Bool
        public let previousApp: String?
        public let currentApp: String?
        public let added: [ScreenElement]
        public let removed: [ScreenElement]
        public let changed: [ElementChange]
        public let summary: String

        public init(
            hasMajorChange: Bool,
            appSwitched: Bool,
            previousApp: String?,
            currentApp: String?,
            added: [ScreenElement],
            removed: [ScreenElement],
            changed: [ElementChange],
            summary: String
        ) {
            self.hasMajorChange = hasMajorChange
            self.appSwitched = appSwitched
            self.previousApp = previousApp
            self.currentApp = currentApp
            self.added = added
            self.removed = removed
            self.changed = changed
            self.summary = summary
        }

        /// True when nothing changed at all.
        public var isEmpty: Bool {
            !hasMajorChange && !appSwitched && added.isEmpty && removed.isEmpty && changed.isEmpty
        }
    }

    /// A single element that changed between snapshots.
    public struct ElementChange: Sendable {
        public let ref: ElementRef
        public let field: String        // "label", "value", "state", "position"
        public let oldValue: String
        public let newValue: String

        public init(ref: ElementRef, field: String, oldValue: String, newValue: String) {
            self.ref = ref
            self.field = field
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }

    // MARK: - Tier 1: Fast Visual Change (dHash)

    /// Compare two screenshots via perceptual hash. Cost: <1ms total.
    /// Returns hamming distance — 0 means identical, >10 means major visual change.
    public static func visualDistance(previous: UInt64, current: UInt64) -> Int {
        ScreenCapture.hammingDistance(previous, current)
    }

    /// Quick check: did the screen change visually?
    public static func hasVisualChange(previousHash: UInt64, currentHash: UInt64, threshold: Int = 5) -> Bool {
        visualDistance(previous: previousHash, current: currentHash) > threshold
    }

    // MARK: - Tier 2: Element-Set Diffing

    /// Compare two ScreenMaps element-by-element. Catches subtle state changes that dHash misses.
    public static func diff(previous: ScreenMap, current: ScreenMap) -> ScreenDiff {
        // Check for app switch
        let appSwitched = previous.focusedApp.pid != current.focusedApp.pid

        // Build lookup by ref
        let prevByRef = Dictionary(
            previous.elements.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currByRef = Dictionary(
            current.elements.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let prevRefs = Set(prevByRef.keys)
        let currRefs = Set(currByRef.keys)

        // Added elements: in current but not previous
        let addedRefs = currRefs.subtracting(prevRefs)
        let added = addedRefs.compactMap { currByRef[$0] }

        // Removed elements: in previous but not current
        let removedRefs = prevRefs.subtracting(currRefs)
        let removed = removedRefs.compactMap { prevByRef[$0] }

        // Changed elements: same ref but different properties
        var changed: [ElementChange] = []
        let commonRefs = prevRefs.intersection(currRefs)
        for ref in commonRefs {
            guard let prev = prevByRef[ref], let curr = currByRef[ref] else { continue }

            if prev.label != curr.label {
                changed.append(ElementChange(
                    ref: ref, field: "label",
                    oldValue: prev.label, newValue: curr.label
                ))
            }

            if prev.value != curr.value {
                changed.append(ElementChange(
                    ref: ref, field: "value",
                    oldValue: String(prev.value.prefix(50)),
                    newValue: String(curr.value.prefix(50))
                ))
            }

            if prev.state != curr.state {
                changed.append(ElementChange(
                    ref: ref, field: "state",
                    oldValue: prev.state.names.joined(separator: ","),
                    newValue: curr.state.names.joined(separator: ",")
                ))
            }

            if let prevBounds = prev.bounds, let currBounds = curr.bounds {
                let dx = abs(prevBounds.origin.x - currBounds.origin.x)
                let dy = abs(prevBounds.origin.y - currBounds.origin.y)
                if dx > 10 || dy > 10 {
                    changed.append(ElementChange(
                        ref: ref, field: "position",
                        oldValue: "\(Int(prevBounds.origin.x)),\(Int(prevBounds.origin.y))",
                        newValue: "\(Int(currBounds.origin.x)),\(Int(currBounds.origin.y))"
                    ))
                }
            }
        }

        // Determine if major change
        let hasMajor = appSwitched || added.count > 5 || removed.count > 5

        // Build summary
        let summary = buildSummary(
            appSwitched: appSwitched,
            previousApp: previous.focusedApp.name,
            currentApp: current.focusedApp.name,
            added: added, removed: removed, changed: changed
        )

        return ScreenDiff(
            hasMajorChange: hasMajor,
            appSwitched: appSwitched,
            previousApp: appSwitched ? previous.focusedApp.name : nil,
            currentApp: appSwitched ? current.focusedApp.name : nil,
            added: added,
            removed: removed,
            changed: changed,
            summary: summary
        )
    }

    // MARK: - Summary Builder

    private static func buildSummary(
        appSwitched: Bool,
        previousApp: String,
        currentApp: String,
        added: [ScreenElement],
        removed: [ScreenElement],
        changed: [ElementChange]
    ) -> String {
        if appSwitched {
            return "App switched: \(previousApp) → \(currentApp)"
        }

        var parts: [String] = []

        if !added.isEmpty {
            let labels = added.prefix(3).map { "\"\($0.label)\"" }.joined(separator: ", ")
            let extra = added.count > 3 ? " +\(added.count - 3) more" : ""
            parts.append("+\(added.count) elements (\(labels)\(extra))")
        }

        if !removed.isEmpty {
            let labels = removed.prefix(3).map { "\"\($0.label)\"" }.joined(separator: ", ")
            let extra = removed.count > 3 ? " +\(removed.count - 3) more" : ""
            parts.append("-\(removed.count) elements (\(labels)\(extra))")
        }

        if !changed.isEmpty {
            let descs = changed.prefix(3).map { "\($0.ref.description).\($0.field)" }.joined(separator: ", ")
            let extra = changed.count > 3 ? " +\(changed.count - 3) more" : ""
            parts.append("~\(changed.count) changed (\(descs)\(extra))")
        }

        if parts.isEmpty {
            return "No changes"
        }

        return parts.joined(separator: "; ")
    }
}
