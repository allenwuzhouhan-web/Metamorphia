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
import AppKit

/// Local matcher for direct web navigation commands.
///
/// Triggers: "go to github.com", "navigate to reddit.com", "open twitter"
///
/// Rejects:
///   - Multi-word targets (avoids "open a new document" → browser)
///   - App-like single tokens (chrome, vscode, etc.) → fall through to agent
///   - Compound workflow phrases ("open X and then Y")
///
/// Uses a curated shortcut dictionary for common shortcuts (twitter → x.com, etc.).
/// Calls `NSWorkspace.shared.open(URL)`.
enum WebNavigationLocalMatcher {

    // MARK: - Curated shortcuts

    private static let shortcuts: [String: String] = [
        "twitter": "https://x.com",
        "x": "https://x.com",
        "gmail": "https://mail.google.com",
        "google": "https://www.google.com",
        "youtube": "https://www.youtube.com",
        "yt": "https://www.youtube.com",
        "reddit": "https://www.reddit.com",
        "github": "https://github.com",
        "gh": "https://github.com",
        "notion": "https://www.notion.so",
        "slack": "https://app.slack.com",
        "linear": "https://linear.app",
        "figma": "https://www.figma.com",
        "hn": "https://news.ycombinator.com",
        "hackernews": "https://news.ycombinator.com",
        "producthunt": "https://www.producthunt.com",
        "claude": "https://claude.ai",
        "chatgpt": "https://chatgpt.com",
        "openai": "https://openai.com",
        "anthropic": "https://www.anthropic.com",
        "vercel": "https://vercel.com",
        "netlify": "https://www.netlify.com",
        "aws": "https://console.aws.amazon.com",
        "azure": "https://portal.azure.com",
        "gcp": "https://console.cloud.google.com",
        "npm": "https://www.npmjs.com",
        "pypi": "https://pypi.org",
        "stackoverflow": "https://stackoverflow.com",
        "so": "https://stackoverflow.com",
        "mdn": "https://developer.mozilla.org",
        "wikipedia": "https://en.wikipedia.org",
        "wiki": "https://en.wikipedia.org",
        "linkedin": "https://www.linkedin.com",
        "instagram": "https://www.instagram.com",
        "facebook": "https://www.facebook.com",
        "fb": "https://www.facebook.com",
        "amazon": "https://www.amazon.com",
        "amzn": "https://www.amazon.com",
        "stripe": "https://dashboard.stripe.com",
        "digitalocean": "https://cloud.digitalocean.com",
        "heroku": "https://dashboard.heroku.com",
        "supabase": "https://app.supabase.com",
        "fly": "https://fly.io",
        "railway": "https://railway.app",
        "airtable": "https://airtable.com",
        "trello": "https://trello.com",
        "asana": "https://app.asana.com",
        "jira": "https://jira.atlassian.com",
        "confluence": "https://confluence.atlassian.com",
        "discord": "https://discord.com",
        "twitch": "https://www.twitch.tv",
        "spotify": "https://open.spotify.com",
        "netflix": "https://www.netflix.com",
        "disneyplus": "https://www.disneyplus.com",
        "hulu": "https://www.hulu.com",
        "medium": "https://medium.com",
        "substack": "https://substack.com",
        "ghost": "https://ghost.org",
        "wordpress": "https://wordpress.com",
        "shopify": "https://www.shopify.com",
    ]

    // Single-token strings that look like app names, NOT websites.
    // If the user says "open vscode" we should NOT open a URL.
    private static let appDenylist: Set<String> = [
        "chrome", "safari", "firefox", "arc", "brave", "opera", "edge",
        "vscode", "xcode", "cursor", "vim", "emacs", "nvim", "nano",
        "terminal", "iterm", "kitty", "warp", "alacritty",
        "finder", "mail", "calendar", "notes", "reminders", "messages",
        "facetime", "maps", "photos", "music", "podcasts", "tv",
        "preview", "quicklook", "automator", "scripteditor",
        "activity", "monitor", "console", "instruments",
        "slack", "teams", "zoom", "meet", "webex",
        "figma", "sketch", "affinity", "photoshop", "illustrator",
        "word", "excel", "powerpoint", "keynote", "pages", "numbers",
        "docker", "homebrew",
        "folder", "file", "document", "directory", "settings", "preferences",
        "window", "app", "application",
    ]

    // Reject if target contains any of these (indicates a multi-step workflow).
    private static let workflowDenylist: [String] = ["and then", " and ", " then "]

    // MARK: - Prefixes

    private static let triggerPrefixes: [String] = [
        "go to ",
        "navigate to ",
        "open ",
        "visit ",
        "take me to ",
    ]

    // MARK: - Handle

    static func handle(_ normalized: String) async -> LocalCommandHit? {
        guard let rawTarget = LocalCommandHelpers.stripPrefix(normalized, prefixes: triggerPrefixes),
              !rawTarget.isEmpty else { return nil }

        // Reject compound workflows.
        for deny in workflowDenylist {
            if rawTarget.contains(deny) { return nil }
        }

        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reject multi-word targets that aren't URLs (they're prose, not sites).
        let words = target.split(separator: " ")
        if words.count > 1 {
            // Allow only if it looks like a URL (contains a dot).
            guard target.contains(".") else { return nil }
        }

        // Reject app-like single tokens.
        if appDenylist.contains(target) { return nil }

        // Curated shortcut lookup.
        if let urlString = shortcuts[target], let url = URL(string: urlString) {
            return openURL(url, displayTarget: target)
        }

        // Single-word domain with dot → prefix https://
        if target.contains(".") && !target.hasPrefix("http") {
            let urlString = "https://\(target)"
            guard let url = URL(string: urlString),
                  url.host != nil else { return nil }
            return openURL(url, displayTarget: target)
        }

        // Full URL already provided.
        if (target.hasPrefix("https://") || target.hasPrefix("http://")),
           let url = URL(string: target) {
            return openURL(url, displayTarget: target)
        }

        return nil
    }

    // MARK: - Side-effect

    private static func openURL(_ url: URL, displayTarget: String) -> LocalCommandHit {
        NSWorkspace.shared.open(url)
        return LocalCommandHit(
            matcherName: "web_navigation",
            message: "Opening \(displayTarget) in your browser.",
            arguments: "url=\"\(url.absoluteString)\"",
            elapsed: 0
        )
    }
}
