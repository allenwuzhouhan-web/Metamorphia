import Foundation

/// What a finish operation does to the deck.
public enum PowerPointFinishOperationKind: String, Codable, Sendable, Hashable {
    case fillPlaceholder   // populate an empty placeholder on an existing slide
    case completeSlide     // author body content for a title-only / partial slide
    case addSlide          // insert a new slide for an outline section with no slide yet

    public var displayName: String {
        switch self {
        case .fillPlaceholder: return "Fill"
        case .completeSlide:   return "Complete"
        case .addSlide:        return "Add slide"
        }
    }
}

/// A single authored span (title or body text) on a slide.
public struct PowerPointFinishTextSpan: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let role: PowerPointShapeRole
    public let text: String

    enum CodingKeys: String, CodingKey {
        case role
        case text
    }

    public init(id: UUID = UUID(), role: PowerPointShapeRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        let roleRaw = try container.decodeIfPresent(String.self, forKey: .role)?.lowercased() ?? "body"
        role = PowerPointShapeRole(rawValue: roleRaw) ?? .body
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role.rawValue, forKey: .role)
        try container.encode(text, forKey: .text)
    }
}

/// One authoring step. For fill/complete it targets an existing slide (and,
/// for fill, an existing empty shape); for addSlide it carries the new slide's
/// title and the outline item it satisfies.
public struct PowerPointFinishOperation: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: PowerPointFinishOperationKind
    public let slideIndex: Int
    public let shapeIndex: Int?
    public let shapeName: String?
    public let slideTitle: String?
    public let outlineReference: String?
    public let spans: [PowerPointFinishTextSpan]
    public let titleFont: String?
    public let bodyFont: String?
    public let titleSize: Double?
    public let bodySize: Double?
    public let textColorHex: String?
    public let rationale: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case slideIndex
        case shapeIndex
        case shapeName
        case slideTitle
        case outlineReference
        case spans
        case titleFont
        case bodyFont
        case titleSize
        case bodySize
        case textColorHex
        case rationale
    }

    public init(
        id: UUID = UUID(),
        kind: PowerPointFinishOperationKind,
        slideIndex: Int,
        shapeIndex: Int? = nil,
        shapeName: String? = nil,
        slideTitle: String? = nil,
        outlineReference: String? = nil,
        spans: [PowerPointFinishTextSpan],
        titleFont: String? = nil,
        bodyFont: String? = nil,
        titleSize: Double? = nil,
        bodySize: Double? = nil,
        textColorHex: String? = nil,
        rationale: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.slideIndex = slideIndex
        self.shapeIndex = shapeIndex
        self.shapeName = shapeName
        self.slideTitle = slideTitle
        self.outlineReference = outlineReference
        self.spans = spans
        self.titleFont = titleFont
        self.bodyFont = bodyFont
        self.titleSize = titleSize
        self.bodySize = bodySize
        self.textColorHex = textColorHex
        self.rationale = rationale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        let kindRaw = try container.decodeIfPresent(String.self, forKey: .kind)?.lowercased() ?? "completeslide"
        kind = PowerPointFinishOperationKind(rawValue: kindRaw)
            ?? PowerPointFinishOperationKind(rawValue: kindRaw.replacingOccurrences(of: "_", with: ""))
            ?? .completeSlide
        slideIndex = try container.decodeIfPresent(Int.self, forKey: .slideIndex) ?? 1
        shapeIndex = try container.decodeIfPresent(Int.self, forKey: .shapeIndex)
        shapeName = try container.decodeIfPresent(String.self, forKey: .shapeName)
        slideTitle = try container.decodeIfPresent(String.self, forKey: .slideTitle)
        outlineReference = try container.decodeIfPresent(String.self, forKey: .outlineReference)
        spans = try container.decodeIfPresent([PowerPointFinishTextSpan].self, forKey: .spans) ?? []
        titleFont = try container.decodeIfPresent(String.self, forKey: .titleFont)
        bodyFont = try container.decodeIfPresent(String.self, forKey: .bodyFont)
        titleSize = try container.decodeIfPresent(Double.self, forKey: .titleSize)
        bodySize = try container.decodeIfPresent(Double.self, forKey: .bodySize)
        textColorHex = try container.decodeIfPresent(String.self, forKey: .textColorHex)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(slideIndex, forKey: .slideIndex)
        try container.encodeIfPresent(shapeIndex, forKey: .shapeIndex)
        try container.encodeIfPresent(shapeName, forKey: .shapeName)
        try container.encodeIfPresent(slideTitle, forKey: .slideTitle)
        try container.encodeIfPresent(outlineReference, forKey: .outlineReference)
        try container.encode(spans, forKey: .spans)
        try container.encodeIfPresent(titleFont, forKey: .titleFont)
        try container.encodeIfPresent(bodyFont, forKey: .bodyFont)
        try container.encodeIfPresent(titleSize, forKey: .titleSize)
        try container.encodeIfPresent(bodySize, forKey: .bodySize)
        try container.encodeIfPresent(textColorHex, forKey: .textColorHex)
        try container.encodeIfPresent(rationale, forKey: .rationale)
    }

    /// Concatenated authored text, used to drop no-op operations.
    public var combinedText: String {
        spans.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct PowerPointFinishResult: Codable, Sendable, Hashable {
    public let presentationTitle: String
    public let sourceFilePath: String?
    public let slideCount: Int
    public let summary: String
    public let palette: PowerPointDesignPalette
    public let typography: PowerPointDesignTypography
    public let operations: [PowerPointFinishOperation]
    public let deckRestoreData: [PowerPointRestoreData]?

    enum CodingKeys: String, CodingKey {
        case presentationTitle
        case sourceFilePath
        case slideCount
        case summary
        case palette
        case typography
        case operations
        case deckRestoreData
    }

    public init(
        presentationTitle: String,
        sourceFilePath: String? = nil,
        slideCount: Int,
        summary: String,
        palette: PowerPointDesignPalette,
        typography: PowerPointDesignTypography,
        operations: [PowerPointFinishOperation],
        deckRestoreData: [PowerPointRestoreData]? = nil
    ) {
        self.presentationTitle = presentationTitle
        self.sourceFilePath = sourceFilePath
        self.slideCount = slideCount
        self.summary = summary
        self.palette = palette
        self.typography = typography
        self.operations = operations
        self.deckRestoreData = deckRestoreData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presentationTitle = try container.decodeIfPresent(String.self, forKey: .presentationTitle) ?? "Presentation"
        sourceFilePath = try container.decodeIfPresent(String.self, forKey: .sourceFilePath)
        slideCount = try container.decodeIfPresent(Int.self, forKey: .slideCount) ?? 0
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        palette = try container.decode(PowerPointDesignPalette.self, forKey: .palette)
        typography = try container.decode(PowerPointDesignTypography.self, forKey: .typography)
        operations = try container.decodeIfPresent([PowerPointFinishOperation].self, forKey: .operations) ?? []
        deckRestoreData = try container.decodeIfPresent([PowerPointRestoreData].self, forKey: .deckRestoreData)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(presentationTitle, forKey: .presentationTitle)
        try container.encodeIfPresent(sourceFilePath, forKey: .sourceFilePath)
        try container.encode(slideCount, forKey: .slideCount)
        try container.encode(summary, forKey: .summary)
        try container.encode(palette, forKey: .palette)
        try container.encode(typography, forKey: .typography)
        try container.encode(operations, forKey: .operations)
        try container.encodeIfPresent(deckRestoreData, forKey: .deckRestoreData)
    }
}

public enum PowerPointFinishAction: Sendable, Hashable {
    case jump(slideIndex: Int)
    case apply
    case restore
    case undo
}
