import Foundation

public struct PresentationDeckSample: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var fileName: String
    public var fileExtension: String
    public var slideCount: Int
    public var slideWidth: Double?
    public var slideHeight: Double?
    public var typography: [PresentationFontSample]
    public var colors: [String]
    public var shapeRoles: [String: Int]
    public var layoutPatterns: [String]
    public var allowModelAnalysis: Bool
    public var addedAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        fileName: String,
        fileExtension: String,
        slideCount: Int,
        slideWidth: Double? = nil,
        slideHeight: Double? = nil,
        typography: [PresentationFontSample] = [],
        colors: [String] = [],
        shapeRoles: [String: Int] = [:],
        layoutPatterns: [String] = [],
        allowModelAnalysis: Bool = false,
        addedAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.slideCount = slideCount
        self.slideWidth = slideWidth
        self.slideHeight = slideHeight
        self.typography = typography
        self.colors = colors
        self.shapeRoles = shapeRoles
        self.layoutPatterns = layoutPatterns
        self.allowModelAnalysis = allowModelAnalysis
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}

public struct PresentationFontSample: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(name)-\(Int(size.rounded()))-\(role)" }
    public var name: String
    public var size: Double
    public var weight: String?
    public var role: String
    public var count: Int

    public init(name: String, size: Double, weight: String? = nil, role: String, count: Int = 1) {
        self.name = name
        self.size = size
        self.weight = weight
        self.role = role
        self.count = count
    }
}

public struct PresentationTasteProfile: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var deckCount: Int
    public var learnedAt: Date
    public var palette: [String]
    public var titleFont: String
    public var bodyFont: String
    public var titleSize: Double
    public var bodySize: Double
    public var spacingRhythm: String
    public var layoutArchetypes: [String]
    public var motifs: [String]
    public var densityPreference: String
    public var antiPatterns: [String]
    public var modelAssistedDeckCount: Int

    public init(
        id: UUID = UUID(),
        name: String = "Presentation Taste",
        deckCount: Int = 0,
        learnedAt: Date = .now,
        palette: [String] = ["1E2761", "CADCFC", "F96167", "FFFFFF", "111827"],
        titleFont: String = "Aptos Display",
        bodyFont: String = "Aptos",
        titleSize: Double = 40,
        bodySize: Double = 16,
        spacingRhythm: String = "Moderate whitespace with clear title/body separation",
        layoutArchetypes: [String] = [],
        motifs: [String] = ["restrained accent shape"],
        densityPreference: String = "balanced",
        antiPatterns: [String] = ["low contrast text", "decorative clutter"],
        modelAssistedDeckCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.deckCount = deckCount
        self.learnedAt = learnedAt
        self.palette = palette
        self.titleFont = titleFont
        self.bodyFont = bodyFont
        self.titleSize = titleSize
        self.bodySize = bodySize
        self.spacingRhythm = spacingRhythm
        self.layoutArchetypes = layoutArchetypes
        self.motifs = motifs
        self.densityPreference = densityPreference
        self.antiPatterns = antiPatterns
        self.modelAssistedDeckCount = modelAssistedDeckCount
    }

    public var promptSummary: String {
        """
        Active presentation design language:
        - Learned from \(deckCount) reference deck(s); model-assisted analysis allowed for \(modelAssistedDeckCount).
        - Palette: \(palette.prefix(6).map { "#\($0)" }.joined(separator: ", "))
        - Typography: title \(titleFont) \(Int(titleSize))pt; body \(bodyFont) \(Int(bodySize))pt.
        - Spacing: \(spacingRhythm)
        - Layout archetypes: \(layoutArchetypes.prefix(5).joined(separator: ", "))
        - Motifs: \(motifs.prefix(4).joined(separator: ", "))
        - Density: \(densityPreference)
        - Avoid: \(antiPatterns.prefix(5).joined(separator: ", "))
        """
    }
}

public struct PresentationTasteSnapshot: Codable, Sendable, Hashable {
    public var samples: [PresentationDeckSample]
    public var activeProfile: PresentationTasteProfile?

    public init(samples: [PresentationDeckSample] = [], activeProfile: PresentationTasteProfile? = nil) {
        self.samples = samples
        self.activeProfile = activeProfile
    }
}
