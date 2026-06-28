/*
 * Metamorphia
 *
 * AgentToolSymbolCatalog — pure toolName -> SF Symbol map for the Pulse.
 *
 * The leading glyph the transient agent presence shows while a tool executes.
 * Mirrors SystemEventIndicatorModifier's switch-on-value symbol style. No
 * state, no SwiftUI — just a lookup so the view layer stays declarative.
 */

import Foundation

enum AgentToolSymbolCatalog {
    /// Maps a raw agent tool name to an SF Symbol. Unknown tools fall back to
    /// `sparkle` (the generic "agent is doing something" glyph).
    static func symbol(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "search_web", "web_search":
            return "magnifyingglass"
        case "edit_file", "write_file", "read_file":
            return "square.and.pencil"
        case "shell", "bash", "run_shell":
            return "terminal"
        case "run_applescript", "applescript", "click", "ui":
            return "cursorarrow.rays"
        case "recall", "remember", "memory_recall":
            return "clock.arrow.circlepath"
        default:
            return "sparkle"
        }
    }
}
