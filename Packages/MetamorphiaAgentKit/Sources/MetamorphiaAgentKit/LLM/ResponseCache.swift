import Foundation

/// TTL-based response cache for repeated informational queries.
/// Skips caching for action commands (open, play, move, etc.) via `isCacheable(_:)`.
public actor ResponseCache {
    public static let shared = ResponseCache()

    private struct CacheEntry {
        let response: String
        let timestamp: Date
        let ttl: TimeInterval
    }

    private var cache: [String: CacheEntry] = [:]
    private let maxEntries = 50

    public init() {}

    // MARK: - TTL Policy

    private func ttl(for command: String) -> TimeInterval {
        let lower = command.lowercased()
        if lower.contains("weather") || lower.contains("temperature") { return 300 }
        if lower.contains("system info") || lower.contains("battery") { return 60 }
        if lower.contains("calendar") || lower.contains("reminder") { return 120 }
        if lower.contains("clipboard") { return 30 }
        return 600
    }

    // MARK: - Cache Operations

    public func get(_ command: String) -> String? {
        let key = normalizeKey(command)
        guard let entry = cache[key] else { return nil }
        guard Date().timeIntervalSince(entry.timestamp) < entry.ttl else {
            cache.removeValue(forKey: key)
            return nil
        }
        print("[Cache] Hit for: \(key.prefix(50))")
        return entry.response
    }

    public func set(_ command: String, response: String) {
        let key = normalizeKey(command)
        guard response.count > 20 else { return }

        cache[key] = CacheEntry(response: response, timestamp: Date(), ttl: ttl(for: command))

        if cache.count > maxEntries {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
            if let oldestKey = oldest?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
    }

    public func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Cacheability Check

    public func isCacheable(_ command: String) -> Bool {
        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let actionPrefixes = [
            "open ", "play ", "set ", "toggle ", "launch ", "quit ", "force quit ",
            "move ", "copy ", "create ", "delete ", "trash ", "rename ",
            "lock", "sleep", "shutdown", "restart", "mute", "unmute",
            "close ", "hide ", "switch to ", "tile ", "click", "type ",
            "press ", "hotkey", "scroll", "drag",
            "save ", "write ", "edit ", "append ",
            "schedule ", "remind me", "send ",
        ]

        if actionPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return false
        }

        return true
    }

    // MARK: - Helpers

    private static let stopWords: Set<String> = [
        "what", "whats", "what's", "how", "hows", "how's", "is", "the", "my",
        "can", "you", "tell", "me", "about", "get", "show", "a", "an", "please",
        "current", "right", "now", "do", "does", "did", "will", "would", "could",
        "i", "have", "has", "are", "was", "were", "been", "be", "to", "of", "for",
        "on", "in", "at", "this", "that", "it", "its", "it's", "?", "whats"
    ]

    private func normalizeKey(_ command: String) -> String {
        let lower = command.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = lower.filter { $0.isLetter || $0.isNumber || $0 == " " }
        let keywords = cleaned.split(separator: " ")
            .map { String($0) }
            .filter { !Self.stopWords.contains($0) && $0.count > 1 }
            .sorted()
        return keywords.isEmpty ? cleaned : keywords.joined(separator: " ")
    }
}
