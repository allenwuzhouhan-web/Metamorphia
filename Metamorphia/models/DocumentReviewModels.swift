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
        id = UUID()
        title = try container.decode(String.self, forKey: .title)
        location = try container.decode(String.self, forKey: .location)
        severity = try container.decode(DocumentReviewSeverity.self, forKey: .severity)
        rationale = try container.decode(String.self, forKey: .rationale)
        anchorText = try container.decodeIfPresent(String.self, forKey: .anchorText)
        suggestedRevision = try container.decodeIfPresent(String.self, forKey: .suggestedRevision)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
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

    public init(
        documentTitle: String,
        documentKind: DocumentReviewKind,
        sourceDescription: String,
        sourceFilePath: String? = nil,
        summary: String,
        nextStep: String? = nil,
        findings: [DocumentReviewFinding]
    ) {
        self.documentTitle = documentTitle
        self.documentKind = documentKind
        self.sourceDescription = sourceDescription
        self.sourceFilePath = sourceFilePath
        self.summary = summary
        self.nextStep = nextStep
        self.findings = findings
    }

    public func withSourceFilePath(_ path: String?) -> DocumentReviewResult {
        DocumentReviewResult(
            documentTitle: documentTitle,
            documentKind: documentKind,
            sourceDescription: sourceDescription,
            sourceFilePath: path,
            summary: summary,
            nextStep: nextStep,
            findings: findings
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
