/*
 * Metamorphia
 * Native LaTeX math rendering — atom tree.
 *
 * The parser produces a tree of `MathAtom` nodes; the layout walks the tree to
 * draw with SwiftUI. Atoms carry no SwiftUI/AppKit types so the parser stays
 * pure and nonisolated (unit-testable). Symbol lookup tables live here too.
 */

import Foundation

/// A styling face applied to a run of characters (\mathbb, \mathbf, \mathrm, \text).
enum MathFontStyle: Equatable {
    case normal      // default math italic-ish (we render upright for robustness)
    case roman       // \mathrm, \text — upright
    case bold        // \mathbf
    case blackboard  // \mathbb (use Unicode double-struck where available)
    case text        // \text — upright, spaces preserved
}

/// Bracket kinds for \left … \right and explicit delimiters.
enum MathDelimiter: Equatable {
    case paren, bracket, brace, angle, vert, doubleVert, none

    /// The left/right glyphs for a non-stretchy fallback.
    var glyphs: (left: String, right: String) {
        switch self {
        case .paren:      return ("(", ")")
        case .bracket:    return ("[", "]")
        case .brace:      return ("{", "}")
        case .angle:      return ("\u{27E8}", "\u{27E9}") // ⟨ ⟩
        case .vert:       return ("|", "|")
        case .doubleVert: return ("\u{2016}", "\u{2016}") // ‖ ‖
        case .none:       return ("", "")
        }
    }
}

/// A node in the math tree.
indirect enum MathAtom: Equatable {
    /// A run of glyphs sharing one font style (the common case: letters, digits, operators).
    case run(String, MathFontStyle)
    /// An ordered sequence of atoms laid out left to right on one baseline.
    case list([MathAtom])
    /// base with optional superscript and/or subscript.
    case scripted(base: MathAtom, sup: MathAtom?, sub: MathAtom?)
    /// \frac{num}{den}.
    case fraction(numerator: MathAtom, denominator: MathAtom)
    /// \sqrt{radicand} or \sqrt[index]{radicand}.
    case radical(index: MathAtom?, radicand: MathAtom)
    /// A large operator (\sum, \prod, \int) that hosts limits via `scripted`.
    case bigOperator(symbol: String, displayLimits: Bool)
    /// \left( … \right) auto-sizing fence.
    case delimited(left: MathDelimiter, body: MathAtom, right: MathDelimiter)
    /// matrix / pmatrix / bmatrix: rows of cells.
    case matrix(rows: [[MathAtom]], delimiter: MathDelimiter)
    /// Horizontal space (thin/med/thick/quad).
    case space(CGFloat)
    /// Unsupported / unparsable LaTeX, surfaced verbatim as a styled fallback.
    case fallback(String)
}

/// Static lookup tables mapping LaTeX command names to Unicode glyphs and roles.
enum MathSymbols {

    /// Greek letters and a few variants. Lowercase and uppercase.
    static let greek: [String: String] = [
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}",
        "epsilon": "\u{03B5}", "varepsilon": "\u{03B5}", "zeta": "\u{03B6}", "eta": "\u{03B7}",
        "theta": "\u{03B8}", "vartheta": "\u{03D1}", "iota": "\u{03B9}", "kappa": "\u{03BA}",
        "lambda": "\u{03BB}", "mu": "\u{03BC}", "nu": "\u{03BD}", "xi": "\u{03BE}",
        "omicron": "\u{03BF}", "pi": "\u{03C0}", "varpi": "\u{03D6}", "rho": "\u{03C1}",
        "varrho": "\u{03F1}", "sigma": "\u{03C3}", "varsigma": "\u{03C2}", "tau": "\u{03C4}",
        "upsilon": "\u{03C5}", "phi": "\u{03C6}", "varphi": "\u{03D5}", "chi": "\u{03C7}",
        "psi": "\u{03C8}", "omega": "\u{03C9}",
        "Gamma": "\u{0393}", "Delta": "\u{0394}", "Theta": "\u{0398}", "Lambda": "\u{039B}",
        "Xi": "\u{039E}", "Pi": "\u{03A0}", "Sigma": "\u{03A3}", "Upsilon": "\u{03A5}",
        "Phi": "\u{03A6}", "Psi": "\u{03A8}", "Omega": "\u{03A9}",
    ]

    /// Binary operators, relations, arrows, set/logic symbols, misc.
    static let operators: [String: String] = [
        "cdot": "\u{22C5}", "times": "\u{00D7}", "div": "\u{00F7}", "ast": "\u{2217}",
        "star": "\u{22C6}", "circ": "\u{2218}", "bullet": "\u{2219}", "oplus": "\u{2295}",
        "otimes": "\u{2297}", "pm": "\u{00B1}", "mp": "\u{2213}",
        "leq": "\u{2264}", "le": "\u{2264}", "geq": "\u{2265}", "ge": "\u{2265}",
        "neq": "\u{2260}", "ne": "\u{2260}", "approx": "\u{2248}", "equiv": "\u{2261}",
        "sim": "\u{223C}", "simeq": "\u{2243}", "cong": "\u{2245}", "propto": "\u{221D}",
        "ll": "\u{226A}", "gg": "\u{226B}",
        "infty": "\u{221E}", "partial": "\u{2202}", "nabla": "\u{2207}",
        "rightarrow": "\u{2192}", "to": "\u{2192}", "leftarrow": "\u{2190}",
        "gets": "\u{2190}", "leftrightarrow": "\u{2194}", "Rightarrow": "\u{21D2}",
        "Leftarrow": "\u{21D0}", "Leftrightarrow": "\u{21D4}", "implies": "\u{27F9}",
        "mapsto": "\u{21A6}", "longrightarrow": "\u{27F6}", "longleftarrow": "\u{27F5}",
        "in": "\u{2208}", "notin": "\u{2209}", "ni": "\u{220B}",
        "subset": "\u{2282}", "supset": "\u{2283}", "subseteq": "\u{2286}",
        "supseteq": "\u{2287}", "cup": "\u{222A}", "cap": "\u{2229}",
        "emptyset": "\u{2205}", "varnothing": "\u{2205}", "setminus": "\u{2216}",
        "forall": "\u{2200}", "exists": "\u{2203}", "nexists": "\u{2204}",
        "neg": "\u{00AC}", "lnot": "\u{00AC}", "land": "\u{2227}", "wedge": "\u{2227}",
        "lor": "\u{2228}", "vee": "\u{2228}", "top": "\u{22A4}", "bot": "\u{22A5}",
        "angle": "\u{2220}", "perp": "\u{22A5}", "parallel": "\u{2225}",
        "cdots": "\u{22EF}", "ldots": "\u{2026}", "dots": "\u{2026}", "vdots": "\u{22EE}",
        "ddots": "\u{22F1}", "prime": "\u{2032}", "degree": "\u{00B0}",
        "aleph": "\u{2135}", "hbar": "\u{210F}", "ell": "\u{2113}", "Re": "\u{211C}",
        "Im": "\u{2111}", "wp": "\u{2118}", "mid": "\u{2223}", "vdash": "\u{22A2}",
        "models": "\u{22A8}", "leftrightarrows": "\u{21C4}",
        "langle": "\u{27E8}", "rangle": "\u{27E9}",
    ]

    /// Named function operators rendered upright (\sin, \log, …).
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc",
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "log", "ln", "lg", "exp", "lim", "limsup", "liminf",
        "max", "min", "sup", "inf", "det", "deg", "dim", "ker",
        "gcd", "hom", "arg", "Pr", "mod",
    ]

    /// Big operators with their glyph and whether they take limits above/below in display.
    static let bigOperators: [String: (glyph: String, displayLimits: Bool)] = [
        "sum": ("\u{2211}", true),
        "prod": ("\u{220F}", true),
        "coprod": ("\u{2210}", true),
        "int": ("\u{222B}", false),
        "iint": ("\u{222C}", false),
        "iiint": ("\u{222D}", false),
        "oint": ("\u{222E}", false),
        "bigcup": ("\u{22C3}", true),
        "bigcap": ("\u{22C2}", true),
        "bigoplus": ("\u{2A01}", true),
        "bigotimes": ("\u{2A02}", true),
        "bigwedge": ("\u{22C0}", true),
        "bigvee": ("\u{22C1}", true),
    ]

    /// Horizontal spacing commands → multiplier of the current font size.
    static let spacing: [String: CGFloat] = [
        ",": 0.16, ":": 0.22, ";": 0.28, " ": 0.25, "quad": 1.0, "qquad": 2.0,
        "!": -0.16, "thinspace": 0.16, "enspace": 0.5,
    ]

    /// Map a delimiter glyph string (as seen after \left/\right) to a kind.
    static func delimiter(for token: String) -> MathDelimiter {
        switch token {
        case "(", ")": return .paren
        case "[", "]", "lbrack", "rbrack": return .bracket
        case "{", "}", "lbrace", "rbrace", "langle": return token == "langle" ? .angle : .brace
        case "rangle": return .angle
        case "|", "vert", "lvert", "rvert": return .vert
        case "Vert", "lVert", "rVert", "\u{2016}": return .doubleVert
        case ".": return .none
        default: return .none
        }
    }
}

/// Blackboard (double-struck) Unicode mapping for \mathbb. Falls back to the
/// raw character when no double-struck form exists.
enum MathBlackboard {
    static func map(_ c: Character) -> String {
        // Letters with dedicated double-struck codepoints (ℂ ℍ ℕ ℙ ℚ ℝ ℤ) plus the
        // contiguous Mathematical Double-Struck block for the rest.
        switch c {
        case "C": return "\u{2102}"
        case "H": return "\u{210D}"
        case "N": return "\u{2115}"
        case "P": return "\u{2119}"
        case "Q": return "\u{211A}"
        case "R": return "\u{211D}"
        case "Z": return "\u{2124}"
        default: break
        }
        if let s = c.unicodeScalars.first {
            if c.isUppercase, c.isLetter {
                // A–Z → U+1D538 …
                return scalarString(base: 0x1D538, offset: s.value - 0x41)
            }
            if c.isLowercase, c.isLetter {
                // a–z → U+1D552 …
                return scalarString(base: 0x1D552, offset: s.value - 0x61)
            }
            if c.isNumber {
                // 0–9 → U+1D7D8 …
                return scalarString(base: 0x1D7D8, offset: s.value - 0x30)
            }
        }
        return String(c)
    }

    private static func scalarString(base: UInt32, offset: UInt32) -> String {
        if let scalar = Unicode.Scalar(base + offset) {
            return String(scalar)
        }
        return ""
    }
}
