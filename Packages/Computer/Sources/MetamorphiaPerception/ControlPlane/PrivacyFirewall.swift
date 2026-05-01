import ApplicationServices
import Foundation

// Secure Event Input probe. The dlsym lookup lives in `SecureInputProbe` —
// this file just forwards so existing call sites (`isSecureEventInputEnabled()`)
// don't have to churn. One symbol lookup across the whole target.
private func isSecureEventInputEnabled() -> Bool {
    SecureInputProbe.isActive()
}

// MARK: - PrivacyFirewall

/// Single chokepoint between every perception lane and the activity stream.
/// All sensor candidates must pass `admit(lane:_:)` before being forwarded.
/// Wave 6 wires admit → ActivityStream.emit; this wave makes the firewall
/// standalone and testable.
public actor PrivacyFirewall {

    public static let shared = PrivacyFirewall()

    // MARK: - Drop

    /// Reason a candidate was rejected. `.ok` means it was allowed through.
    public enum Drop: Sendable, Codable, Hashable {
        case ok
        case denyAppDenylist(bundleID: String)
        case denyDRM
        case denySecureInput
        case denyPII(SensitivityKind)
        case denyUserPaused(until: Date)
        case denyUnknownFailClosed(rule: String)
    }

    // MARK: - SensitivityKind

    public enum SensitivityKind: String, Sendable, Codable {
        case password, creditCard, ssn, apiKey, otherPII
    }

    // MARK: - Token

    /// Proof-of-passage issued on `.ok`. Wave 6 uses `proof` to gate emit.
    public struct Token: Sendable {
        fileprivate let proof: UInt64
        fileprivate let issuedAt: Date
    }

    // MARK: - Candidate

    /// Sensor-agnostic description of an event to be considered for admission.
    public struct Candidate: Sendable {
        public let bundleID: String?
        /// Short label matching an ActivityEvent case name, e.g. "clipboardCopied".
        public let kind: String
        /// Raw OCR or clipboard text. If present the PII classifier runs against it.
        public let ocrText: String?
        /// AX role hint — "AXSecureTextField" triggers a secure-input deny.
        public let axRoleHint: String?
        /// Mean pixel luminance. Values below 4.0 combined with a DRM bundle trigger denyDRM.
        public let pixelMeanHint: Double?
        public let at: Date

        public init(
            bundleID: String?,
            kind: String,
            ocrText: String? = nil,
            axRoleHint: String? = nil,
            pixelMeanHint: Double? = nil,
            at: Date = Date()
        ) {
            self.bundleID = bundleID
            self.kind = kind
            self.ocrText = ocrText
            self.axRoleHint = axRoleHint
            self.pixelMeanHint = pixelMeanHint
            self.at = at
        }
    }

    // MARK: - DropRecord

    /// An immutable log entry for a denied candidate. Contains no raw content.
    public struct DropRecord: Sendable, Codable {
        public let at: Date
        public let lane: String
        public let bundleID: String?
        public let reason: Drop
        public let eventKind: String
        /// Non-reversible shape hash: length bucket + digit-ratio bucket + colon flag + dash flag.
        public let contentShapeSignature: UInt16
    }

    // MARK: - Private state

    private var pausedUntil: Date = .distantPast
    private var userDenylist: Set<String> = []
    /// Ring buffer — max 1000 entries.
    private var dropLog: [DropRecord] = []
    private static let ringCapacity = 1000

    // MARK: - Built-in denylist (password managers + sensitive system apps)

    private static let builtinDenylist: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacapp",
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.dashlane-mac",
        "com.apple.Passwords",
        "org.keepassxc.keepassxc",
        "me.proton.pass",
    ]

    /// Bundles associated with DRM content sources (requires BOTH bundle match AND dark-frame signal).
    private static let drmBundlelist: Set<String> = [
        "com.apple.TVApp",
        "com.netflix.Netflix",
        "tv.spotify.lyrics",
    ]

    /// Exhaustive set of allowed ActivityEvent case names. Anything else fails closed.
    private static let allowedKinds: Set<String> = [
        "focusChanged",
        "inputIdle",
        "inputResumed",
        "urlVisited",
        "meetingStarted",
        "meetingEnded",
        "placeChanged",
        "cameraToggled",
        "microphoneToggled",
        "focusModeChanged",
        "clipboardCopied",
        "querySubmitted",
        "surfaceEngaged",
        "sessionClosed",
        "screenFrameIngested",
        "fileIndexed",
        "clipIndexed",
        "browserPageIndexed",
        "messageIndexed",
        "mailIndexed",
        "calendarIndexed",
        "agentTurnIndexed",
    ]

    // MARK: - Init

    public init() {}

    // MARK: - Admission

    /// Run the filter chain and return `(token, verdict)`.
    /// Returns a non-nil `Token` only on `.ok`. On any deny the token is nil
    /// and a `DropRecord` is appended to the ring buffer.
    @discardableResult
    public func admit(lane: String, _ candidate: Candidate) async -> (Token?, Drop) {
        let verdict = evaluate(candidate)
        if case .ok = verdict {
            var rng = SystemRandomNumberGenerator()
            let token = Token(proof: rng.next(), issuedAt: candidate.at)
            return (token, .ok)
        }
        appendDrop(lane: lane, candidate: candidate, reason: verdict)
        return (nil, verdict)
    }

    // MARK: - User controls

    /// Pause all admission for `interval` seconds.
    public func pause(for interval: TimeInterval) {
        pausedUntil = Date(timeIntervalSinceNow: interval)
    }

    /// Lift a previously set pause immediately.
    public func unpause() {
        pausedUntil = .distantPast
    }

    /// Add a bundle ID to the per-user denylist.
    public func denyBundle(_ id: String) {
        userDenylist.insert(id)
    }

    /// Remove a bundle ID from the per-user denylist.
    public func allowBundle(_ id: String) {
        userDenylist.remove(id)
    }

    public func isBundleDenied(_ id: String) async -> Bool {
        userDenylist.contains(id) || Self.builtinDenylist.contains(id)
    }

    // MARK: - Diagnostics

    public func recentDrops(limit: Int) async -> [DropRecord] {
        let clamped = Swift.min(limit, dropLog.count)
        return Array(dropLog.suffix(clamped))
    }

    public func dropCount() async -> Int {
        dropLog.count
    }

    // MARK: - Filter chain (private)

    private func evaluate(_ candidate: Candidate) -> Drop {
        // 1. User pause
        let now = Date()
        if pausedUntil > now {
            return .denyUserPaused(until: pausedUntil)
        }

        // 2. App denylist (builtin + user)
        if let bid = candidate.bundleID {
            if Self.builtinDenylist.contains(bid) || userDenylist.contains(bid) {
                return .denyAppDenylist(bundleID: bid)
            }
        }

        // 3a. DRM — BOTH bundle match AND dark frame required
        if let mean = candidate.pixelMeanHint, mean < 4.0 {
            if let bid = candidate.bundleID, Self.drmBundlelist.contains(bid) {
                return .denyDRM
            }
        }

        // 3b. Secure input — AX role hint or system secure event input
        if candidate.axRoleHint == "AXSecureTextField" {
            return .denySecureInput
        }
        if isSecureEventInputEnabled() {
            return .denySecureInput
        }

        // 4. PII classifier on OCR / clipboard text
        if let text = candidate.ocrText {
            if let piiKind = Self.classifyPII(text) {
                return .denyPII(piiKind)
            }
        }

        // 5. Content whitelist — fail closed on unknown kind
        if !Self.allowedKinds.contains(candidate.kind) {
            return .denyUnknownFailClosed(rule: "unknownKind:\(candidate.kind)")
        }

        return .ok
    }

    // MARK: - PII classifier

    /// Returns the first PII kind found in `text`, or nil if clean.
    static func classifyPII(_ text: String) -> SensitivityKind? {
        // Password context: "password" or "pwd" immediately precedes content
        let lower = text.lowercased()
        if Self.hasPasswordContext(lower) {
            return .password
        }

        // API key patterns
        if text.range(of: #"sk-[a-zA-Z0-9]{20,}"#, options: .regularExpression) != nil {
            return .apiKey
        }
        if text.range(of: #"AKIA[0-9A-Z]{16}"#, options: .regularExpression) != nil {
            return .apiKey
        }
        if text.range(of: #"ghp_[a-zA-Z0-9]{36}"#, options: .regularExpression) != nil {
            return .apiKey
        }

        // SSN: nnn-nn-nnnn or 9-digit run with nearby keyword
        if text.range(of: #"\b\d{3}-\d{2}-\d{4}\b"#, options: .regularExpression) != nil {
            return .ssn
        }
        if let m = text.range(of: #"\b\d{9}\b"#, options: .regularExpression) {
            let context = String(text[text.startIndex..<m.upperBound]).lowercased()
            if context.contains("ssn") || context.contains("social") || context.contains("tax") {
                return .ssn
            }
        }

        // Credit card: Luhn-valid 13–19 digit sequence (spaces/dashes stripped)
        if let kind = Self.detectCreditCard(text) {
            return kind
        }

        return nil
    }

    private static func hasPasswordContext(_ lower: String) -> Bool {
        let triggers = ["password", "pwd", "passcode", "passphrase"]
        for trigger in triggers {
            guard let range = lower.range(of: trigger) else { continue }
            // Look at the 20 chars before any colon or equals after the keyword
            let after = lower[range.upperBound...]
            let afterTrimmed = after.drop(while: { $0 == " " || $0 == ":" || $0 == "=" })
            if !afterTrimmed.isEmpty {
                return true
            }
        }
        return false
    }

    private static func detectCreditCard(_ text: String) -> SensitivityKind? {
        // Extract contiguous digit groups (optionally separated by spaces/dashes)
        let pattern = #"\b(?:\d[ -]?){12,18}\d\b"#
        guard let _ = text.range(of: pattern, options: .regularExpression) else { return nil }

        // Walk all matches and run Luhn
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            let candidate = String(text[match]).filter(\.isNumber)
            if candidate.count >= 13 && candidate.count <= 19 && luhn(candidate) {
                return .creditCard
            }
            searchRange = match.upperBound..<text.endIndex
        }
        return nil
    }

    private static func luhn(_ digits: String) -> Bool {
        let ns = digits.compactMap { $0.wholeNumberValue }
        guard ns.count >= 13 else { return false }
        var sum = 0
        let parity = ns.count % 2
        for (i, d) in ns.enumerated() {
            var v = d
            if i % 2 == parity { v *= 2; if v > 9 { v -= 9 } }
            sum += v
        }
        return sum % 10 == 0
    }

    // MARK: - Ring buffer

    private func appendDrop(lane: String, candidate: Candidate, reason: Drop) {
        let sig = Self.shapeSignature(candidate.ocrText)
        let record = DropRecord(
            at: candidate.at,
            lane: lane,
            bundleID: candidate.bundleID,
            reason: reason,
            eventKind: candidate.kind,
            contentShapeSignature: sig
        )
        dropLog.append(record)
        if dropLog.count > Self.ringCapacity {
            dropLog.removeFirst(dropLog.count - Self.ringCapacity)
        }
    }

    // MARK: - Shape signature (non-reversible)

    /// Combines: length power-of-2 bucket (bits 15-12), digit-ratio 0..15 (bits 11-8),
    /// has-colon flag (bit 1), has-dash flag (bit 0). Cannot reconstruct original text.
    static func shapeSignature(_ text: String?) -> UInt16 {
        guard let text, !text.isEmpty else { return 0 }

        // Length bucket: floor(log2(length)), clamped to 0..15
        let lenBucket: UInt16 = {
            var n = text.count
            var bucket = 0
            while n > 1 && bucket < 15 { n >>= 1; bucket += 1 }
            return UInt16(bucket)
        }()

        // Digit ratio: 0..15 scale
        let digitCount = text.filter(\.isNumber).count
        let ratio = Double(digitCount) / Double(text.count)
        let digitBucket = UInt16(ratio * 15.0)

        let hasColon: UInt16 = text.contains(":") ? 1 : 0
        let hasDash: UInt16  = text.contains("-") ? 1 : 0

        return (lenBucket << 12) | (digitBucket << 8) | (hasColon << 1) | hasDash
    }
}
