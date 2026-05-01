import Foundation

/// Cross-app element pattern recognition.
/// Learns that hamburger icon = menu, gear = settings, etc. across apps.
/// Promotes to universal when seen in 3+ apps with confidence > 0.7.
public enum PatternRecognizer {

    // MARK: - Structural Signature

    /// Compute a structural signature for pattern matching.
    /// Format: `role/parentRole@depth#textHint`
    public static func structuralSignature(
        role: String,
        parentRole: String?,
        depth: Int,
        label: String
    ) -> String {
        let parent = parentRole ?? "root"
        let hint = String(label.prefix(20).lowercased().trimmingCharacters(in: .whitespaces))
        return "\(role)/\(parent)@\(depth)#\(hint)"
    }

    /// Build a signature from a ScreenElement.
    public static func signatureFor(element: ScreenElement, parentElement: ScreenElement?) -> String {
        structuralSignature(
            role: element.role.rawValue,
            parentRole: parentElement?.role.rawValue,
            depth: element.depth,
            label: element.label
        )
    }

    // MARK: - Pattern Matching

    /// Check if an element matches any known pattern. Returns the meaning (e.g., "menu", "settings").
    public static func matchPattern(element: ScreenElement, appBundleID: String?, db: ElementDatabase) -> String? {
        let sig = UnknownElementHandler.structuralSignature(element: element)
        let patterns = db.findPatterns(signature: sig)

        // Return the highest-confidence match
        if let best = patterns.first, best.confidence > 0.5 {
            return best.meaning
        }

        return nil
    }

    /// Record a new pattern observation. If seen across enough apps, promotes to universal.
    public static func recordObservation(
        element: ScreenElement,
        meaning: String,
        appBundleID: String?,
        db: ElementDatabase
    ) {
        let sig = UnknownElementHandler.structuralSignature(element: element)
        let patternID = "\(sig)::\(meaning)"

        // Get existing pattern to update apps list
        let existing = db.findPatterns(signature: sig).first(where: { $0.meaning == meaning })

        var appsSeen: [String] = []
        if let existingApps = existing?.appsSeenIn,
           let data = existingApps.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            appsSeen = arr
        }

        if let bundleID = appBundleID, !appsSeen.contains(bundleID) {
            appsSeen.append(bundleID)
        }

        let confidence: Float = min(1.0, Float(appsSeen.count) * 0.25)

        db.upsertPattern(
            id: patternID,
            signature: sig,
            meaning: meaning,
            confidence: confidence,
            appsSeen: appsSeen
        )

        // Promote to universal if seen in 3+ apps with high confidence
        if appsSeen.count >= 3 && confidence > 0.7 {
            let hash = UnknownElementHandler.elementHash(element: element, appBundleID: nil)
            db.setUniversal(hash: hash, isUniversal: true)
        }
    }

    // MARK: - Confusion Patterns

    /// A recurring confusion between two elements.
    public struct ConfusionPattern: Sendable {
        public let wrongSignature: String
        public let correctSignature: String
        public let frequency: Int
        public let appBundleID: String?

        public init(wrongSignature: String, correctSignature: String, frequency: Int, appBundleID: String?) {
            self.wrongSignature = wrongSignature
            self.correctSignature = correctSignature
            self.frequency = frequency
            self.appBundleID = appBundleID
        }
    }

    /// Extract confusion patterns from corrections. Pairs seen 3+ times are patterns.
    public static func extractConfusionPatterns(appBundleID: String?, db: ElementDatabase) -> [ConfusionPattern] {
        let corrections = db.recentCorrections(appBundleID: appBundleID, limit: 200)

        // Group by (selectedSignature → correctSignature) pairs
        var pairs: [String: Int] = [:]
        for c in corrections {
            guard let selected = c.selectedSignature, let correct = c.correctSignature else { continue }
            let key = "\(selected)->\(correct)"
            pairs[key, default: 0] += 1
        }

        // Pairs seen 3+ times are confusion patterns
        return pairs.compactMap { key, count in
            guard count >= 3 else { return nil }
            let parts = key.components(separatedBy: "->")
            guard parts.count == 2 else { return nil }
            return ConfusionPattern(
                wrongSignature: parts[0],
                correctSignature: parts[1],
                frequency: count,
                appBundleID: appBundleID
            )
        }.sorted(by: { $0.frequency > $1.frequency })
    }
}
