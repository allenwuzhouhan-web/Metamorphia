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
import CoreServices

/// Local matcher for dictionary lookups.
///
/// Triggers:
///   "define serendipity"
///   "definition of serendipity"
///   "what does serendipity mean"
///   "what's the meaning of serendipity"
///
/// Uses `DCSCopyTextDefinition` (CoreServices). Unsandboxed macOS apps can call
/// this without additional entitlements. Returns nil if DCS finds no definition,
/// allowing the prompt to fall through to the LLM.
///
/// 3-word cap on the looked-up term avoids defining multi-word phrases that DCS
/// would fail on anyway.
enum DictionaryLocalMatcher {

    private static let maxTermWords = 3

    static func handle(_ normalized: String) async -> LocalCommandHit? {
        guard let term = extractTerm(from: normalized),
              !term.isEmpty else { return nil }

        let wordCount = term.split(separator: " ").count
        guard wordCount <= maxTermWords else { return nil }

        let start = Date()

        guard let definition = lookupDefinition(term) else { return nil }

        let elapsed = Date().timeIntervalSince(start)
        // Trim trailing whitespace / newlines from DCS output.
        let trimmed = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cap at 600 chars — DCS entries can be very long.
        let capped = trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
        return LocalCommandHit(
            matcherName: "dictionary",
            message: "**\(term.capitalized)**: \(capped)",
            arguments: "term=\"\(term)\"",
            elapsed: elapsed
        )
    }

    // MARK: - Term extraction

    private static func extractTerm(from s: String) -> String? {
        let patterns: [(prefix: String, suffix: String?)] = [
            ("define ", nil),
            ("definition of ", nil),
            ("what does ", " mean"),
            ("what's the meaning of ", nil),
            ("what is the meaning of ", nil),
            ("whats the meaning of ", nil),
            ("meaning of ", nil),
        ]
        for (prefix, suffix) in patterns {
            guard s.hasPrefix(prefix) else { continue }
            var body = String(s.dropFirst(prefix.count))
            if let suf = suffix, body.hasSuffix(suf) {
                body = String(body.dropLast(suf.count))
            }
            let term = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty { return term }
        }
        return nil
    }

    // MARK: - DCS lookup

    private static func lookupDefinition(_ term: String) -> String? {
        let cfTerm = term as CFString
        let range = CFRangeMake(0, CFStringGetLength(cfTerm))
        guard let rawResult = DCSCopyTextDefinition(nil, cfTerm, range) else { return nil }
        return rawResult.takeRetainedValue() as String
    }
}
