import Foundation

/// Converts a *simple* LaTeX equation into a plottable expression string and the plot
/// kind it implies. This is a best-effort textual rewriter, not a full LaTeX parser:
/// it handles the constructs a graphing calculator actually meets (fractions, powers,
/// roots, Greek letters, the common spacing/grouping macros) and returns nil for
/// anything it can't confidently turn into a `PlotExpression` source.
///
/// Examples:
///   "y = \frac{1}{2}x^2"   -> (.explicit,  "(1/2)*x^2",   "")
///   "r = \sin(3\theta)"    -> (.polar,     "sin(3*theta)", "")
///   "x = \cos t, y = \sin t" is *not* handled here (parametric LHS detection is by
///   the `r =` / `y =` prefix only); callers wanting parametric should build a
///   `PlotCurve` directly.
public enum LatexToPlot {

    /// Returns the inferred kind plus the converted expression strings, or nil if the
    /// input isn't a simple plottable equation.
    public static func expression(fromLatex latex: String) -> (kind: PlotKind, a: String, b: String)? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split off the left-hand side to decide the plot kind. We accept an optional
        // "y =", "r =", or "f(x) =" prefix; a bare expression is treated as explicit y.
        let (kind, rhsRaw) = splitEquation(trimmed)

        // Rewrite LaTeX constructs into plain infix.
        guard let converted = convertBody(rhsRaw) else { return nil }
        let cleaned = converted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // Final gate: it must actually parse as a math expression.
        guard PlotExpression(cleaned) != nil else { return nil }

        return (kind, cleaned, "")
    }

    // MARK: - Equation splitting

    private static func splitEquation(_ source: String) -> (PlotKind, String) {
        // Find the first '=' that is not part of a comparison/escape. Simple '=' only.
        guard let eqIndex = source.firstIndex(of: "=") else {
            return (.explicit, source)   // no '=', assume y = <source>
        }

        let lhs = String(source[source.startIndex..<eqIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rhs = String(source[source.index(after: eqIndex)...])

        // Polar if the dependent variable is r (and the body mentions theta-ish).
        if lhs == "r" || lhs.hasPrefix("r ") || lhs == "\\rho" {
            return (.polar, rhs)
        }
        // Otherwise explicit y = f(x). Accept "y", "f(x)", "g(x)", or anything else.
        return (.explicit, rhs)
    }

    // MARK: - Body conversion

    /// Rewrites a LaTeX RHS into infix. Returns nil if a construct is malformed.
    private static func convertBody(_ raw: String) -> String? {
        var s = raw

        // Strip cosmetic/spacing macros and delimiters first.
        let strip = ["\\left", "\\right", "\\,", "\\;", "\\!", "\\quad", "\\qquad",
                     "\\displaystyle", "\\mathrm", "\\text", "$"]
        for token in strip {
            s = s.replacingOccurrences(of: token, with: "")
        }

        // Expand \frac{a}{b}, \sqrt{...}, \sqrt[n]{...} which use brace groups.
        guard let braced = expandBracedMacros(s) else { return nil }
        s = braced

        // Map Greek letters, named constants, and function macros to engine names.
        s = applySymbolMap(s)

        // Convert remaining LaTeX braces used as grouping into parentheses.
        s = s.replacingOccurrences(of: "{", with: "(")
        s = s.replacingOccurrences(of: "}", with: ")")

        // Remove backslashes left over from any unmapped macro -> that means we don't
        // understand it; fail rather than silently dropping it.
        if s.contains("\\") { return nil }

        // Add explicit function-application parens, brace unbraced superscripts, and
        // make adjacency (e.g. `g x`) an explicit multiply. This runs while spaces are
        // still present so token boundaries are visible; it also makes implicit products
        // explicit so the upcoming whitespace collapse can't merge two names into one.
        s = applyImplicitGrouping(s)

        // Collapse stray whitespace.
        s = s.replacingOccurrences(of: " ", with: "")

        return s.isEmpty ? nil : s
    }

    /// Replaces `\frac{A}{B}` -> `((A)/(B))`, `\sqrt{A}` -> `sqrt(A)`,
    /// `\sqrt[N]{A}` -> `(A)^(1/(N))`, recursively. Returns nil on unbalanced braces.
    private static func expandBracedMacros(_ input: String) -> String? {
        var s = input
        var guardCounter = 0
        let macros = ["\\frac", "\\sqrt"]

        while guardCounter < 5_000 {
            guardCounter += 1
            // Find the earliest macro occurrence.
            var earliest: (range: Range<String.Index>, name: String)?
            for name in macros {
                if let r = s.range(of: name) {
                    if earliest == nil || r.lowerBound < earliest!.range.lowerBound {
                        earliest = (r, name)
                    }
                }
            }
            guard let hit = earliest else { break }

            var cursor = hit.range.upperBound

            if hit.name == "\\frac" {
                guard let first = readBraceGroup(s, from: &cursor),
                      let second = readBraceGroup(s, from: &cursor) else { return nil }
                let replacement = "((\(first))/(\(second)))"
                s.replaceSubrange(hit.range.lowerBound..<cursor, with: replacement)
            } else { // \sqrt
                // Optional index: \sqrt[n]{...}
                var indexExpr: String?
                if cursor < s.endIndex && s[cursor] == "[" {
                    guard let n = readBracketGroup(s, from: &cursor) else { return nil }
                    indexExpr = n
                }
                guard let radicand = readBraceGroup(s, from: &cursor) else { return nil }
                let replacement: String
                if let n = indexExpr {
                    replacement = "((\(radicand))^(1/(\(n))))"
                } else {
                    replacement = "sqrt(\(radicand))"
                }
                s.replaceSubrange(hit.range.lowerBound..<cursor, with: replacement)
            }
        }
        return s
    }

    /// Reads a `{ ... }` group starting at `cursor` (which must point at `{`).
    /// Advances `cursor` past the closing brace. Returns the inner text, nil if malformed.
    private static func readBraceGroup(_ s: String, from cursor: inout String.Index) -> String? {
        guard cursor < s.endIndex, s[cursor] == "{" else { return nil }
        var depth = 0
        let start = s.index(after: cursor)
        var i = cursor
        while i < s.endIndex {
            let c = s[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let inner = String(s[start..<i])
                    cursor = s.index(after: i)
                    return inner
                }
            }
            i = s.index(after: i)
        }
        return nil   // unbalanced
    }

    /// Reads a `[ ... ]` group (the root index). Same contract as `readBraceGroup`.
    private static func readBracketGroup(_ s: String, from cursor: inout String.Index) -> String? {
        guard cursor < s.endIndex, s[cursor] == "[" else { return nil }
        let start = s.index(after: cursor)
        var i = start
        while i < s.endIndex {
            if s[i] == "]" {
                let inner = String(s[start..<i])
                cursor = s.index(after: i)
                return inner
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Maps LaTeX symbol/function macros to engine identifiers. Longer tokens first so
    /// e.g. `\theta` is replaced before a hypothetical `\th`.
    private static func applySymbolMap(_ input: String) -> String {
        var s = input

        // Multiplicative / operator macros.
        let operators: [(String, String)] = [
            ("\\cdot", "*"), ("\\times", "*"), ("\\div", "/"),
            // `\pm` has no single-value meaning; we deliberately keep the PLUS branch
            // (the principal/upper sign) so the source still parses as one curve.
            ("\\pm", "+"),
        ]
        // Function macros -> bare engine name (the following "(" stays).
        let functions = ["arcsin", "arccos", "arctan",
                         "sinh", "cosh", "tanh",
                         "sin", "cos", "tan",
                         "exp", "ln", "log",
                         "sqrt", "abs", "floor", "ceil", "min", "max"]
        // Greek / constants.
        let symbols: [(String, String)] = [
            ("\\theta", "theta"), ("\\vartheta", "theta"),
            ("\\phi", "phi"), ("\\varphi", "phi"),
            ("\\alpha", "a"), ("\\beta", "b"), ("\\gamma", "g"),
            ("\\omega", "w"), ("\\lambda", "l"), ("\\mu", "m"),
            ("\\pi", "pi"), ("\\tau", "tau"),
            ("\\rho", "r"),
        ]

        for (from, to) in operators { s = s.replacingOccurrences(of: from, with: to) }

        // arcsin/arccos/arctan need to map onto engine names asin/acos/atan.
        s = s.replacingOccurrences(of: "\\arcsin", with: "asin")
        s = s.replacingOccurrences(of: "\\arccos", with: "acos")
        s = s.replacingOccurrences(of: "\\arctan", with: "atan")
        for fn in functions {
            s = s.replacingOccurrences(of: "\\\(fn)", with: fn)
        }
        // Bare arcsin/arccos/arctan that weren't escaped.
        s = s.replacingOccurrences(of: "arcsin", with: "asin")
        s = s.replacingOccurrences(of: "arccos", with: "acos")
        s = s.replacingOccurrences(of: "arctan", with: "atan")

        for (from, to) in symbols { s = s.replacingOccurrences(of: from, with: to) }

        return s
    }

    // MARK: - Implicit grouping

    /// The single-argument function names the engine (`PlotExpression`) understands.
    /// A name in this set that is written without parentheses (LaTeX `\sin x`) needs
    /// explicit application parens or the parser would either reject it (a function
    /// must be followed by `(`) or, once spaces are stripped, read it as a free variable.
    private static let knownFunctions: Set<String> = [
        "sin", "cos", "tan", "asin", "acos", "atan",
        "sinh", "cosh", "tanh", "exp", "ln", "log", "log2", "log10",
        "sqrt", "cbrt", "abs", "floor", "ceil", "round", "sign",
    ]

    /// Rewrites three implicit-notation cases while spaces still mark token boundaries:
    ///
    ///   1. A known function name followed by a bare operand gets application parens:
    ///      `sin x` -> `sin(x)`, `cos 2x` -> `cos(2*x)`. A name already followed by `(`
    ///      is left untouched.
    ///   2. An unbraced superscript keeps only its FIRST character as the exponent and
    ///      turns the rest into trailing factors: `x^23` -> `x^(2)*3`. A `^` that is
    ///      already followed by a group `(...)` (e.g. an expanded `^{...}`) is left as is.
    ///   3. Two adjacent operands separated by a space become an explicit product so the
    ///      later whitespace collapse can't merge them: `g x` -> `g*x`.
    private static func applyImplicitGrouping(_ input: String) -> String {
        let chars = Array(input)
        let n = chars.count
        var out: [Character] = []
        out.reserveCapacity(n + 8)

        func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdentBody(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func isDigit(_ c: Character) -> Bool { c.isNumber }

        // The previous emitted token can end an operand (a name, number, or `)`), which
        // is what makes a following operand an implicit product.
        var prevEndsOperand = false

        var i = 0
        while i < n {
            let c = chars[i]

            // Whitespace: only meaningful as a token separator. If it sits between two
            // operands, emit an explicit '*' so collapsing spaces can't merge the names.
            if c == " " || c == "\t" || c == "\n" {
                var j = i
                while j < n && (chars[j] == " " || chars[j] == "\t" || chars[j] == "\n") { j += 1 }
                if prevEndsOperand && j < n {
                    let next = chars[j]
                    let nextStartsOperand = isIdentStart(next) || isDigit(next)
                        || next == "(" || next == "."
                    if nextStartsOperand {
                        // Emit the product here so the operand handler doesn't add a second.
                        out.append("*")
                        prevEndsOperand = false
                    }
                }
                i = j
                continue
            }

            // Identifier (variable, constant, or function name).
            if isIdentStart(c) {
                if prevEndsOperand { out.append("*") }   // e.g. `2x`, `)x`
                var j = i + 1
                while j < n && isIdentBody(chars[j]) { j += 1 }
                let name = String(chars[i..<j]).lowercased()
                out.append(contentsOf: chars[i..<j])

                // Is this a function application? Skip any spaces to find the operand.
                if knownFunctions.contains(name) {
                    var k = j
                    while k < n && (chars[k] == " " || chars[k] == "\t" || chars[k] == "\n") { k += 1 }
                    if k < n && chars[k] == "(" {
                        // Already parenthesized (`cos(x)`, `cos (x)`): drop any gap so the
                        // `(` binds as application, not an implicit product.
                        i = k
                        prevEndsOperand = false
                        continue
                    }
                    if k < n, let (primary, end) = readPrimary(chars, from: k) {
                        // Bare operand (`cos 2x`): wrap it in explicit application parens.
                        out.append("(")
                        out.append(contentsOf: primary)
                        out.append(")")
                        i = end
                        prevEndsOperand = true
                        continue
                    }
                }
                i = j
                prevEndsOperand = true
                continue
            }

            // Number literal.
            if isDigit(c) || (c == "." && i + 1 < n && isDigit(chars[i + 1])) {
                if prevEndsOperand { out.append("*") }   // e.g. `)2`
                var j = i
                var seenDot = false
                while j < n {
                    let d = chars[j]
                    if isDigit(d) { j += 1 }
                    else if d == "." && !seenDot { seenDot = true; j += 1 }
                    else { break }
                }
                out.append(contentsOf: chars[i..<j])
                i = j
                prevEndsOperand = true
                continue
            }

            // Superscript: keep only the first non-group character as the exponent.
            if c == "^" {
                var k = i + 1
                while k < n && (chars[k] == " " || chars[k] == "\t" || chars[k] == "\n") { k += 1 }
                // A grouped exponent `^(...)` (also what an expanded `^{...}` becomes) or a
                // signed/empty exponent is already correct — leave the caret as written.
                if k < n && (isDigit(chars[k]) || isIdentStart(chars[k])) {
                    out.append("^")
                    out.append("(")
                    out.append(chars[k])     // exactly one character is the exponent
                    out.append(")")
                    i = k + 1
                    prevEndsOperand = true   // the `(...)` group closes an operand
                    // Any immediately-following run becomes trailing factors; the loop
                    // will emit explicit `*` for them via prevEndsOperand.
                    continue
                }
                out.append("^")
                i += 1
                prevEndsOperand = false
                continue
            }

            // Any other character (operators, parens, comma, …): copy through and update
            // whether it can end an operand.
            out.append(c)
            switch c {
            case ")": prevEndsOperand = true
            default:  prevEndsOperand = false   // `(`, `+`, `-`, `*`, `/`, `,`, `^` (handled)
            }
            i += 1
        }

        return String(out)
    }

    /// Reads the single primary that a bare function applies to, starting at `start`:
    /// a parenthesized group, a number (optionally followed by an identifier, joined with
    /// `*` as in `2x` -> `2*x`), or a lone identifier. Returns the primary's text and the
    /// index just past it, or nil if `start` isn't the beginning of a primary.
    private static func readPrimary(_ chars: [Character], from start: Int) -> ([Character], Int)? {
        let n = chars.count
        guard start < n else { return nil }
        let c = chars[start]

        func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        func isIdentBody(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func isDigit(_ c: Character) -> Bool { c.isNumber }

        // Parenthesized group: read the matched span so the whole group is the operand.
        if c == "(" {
            var depth = 0
            var j = start
            while j < n {
                if chars[j] == "(" { depth += 1 }
                else if chars[j] == ")" {
                    depth -= 1
                    if depth == 0 { return (Array(chars[start...j]), j + 1) }
                }
                j += 1
            }
            return nil   // unbalanced — let the later parse gate reject it
        }

        // Number, with an optional trailing identifier (`2x` -> `2*x`).
        if isDigit(c) || (c == "." && start + 1 < n && isDigit(chars[start + 1])) {
            var j = start
            var seenDot = false
            while j < n {
                let d = chars[j]
                if isDigit(d) { j += 1 }
                else if d == "." && !seenDot { seenDot = true; j += 1 }
                else { break }
            }
            var primary = Array(chars[start..<j])
            if j < n && isIdentStart(chars[j]) {
                let idStart = j
                j += 1
                while j < n && isIdentBody(chars[j]) { j += 1 }
                primary.append("*")
                primary.append(contentsOf: chars[idStart..<j])
            }
            return (primary, j)
        }

        // Lone identifier.
        if isIdentStart(c) {
            var j = start + 1
            while j < n && isIdentBody(chars[j]) { j += 1 }
            return (Array(chars[start..<j]), j)
        }

        return nil
    }
}
