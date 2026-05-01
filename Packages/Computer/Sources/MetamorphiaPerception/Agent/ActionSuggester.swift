import Foundation

/// Given a goal string and current ScreenMap, suggests a ranked sequence of elements to interact with.
/// Uses label matching heuristics and learned workflow patterns.
public enum ActionSuggester {

    // MARK: - Suggestion

    public struct ActionSuggestion: Sendable {
        public let element: ScreenElement
        public let action: ElementAction
        public let rationale: String
        public let score: Float

        public init(element: ScreenElement, action: ElementAction, rationale: String, score: Float) {
            self.element = element
            self.action = action
            self.rationale = rationale
            self.score = score
        }
    }

    /// A full action plan: ordered sequence of suggestions to achieve a goal.
    public struct ActionPlan: Sendable {
        public let goal: String
        public let steps: [ActionSuggestion]
        public let confidence: Float
        public let shortcutAlternative: ShortcutAdvisor.Shortcut?

        public init(goal: String, steps: [ActionSuggestion], confidence: Float, shortcutAlternative: ShortcutAdvisor.Shortcut?) {
            self.goal = goal
            self.steps = steps
            self.confidence = confidence
            self.shortcutAlternative = shortcutAlternative
        }
    }

    // MARK: - Suggestion Engine

    /// Suggest actions to achieve a goal.
    public static func suggest(
        goal: String,
        in map: ScreenMap,
        shortcuts: [ShortcutAdvisor.Shortcut] = [],
        db: ElementDatabase? = nil
    ) -> ActionPlan {
        let goalLower = goal.lowercased()
        let goalWords = goalLower.split(separator: " ").map(String.init)
        var suggestions: [ActionSuggestion] = []

        // Score every interactive element against the goal
        let interactive = map.elements.filter { $0.role.isInteractive }

        for el in interactive {
            let score = matchScore(element: el, goalWords: goalWords, goalFull: goalLower, map: map)
            if score > 0.1 {
                let action = bestAction(for: el)
                let rationale = buildRationale(element: el, goalWords: goalWords, score: score)
                suggestions.append(ActionSuggestion(
                    element: el,
                    action: action,
                    rationale: rationale,
                    score: score
                ))
            }
        }

        // Sort by score descending
        suggestions.sort { $0.score > $1.score }

        // Check if there's a keyboard shortcut that achieves the goal
        let shortcutAlt = findShortcutAlternative(goal: goalLower, shortcuts: shortcuts)

        // Overall confidence based on best match score
        let confidence = suggestions.first?.score ?? 0

        return ActionPlan(
            goal: goal,
            steps: Array(suggestions.prefix(5)),
            confidence: confidence,
            shortcutAlternative: shortcutAlt
        )
    }

    /// Format an action plan as text for LLM consumption.
    public static func formatPlan(_ plan: ActionPlan) -> String {
        var lines: [String] = ["Goal: \(plan.goal)"]

        if let shortcut = plan.shortcutAlternative {
            lines.append("Shortcut: \(shortcut.displayString) (\(shortcut.menuPath.joined(separator: " > ")))")
        }

        if plan.steps.isEmpty {
            lines.append("No matching elements found.")
        } else {
            lines.append("Suggested actions:")
            for (i, step) in plan.steps.enumerated() {
                lines.append("  \(i + 1). \(step.action.rawValue) \(step.element.ref) \"\(step.element.label)\" — \(step.rationale)")
            }
        }

        lines.append("Confidence: \(Int(plan.confidence * 100))%")
        return lines.joined(separator: "\n")
    }

    // MARK: - Scoring

    private static func matchScore(
        element: ScreenElement,
        goalWords: [String],
        goalFull: String,
        map: ScreenMap
    ) -> Float {
        let labelLower = element.label.lowercased()
        let valueLower = element.value.lowercased()

        var score: Float = 0

        // Exact label match
        if labelLower == goalFull {
            score += 0.9
        }

        // Label contains goal
        if labelLower.contains(goalFull) || goalFull.contains(labelLower) {
            score += 0.5
        }

        // Word-level matching
        var wordMatches = 0
        for word in goalWords {
            if word.count < 3 { continue } // Skip short words like "the", "a"
            if labelLower.contains(word) || valueLower.contains(word) {
                wordMatches += 1
            }
        }
        if !goalWords.isEmpty {
            let wordScore = Float(wordMatches) / Float(goalWords.count)
            score += wordScore * 0.4
        }

        // Action verb mapping: "click X" → look for button labeled X
        let actionVerbs: [String: ElementRole] = [
            "click": .button, "press": .button, "tap": .button,
            "type": .textField, "enter": .textField, "fill": .textField,
            "search": .textField, "select": .popUpButton,
            "check": .checkbox, "toggle": .checkbox,
            "open": .menuItem, "choose": .menuItem,
        ]
        for (verb, role) in actionVerbs {
            if goalFull.contains(verb) && element.role == role {
                score += 0.15
            }
        }

        // Parent context matching
        if let parentRef = element.parentRef,
           let parent = map.elements.first(where: { $0.ref == parentRef }) {
            let parentLower = parent.label.lowercased()
            for word in goalWords {
                if word.count >= 3 && parentLower.contains(word) {
                    score += 0.1
                    break
                }
            }
        }

        // Enabled bonus
        if element.state.contains(.enabled) { score += 0.05 }

        return min(score, 1.0)
    }

    /// Pick the most appropriate action for an element.
    private static func bestAction(for element: ScreenElement) -> ElementAction {
        // Use the first available action, or default to press
        if !element.actions.isEmpty {
            // Prefer press over showMenu for buttons
            if element.actions.contains(.press) { return .press }
            return element.actions.first!
        }
        return .press
    }

    private static func buildRationale(element: ScreenElement, goalWords: [String], score: Float) -> String {
        let labelLower = element.label.lowercased()
        var reasons: [String] = []

        for word in goalWords {
            if word.count >= 3 && labelLower.contains(word) {
                reasons.append("matches \"\(word)\"")
                break
            }
        }

        if reasons.isEmpty {
            reasons.append("possible match (score: \(Int(score * 100))%)")
        }

        return reasons.joined(separator: ", ")
    }

    // MARK: - Shortcut Alternative

    private static func findShortcutAlternative(goal: String, shortcuts: [ShortcutAdvisor.Shortcut]) -> ShortcutAdvisor.Shortcut? {
        let goalWords = goal.split(separator: " ").map { $0.lowercased() }

        for shortcut in shortcuts {
            let menuLabel = shortcut.menuPath.last?.lowercased() ?? ""
            for word in goalWords {
                if word.count >= 3 && menuLabel.contains(word) {
                    return shortcut
                }
            }
        }

        return nil
    }
}
