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

/// Local matcher for timer commands.
///
/// Triggers:
///   - "set a timer for 5 minutes"
///   - "timer 10 minutes"
///   - "timer pasta for 12 minutes"   → label = "pasta"
///   - "remind me to stretch in 30 minutes"
///
/// Calls `TimerManager.shared.startTimer(duration:name:preset:)` on MainActor.
enum TimerLocalMatcher {

    // Prefixes that strongly indicate a timer intent.
    private static let triggerPrefixes = [
        "set a timer for ",
        "set timer for ",
        "start a timer for ",
        "start timer for ",
        "timer for ",
        "timer ",
        "set a timer ",
        "set timer ",
        "remind me in ",
        "remind me to ",
    ]

    static func handle(_ normalized: String) async -> LocalCommandHit? {
        guard containsTimerHint(normalized) else { return nil }

        let start = Date()

        // "remind me to X in Y" — extract label and duration separately.
        if normalized.hasPrefix("remind me to ") {
            return await handleRemindMe(normalized, start: start)
        }

        // Standard timer prefix strip.
        guard let body = LocalCommandHelpers.stripPrefix(normalized, prefixes: triggerPrefixes) else {
            return nil
        }

        // "timer <label> for <duration>" e.g. "timer pasta for 12 minutes"
        if let forRange = body.range(of: " for ") {
            let label = String(body[body.startIndex..<forRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let durationText = String(body[forRange.upperBound...])
            if let duration = LocalCommandHelpers.parseCompoundDuration(from: durationText), duration > 0 {
                let name = label.isEmpty ? "Timer" : label.prefix(1).uppercased() + label.dropFirst()
                return await startTimer(duration: duration, name: name, start: start)
            }
        }

        // Plain duration: "timer 5 minutes" / "set a timer for 10 min"
        if let duration = LocalCommandHelpers.parseCompoundDuration(from: body), duration > 0 {
            return await startTimer(duration: duration, name: "Timer", start: start)
        }

        return nil
    }

    // MARK: - "Remind me to X in Y"

    private static func handleRemindMe(_ normalized: String, start: Date) async -> LocalCommandHit? {
        // Pattern: "remind me to <label> in <duration>"
        let body = String(normalized.dropFirst("remind me to ".count))

        if let inRange = body.range(of: " in ", options: .backwards) {
            let label = String(body[body.startIndex..<inRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let durationText = String(body[inRange.upperBound...])
            if let duration = LocalCommandHelpers.parseCompoundDuration(from: durationText), duration > 0 {
                let name = label.isEmpty ? "Timer" : label.prefix(1).uppercased() + label.dropFirst()
                return await startTimer(duration: duration, name: name, start: start)
            }
        }

        // "remind me in <duration>" — no label
        if let body2 = LocalCommandHelpers.stripPrefix(normalized, prefixes: ["remind me in "]) {
            if let duration = LocalCommandHelpers.parseCompoundDuration(from: body2), duration > 0 {
                return await startTimer(duration: duration, name: "Timer", start: start)
            }
        }

        return nil
    }

    // MARK: - Side-effect

    private static func startTimer(duration: TimeInterval, name: String, start: Date) async -> LocalCommandHit {
        if let registry = LocalCommandPipeline.registry {
            let argsJSON = """
            {"duration_seconds":\(Int(duration)),"label":"\(name)"}
            """
            _ = try? await registry.executeDirectly(toolName: "start_timer", arguments: argsJSON)
        } else {
            await MainActor.run {
                TimerManager.shared.startTimer(duration: duration, name: name, preset: nil)
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        let friendly: String
        if mins > 0 && secs > 0 {
            friendly = "\(mins)m \(secs)s"
        } else if mins > 0 {
            friendly = "\(mins) minute\(mins == 1 ? "" : "s")"
        } else {
            friendly = "\(secs) second\(secs == 1 ? "" : "s")"
        }
        let label = name == "Timer" ? "" : " (\(name))"
        return LocalCommandHit(
            matcherName: "timer",
            message: "Timer started\(label): \(friendly)",
            arguments: "duration=\(Int(duration)) name=\"\(name)\"",
            elapsed: elapsed
        )
    }

    // MARK: - Guard

    private static func containsTimerHint(_ s: String) -> Bool {
        s.contains("timer") || s.hasPrefix("remind me")
    }
}
