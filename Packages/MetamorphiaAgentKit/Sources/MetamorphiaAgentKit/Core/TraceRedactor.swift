import Foundation

/// Redacts sensitive patterns from trace display strings.
/// Applied at display time only — full data preserved in memory.
public enum TraceRedactor {

    private static let patterns: [(NSRegularExpression, String)] = {
        var list: [(NSRegularExpression, String)] = []
        // API keys: sk-..., key-..., Bearer tokens
        if let re = try? NSRegularExpression(pattern: #"(sk-|key-|Bearer\s+)[A-Za-z0-9_\-]{20,}"#) {
            list.append((re, "$1[REDACTED]"))
        }
        // Passwords / secrets / tokens / api_keys in JSON strings
        if let re = try? NSRegularExpression(pattern: #""(password|secret|token|api_key)"\s*:\s*"[^"]+""#, options: .caseInsensitive) {
            list.append((re, "\"$1\": \"[REDACTED]\""))
        }
        // Credit card patterns (4 groups of 4 digits)
        if let re = try? NSRegularExpression(pattern: #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#) {
            list.append((re, "[card-number]"))
        }
        return list
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in patterns {
            // Recompute range each iteration: earlier substitutions change the string length,
            // and a stale range triggers NSRangeException. The original Executer implementation
            // computed this once outside the loop — that bug is fixed here.
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
