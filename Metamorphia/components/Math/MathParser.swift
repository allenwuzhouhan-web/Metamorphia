/*
 * Metamorphia
 * Native LaTeX math rendering — parser.
 *
 * Turns a token stream into a `MathAtom` tree. Pure and nonisolated so it can be
 * unit-tested. Never throws and never crashes: anything it cannot interpret is
 * captured as `.fallback(rawLaTeX)` so the layout can show a subtle inline form.
 */

import Foundation

/// Recursive-descent parser over `LatexToken`s. Single-use per parse.
struct LatexParser {

    private let tokens: [LatexToken]
    private var index = 0

    private init(tokens: [LatexToken]) {
        self.tokens = tokens
    }

    /// Bounded in-memory memo for `parse`, keyed by source LaTeX. `MathView.body`
    /// re-parses on every SwiftUI render, so caching the tree turns repeat
    /// renders into hits. Oldest entry evicted at the cap. NSLock-guarded so the
    /// API stays pure/nonisolated and thread-safe.
    private static let cacheLock = NSLock()
    private static var cache: [String: MathAtom] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheCap = 128

    /// Longest source we will attempt to parse. Pathological assistant/scratchpad
    /// input (thousands of nested braces or fractions) recurses one frame per
    /// nesting level; anything past this is surfaced verbatim instead of risking
    /// stack exhaustion. Well below the realistic frame-crash floor.
    private static let maxSourceLength = 4096

    /// Maximum nesting depth before the parser bails to a `.fallback`. Threaded
    /// through every mutually-recursive entry point. Defense in depth behind the
    /// length cap above.
    private static let maxDepth = 64

    /// Parse a LaTeX math fragment into an atom tree. Always returns something.
    nonisolated static func parse(_ latex: String) -> MathAtom {
        cacheLock.lock()
        if let cached = cache[latex] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Over-long sources never reach the recursive parser.
        guard latex.count <= maxSourceLength else {
            return .fallback(latex)
        }

        let tokens = LatexTokenizer.tokenize(latex)
        var parser = LatexParser(tokens: tokens)
        let atoms = parser.parseList(until: nil, depth: 0)
        let atom = normalize(atoms)

        cacheLock.lock()
        if cache[latex] == nil {
            cache[latex] = atom
            cacheOrder.append(latex)
            if cacheOrder.count > cacheCap {
                let oldest = cacheOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
        }
        cacheLock.unlock()

        return atom
    }

    /// Collapse a parsed atom array into a single atom.
    private static func normalize(_ atoms: [MathAtom]) -> MathAtom {
        if atoms.isEmpty { return .list([]) }
        if atoms.count == 1 { return atoms[0] }
        return .list(atoms)
    }

    // MARK: - Cursor helpers

    /// Insignificant whitespace is transparent to the normal parse; only the
    /// verbatim reader (\text) observes it. These helpers skip it.

    private func peek() -> LatexToken? {
        var j = index
        while j < tokens.count, tokens[j] == .whitespace { j += 1 }
        return j < tokens.count ? tokens[j] : nil
    }

    private mutating func advance() -> LatexToken? {
        while index < tokens.count, tokens[index] == .whitespace { index += 1 }
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    /// Raw lookahead including whitespace (used by the verbatim \text reader).
    private func peekRaw() -> LatexToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func advanceRaw() -> LatexToken? {
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    // MARK: - List parsing

    /// Parse atoms until `stop` is reached (consumed) or input ends.
    /// Handles scripts (^ _) by attaching them to the preceding atom.
    /// `depth` bounds nesting so pathological input can't overflow the stack.
    private mutating func parseList(until stop: LatexToken?, depth: Int) -> [MathAtom] {
        guard depth <= LatexParser.maxDepth else {
            // Too deeply nested — consume the rest of this group as a flat run so
            // we still advance the cursor, then surface a fallback.
            skipUntil(stop)
            return [.fallback("…")]
        }
        var atoms: [MathAtom] = []

        while let tok = peek() {
            if let stop, tok == stop {
                _ = advance() // consume the stop token (skips leading whitespace)
                return atoms
            }
            // Row break / column separators are not valid in a plain list; the
            // matrix parser handles them. If we hit one here, stop so the caller
            // can deal with it (defensive — normally unreachable).
            if tok == .rowBreak || tok == .ampersand {
                return atoms
            }

            switch tok {
            case .caret, .underscore:
                // A script with no base: attach to an empty run so it still renders.
                let base: MathAtom = atoms.popLast() ?? .run("", .normal)
                atoms.append(parseScripts(base: base, depth: depth))
            default:
                let atom = parseAtom(depth: depth)
                // Look ahead for scripts immediately following this atom.
                if case .caret = peek() {
                    atoms.append(parseScripts(base: atom, depth: depth))
                } else if case .underscore = peek() {
                    atoms.append(parseScripts(base: atom, depth: depth))
                } else {
                    atoms.append(atom)
                }
            }
        }
        return atoms
    }

    /// Consume tokens until `stop` (or EOF) without building atoms. Used to keep
    /// the cursor advancing when a depth budget is exhausted, so an over-nested
    /// group is swallowed whole rather than partially re-parsed by the caller.
    private mutating func skipUntil(_ stop: LatexToken?) {
        guard let stop else {
            index = tokens.count
            return
        }
        while let tok = advance() {
            if tok == stop { return }
        }
    }

    /// Parse trailing ^ and _ scripts onto a base. Either or both, any order.
    private mutating func parseScripts(base: MathAtom, depth: Int) -> MathAtom {
        var sup: MathAtom?
        var sub: MathAtom?

        while let tok = peek() {
            if tok == .caret {
                _ = advance()
                let s = parseScriptArgument(depth: depth)
                sup = sup.map { .list([$0, s]) } ?? s
            } else if tok == .underscore {
                _ = advance()
                let s = parseScriptArgument(depth: depth)
                sub = sub.map { .list([$0, s]) } ?? s
            } else {
                break
            }
        }

        // If the base is a big operator, the scripts become its limits but we still
        // model them via `scripted`; layout decides over/under vs. corner placement.
        return .scripted(base: base, sup: sup, sub: sub)
    }

    /// A script argument is a single atom or a braced group.
    private mutating func parseScriptArgument(depth: Int) -> MathAtom {
        guard let tok = peek() else { return .run("", .normal) }
        if tok == .openBrace {
            _ = advance()
            let inner = parseList(until: .closeBrace, depth: depth + 1)
            return LatexParser.normalize(inner)
        }
        return parseAtom(depth: depth)
    }

    // MARK: - Single atom

    private mutating func parseAtom(depth: Int) -> MathAtom {
        guard let tok = advance() else { return .run("", .normal) }

        switch tok {
        case .openBrace:
            let inner = parseList(until: .closeBrace, depth: depth + 1)
            return LatexParser.normalize(inner)

        case .closeBrace:
            // Unbalanced brace — render literally.
            return .run("}", .normal)

        case .symbol(let c):
            return .run(String(c), .normal)

        case .caret, .underscore:
            // Should be handled by parseList; treat defensively as literal.
            return .run(tok == .caret ? "^" : "_", .normal)

        case .ampersand:
            return .run("&", .normal)

        case .rowBreak, .whitespace:
            // advance() skips whitespace, so this is unreachable in practice.
            return .run("", .normal)

        case .command(let name):
            return parseCommand(name, depth: depth)
        }
    }

    // MARK: - Commands

    private mutating func parseCommand(_ name: String, depth: Int) -> MathAtom {
        // Spacing commands.
        if let amount = MathSymbols.spacing[name] {
            return .space(amount)
        }

        switch name {
        case "frac", "tfrac", "dfrac", "cfrac":
            let num = parseGroupArgument(depth: depth)
            let den = parseGroupArgument(depth: depth)
            return .fraction(numerator: num, denominator: den)

        case "sqrt":
            // Optional [index] then a required radicand.
            let index = parseOptionalBracketArgument(depth: depth)
            let radicand = parseGroupArgument(depth: depth)
            return .radical(index: index, radicand: radicand)

        case "text", "textrm", "textnormal", "mbox":
            return .run(readVerbatimGroup(), .text)

        case "mathrm", "operatorname", "rm":
            let g = parseGroupArgument(depth: depth)
            return restyle(g, to: .roman)

        case "mathbf", "bf", "boldsymbol", "bm":
            let g = parseGroupArgument(depth: depth)
            return restyle(g, to: .bold)

        case "mathbb":
            let g = parseGroupArgument(depth: depth)
            return restyle(g, to: .blackboard)

        case "mathit", "mathsf", "mathcal", "mathfrak", "mathnormal":
            // We do not have dedicated faces for these; render upright-normal.
            return parseGroupArgument(depth: depth)

        case "left":
            return parseLeftRight(depth: depth)

        case "right":
            // A stray \right with no matching \left — skip its delimiter token.
            _ = consumeDelimiterToken()
            return .run("", .normal)

        case "begin":
            return parseEnvironment(depth: depth)

        case "end":
            // Stray \end — swallow its name argument.
            _ = readVerbatimGroup()
            return .run("", .normal)

        case "langle":
            return .run("\u{27E8}", .normal)
        case "rangle":
            return .run("\u{27E9}", .normal)
        case "lbrace":
            return .run("{", .normal)
        case "rbrace":
            return .run("}", .normal)
        case "lbrack":
            return .run("[", .normal)
        case "rbrack":
            return .run("]", .normal)
        case "vert", "lvert", "rvert":
            return .run("|", .normal)
        case "Vert":
            return .run("\u{2016}", .normal)
        case "backslash":
            return .run("\\", .normal)

        default:
            break
        }

        // Big operators (\sum, \int, …).
        if let big = MathSymbols.bigOperators[name] {
            return .bigOperator(symbol: big.glyph, displayLimits: big.displayLimits)
        }

        // Named functions (\sin, \log, …) render upright.
        if MathSymbols.functions.contains(name) {
            return .run(name, .roman)
        }

        // Greek letters.
        if let g = MathSymbols.greek[name] {
            return .run(g, .normal)
        }

        // Operators / relations / arrows / sets.
        if let g = MathSymbols.operators[name] {
            return .run(g, .normal)
        }

        // Unknown command — surface verbatim as a subtle fallback.
        return .fallback("\\" + name)
    }

    /// Re-tag every `run` inside an atom with a new font style.
    private func restyle(_ atom: MathAtom, to style: MathFontStyle) -> MathAtom {
        switch atom {
        case .run(let s, _):
            return .run(s, style)
        case .list(let items):
            return .list(items.map { restyle($0, to: style) })
        case .scripted(let base, let sup, let sub):
            return .scripted(base: restyle(base, to: style),
                             sup: sup.map { restyle($0, to: style) },
                             sub: sub.map { restyle($0, to: style) })
        default:
            return atom
        }
    }

    // MARK: - Argument helpers

    /// Parse a required argument: a braced group, or the next single atom.
    private mutating func parseGroupArgument(depth: Int) -> MathAtom {
        guard let tok = peek() else { return .run("", .normal) }
        if tok == .openBrace {
            _ = advance()
            let inner = parseList(until: .closeBrace, depth: depth + 1)
            return LatexParser.normalize(inner)
        }
        // Single-token argument (e.g. \sqrt2, x^2 already handled). Honor scripts.
        let atom = parseAtom(depth: depth)
        return atom
    }

    /// Parse an optional `[ … ]` argument (used by \sqrt[n]). Returns nil if absent.
    private mutating func parseOptionalBracketArgument(depth: Int) -> MathAtom? {
        guard case .symbol("[") = peek() else { return nil }
        _ = advance() // consume '['
        var inner: [MathAtom] = []
        while let tok = peek() {
            if case .symbol("]") = tok {
                _ = advance()
                return LatexParser.normalize(inner)
            }
            inner.append(parseAtom(depth: depth))
        }
        // Unterminated bracket — return what we have.
        return LatexParser.normalize(inner)
    }

    /// Read a `{ … }` group as a plain string (for \text). Preserves spaces.
    /// Whitespace tokens are preserved here (via raw access) so word spacing in
    /// \text{…} survives, even though it is dropped everywhere else.
    private mutating func readVerbatimGroup() -> String {
        // Skip insignificant leading whitespace, then require an opening brace.
        guard case .openBrace? = peek() else {
            // Single token text argument.
            if let tok = advance(), case .symbol(let c) = tok { return String(c) }
            return ""
        }
        _ = advance() // consume '{'
        var out = ""
        var depth = 1
        while let tok = advanceRaw() {
            switch tok {
            case .openBrace:
                depth += 1; out += "{"
            case .closeBrace:
                depth -= 1
                if depth == 0 { return out }
                out += "}"
            case .symbol(let c):
                out.append(c)
            case .whitespace:
                out += " "
            case .command(let name):
                // Insert a space for explicit spacing commands; otherwise keep name.
                if name == " " || name == "," || name == ";" {
                    out += " "
                } else {
                    out += "\\" + name
                }
            case .caret: out += "^"
            case .underscore: out += "_"
            case .ampersand: out += "&"
            case .rowBreak: out += " "
            }
        }
        return out
    }

    // MARK: - \left … \right

    private mutating func parseLeftRight(depth: Int) -> MathAtom {
        let leftTok = consumeDelimiterToken()
        let left = MathSymbols.delimiter(for: leftTok)

        // A fence opens a new nesting level for its body.
        let bodyDepth = depth + 1
        guard bodyDepth <= LatexParser.maxDepth else {
            skipUntil(.command("right"))
            _ = consumeDelimiterToken()
            return .fallback("…")
        }

        // Parse the body until we hit a matching \right.
        var body: [MathAtom] = []
        var right: MathDelimiter = .none

        while let tok = peek() {
            if case .command("right") = tok {
                _ = advance()
                let rightTok = consumeDelimiterToken()
                right = MathSymbols.delimiter(for: rightTok)
                break
            }
            if tok == .rowBreak || tok == .ampersand {
                // Allow these to pass through inside fences (e.g. cases-like).
                _ = advance()
                continue
            }
            // Reuse list parsing semantics for scripts.
            if case .caret = tok {
                let base = body.popLast() ?? .run("", .normal)
                body.append(parseScripts(base: base, depth: bodyDepth))
                continue
            }
            if case .underscore = tok {
                let base = body.popLast() ?? .run("", .normal)
                body.append(parseScripts(base: base, depth: bodyDepth))
                continue
            }
            let atom = parseAtom(depth: bodyDepth)
            if case .caret = peek() {
                body.append(parseScripts(base: atom, depth: bodyDepth))
            } else if case .underscore = peek() {
                body.append(parseScripts(base: atom, depth: bodyDepth))
            } else {
                body.append(atom)
            }
        }

        return .delimited(left: left, body: LatexParser.normalize(body), right: right)
    }

    /// Consume the delimiter token following \left or \right and return its string.
    private mutating func consumeDelimiterToken() -> String {
        guard let tok = advance() else { return "." }
        switch tok {
        case .symbol(let c): return String(c)
        case .openBrace: return "{"
        case .closeBrace: return "}"
        case .command(let name): return name
        default: return "."
        }
    }

    // MARK: - Environments (matrices)

    private mutating func parseEnvironment(depth: Int) -> MathAtom {
        let envName = readVerbatimGroup()

        // An environment body nests one level deeper.
        let bodyDepth = depth + 1
        guard bodyDepth <= LatexParser.maxDepth else {
            _ = parseUntilEnd(envName: envName, depth: LatexParser.maxDepth)
            return .fallback("…")
        }

        let delimiter: MathDelimiter
        switch envName {
        case "pmatrix": delimiter = .paren
        case "bmatrix": delimiter = .bracket
        case "Bmatrix": delimiter = .brace
        case "vmatrix": delimiter = .vert
        case "Vmatrix": delimiter = .doubleVert
        case "matrix", "array", "cases", "aligned", "align", "gathered": delimiter = .none
        default:
            // Unknown environment: parse its body as a flat list until \end.
            let body = parseUntilEnd(envName: envName, depth: bodyDepth)
            return LatexParser.normalize(body)
        }

        let rows = parseMatrixRows(envName: envName, depth: bodyDepth)
        return .matrix(rows: rows, delimiter: delimiter)
    }

    /// Parse matrix cells split by `&` and rows split by `\\`, until \end{env}.
    private mutating func parseMatrixRows(envName: String, depth: Int) -> [[MathAtom]] {
        var rows: [[MathAtom]] = []
        var currentRow: [MathAtom] = []
        var currentCell: [MathAtom] = []

        func flushCell() {
            currentRow.append(LatexParser.normalize(currentCell))
            currentCell = []
        }
        func flushRow() {
            flushCell()
            // Drop a trailing fully-empty row (common after a final \\).
            if !(currentRow.count == 1 && currentRow[0] == .list([])) {
                rows.append(currentRow)
            }
            currentRow = []
        }

        while let tok = peek() {
            switch tok {
            case .command("end"):
                _ = advance()
                _ = readVerbatimGroup() // consume the env name
                flushRow()
                return rows
            case .ampersand:
                _ = advance()
                flushCell()
            case .rowBreak:
                _ = advance()
                flushRow()
            case .caret:
                let base = currentCell.popLast() ?? .run("", .normal)
                currentCell.append(parseScripts(base: base, depth: depth))
            case .underscore:
                let base = currentCell.popLast() ?? .run("", .normal)
                currentCell.append(parseScripts(base: base, depth: depth))
            default:
                let atom = parseAtom(depth: depth)
                if case .caret = peek() {
                    currentCell.append(parseScripts(base: atom, depth: depth))
                } else if case .underscore = peek() {
                    currentCell.append(parseScripts(base: atom, depth: depth))
                } else {
                    currentCell.append(atom)
                }
            }
        }
        // EOF without \end — flush what we have.
        flushRow()
        return rows
    }

    /// Parse a flat list until the matching \end (for unknown environments).
    private mutating func parseUntilEnd(envName: String, depth: Int) -> [MathAtom] {
        var atoms: [MathAtom] = []
        while let tok = peek() {
            if case .command("end") = tok {
                _ = advance()
                _ = readVerbatimGroup()
                return atoms
            }
            if tok == .ampersand || tok == .rowBreak {
                _ = advance()
                atoms.append(.space(0.5))
                continue
            }
            if case .caret = tok {
                let base = atoms.popLast() ?? .run("", .normal)
                atoms.append(parseScripts(base: base, depth: depth))
                continue
            }
            if case .underscore = tok {
                let base = atoms.popLast() ?? .run("", .normal)
                atoms.append(parseScripts(base: base, depth: depth))
                continue
            }
            let atom = parseAtom(depth: depth)
            if case .caret = peek() {
                atoms.append(parseScripts(base: atom, depth: depth))
            } else if case .underscore = peek() {
                atoms.append(parseScripts(base: atom, depth: depth))
            } else {
                atoms.append(atom)
            }
        }
        return atoms
    }
}
