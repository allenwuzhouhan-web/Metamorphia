import Foundation

/// Detects sensitive input fields: passwords, credit cards, SSNs, API keys.
/// Sensitive field values are redacted in output to prevent data leakage.
public enum SensitiveFieldDetector {

    // MARK: - Sensitivity Type

    public enum SensitivityType: String, Sendable {
        case password
        case creditCard
        case ssn
        case apiKey
        case secret         // generic sensitive field
    }

    /// Result of scanning a single element.
    public struct SensitiveResult: Sendable {
        public let ref: ElementRef
        public let type: SensitivityType
        public let reason: String

        public init(ref: ElementRef, type: SensitivityType, reason: String) {
            self.ref = ref
            self.type = type
            self.reason = reason
        }
    }

    // MARK: - Label Patterns

    /// Labels that indicate credit card fields.
    private static let creditCardLabels: [String] = [
        "card number", "credit card", "debit card",
        "cvv", "cvc", "security code", "card security",
        "expiration", "expiry", "exp date",
        "cardholder", "name on card",
    ]

    /// Labels that indicate SSN/tax ID fields.
    private static let ssnLabels: [String] = [
        "social security", "ssn", "tax id",
        "taxpayer", "ein", "itin",
        "national id", "identity number",
    ]

    /// Labels that indicate API key / secret fields.
    private static let secretLabels: [String] = [
        "api key", "api token", "secret key",
        "access key", "access token", "auth token",
        "client secret", "private key", "secret",
    ]

    /// Labels that indicate generic password fields (beyond AXSecureTextField subrole).
    private static let passwordLabels: [String] = [
        "password", "passcode", "passphrase",
        "pin", "current password", "new password",
        "confirm password", "master password",
    ]

    // MARK: - Scanning

    /// Scan all elements for sensitive fields.
    public static func scan(elements: [ScreenElement]) -> [SensitiveResult] {
        var results: [SensitiveResult] = []

        // Build a coarse spatial grid of candidate label elements once per scan so
        // findNearbyLabels queries only nearby buckets instead of the full array.
        let grid = LabelGrid(elements: elements)

        for element in elements {
            if let result = classify(element: element, allElements: elements, labelGrid: grid) {
                results.append(result)
            }
        }

        return results
    }

    /// Classify a single element's sensitivity.
    public static func classify(element: ScreenElement, allElements: [ScreenElement]) -> SensitiveResult? {
        classify(element: element, allElements: allElements, labelGrid: nil)
    }

    /// Classify a single element's sensitivity, optionally reusing a prebuilt label grid.
    private static func classify(element: ScreenElement, allElements: [ScreenElement], labelGrid: LabelGrid?) -> SensitiveResult? {
        // AXSecureTextField is the definitive signal for password fields
        if element.state.contains(.password) || element.subrole == "AXSecureTextField" {
            return SensitiveResult(ref: element.ref, type: .password, reason: "Secure text field")
        }

        // Only check text input fields for sensitivity (buttons, labels etc. are not sensitive)
        guard element.role == .textField || element.role == .textArea || element.role == .comboBox else {
            return nil
        }

        let labelLower = element.label.lowercased()

        // Check own label
        for pattern in passwordLabels {
            if labelLower.contains(pattern) {
                return SensitiveResult(ref: element.ref, type: .password, reason: "Label contains '\(pattern)'")
            }
        }

        for pattern in creditCardLabels {
            if labelLower.contains(pattern) {
                return SensitiveResult(ref: element.ref, type: .creditCard, reason: "Label contains '\(pattern)'")
            }
        }

        for pattern in ssnLabels {
            if labelLower.contains(pattern) {
                return SensitiveResult(ref: element.ref, type: .ssn, reason: "Label contains '\(pattern)'")
            }
        }

        for pattern in secretLabels {
            if labelLower.contains(pattern) {
                return SensitiveResult(ref: element.ref, type: .apiKey, reason: "Label contains '\(pattern)'")
            }
        }

        // Check nearby labels — a text field next to a "Password" static text label
        let nearbyLabels = findNearbyLabels(for: element, in: allElements, radius: 150, grid: labelGrid)
        for nearby in nearbyLabels {
            let nearLower = nearby.lowercased()
            for pattern in passwordLabels {
                if nearLower.contains(pattern) {
                    return SensitiveResult(ref: element.ref, type: .password, reason: "Near label '\(nearby)'")
                }
            }
            for pattern in creditCardLabels {
                if nearLower.contains(pattern) {
                    return SensitiveResult(ref: element.ref, type: .creditCard, reason: "Near label '\(nearby)'")
                }
            }
            for pattern in ssnLabels {
                if nearLower.contains(pattern) {
                    return SensitiveResult(ref: element.ref, type: .ssn, reason: "Near label '\(nearby)'")
                }
            }
        }

        // Check value patterns (credit card numbers, etc.)
        if let sensitiveType = detectValuePattern(element.value) {
            return SensitiveResult(ref: element.ref, type: sensitiveType, reason: "Value matches sensitive pattern")
        }

        return nil
    }

    // MARK: - Nearby Label Detection

    /// Coarse spatial index of candidate label elements, bucketed by clickPoint.
    /// Lets findNearbyLabels query only buckets within `radius` instead of the full array.
    private struct LabelGrid {
        static let cellSize: CGFloat = 50

        /// Candidate label element (center + label) keyed by grid cell.
        private var cells: [GridKey: [(center: CGPoint, label: String, ref: ElementRef)]] = [:]

        struct GridKey: Hashable {
            let x: Int
            let y: Int
        }

        init(elements: [ScreenElement]) {
            for element in elements {
                guard element.role == .staticText || element.role == .unknown,
                      !element.label.isEmpty,
                      let center = element.clickPoint else { continue }
                let key = Self.key(for: center)
                cells[key, default: []].append((center, element.label, element.ref))
            }
        }

        static func key(for point: CGPoint) -> GridKey {
            GridKey(x: Int((point.x / cellSize).rounded(.down)),
                    y: Int((point.y / cellSize).rounded(.down)))
        }

        /// Candidate label elements in cells within `radius` of the given center.
        func candidates(near center: CGPoint, radius: CGFloat) -> [(center: CGPoint, label: String, ref: ElementRef)] {
            let span = Int((radius / Self.cellSize).rounded(.up))
            let base = Self.key(for: center)
            var result: [(center: CGPoint, label: String, ref: ElementRef)] = []
            for dx in -span...span {
                for dy in -span...span {
                    if let bucket = cells[GridKey(x: base.x + dx, y: base.y + dy)] {
                        result.append(contentsOf: bucket)
                    }
                }
            }
            return result
        }
    }

    /// Find labels of static text elements near a given element (within radius pixels).
    private static func findNearbyLabels(for element: ScreenElement, in allElements: [ScreenElement], radius: CGFloat, grid: LabelGrid? = nil) -> [String] {
        guard let targetCenter = element.clickPoint else { return [] }

        var labels: [String] = []

        if let grid {
            for other in grid.candidates(near: targetCenter, radius: radius) {
                guard other.ref != element.ref else { continue }
                let dx = targetCenter.x - other.center.x
                let dy = targetCenter.y - other.center.y
                if sqrt(dx * dx + dy * dy) <= radius {
                    labels.append(other.label)
                }
            }
            return labels
        }

        for other in allElements {
            guard other.ref != element.ref,
                  other.role == .staticText || other.role == .unknown,
                  !other.label.isEmpty,
                  let otherCenter = other.clickPoint else { continue }

            let dx = targetCenter.x - otherCenter.x
            let dy = targetCenter.y - otherCenter.y
            let distance = sqrt(dx * dx + dy * dy)

            if distance <= radius {
                labels.append(other.label)
            }
        }

        return labels
    }

    // MARK: - Value Pattern Detection

    /// Check if a field's value looks like sensitive data.
    private static func detectValuePattern(_ value: String) -> SensitivityType? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Credit card: 13-19 digits (possibly with spaces/dashes)
        let digitsOnly = trimmed.filter(\.isNumber)
        if digitsOnly.count >= 13 && digitsOnly.count <= 19 && luhnCheck(digitsOnly) {
            return .creditCard
        }

        // SSN: XXX-XX-XXXX
        if trimmed.range(of: #"^\d{3}-?\d{2}-?\d{4}$"#, options: .regularExpression) != nil {
            return .ssn
        }

        return nil
    }

    /// Luhn algorithm to validate credit card numbers.
    private static func luhnCheck(_ number: String) -> Bool {
        let digits = number.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13 else { return false }

        var sum = 0
        let parity = digits.count % 2
        for (i, digit) in digits.enumerated() {
            var d = digit
            if i % 2 == parity {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0
    }

    // MARK: - Value Redaction

    /// Redact a sensitive field's value for safe output.
    public static func redact(_ value: String, type: SensitivityType) -> String {
        switch type {
        case .password:
            return "••••••••"
        case .creditCard:
            let digits = value.filter(\.isNumber)
            if digits.count >= 4 {
                return "••••-••••-••••-\(digits.suffix(4))"
            }
            return "••••-••••-••••-••••"
        case .ssn:
            return "•••-••-••••"
        case .apiKey, .secret:
            if value.count > 4 {
                return "\(value.prefix(4))••••••••"
            }
            return "••••••••"
        }
    }
}
