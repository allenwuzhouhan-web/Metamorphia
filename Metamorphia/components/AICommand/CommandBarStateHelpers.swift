import SwiftUI

/// Pure functions mapping `InputBarState` to view concerns. Kept free of
/// SwiftUI state so both `NotchCommandBarView` and future surfaces can call
/// them without duplicating switch statements.
enum CommandBarStateHelpers {

    /// SF Symbol name for the leading icon.
    static func icon(for state: InputBarState) -> String {
        switch state {
        case .ready:                return "sparkle"
        case .processing:           return "brain"
        case .planning:             return "list.bullet.clipboard"
        case .executing:            return "gearshape.2"
        case .streaming:            return "text.bubble"
        case .voiceListening:       return "mic.fill"
        case .researchChoice:       return "magnifyingglass"
        case .browserChoice:        return "globe"
        case .thoughtRecall:        return "brain.fill"
        case .result:               return "checkmark.circle.fill"
        case .error:                return "xmark.circle.fill"
        case .healthCard:           return "heart.circle.fill"
        case .newsBriefing:         return "newspaper.fill"
        case .coworkingSuggestion:  return "person.2.fill"
        }
    }

    /// Accent color for the leading icon.
    static func iconColor(for state: InputBarState) -> Color {
        switch state {
        case .result:           return .green
        case .error:            return .red
        case .voiceListening:   return .purple
        case .thoughtRecall:    return .purple
        case .healthCard:       return .teal
        default:                return .accentColor
        }
    }

    /// Human-readable status label shown in the pill when the user is not
    /// actively editing. Empty string = "show placeholder / the TextField".
    ///
    /// T2: `.result` and `.error` return "" because those states now render
    /// the full message in a dedicated bubble below the pill (see
    /// `ResultBubbleView` / `ErrorBubbleView`). The pill itself flips back
    /// to the editable TextField so the user can immediately type the next
    /// question.
    static func statusText(for state: InputBarState) -> String {
        switch state {
        case .ready:
            return ""
        case .processing:
            return "Thinking…"
        case .planning(let summary):
            return summary.isEmpty ? "Planning…" : summary
        case .executing(let name, let step, let total):
            if total > 0 {
                return "Running \(name)… (\(step)/\(total))"
            }
            return "Running \(name)…"
        case .streaming(let partial):
            return partial.isEmpty ? "Responding…" : partial
        case .voiceListening(let partial):
            return partial.isEmpty ? "Listening…" : partial
        case .result:                   return ""
        case .error:                    return ""
        case .researchChoice:           return "What kind of research?"
        case .browserChoice:            return "Watch or run in background?"
        case .thoughtRecall(let s):     return s.isEmpty ? "Welcome back" : s
        case .newsBriefing:             return "Morning briefing"
        case .coworkingSuggestion(let t): return t
        case .healthCard(let m):        return m
        }
    }

    /// True while the pill should display the animated shimmer overlay.
    static func isShimmering(_ state: InputBarState) -> Bool {
        switch state {
        case .processing, .planning, .executing, .streaming, .voiceListening:
            return true
        default:
            return false
        }
    }

    /// Gradient colors for the shimmer overlay. Distinct palette per state
    /// so the user can read the phase without looking at the label.
    static func shimmerGradient(for state: InputBarState) -> [Color] {
        switch state {
        case .voiceListening:
            return [.clear,
                    Color(hue: 0.78, saturation: 0.30, brightness: 1.0).opacity(0.55),
                    Color(hue: 0.62, saturation: 0.30, brightness: 1.0).opacity(0.55),
                    .clear]
        case .executing:
            return [.clear,
                    Color(hue: 0.58, saturation: 0.25, brightness: 1.0).opacity(0.45),
                    Color(hue: 0.50, saturation: 0.25, brightness: 1.0).opacity(0.45),
                    .clear]
        case .planning:
            return [.clear,
                    Color(hue: 0.10, saturation: 0.28, brightness: 1.0).opacity(0.45),
                    Color(hue: 0.13, saturation: 0.28, brightness: 1.0).opacity(0.45),
                    .clear]
        default:
            // processing / streaming — the Apple-Intelligence rainbow.
            return [.clear,
                    Color(hue: 0.75, saturation: 0.25, brightness: 1.0).opacity(0.50),
                    Color(hue: 0.60, saturation: 0.25, brightness: 1.0).opacity(0.50),
                    Color(hue: 0.85, saturation: 0.25, brightness: 1.0).opacity(0.50),
                    Color(hue: 0.08, saturation: 0.25, brightness: 1.0).opacity(0.50),
                    .clear]
        }
    }
}
