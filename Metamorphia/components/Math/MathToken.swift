/*
 * Metamorphia
 * Native LaTeX math rendering — tokenizer.
 *
 * Splits a LaTeX math string into a flat token stream. Pure and nonisolated
 * so it can be unit-tested off the main actor. Never throws: malformed input
 * yields whatever tokens it can, and the parser/layout degrade gracefully.
 */

import Foundation

/// A single lexical unit of LaTeX math.
enum LatexToken: Equatable {
    /// A control sequence like `\frac`, `\alpha`, `\left`. Stored without the backslash.
    case command(String)
    /// A single printable character (letter, digit, operator glyph, …).
    case symbol(Character)
    /// `{` — begins a group.
    case openBrace
    /// `}` — ends a group.
    case closeBrace
    /// `^` — superscript marker.
    case caret
    /// `_` — subscript marker.
    case underscore
    /// `&` — matrix/alignment column separator.
    case ampersand
    /// `\\` — matrix/alignment row break.
    case rowBreak
    /// Literal whitespace. Insignificant in math mode, but preserved so that
    /// \text{…} can reconstruct spaces between words.
    case whitespace
}

/// Pure tokenizer for LaTeX math. Stateless entry point.
enum LatexTokenizer {
    /// Convert a LaTeX math fragment into tokens. Always succeeds.
    nonisolated static func tokenize(_ source: String) -> [LatexToken] {
        var tokens: [LatexToken] = []
        let chars = Array(source)
        var i = 0
        let n = chars.count

        while i < n {
            let c = chars[i]
            switch c {
            case "\\":
                // Control sequence or escaped symbol.
                let next = i + 1 < n ? chars[i + 1] : nil
                if let next {
                    if next == "\\" {
                        tokens.append(.rowBreak)
                        i += 2
                        continue
                    }
                    if next.isLetter {
                        // Read the full command name (letters only).
                        var j = i + 1
                        var name = ""
                        while j < n, chars[j].isLetter {
                            name.append(chars[j])
                            j += 1
                        }
                        tokens.append(.command(name))
                        i = j
                        continue
                    }
                    // Escaped single non-letter: \{ \} \$ \% \& \_ \# \, \; \  etc.
                    // Spacing commands keep their backslash so the parser can map them.
                    if next == " " || next == "," || next == ";" || next == ":" || next == "!" {
                        tokens.append(.command(String(next)))
                        i += 2
                        continue
                    }
                    tokens.append(.symbol(next))
                    i += 2
                    continue
                }
                // Trailing lone backslash: treat as a literal.
                tokens.append(.symbol("\\"))
                i += 1

            case "{":
                tokens.append(.openBrace); i += 1
            case "}":
                tokens.append(.closeBrace); i += 1
            case "^":
                tokens.append(.caret); i += 1
            case "_":
                tokens.append(.underscore); i += 1
            case "&":
                tokens.append(.ampersand); i += 1
            case " ", "\t", "\n", "\r":
                // Whitespace is insignificant in math mode, but emit a marker so
                // \text{…} can reconstruct word spacing. Collapse runs into one.
                if tokens.last != .whitespace {
                    tokens.append(.whitespace)
                }
                i += 1
            default:
                tokens.append(.symbol(c)); i += 1
            }
        }
        return tokens
    }
}
