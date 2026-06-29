import Foundation

public enum PowerPointShapeRole: String, Codable, Sendable, Hashable {
    case title
    case body
    case footer
    case other

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .body: return "Body"
        case .footer: return "Footer"
        case .other: return "Other"
        }
    }
}

public enum PowerPointAutomationScope: Codable, Sendable, Hashable {
    case currentSlide
    case selectedSlides
    case slideRange(start: Int, end: Int)
    case wholeDeck

    public var displayName: String {
        switch self {
        case .currentSlide:
            return "Current slide"
        case .selectedSlides:
            return "Selected slides"
        case .slideRange(let start, let end):
            return start == end ? "Slide \(start)" : "Slides \(start)-\(end)"
        case .wholeDeck:
            return "Whole deck"
        }
    }
}

public struct PowerPointSession: Codable, Sendable, Hashable {
    public let presentationTitle: String
    public let sourceFilePath: String?
    public let activeSlideIndex: Int
    public let activeSlideTitle: String?
    public let selectedSlideIndexes: [Int]
    public let shapeCount: Int
    public let editableTextShapeCount: Int
    public let capabilities: [String]

    public init(
        presentationTitle: String,
        sourceFilePath: String? = nil,
        activeSlideIndex: Int,
        activeSlideTitle: String? = nil,
        selectedSlideIndexes: [Int] = [],
        shapeCount: Int = 0,
        editableTextShapeCount: Int = 0,
        capabilities: [String] = []
    ) {
        self.presentationTitle = presentationTitle
        self.sourceFilePath = sourceFilePath
        self.activeSlideIndex = activeSlideIndex
        self.activeSlideTitle = activeSlideTitle
        self.selectedSlideIndexes = selectedSlideIndexes
        self.shapeCount = shapeCount
        self.editableTextShapeCount = editableTextShapeCount
        self.capabilities = capabilities
    }
}

public enum PowerPointTextFormatProperty: String, Codable, Sendable, Hashable {
    case textColor
    case fontSize
    case bold
    case italic
    case underline
    case alignment
    case exactReplacement
    case findReplace

    public var displayName: String {
        switch self {
        case .textColor: return "Text color"
        case .fontSize: return "Font size"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .alignment: return "Alignment"
        case .exactReplacement: return "Text replacement"
        case .findReplace: return "Find and replace"
        }
    }
}

public enum PowerPointCommand: Codable, Sendable, Hashable {
    case textFormatting(scope: PowerPointAutomationScope, property: PowerPointTextFormatProperty, value: String)
    case rewrite(scope: PowerPointAutomationScope, instruction: String)
    case design(scope: PowerPointAutomationScope, instruction: String)
    case slideBackground(scope: PowerPointAutomationScope, color: String)
    case review(scope: PowerPointAutomationScope, instruction: String)
    case clarification(message: String)

    public var requiresPreview: Bool {
        switch self {
        case .rewrite, .design, .review, .clarification:
            return true
        case .slideBackground(let scope, _):
            return scope != .currentSlide
        case .textFormatting(let scope, _, _):
            return scope == .wholeDeck
        }
    }
}

public struct PowerPointShapeRestoreSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { shapeIndex }
    public let shapeIndex: Int
    public let shapeName: String
    public let text: String
    public let fontName: String?
    public let fontSize: Double?
    public let bold: Bool?
    public let italic: Bool?
    public let underline: Bool?
    public let alignment: Int?
    public let fontColor: [Int]?
    public let left: Double?
    public let top: Double?
    public let width: Double?
    public let height: Double?

    public init(
        shapeIndex: Int,
        shapeName: String,
        text: String,
        fontName: String? = nil,
        fontSize: Double? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        alignment: Int? = nil,
        fontColor: [Int]? = nil,
        left: Double? = nil,
        top: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.shapeIndex = shapeIndex
        self.shapeName = shapeName
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.alignment = alignment
        self.fontColor = fontColor
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

public struct PowerPointRestoreData: Codable, Sendable, Hashable {
    public let presentationTitle: String
    public let sourceFilePath: String?
    public let slideIndex: Int
    public let slideTitle: String?
    public let snapshots: [PowerPointShapeRestoreSnapshot]

    public init(
        presentationTitle: String,
        sourceFilePath: String? = nil,
        slideIndex: Int,
        slideTitle: String? = nil,
        snapshots: [PowerPointShapeRestoreSnapshot]
    ) {
        self.presentationTitle = presentationTitle
        self.sourceFilePath = sourceFilePath
        self.slideIndex = slideIndex
        self.slideTitle = slideTitle
        self.snapshots = snapshots
    }
}

public struct PowerPointAutomationResult: Codable, Sendable, Hashable {
    public let command: PowerPointCommand?
    public let session: PowerPointSession?
    public let applied: Bool
    public let previewRequired: Bool
    public let summary: String
    public let affectedShapeIndexes: [Int]
    public let skippedShapeIndexes: [Int]
    public let warnings: [String]
    public let restoreData: PowerPointRestoreData?

    public init(
        command: PowerPointCommand? = nil,
        session: PowerPointSession? = nil,
        applied: Bool,
        previewRequired: Bool = false,
        summary: String,
        affectedShapeIndexes: [Int] = [],
        skippedShapeIndexes: [Int] = [],
        warnings: [String] = [],
        restoreData: PowerPointRestoreData? = nil
    ) {
        self.command = command
        self.session = session
        self.applied = applied
        self.previewRequired = previewRequired
        self.summary = summary
        self.affectedShapeIndexes = affectedShapeIndexes
        self.skippedShapeIndexes = skippedShapeIndexes
        self.warnings = warnings
        self.restoreData = restoreData
    }
}

public struct PowerPointDesignPalette: Codable, Sendable, Hashable {
    public let name: String
    public let primary: String
    public let secondary: String
    public let accent: String
    public let background: String
    public let text: String
    public let mutedText: String

    public init(
        name: String,
        primary: String,
        secondary: String,
        accent: String,
        background: String,
        text: String,
        mutedText: String
    ) {
        self.name = name
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.background = background
        self.text = text
        self.mutedText = mutedText
    }
}

public struct PowerPointDesignTypography: Codable, Sendable, Hashable {
    public let titleFont: String
    public let bodyFont: String
    public let titleSize: Double
    public let bodySize: Double

    public init(
        titleFont: String,
        bodyFont: String,
        titleSize: Double,
        bodySize: Double
    ) {
        self.titleFont = titleFont
        self.bodyFont = bodyFont
        self.titleSize = titleSize
        self.bodySize = bodySize
    }
}

public enum PowerPointDesignOperationKind: String, Codable, Sendable, Hashable {
    case palette
    case typography
    case content
    case hierarchy
    case alignment
    case motif
    case whitespace

    public var displayName: String {
        switch self {
        case .palette: return "Palette"
        case .typography: return "Typography"
        case .content: return "Content"
        case .hierarchy: return "Hierarchy"
        case .alignment: return "Alignment"
        case .motif: return "Motif"
        case .whitespace: return "Whitespace"
        }
    }
}

public struct PowerPointDesignOperation: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: PowerPointDesignOperationKind
    public let target: String
    public let detail: String

    enum CodingKeys: String, CodingKey {
        case kind
        case target
        case detail
    }

    public init(
        id: UUID = UUID(),
        kind: PowerPointDesignOperationKind,
        target: String,
        detail: String
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        kind = try container.decodeIfPresent(PowerPointDesignOperationKind.self, forKey: .kind) ?? .hierarchy
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? "Current slide"
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(target, forKey: .target)
        try container.encode(detail, forKey: .detail)
    }
}

public struct PowerPointDesignTextBlock: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let shapeIndex: Int
    public let shapeName: String
    public let role: PowerPointShapeRole
    public let originalText: String
    public let replacementText: String
    public let rationale: String?

    enum CodingKeys: String, CodingKey {
        case shapeIndex
        case shapeName
        case role
        case originalText
        case replacementText
        case rationale
    }

    public init(
        id: UUID = UUID(),
        shapeIndex: Int,
        shapeName: String,
        role: PowerPointShapeRole,
        originalText: String,
        replacementText: String,
        rationale: String? = nil
    ) {
        self.id = id
        self.shapeIndex = shapeIndex
        self.shapeName = shapeName
        self.role = role
        self.originalText = originalText
        self.replacementText = replacementText
        self.rationale = rationale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        shapeIndex = try container.decodeIfPresent(Int.self, forKey: .shapeIndex) ?? 0
        shapeName = try container.decodeIfPresent(String.self, forKey: .shapeName) ?? ""
        let roleRaw = try container.decodeIfPresent(String.self, forKey: .role)?.lowercased() ?? "other"
        role = PowerPointShapeRole(rawValue: roleRaw) ?? .other
        originalText = try container.decodeIfPresent(String.self, forKey: .originalText) ?? ""
        replacementText = try container.decodeIfPresent(String.self, forKey: .replacementText) ?? ""
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shapeIndex, forKey: .shapeIndex)
        try container.encode(shapeName, forKey: .shapeName)
        try container.encode(role.rawValue, forKey: .role)
        try container.encode(originalText, forKey: .originalText)
        try container.encode(replacementText, forKey: .replacementText)
        try container.encodeIfPresent(rationale, forKey: .rationale)
    }
}

public struct PowerPointDesignResult: Codable, Sendable, Hashable {
    public let presentationTitle: String
    public let sourceFilePath: String?
    public let slideIndex: Int
    public let slideTitle: String?
    public let scope: PowerPointAutomationScope?
    public let slideCount: Int?
    public let slidePreviews: [PowerPointDeckSlidePreview]?
    public let summary: String
    public let recipe: String
    public let palette: PowerPointDesignPalette
    public let typography: PowerPointDesignTypography
    public let motif: String
    public let operations: [PowerPointDesignOperation]
    public let textBlocks: [PowerPointDesignTextBlock]
    public let restoreData: PowerPointRestoreData?
    public let deckRestoreData: [PowerPointRestoreData]?

    enum CodingKeys: String, CodingKey {
        case presentationTitle
        case sourceFilePath
        case slideIndex
        case slideTitle
        case scope
        case slideCount
        case slidePreviews
        case summary
        case recipe
        case palette
        case typography
        case motif
        case operations
        case textBlocks
        case restoreData
        case deckRestoreData
    }

    public init(
        presentationTitle: String,
        sourceFilePath: String? = nil,
        slideIndex: Int,
        slideTitle: String? = nil,
        scope: PowerPointAutomationScope? = nil,
        slideCount: Int? = nil,
        slidePreviews: [PowerPointDeckSlidePreview]? = nil,
        summary: String,
        recipe: String = "Editorial feature",
        palette: PowerPointDesignPalette,
        typography: PowerPointDesignTypography,
        motif: String,
        operations: [PowerPointDesignOperation],
        textBlocks: [PowerPointDesignTextBlock] = [],
        restoreData: PowerPointRestoreData? = nil,
        deckRestoreData: [PowerPointRestoreData]? = nil
    ) {
        self.presentationTitle = presentationTitle
        self.sourceFilePath = sourceFilePath
        self.slideIndex = slideIndex
        self.slideTitle = slideTitle
        self.scope = scope
        self.slideCount = slideCount
        self.slidePreviews = slidePreviews
        self.summary = summary
        self.recipe = recipe
        self.palette = palette
        self.typography = typography
        self.motif = motif
        self.operations = operations
        self.textBlocks = textBlocks
        self.restoreData = restoreData
        self.deckRestoreData = deckRestoreData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presentationTitle = try container.decode(String.self, forKey: .presentationTitle)
        sourceFilePath = try container.decodeIfPresent(String.self, forKey: .sourceFilePath)
        slideIndex = try container.decode(Int.self, forKey: .slideIndex)
        slideTitle = try container.decodeIfPresent(String.self, forKey: .slideTitle)
        scope = try container.decodeIfPresent(PowerPointAutomationScope.self, forKey: .scope)
        slideCount = try container.decodeIfPresent(Int.self, forKey: .slideCount)
        slidePreviews = try container.decodeIfPresent([PowerPointDeckSlidePreview].self, forKey: .slidePreviews)
        summary = try container.decode(String.self, forKey: .summary)
        recipe = try container.decodeIfPresent(String.self, forKey: .recipe) ?? "Editorial feature"
        palette = try container.decodeIfPresent(PowerPointDesignPalette.self, forKey: .palette) ?? PowerPointDesignPalette(
            name: "Custom",
            primary: "2F3C7E",
            secondary: "F2F2F2",
            accent: "F96167",
            background: "FFFFFF",
            text: "111827",
            mutedText: "4B5563"
        )
        typography = try container.decodeIfPresent(PowerPointDesignTypography.self, forKey: .typography) ?? PowerPointDesignTypography(
            titleFont: "Aptos Display",
            bodyFont: "Aptos",
            titleSize: 38,
            bodySize: 16
        )
        motif = try container.decodeIfPresent(String.self, forKey: .motif) ?? "Accent bar"
        operations = try container.decodeIfPresent([PowerPointDesignOperation].self, forKey: .operations) ?? []
        textBlocks = try container.decodeIfPresent([PowerPointDesignTextBlock].self, forKey: .textBlocks) ?? []
        restoreData = try container.decodeIfPresent(PowerPointRestoreData.self, forKey: .restoreData)
        deckRestoreData = try container.decodeIfPresent([PowerPointRestoreData].self, forKey: .deckRestoreData)
    }

    public func withSourceFilePath(_ path: String?, restoreData: PowerPointRestoreData?) -> PowerPointDesignResult {
        PowerPointDesignResult(
            presentationTitle: presentationTitle,
            sourceFilePath: path,
            slideIndex: slideIndex,
            slideTitle: slideTitle,
            scope: scope,
            slideCount: slideCount,
            slidePreviews: slidePreviews,
            summary: summary,
            recipe: recipe,
            palette: palette,
            typography: typography,
            motif: motif,
            operations: operations,
            textBlocks: textBlocks,
            restoreData: restoreData,
            deckRestoreData: deckRestoreData
        )
    }

    public var isWholeDeck: Bool {
        if scope == .wholeDeck { return true }
        return (slideCount ?? 1) > 1 || !(deckRestoreData ?? []).isEmpty
    }
}

public enum PowerPointDesignAction: Sendable, Hashable {
    case jump
    case apply
    case restore
    case undo
}

public struct PowerPointDeckSlidePreview: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { slideIndex }
    public let slideIndex: Int
    public let title: String?
    public let shapeCount: Int
    public let titleShapeCount: Int
    public let bodyShapeCount: Int

    public init(
        slideIndex: Int,
        title: String? = nil,
        shapeCount: Int,
        titleShapeCount: Int,
        bodyShapeCount: Int
    ) {
        self.slideIndex = slideIndex
        self.title = title
        self.shapeCount = shapeCount
        self.titleShapeCount = titleShapeCount
        self.bodyShapeCount = bodyShapeCount
    }
}

public struct PowerPointRewriteReplacement: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let shapeIndex: Int
    public let shapeName: String
    public let role: PowerPointShapeRole
    public let originalText: String
    public let replacementText: String
    public let rationale: String?

    enum CodingKeys: String, CodingKey {
        case shapeIndex
        case shapeName
        case role
        case originalText
        case replacementText
        case rationale
    }

    public init(
        id: UUID = UUID(),
        shapeIndex: Int,
        shapeName: String,
        role: PowerPointShapeRole,
        originalText: String,
        replacementText: String,
        rationale: String? = nil
    ) {
        self.id = id
        self.shapeIndex = shapeIndex
        self.shapeName = shapeName
        self.role = role
        self.originalText = originalText
        self.replacementText = replacementText
        self.rationale = rationale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        shapeIndex = try container.decodeIfPresent(Int.self, forKey: .shapeIndex) ?? 0
        shapeName = try container.decodeIfPresent(String.self, forKey: .shapeName) ?? ""
        role = try container.decodeIfPresent(PowerPointShapeRole.self, forKey: .role) ?? .other
        originalText = try container.decodeIfPresent(String.self, forKey: .originalText) ?? ""
        replacementText = try container.decode(String.self, forKey: .replacementText)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shapeIndex, forKey: .shapeIndex)
        try container.encode(shapeName, forKey: .shapeName)
        try container.encode(role, forKey: .role)
        try container.encode(originalText, forKey: .originalText)
        try container.encode(replacementText, forKey: .replacementText)
        try container.encodeIfPresent(rationale, forKey: .rationale)
    }

    public var trimmedReplacementText: String? {
        let trimmed = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct PowerPointRewriteResult: Codable, Sendable, Hashable {
    public let presentationTitle: String
    public let sourceFilePath: String?
    public let slideIndex: Int
    public let slideTitle: String?
    public let summary: String
    public let replacements: [PowerPointRewriteReplacement]

    public init(
        presentationTitle: String,
        sourceFilePath: String? = nil,
        slideIndex: Int,
        slideTitle: String? = nil,
        summary: String,
        replacements: [PowerPointRewriteReplacement]
    ) {
        self.presentationTitle = presentationTitle
        self.sourceFilePath = sourceFilePath
        self.slideIndex = slideIndex
        self.slideTitle = slideTitle
        self.summary = summary
        self.replacements = replacements
    }

    public func withSourceFilePath(_ path: String?) -> PowerPointRewriteResult {
        PowerPointRewriteResult(
            presentationTitle: presentationTitle,
            sourceFilePath: path,
            slideIndex: slideIndex,
            slideTitle: slideTitle,
            summary: summary,
            replacements: replacements
        )
    }
}

public enum PowerPointRewriteAction: Sendable, Hashable {
    case jump
    case apply
    case restore
}

public enum PowerPointDirectEditKind: String, Codable, Sendable, Hashable {
    case textColor
    case fontSize
    case bold
    case italic
    case underline
    case alignment
    case backgroundColor

    public var displayName: String {
        switch self {
        case .textColor: return "Text color"
        case .fontSize: return "Font size"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .alignment: return "Alignment"
        case .backgroundColor: return "Background color"
        }
    }
}

public struct PowerPointDirectEditAction: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let targetScope: String
    public let property: PowerPointDirectEditKind
    public let value: String
    public let affectedShapeIndexes: [Int]

    enum CodingKeys: String, CodingKey {
        case targetScope
        case property
        case value
        case affectedShapeIndexes
    }

    public init(
        id: UUID = UUID(),
        targetScope: String,
        property: PowerPointDirectEditKind,
        value: String,
        affectedShapeIndexes: [Int]
    ) {
        self.id = id
        self.targetScope = targetScope
        self.property = property
        self.value = value
        self.affectedShapeIndexes = affectedShapeIndexes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        targetScope = try container.decode(String.self, forKey: .targetScope)
        property = try container.decode(PowerPointDirectEditKind.self, forKey: .property)
        value = try container.decode(String.self, forKey: .value)
        affectedShapeIndexes = try container.decode([Int].self, forKey: .affectedShapeIndexes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetScope, forKey: .targetScope)
        try container.encode(property, forKey: .property)
        try container.encode(value, forKey: .value)
        try container.encode(affectedShapeIndexes, forKey: .affectedShapeIndexes)
    }
}

public struct PowerPointDirectEditResult: Codable, Sendable, Hashable {
    public let presentationTitle: String
    public let sourceFilePath: String?
    public let slideIndex: Int
    public let slideTitle: String?
    public let summary: String
    public let actions: [PowerPointDirectEditAction]
    public let skippedShapeCount: Int
    public let warnings: [String]
    public let restoreData: PowerPointRestoreData?

    public init(
        presentationTitle: String,
        sourceFilePath: String? = nil,
        slideIndex: Int,
        slideTitle: String? = nil,
        summary: String,
        actions: [PowerPointDirectEditAction],
        skippedShapeCount: Int = 0,
        warnings: [String] = [],
        restoreData: PowerPointRestoreData? = nil
    ) {
        self.presentationTitle = presentationTitle
        self.sourceFilePath = sourceFilePath
        self.slideIndex = slideIndex
        self.slideTitle = slideTitle
        self.summary = summary
        self.actions = actions
        self.skippedShapeCount = skippedShapeCount
        self.warnings = warnings
        self.restoreData = restoreData
    }

    public var affectedShapeCount: Int {
        actions.reduce(0) { $0 + $1.affectedShapeIndexes.count }
    }
}

public enum PowerPointDirectEditControlAction: Sendable, Hashable {
    case jump
    case restore
    case undo
}
