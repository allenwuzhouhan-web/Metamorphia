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
import Defaults

/// Local matcher for quick-note commands.
///
/// Triggers (case-insensitive via lowercased input):
///   "note: buy milk"
///   "note buy milk"
///   "take a note buy milk"
///   "make a note buy milk"
///   "quick note buy milk"
///
/// Rejects body that looks like a timer command to avoid "note: set a timer for 5 min"
/// saving as a note instead of falling through to the timer matcher.
enum NoteLocalMatcher {

    private static let prefixes: [String] = [
        "note: ",
        "note ",
        "take a note: ",
        "take a note ",
        "make a note: ",
        "make a note ",
        "quick note: ",
        "quick note ",
        "add a note: ",
        "add a note ",
        "save a note: ",
        "save a note ",
        "jot down: ",
        "jot down ",
    ]

    // Words at the start of the body that indicate this is NOT a note.
    private static let timerBodyPrefixes: [String] = [
        "set a timer",
        "set timer",
        "start a timer",
        "start timer",
        "timer",
        "remind me",
    ]

    static func handle(_ normalized: String) async -> LocalCommandHit? {
        guard let body = LocalCommandHelpers.stripPrefix(normalized, prefixes: prefixes),
              !body.isEmpty else { return nil }

        // Guard: if body looks like a timer command, fall through so timer matcher handles it.
        for timerPrefix in timerBodyPrefixes {
            if body.hasPrefix(timerPrefix) { return nil }
        }

        let start = Date()

        // Title = first 40 chars of body (matching existing MetamorphiaTools convention).
        let title = String(body.prefix(40))

        if let registry = LocalCommandPipeline.registry {
            // Escape body for JSON: replace backslashes then quotes.
            let escaped = body
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let argsJSON = "{\"title\":\"\(title)\",\"body\":\"\(escaped)\"}"
            _ = try? await registry.executeDirectly(toolName: "append_note", arguments: argsJSON)
        } else {
            let note = NoteItem(
                id: UUID(),
                title: title,
                content: body,
                creationDate: Date(),
                colorIndex: 0,
                isPinned: false,
                imageFileName: nil
            )
            await MainActor.run {
                var current = Defaults[.savedNotes]
                current.append(note)
                Defaults[.savedNotes] = current
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        let preview = body.count > 50 ? String(body.prefix(47)) + "..." : body
        return LocalCommandHit(
            matcherName: "note",
            message: "Note saved: \"\(preview)\"",
            arguments: "title=\"\(title)\"",
            elapsed: elapsed
        )
    }
}
