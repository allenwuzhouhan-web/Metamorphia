import Foundation
import CoreGraphics

/// Detects unknown UI elements and manages user-teaching flow.
/// Triggers when: role is empty/unknown, label missing on interactive element, confidence < 0.3.
public enum UnknownElementHandler {

    // MARK: - Unknown Element Query

    /// An element that needs user identification.
    public struct UnknownQuery: Sendable {
        public let element: ScreenElement
        public let trigger: Trigger
        public let nearbyLabels: [String]
        public let appName: String
        public let windowTitle: String

        public init(element: ScreenElement, trigger: Trigger, nearbyLabels: [String], appName: String, windowTitle: String) {
            self.element = element
            self.trigger = trigger
            self.nearbyLabels = nearbyLabels
            self.appName = appName
            self.windowTitle = windowTitle
        }

        /// Human-readable question for the user.
        public var question: String {
            var parts: [String] = []
            parts.append("Unknown element in \(appName)")
            if !windowTitle.isEmpty { parts.append("window: \(windowTitle)") }
            if let bounds = element.bounds {
                parts.append("at (\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) \(Int(bounds.width))x\(Int(bounds.height)))")
            }
            if !nearbyLabels.isEmpty {
                parts.append("near: \(nearbyLabels.prefix(3).joined(separator: ", "))")
            }
            parts.append("trigger: \(trigger.description)")
            return parts.joined(separator: " | ")
        }
    }

    /// Why the element was flagged as unknown.
    public enum Trigger: String, Sendable, CustomStringConvertible {
        case missingRole        // role is "" or "AXUnknown"
        case missingLabel       // interactive element with no label
        case unrecognizedRole   // role not in standard set
        case lowConfidence      // best match confidence < 0.3

        public var description: String { rawValue }
    }

    /// User's answer to an unknown element query.
    public struct UserAnswer: Sendable {
        public let label: String
        public let role: String?        // User-specified type (button, menu, toggle, etc.)
        public let behavior: String?    // What happens when you interact with it

        public init(label: String, role: String? = nil, behavior: String? = nil) {
            self.label = label
            self.role = role
            self.behavior = behavior
        }
    }

    // MARK: - Detection

    /// Scan elements for unknowns that need user identification.
    public static func findUnknowns(in elements: [ScreenElement]) -> [UnknownQuery] {
        var queries: [UnknownQuery] = []

        for element in elements {
            guard let trigger = evaluate(element) else { continue }

            let nearbyLabels = findNearbyLabels(for: element, in: elements, radius: 150)

            queries.append(UnknownQuery(
                element: element,
                trigger: trigger,
                nearbyLabels: nearbyLabels,
                appName: "",  // Filled by caller
                windowTitle: ""
            ))
        }

        return queries
    }

    /// Evaluate a single element — returns trigger reason or nil if known.
    public static func evaluate(_ element: ScreenElement) -> Trigger? {
        // Missing role
        if element.role == .unknown && element.subrole.isEmpty {
            return .missingRole
        }

        // Missing label on interactive element
        if element.role.isInteractive && element.label.isEmpty {
            return .missingLabel
        }

        // Low confidence (from database matching)
        if element.confidence < 0.3 && element.source == .accessibility {
            return .lowConfidence
        }

        return nil
    }

    // MARK: - Teaching

    /// Record a user's teaching into the element database.
    public static func recordTeaching(
        element: ScreenElement,
        answer: UserAnswer,
        appBundleID: String?,
        db: ElementDatabase
    ) {
        let hash = elementHash(element: element, appBundleID: appBundleID)
        let signature = structuralSignature(element: element)

        db.upsertElement(
            hash: hash,
            appBundleID: appBundleID,
            role: answer.role ?? element.role.rawValue,
            label: answer.label,
            customLabel: answer.label,
            structuralSignature: signature,
            visualHash: nil,
            confidence: 0.7,  // User-taught starts higher than auto-inferred
            behavior: answer.behavior
        )
    }

    // MARK: - Helpers

    /// Compute a hash for an element identity.
    public static func elementHash(element: ScreenElement, appBundleID: String?) -> String {
        var hash: UInt64 = 5381
        func mix(_ s: String) { for b in s.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(b) } }
        mix(appBundleID ?? "")
        mix(element.role.rawValue)
        mix(element.label)
        if let click = element.clickPoint {
            mix("\(Int(click.x / 50)),\(Int(click.y / 50))")
        }
        return String(hash, radix: 16)
    }

    /// Compute a structural signature for an element.
    public static func structuralSignature(element: ScreenElement) -> String {
        "\(element.role.rawValue)/\(element.parentRef?.description ?? "root")@\(element.depth)#\(String(element.label.prefix(20).lowercased()))"
    }

    /// Find labels of nearby elements within a radius.
    private static func findNearbyLabels(for element: ScreenElement, in allElements: [ScreenElement], radius: CGFloat) -> [String] {
        guard let targetCenter = element.clickPoint else { return [] }
        var labels: [String] = []
        for other in allElements {
            guard other.ref != element.ref,
                  !other.label.isEmpty,
                  let otherCenter = other.clickPoint else { continue }
            let dx = targetCenter.x - otherCenter.x
            let dy = targetCenter.y - otherCenter.y
            if sqrt(dx * dx + dy * dy) <= radius {
                labels.append(other.label)
            }
        }
        return labels
    }
}
