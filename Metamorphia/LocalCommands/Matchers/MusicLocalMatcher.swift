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

/// Local matcher for Music.app transport controls.
///
/// Handles exact transport keywords only:
///   pause / play / resume / next / previous / prev / skip
///   shuffle / "what's playing" / "what is playing"
///   "music volume X%"
///
/// Returns nil on AppleScript failure (Music.app not running, permission denied),
/// allowing the prompt to fall through to the LLM.
///
/// Does NOT handle "play Shape of You by Taylor Swift" — song-library matching
/// is out of scope for T13.
enum MusicLocalMatcher {

    static func handle(_ normalized: String) async -> LocalCommandHit? {
        guard let (script, reply) = command(for: normalized) else { return nil }

        let start = Date()
        // AppleScript is synchronous and can block; run off MainActor.
        let result = await Task.detached(priority: .userInitiated) {
            LocalCommandHelpers.runAppleScript(script)
        }.value

        // nil result means script failed (app not running, permission denied, etc.)
        guard result != nil else { return nil }

        let elapsed = Date().timeIntervalSince(start)
        return LocalCommandHit(
            matcherName: "music",
            message: reply,
            arguments: "command=\"\(normalized)\"",
            elapsed: elapsed
        )
    }

    // MARK: - Command resolution

    /// Returns (appleScriptSource, userFacingReply) or nil if not a music command.
    private static func command(for s: String) -> (String, String)? {
        switch s {
        case "pause", "pause music", "pause the music":
            return (musicScript("pause"), "Music paused.")
        case "play", "resume", "play music", "resume music", "continue music":
            return (musicScript("play"), "Music playing.")
        case "next", "next song", "next track", "skip", "skip song":
            return (musicScript("next track"), "Skipped to next track.")
        case "previous", "previous song", "previous track", "prev", "prev song", "back":
            return (musicScript("previous track"), "Went to previous track.")
        case "shuffle", "shuffle music", "toggle shuffle":
            return (toggleShuffleScript(), "Shuffle toggled.")
        case "what's playing", "whats playing", "what is playing",
             "what song is playing", "what's the song", "whats the song":
            return (nowPlayingScript(), "")  // reply filled in from script result
        default:
            break
        }

        // "music volume 50%", "music volume 80"
        if s.hasPrefix("music volume ") || s.hasPrefix("set music volume ") {
            let tail = s.hasPrefix("music volume ") ?
                String(s.dropFirst("music volume ".count)) :
                String(s.dropFirst("set music volume ".count))
            let digits = tail.filter { $0.isNumber }
            if let vol = Int(digits), vol >= 0, vol <= 100 {
                return (setVolumeScript(vol), "Music volume set to \(vol)%.")
            }
        }

        return nil
    }

    // MARK: - AppleScript builders

    private static func musicScript(_ cmd: String) -> String {
        """
        tell application "Music"
            \(cmd)
        end tell
        """
    }

    private static func toggleShuffleScript() -> String {
        """
        tell application "Music"
            set shuffle enabled to not shuffle enabled
        end tell
        """
    }

    private static func nowPlayingScript() -> String {
        """
        tell application "Music"
            if player state is playing then
                set t to name of current track
                set a to artist of current track
                return a & " — " & t
            else
                return "Nothing is playing."
            end if
        end tell
        """
    }

    private static func setVolumeScript(_ volume: Int) -> String {
        """
        tell application "Music"
            set sound volume to \(volume)
        end tell
        """
    }
}
