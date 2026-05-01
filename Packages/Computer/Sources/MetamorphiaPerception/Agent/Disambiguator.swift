import Foundation
import CoreGraphics

/// Resolves ambiguity when multiple elements share the same label.
/// Ranks by: (1) enabled/visible, (2) proximity to focus, (3) parent context, (4) learned preference.
public enum Disambiguator {

    /// A ranked disambiguation result.
    public struct RankedMatch: Sendable {
        public let element: ScreenElement
        public let score: Float
        public let reason: String

        public init(element: ScreenElement, score: Float, reason: String) {
            self.element = element
            self.score = score
            self.reason = reason
        }
    }

    /// Find all elements matching a label and rank them by likelihood of being the intended target.
    public static func disambiguate(
        label: String,
        in map: ScreenMap,
        preferredRole: ElementRole? = nil,
        nearRef: ElementRef? = nil,
        db: ElementDatabase? = nil
    ) -> [RankedMatch] {
        let labelLower = label.lowercased()

        // Find all candidates: exact match first, then prefix/contains
        let candidates = map.elements.filter { el in
            let elLower = el.label.lowercased()
            return elLower == labelLower || elLower.contains(labelLower) || labelLower.contains(elLower)
        }

        guard candidates.count > 1 else {
            if let only = candidates.first {
                return [RankedMatch(element: only, score: 1.0, reason: "Only match")]
            }
            return []
        }

        // Score each candidate
        let focusedElement = nearRef.flatMap { ref in map.elements.first(where: { $0.ref == ref }) }

        var ranked = candidates.map { el -> RankedMatch in
            var score: Float = 0
            var reasons: [String] = []

            // 1. Exact label match bonus
            if el.label.lowercased() == labelLower {
                score += 0.2
                reasons.append("exact match")
            }

            // 2. Enabled/visible state (weight: 0.25)
            if el.state.contains(.enabled) && !el.state.contains(.disabled) {
                score += 0.25
            }
            if el.state.contains(.disabled) {
                score -= 0.3
                reasons.append("disabled")
            }

            // 3. Proximity to focused element (weight: 0.2)
            if let focusClick = focusedElement?.clickPoint, let elClick = el.clickPoint {
                let dx = focusClick.x - elClick.x
                let dy = focusClick.y - elClick.y
                let distance = sqrt(dx * dx + dy * dy)
                let proxScore = max(0, 1.0 - Float(distance) / 1000.0)
                score += 0.2 * proxScore
                if proxScore > 0.7 { reasons.append("near focus") }
            }

            // 4. Role preference (weight: 0.15)
            if let preferred = preferredRole, el.role == preferred {
                score += 0.15
                reasons.append("preferred role")
            } else if el.role.isInteractive {
                score += 0.1
            }

            // 5. Parent context uniqueness (weight: 0.1)
            if let parentRef = el.parentRef {
                let parent = map.elements.first(where: { $0.ref == parentRef })
                if let parentLabel = parent?.label, !parentLabel.isEmpty {
                    score += 0.1
                    reasons.append("in \"\(String(parentLabel.prefix(20)))\"")
                }
            }

            // 6. Depth preference — shallower elements are more likely primary targets (weight: 0.05)
            let depthPenalty = Float(min(el.depth, 10)) * 0.005
            score -= depthPenalty

            // 7. Focused/selected state bonus (weight: 0.05)
            if el.state.contains(.focused) || el.state.contains(.selected) {
                score += 0.05
                reasons.append("focused")
            }

            // 8. Learned preference from corrections database
            if let database = db, let bundleID = el.appBundleID {
                let hash = UnknownElementHandler.elementHash(element: el, appBundleID: bundleID)
                if let record = database.getElement(hash: hash) {
                    score += record.confidence * 0.1
                    if record.timesCorrect > record.timesWrong {
                        reasons.append("learned (\(record.timesCorrect)x correct)")
                    }
                }
            }

            return RankedMatch(
                element: el,
                score: score,
                reason: reasons.isEmpty ? "default" : reasons.joined(separator: ", ")
            )
        }

        ranked.sort { $0.score > $1.score }
        return ranked
    }

    /// Quick resolve: return the best match for a label, or nil if no match.
    public static func bestMatch(
        label: String,
        in map: ScreenMap,
        preferredRole: ElementRole? = nil,
        db: ElementDatabase? = nil
    ) -> ScreenElement? {
        disambiguate(label: label, in: map, preferredRole: preferredRole, db: db).first?.element
    }

    /// Find elements by ref string (e.g., "@e5").
    public static func findByRef(_ refString: String, in map: ScreenMap) -> ScreenElement? {
        guard let ref = ElementRef.parse(refString) else { return nil }
        return map.elements.first(where: { $0.ref == ref })
    }
}
