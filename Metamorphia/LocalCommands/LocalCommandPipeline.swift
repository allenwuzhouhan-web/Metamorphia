/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// Tiered local-command dispatcher.
///
/// Priority:
///   Tier 1 — Five pattern matchers (timer, note, dictionary, web-nav, music).
///   Tier 2 — SmartCalculator (unit-aware math, zero API calls).
///   Tier 3 — FormulaDatabase (formula/constant lookup, zero API calls).
///   Fall-through → caller sends to AgentLoop.
///
/// The 40-word cap prevents runaway pasted text from clogging the matchers.
public enum LocalCommandPipeline {

    private static let maxWordCount = 40

    /// Attempt to handle `prompt` locally. Returns a `LocalCommandHit` on
    /// success, nil to signal that the caller should fall through to the agent.
    public static func handle(prompt: String) async -> LocalCommandHit? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        let wordCount = normalized.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount <= maxWordCount else { return nil }

        // Tier 1 — pattern matchers (cheap / specific first).
        if let hit = await TimerLocalMatcher.handle(normalized) { return hit }
        if let hit = await NoteLocalMatcher.handle(normalized) { return hit }
        if let hit = await DictionaryLocalMatcher.handle(normalized) { return hit }
        if let hit = await MusicLocalMatcher.handle(normalized) { return hit }
        if let hit = await WebNavigationLocalMatcher.handle(normalized) { return hit }

        // Tier 2 — SmartCalculator.
        if let result = SmartCalculator.evaluate(normalized) {
            return LocalCommandHit(
                matcherName: "smart_calculator",
                message: result,
                arguments: "query=\"\(normalized)\"",
                elapsed: 0
            )
        }

        // Tier 3 — FormulaDatabase.
        if let result = FormulaDatabase.shared.lookup(normalized) {
            return LocalCommandHit(
                matcherName: "formula_database",
                message: result,
                arguments: "query=\"\(normalized)\"",
                elapsed: 0
            )
        }

        return nil
    }
}
