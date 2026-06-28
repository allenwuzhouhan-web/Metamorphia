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

// MARK: - Duration Parsing

enum LocalCommandHelpers {
    struct AppleScriptRunResult {
        let output: String?
        let errorMessage: String?
    }

    // MARK: - Duration

    /// Parses natural-language compound durations.
    /// Handles: "5 minutes", "1 hour 30 minutes", "2h30m", "90 seconds",
    ///          "1:30" (m:s), "1:30:00" (h:m:s), "an hour", "half an hour".
    /// Returns nil if no duration found.
    static func parseCompoundDuration(from input: String) -> TimeInterval? {
        let s = input
            .replacingOccurrences(of: "an hour", with: "1 hour")
            .replacingOccurrences(of: "a half hour", with: "30 minutes")
            .replacingOccurrences(of: "half an hour", with: "30 minutes")
            .replacingOccurrences(of: "half hour", with: "30 minutes")

        var total: TimeInterval = 0
        var found = false

        // Word-based patterns: "5 minutes", "2 hours", "30 seconds", "1 day"
        let wordPattern = #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?|days?|weeks?|months?|years?)"#
        if let regex = try? NSRegularExpression(pattern: wordPattern, options: .caseInsensitive) {
            let range = NSRange(s.startIndex..., in: s)
            let matches = regex.matches(in: s, range: range)
            for m in matches {
                guard let numRange = Range(m.range(at: 1), in: s),
                      let unitRange = Range(m.range(at: 2), in: s),
                      let num = Double(s[numRange]) else { continue }
                let unit = s[unitRange].lowercased()
                let factor: Double
                if unit.hasPrefix("year") { factor = 31_536_000 }
                else if unit.hasPrefix("month") { factor = 2_592_000 }
                else if unit.hasPrefix("week") { factor = 604_800 }
                else if unit.hasPrefix("day") { factor = 86_400 }
                else if unit.hasPrefix("h") { factor = 3_600 }
                else if unit.hasPrefix("min") || unit.hasPrefix("m") { factor = 60 }
                else { factor = 1 }
                total += num * factor
                found = true
            }
        }
        if found { return total }

        // Compact patterns: "2h30m", "1h", "30m", "45s"
        let compactPattern = #"(?:(\d+)h)?(?:(\d+)m(?!o))?(?:(\d+)s)?"#
        if let regex = try? NSRegularExpression(pattern: compactPattern, options: .caseInsensitive) {
            let range = NSRange(s.startIndex..., in: s)
            if let m = regex.firstMatch(in: s, range: range) {
                let h = groupDouble(m, 1, in: s) ?? 0
                let min = groupDouble(m, 2, in: s) ?? 0
                let sec = groupDouble(m, 3, in: s) ?? 0
                let t = h * 3600 + min * 60 + sec
                if t > 0 { return t }
            }
        }

        // Colon notation: "1:30" → 90s, "1:30:00" → 5400s
        let colonPattern = #"^(\d+):(\d{2})(?::(\d{2}))?$"#
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let regex = try? NSRegularExpression(pattern: colonPattern),
           let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
            let a = groupDouble(m, 1, in: trimmed) ?? 0
            let b = groupDouble(m, 2, in: trimmed) ?? 0
            let c = groupDouble(m, 3, in: trimmed)
            if c != nil {
                // h:m:s
                return a * 3600 + b * 60 + (c ?? 0)
            } else {
                // m:s
                return a * 60 + b
            }
        }

        return nil
    }

    private static func groupDouble(_ match: NSTextCheckingResult, _ idx: Int, in s: String) -> Double? {
        guard let r = Range(match.range(at: idx), in: s) else { return nil }
        return Double(s[r])
    }

    // MARK: - Prefix Trim

    /// Strips a recognized prefix from input, returning the remainder (trimmed).
    /// Returns nil if none of the prefixes match.
    static func stripPrefix(_ input: String, prefixes: [String]) -> String? {
        for prefix in prefixes {
            if input.hasPrefix(prefix) {
                return String(input.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    // MARK: - AppleScript

    /// Run an AppleScript string synchronously on a background thread.
    /// Never call from MainActor — uses NSAppleScript which can block.
    /// Returns the result string, or nil on error.
    @discardableResult
    static func runAppleScript(_ source: String) -> String? {
        runAppleScriptDetailed(source).output
    }

    /// Dedicated serial queue for NSAppleScript. Apple Events block the calling
    /// thread until the target app replies (up to the Apple Event timeout), so
    /// they must never run on the main thread (UI hang); the single serial queue
    /// also keeps NSAppleScript work off arbitrary concurrent pool threads.
    private static let appleScriptQueue = DispatchQueue(label: "com.metamorphia.applescript")

    /// Async wrapper that runs `runAppleScript` on the dedicated background queue,
    /// safe to `await` from the main actor without blocking it.
    static func runAppleScriptOffMain(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            appleScriptQueue.async {
                continuation.resume(returning: runAppleScript(source))
            }
        }
    }

    /// Same as `runAppleScript`, but preserves the AppleScript error text for UI diagnostics.
    static func runAppleScriptDetailed(_ source: String) -> AppleScriptRunResult {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        if let err = error {
            let message = appleScriptErrorMessage(err)
            print("[LocalCmd] AppleScript error: \(message)")
            return AppleScriptRunResult(output: nil, errorMessage: message)
        }
        return AppleScriptRunResult(output: result?.stringValue, errorMessage: nil)
    }

    private static func appleScriptErrorMessage(_ error: NSDictionary) -> String {
        let message = error[NSAppleScript.errorMessage] as? String
        let brief = error[NSAppleScript.errorBriefMessage] as? String
        let number = error[NSAppleScript.errorNumber] as? NSNumber

        var parts: [String] = []
        if let message, !message.isEmpty {
            parts.append(message)
        } else if let brief, !brief.isEmpty {
            parts.append(brief)
        }
        if let number {
            parts.append("code \(number.intValue)")
        }
        return parts.isEmpty ? "\(error)" : parts.joined(separator: " ")
    }

    /// Escapes a Swift string for safe insertion inside a double-quoted AppleScript string.
    static func escapeAppleScript(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
