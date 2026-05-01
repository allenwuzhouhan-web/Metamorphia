import Foundation

enum ResearchDetector {
    static let prefixes: [String] = [
        "research ", "deep dive ", "investigate ", "deep research ",
    ]

    static func matches(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefixes.contains { lower.hasPrefix($0) }
    }
}
