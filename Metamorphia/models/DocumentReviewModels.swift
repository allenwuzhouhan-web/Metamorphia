import Foundation

public enum DocumentReviewKind: String, Codable, Sendable, Hashable {
    case presentation
    case document

    public var displayName: String {
        switch self {
        case .presentation:
            return "Presentation"
        case .document:
            return "Document"
        }
    }

    public var symbolName: String {
        switch self {
        case .presentation:
            return "rectangle.on.rectangle"
        case .document:
            return "doc.text"
        }
    }
}

public enum DocumentReviewSeverity: String, Codable, Sendable, Hashable, CaseIterable {
    case high
    case medium
    case low

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        self = DocumentReviewSeverity(rawValue: raw) ?? .medium
    }

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct DocumentReviewFinding: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let location: String
    public let severity: DocumentReviewSeverity
    public let rationale: String
    public let anchorText: String?
    public let suggestedRevision: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case location
        case severity
        case rationale
        case anchorText
        case suggestedRevision
    }

    public init(
        id: UUID = UUID(),
        title: String,
        location: String,
        severity: DocumentReviewSeverity,
        rationale: String,
        anchorText: String? = nil,
        suggestedRevision: String? = nil
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.severity = severity
        self.rationale = rationale
        self.anchorText = anchorText
        self.suggestedRevision = suggestedRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve the persisted id when present; only mint a new one for legacy
        // records that predate id persistence.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        location = try container.decode(String.self, forKey: .location)
        severity = try container.decode(DocumentReviewSeverity.self, forKey: .severity)
        rationale = try container.decode(String.self, forKey: .rationale)
        anchorText = try container.decodeIfPresent(String.self, forKey: .anchorText)
        suggestedRevision = try container.decodeIfPresent(String.self, forKey: .suggestedRevision)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(location, forKey: .location)
        try container.encode(severity, forKey: .severity)
        try container.encode(rationale, forKey: .rationale)
        try container.encodeIfPresent(anchorText, forKey: .anchorText)
        try container.encodeIfPresent(suggestedRevision, forKey: .suggestedRevision)
    }

    public var trimmedAnchorText: String? {
        let trimmed = anchorText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public var trimmedSuggestedRevision: String? {
        let trimmed = suggestedRevision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct DocumentReviewResult: Codable, Sendable, Hashable {
    public let documentTitle: String
    public let documentKind: DocumentReviewKind
    public let sourceDescription: String
    public let sourceFilePath: String?
    public let summary: String
    public let nextStep: String?
    public let findings: [DocumentReviewFinding]
    /// The document's purpose as stated by the user (or inferred from their request).
    /// Set deterministically from the review route, not decoded from the model.
    public let purpose: String?

    public init(
        documentTitle: String,
        documentKind: DocumentReviewKind,
        sourceDescription: String,
        sourceFilePath: String? = nil,
        summary: String,
        nextStep: String? = nil,
        findings: [DocumentReviewFinding],
        purpose: String? = nil
    ) {
        self.documentTitle = documentTitle
        self.documentKind = documentKind
        self.sourceDescription = sourceDescription
        self.sourceFilePath = sourceFilePath
        self.summary = summary
        self.nextStep = nextStep
        self.findings = findings
        self.purpose = purpose
    }

    public func withSourceFilePath(_ path: String?) -> DocumentReviewResult {
        DocumentReviewResult(
            documentTitle: documentTitle,
            documentKind: documentKind,
            sourceDescription: sourceDescription,
            sourceFilePath: path,
            summary: summary,
            nextStep: nextStep,
            findings: findings,
            purpose: purpose
        )
    }

    public func withPurpose(_ purpose: String?) -> DocumentReviewResult {
        DocumentReviewResult(
            documentTitle: documentTitle,
            documentKind: documentKind,
            sourceDescription: sourceDescription,
            sourceFilePath: sourceFilePath,
            summary: summary,
            nextStep: nextStep,
            findings: findings,
            purpose: purpose
        )
    }
}

public enum DocumentReviewAction: Sendable, Hashable {
    case jump(findingID: UUID)
    case insertComment(findingID: UUID)
    case applySuggestedRevision(findingID: UUID)

    public var findingID: UUID {
        switch self {
        case .jump(let findingID), .insertComment(let findingID), .applySuggestedRevision(let findingID):
            return findingID
        }
    }
}

/// Result of the verification pass run after the user has addressed and cleared
/// all proofread comments. Either confirms the document is clean, or surfaces a
/// short list of anything that genuinely remains.
public struct DocumentRecheckResult: Codable, Sendable, Hashable {
    public let documentTitle: String
    public let purpose: String?
    public let isClean: Bool
    public let summary: String
    public let remainingFindings: [DocumentReviewFinding]

    public init(
        documentTitle: String,
        purpose: String? = nil,
        isClean: Bool,
        summary: String,
        remainingFindings: [DocumentReviewFinding] = []
    ) {
        self.documentTitle = documentTitle
        self.purpose = purpose
        self.isClean = isClean
        self.summary = summary
        self.remainingFindings = remainingFindings
    }
}

extension DocumentReviewFinding {
    /// Hard ceiling on the comment body so proofread comments stay scannable.
    public static let maxRationaleWords = 15

    /// Caps the rationale to `maxRationaleWords` words. The prompt asks the model to
    /// stay under the limit; this guarantees it regardless of what the model returns.
    public func enforcingLimits() -> DocumentReviewFinding {
        DocumentReviewFinding(
            id: id,
            title: title,
            location: location,
            severity: severity,
            rationale: DocumentReviewFinding.capWords(rationale, limit: Self.maxRationaleWords),
            anchorText: anchorText,
            suggestedRevision: suggestedRevision
        )
    }

    static func capWords(_ string: String, limit: Int) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard words.count > limit else { return trimmed }
        return words.prefix(limit).joined(separator: " ")
    }
}

extension DocumentReviewResult {
    /// Caps every finding's rationale and drops findings that lack an exact replacement,
    /// so every surviving finding can be rendered as a "Change to:" comment.
    public func enforcingFindingLimits() -> DocumentReviewResult {
        let kept = findings
            .filter { $0.trimmedSuggestedRevision != nil }
            .map { $0.enforcingLimits() }
        return DocumentReviewResult(
            documentTitle: documentTitle,
            documentKind: documentKind,
            sourceDescription: sourceDescription,
            sourceFilePath: sourceFilePath,
            summary: summary,
            nextStep: nextStep,
            findings: kept,
            purpose: purpose
        )
    }
}
