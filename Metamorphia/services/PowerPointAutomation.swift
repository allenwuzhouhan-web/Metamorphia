import AppKit
import Foundation

enum PowerPointAutomationRoute: Sendable, Hashable {
    case deterministic(PowerPointCommand)
    case rewrite(PowerPointCommand)
    case unsupported
}

enum PowerPointAutomationRouter {
    private static let powerPointBundleID = "com.microsoft.Powerpoint"

    static func route(prompt: String) -> PowerPointAutomationRoute {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported }

        let normalized = trimmed.lowercased()
        let scope = scope(from: normalized)
        let frontmostPowerPoint = Self.isPowerPointFrontmost
        let openPowerPoint = Self.isPowerPointOpen

        if let textCommand = textFormattingCommand(from: normalized, scope: scope),
           mentionsPowerPointTarget(normalized, frontmostPowerPoint: frontmostPowerPoint, openPowerPoint: openPowerPoint) {
            return .deterministic(textCommand)
        }

        if isDesignIntent(normalized, frontmostPowerPoint: frontmostPowerPoint, openPowerPoint: openPowerPoint) {
            return .rewrite(.design(scope: scope, instruction: trimmed))
        }

        if isRewriteIntent(normalized, frontmostPowerPoint: frontmostPowerPoint, openPowerPoint: openPowerPoint) {
            return .rewrite(.rewrite(scope: scope, instruction: trimmed))
        }

        return .unsupported
    }

    private static var isPowerPointFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == powerPointBundleID
    }

    private static var isPowerPointOpen: Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: powerPointBundleID)
            .contains { !$0.isTerminated }
    }

    private static func scope(from normalized: String) -> PowerPointAutomationScope {
        if normalized.contains("whole deck") ||
            normalized.contains("entire deck") ||
            normalized.contains("all slides") ||
            normalized.contains("the deck") ||
            normalized.contains("this deck") ||
            normalized.contains("current deck") ||
            normalized.contains("open deck") {
            return .wholeDeck
        }

        if normalized.contains("selected slides") {
            return .selectedSlides
        }

        if let range = slideRange(from: normalized) {
            return .slideRange(start: range.start, end: range.end)
        }

        return .currentSlide
    }

    private static func slideRange(from normalized: String) -> (start: Int, end: Int)? {
        let patterns = [
            #"slides?\s+(\d{1,3})\s*(?:-|to|through)\s*(\d{1,3})"#,
            #"slides?\s+(\d{1,3})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range),
                  match.numberOfRanges > 1,
                  let startRange = Range(match.range(at: 1), in: normalized),
                  let start = Int(normalized[startRange]) else {
                continue
            }
            if match.numberOfRanges > 2,
               let endRange = Range(match.range(at: 2), in: normalized),
               let end = Int(normalized[endRange]) {
                return (min(start, end), max(start, end))
            }
            return (start, start)
        }
        return nil
    }

    private static func textFormattingCommand(
        from normalized: String,
        scope: PowerPointAutomationScope
    ) -> PowerPointCommand? {
        if let color = colorName(from: normalized),
           (normalized.contains("color") ||
            normalized.contains("colour") ||
            normalized.contains("text") ||
            normalized.contains("font")) {
            return .textFormatting(scope: scope, property: .textColor, value: color)
        }

        if let fontSize = fontSize(from: normalized) {
            return .textFormatting(scope: scope, property: .fontSize, value: "\(fontSize) pt")
        }

        if normalized.contains("bold") {
            let enabled = !(normalized.contains("unbold") ||
                normalized.contains("not bold") ||
                normalized.contains("remove bold"))
            return .textFormatting(scope: scope, property: .bold, value: enabled ? "on" : "off")
        }

        if normalized.contains("italic") || normalized.contains("italics") {
            let enabled = !(normalized.contains("unitalic") ||
                normalized.contains("not italic") ||
                normalized.contains("remove italic") ||
                normalized.contains("remove italics"))
            return .textFormatting(scope: scope, property: .italic, value: enabled ? "on" : "off")
        }

        if normalized.contains("underline") {
            let enabled = !(normalized.contains("remove underline") ||
                normalized.contains("no underline") ||
                normalized.contains("not underlined"))
            return .textFormatting(scope: scope, property: .underline, value: enabled ? "on" : "off")
        }

        if let alignment = alignment(from: normalized) {
            return .textFormatting(scope: scope, property: .alignment, value: alignment)
        }

        return nil
    }

    private static func mentionsPowerPointTarget(
        _ normalized: String,
        frontmostPowerPoint: Bool,
        openPowerPoint: Bool
    ) -> Bool {
        let targets = [
            "slide", "slides", "deck", "presentation", "powerpoint",
            "ppt", "pptx"
        ]
        let currentOpenTargets = [
            "this", "current", "open", "selected", "active"
        ]
        return frontmostPowerPoint ||
            targets.contains { normalized.contains($0) } ||
            (openPowerPoint && currentOpenTargets.contains { normalized.contains($0) })
    }

    private static func isDesignIntent(
        _ normalized: String,
        frontmostPowerPoint: Bool,
        openPowerPoint: Bool
    ) -> Bool {
        let designTerms = [
            "design", "redesign", "make it look better", "make this look better",
            "make this slide look better", "make the slide look better",
            "improve the design", "better layout", "visual polish",
            "polish the design", "make it prettier", "improve visuals",
            "style this slide", "restyle this slide", "style this deck",
            "restyle this deck", "design language"
        ]
        let targetTerms = ["slide", "deck", "presentation", "powerpoint", "ppt"]
        let currentOpenTerms = ["this", "current", "open", "selected", "active"]
        return designTerms.contains { normalized.contains($0) } &&
            (
                frontmostPowerPoint ||
                targetTerms.contains { normalized.contains($0) } ||
                (openPowerPoint && currentOpenTerms.contains { normalized.contains($0) })
            )
    }

    private static func isRewriteIntent(
        _ normalized: String,
        frontmostPowerPoint: Bool,
        openPowerPoint: Bool
    ) -> Bool {
        if normalized.contains("presentation skills") ||
            normalized.contains("public speaking") ||
            normalized.contains("speaker notes") {
            return false
        }

        let creationTerms = ["create", "build", "generate", "make a deck", "make me a deck", "make slides"]
        if creationTerms.contains(where: { normalized.contains($0) }) &&
            !normalized.contains("current") &&
            !normalized.contains("this slide") {
            return false
        }

        let rewriteVerbs = [
            "rewrite", "revise", "improve", "polish", "tighten", "simplify",
            "shorten", "condense", "clean up", "sharpen", "make this slide",
            "make the slide", "make my slide", "board-ready", "executive-ready",
            "more concise", "more professional"
        ]
        let explicitTargets = [
            "this slide", "current slide", "open slide", "selected slide",
            "this powerpoint", "current powerpoint", "open powerpoint",
            "this deck", "current deck", "open deck",
            "this presentation", "current presentation", "open presentation"
        ]
        let hasRewriteVerb = rewriteVerbs.contains { normalized.contains($0) }
        let mentionsCurrentTarget = explicitTargets.contains { normalized.contains($0) }
        let mentionsCurrentThing = normalized.contains("this") ||
            normalized.contains("current") ||
            normalized.contains("open") ||
            normalized.contains("selected")
        return hasRewriteVerb &&
            (mentionsCurrentTarget || ((frontmostPowerPoint || openPowerPoint) && mentionsCurrentThing))
    }

    private static func colorName(from normalized: String) -> String? {
        let colors = [
            "lime green", "black", "white", "red", "green", "blue",
            "yellow", "orange", "purple", "gray", "grey"
        ]
        return colors.first { normalized.contains($0) }
    }

    private static func fontSize(from normalized: String) -> Int? {
        let patterns = [
            #"font size(?:\D{0,20})(\d{1,3})"#,
            #"text size(?:\D{0,20})(\d{1,3})"#,
            #"(\d{1,3})\s*(?:pt|point|points)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            guard let match = regex.firstMatch(in: normalized, range: range),
                  match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: normalized),
                  let value = Int(normalized[swiftRange]),
                  (4...200).contains(value) else {
                continue
            }
            return value
        }
        return nil
    }

    private static func alignment(from normalized: String) -> String? {
        let candidates: [(tokens: [String], value: String)] = [
            (["align left", "left align", "left aligned"], "left"),
            (["align center", "center align", "centered", "centre align", "align centre"], "center"),
            (["align right", "right align", "right aligned"], "right"),
            (["justify"], "justified")
        ]
        return candidates.first { candidate in
            candidate.tokens.contains { normalized.contains($0) }
        }?.value
    }
}

enum PowerPointExecutor {
    struct JSONEnvelope: Decodable {
        let ok: Bool?
        let error: String?
        let presentationTitle: String?
        let filePath: String?
        let slideIndex: Int?
        let slideTitle: String?
        let shapeCount: Int?
        let applied: [Int]?
        let skipped: [Int]?
        let warnings: [String]?
        let snapshots: [PowerPointShapeRestoreSnapshot]?
    }

    static func runJSON<T: Decodable>(
        _ script: String,
        as type: T.Type,
        timeoutSeconds: TimeInterval
    ) async throws -> T {
        guard let descriptor = try await AppleScriptHelper.execute(script, timeoutSeconds: timeoutSeconds),
              let raw = descriptor.stringValue,
              let data = raw.data(using: .utf8) else {
            throw NSError(
                domain: "PowerPointAutomation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "PowerPoint did not return JSON output."]
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NSError(
                domain: "PowerPointAutomation",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "PowerPoint returned JSON Metamorphia could not parse: \(error.localizedDescription)"]
            )
        }
    }

    static func runText(_ script: String, timeoutSeconds: TimeInterval) async throws -> String {
        guard let descriptor = try await AppleScriptHelper.execute(script, timeoutSeconds: timeoutSeconds),
              let raw = descriptor.stringValue else {
            throw NSError(
                domain: "PowerPointAutomation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "PowerPoint did not return output."]
            )
        }
        return raw
    }
}
