/*
 * Metamorphia
 * Native LaTeX math rendering — message span scanner.
 *
 * Splits an assistant message into text vs. math spans so chat can render math
 * inline. Recognizes $…$, $$…$$, \( … \), \[ … \]. An escaped \$ is treated as
 * a literal dollar sign, never a delimiter. Pure and nonisolated; never crashes.
 */

import Foundation

/// One piece of a scanned message: literal text, inline math, or display math.
public enum MathSpan: Equatable {
    case text(String)
    case inline(String)
    case display(String)
}

/// Splits messages into `MathSpan`s. Stateless entry point.
public enum MathSpanScanner {

    /// Bounded in-memory memo for `split`. Repeated renders of the same message
    /// (SwiftUI re-evaluates `body` often) become cache hits. Oldest entry is
    /// evicted once the cap is reached. NSLock-guarded so it stays thread-safe
    /// while the API remains pure/nonisolated.
    private static let splitCacheLock = NSLock()
    private static var splitCache: [String: [MathSpan]] = [:]
    private static var splitCacheOrder: [String] = []
    private static let splitCacheCap = 128

    /// Scan a string into ordered text/math spans. Unterminated delimiters are
    /// emitted as plain text so nothing is ever lost.
    public static func split(_ s: String) -> [MathSpan] {
        splitCacheLock.lock()
        if let cached = splitCache[s] {
            splitCacheLock.unlock()
            return cached
        }
        splitCacheLock.unlock()

        let result = scan(s)

        splitCacheLock.lock()
        if splitCache[s] == nil {
            splitCache[s] = result
            splitCacheOrder.append(s)
            if splitCacheOrder.count > splitCacheCap {
                let oldest = splitCacheOrder.removeFirst()
                splitCache.removeValue(forKey: oldest)
            }
        }
        splitCacheLock.unlock()

        return result
    }

    /// The actual scan, uncached.
    private static func scan(_ s: String) -> [MathSpan] {
        let chars = Array(s)
        let n = chars.count
        var spans: [MathSpan] = []
        var text = ""           // accumulating literal text
        var i = 0

        func flushText() {
            if !text.isEmpty {
                spans.append(.text(text))
                text = ""
            }
        }

        while i < n {
            let c = chars[i]

            // Escaped dollar: \$ → literal '$'.
            if c == "\\", i + 1 < n, chars[i + 1] == "$" {
                text.append("$")
                i += 2
                continue
            }

            // \[ … \]  — display math.
            if c == "\\", i + 1 < n, chars[i + 1] == "[" {
                if let (body, next) = scanUntil(close: ["\\", "]"], chars: chars, start: i + 2) {
                    flushText()
                    spans.append(.display(body))
                    i = next
                    continue
                }
                // No closing \]; fall through, emit the backslash literally.
                text.append(c); i += 1; continue
            }

            // \( … \)  — inline math.
            if c == "\\", i + 1 < n, chars[i + 1] == "(" {
                if let (body, next) = scanUntil(close: ["\\", ")"], chars: chars, start: i + 2) {
                    flushText()
                    spans.append(.inline(body))
                    i = next
                    continue
                }
                text.append(c); i += 1; continue
            }

            // $$ … $$  — display math (check before single $).
            if c == "$", i + 1 < n, chars[i + 1] == "$" {
                if let (body, next) = scanDollar(chars: chars, start: i + 2, isDouble: true) {
                    flushText()
                    spans.append(.display(body))
                    i = next
                    continue
                }
                text.append(c); i += 1; continue
            }

            // $ … $  — inline math.
            if c == "$" {
                if let (body, next) = scanDollar(chars: chars, start: i + 1, isDouble: false) {
                    flushText()
                    spans.append(.inline(body))
                    i = next
                    continue
                }
                text.append(c); i += 1; continue
            }

            text.append(c)
            i += 1
        }

        flushText()
        return spans
    }

    // MARK: - Helpers

    /// Scan from `start` until the multi-character `close` marker is found.
    /// Returns the body (exclusive of the close) and the index just past it.
    private static func scanUntil(close: [Character], chars: [Character], start: Int) -> (String, Int)? {
        var i = start
        let n = chars.count
        var body = ""
        while i < n {
            // Match the close sequence.
            if matches(close, in: chars, at: i) {
                return (body, i + close.count)
            }
            body.append(chars[i])
            i += 1
        }
        return nil
    }

    /// Scan a `$`-delimited region. For `$$` the close is `$$`; for `$` it is a
    /// single `$`, with `\$` inside treated as a literal dollar. A `$` region may
    /// not be empty or contain a stray unescaped delimiter run that never closes.
    private static func scanDollar(chars: [Character], start: Int, isDouble: Bool) -> (String, Int)? {
        var i = start
        let n = chars.count
        var body = ""
        while i < n {
            let c = chars[i]
            // Honor escaped dollars inside the math body.
            if c == "\\", i + 1 < n, chars[i + 1] == "$" {
                body.append("$")
                i += 2
                continue
            }
            if c == "$" {
                if isDouble {
                    if i + 1 < n, chars[i + 1] == "$" {
                        return body.isEmpty ? nil : (body, i + 2)
                    }
                    // A single $ inside a $$ block — keep scanning.
                    body.append(c); i += 1; continue
                } else {
                    return body.isEmpty ? nil : (body, i + 1)
                }
            }
            body.append(c)
            i += 1
        }
        return nil
    }

    /// True if `seq` appears in `chars` starting at `at`.
    private static func matches(_ seq: [Character], in chars: [Character], at: Int) -> Bool {
        guard at + seq.count <= chars.count else { return false }
        for k in 0..<seq.count where chars[at + k] != seq[k] {
            return false
        }
        return true
    }

    // MARK: - Math-likeness

    /// Math-relevant operators, relations, and symbols that, when present in an
    /// inline `$…$` body, mark it as real math rather than prose or currency.
    private static let mathSignals: Set<Character> = [
        "=", "+", "*", "/", "×", "·", "÷", "±", "∓", "<", ">", "≤", "≥",
        "≠", "≈", "≡", "√", "^", "_", "{", "}", "∑", "∏", "∫", "∞", "∂",
        "∇", "∈", "∉", "⊂", "⊃", "∪", "∩", "→", "←", "↔", "⇒", "⇐", "⇔",
    ]

    /// Heuristic: does an inline-span body actually look like math, as opposed
    /// to currency (`$5`, `$10.50`), a bare number, or a few plain words?
    ///
    /// Returns true when the body contains a backslash command, a caret `^` or
    /// underscore `_`, braces, a fraction/root, or a math operator/relation —
    /// AND is not merely digits, currency, or words. A lone `$5` or `5 to $10`
    /// (where each span body is just a number) returns false, so prose keeps the
    /// plain markdown path.
    public static func looksLikeMath(_ body: String) -> Bool {
        // A backslash command (\frac, \alpha, \sqrt, …) is an unambiguous tell.
        if body.contains("\\") { return true }

        for ch in body {
            // Operators, relations, structure, and roots.
            if mathSignals.contains(ch) { return true }
            // Literal Greek letters (π, θ, λ, …) written as Unicode rather than
            // a \-command are a math signal too. Greek block is U+0370…U+03FF.
            if let scalar = ch.unicodeScalars.first,
               (0x0370...0x03FF).contains(scalar.value) {
                return true
            }
        }

        // No structural or operator signal: it's a number, currency, or words.
        return false
    }
}
