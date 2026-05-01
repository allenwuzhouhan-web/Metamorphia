import SwiftUI

public struct AgentProfile: Identifiable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let systemPromptFragment: String
    public let colorHex: String
    public let iconSymbol: String

    public init(
        id: String, displayName: String, systemPromptFragment: String,
        colorHex: String, iconSymbol: String
    ) {
        self.id = id
        self.displayName = displayName
        self.systemPromptFragment = systemPromptFragment
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
    }

    public var color: Color {
        Color(agentHex: colorHex) ?? .white
    }

    public static let general = AgentProfile(
        id: "general",
        displayName: "General",
        systemPromptFragment: "",
        colorHex: "#FFFFFF",
        iconSymbol: "sparkle"
    )
}

extension Color {
    init?(agentHex: String) {
        var hex = agentHex.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgb) else { return nil }
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((rgb & 0xFF0000) >> 16) / 255.0
            g = Double((rgb & 0x00FF00) >> 8) / 255.0
            b = Double(rgb & 0x0000FF) / 255.0
        case 8:
            r = Double((rgb & 0xFF000000) >> 24) / 255.0
            g = Double((rgb & 0x00FF0000) >> 16) / 255.0
            b = Double((rgb & 0x0000FF00) >> 8) / 255.0
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b)
    }
}
