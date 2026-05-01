import Foundation
import CoreGraphics

// MARK: - Selector Parser (Rank 6)
//
// Hand-written recursive-descent parser. Every character is consumed
// deterministically; no regex shortcuts, no `String.components(separatedBy:)`
// hacks. This matters because selectors contain quoted substrings and regex
// literals with arbitrary embedded characters, and "split on spaces" would
// mangle them.
//
// Full grammar (BNF):
//
// ```
// selector     := term (' '+ term)*
// term         := field ':' value
//              |  field '~' '/' regex '/'      // regex match
//              |  field '*' value              // contains
//              |  field '^' value              // startswith
//              |  field '=' value              // explicit equals (vs shortcut ':')
//              |  field '>' number             // depth > n (field == "depth")
//              |  field '<' number
//              |  '!' term                     // NOT (negation)
//              |  ref                          // bare @e42
//              |  '(' selector ')'             // grouping (AND within group)
// field        := 'role' | 'label' | 'value' | 'parent' | 'in' | 'depth'
//              |  'visible' | 'interactive' | 'state' | 'action'
//              |  'display' | 'ref' | 'near' | 'tier' | 'confidence'
// value        := quoted-string | unquoted-word | number | boolean
// quoted-string:= '"' <chars> '"'
// ref          := '@e' digits
// boolean      := 'true' | 'false'
// ```
//
// The parser is available as a standalone module — `SelectorParser.parse(...)`
// — so callers that want to introspect a selector without running it can do
// so. `QueryEngine.parse` is a thin wrapper.

public enum SelectorParser {

    // MARK: - Public entry

    /// Parse a selector string into a validated `Selector`. Throws
    /// `QueryError` on any malformed / unknown construct. Whitespace-only input
    /// raises `.emptySelector`.
    public static func parse(_ raw: String) throws -> Selector {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw QueryError.emptySelector
        }
        var cursor = Cursor(source: raw)
        let predicates = try parseSelector(&cursor)
        if predicates.isEmpty {
            throw QueryError.emptySelector
        }
        // After parsing the top-level selector we should be at EOF; anything
        // left (unmatched ')', stray ':' etc.) is a hard error.
        cursor.skipSpaces()
        if !cursor.isAtEnd {
            let rest = String(cursor.peekRemaining().prefix(16))
            throw QueryError.malformedPredicate(rest, reason: "unexpected trailing input")
        }
        return Selector(raw: raw, predicates: predicates)
    }

    // MARK: - Parsing internals

    /// Parse a whitespace-separated chain of terms. The top-level call starts
    /// with no group context; recursive calls from `(` pass `closingParen: ")"`.
    private static func parseSelector(_ cursor: inout Cursor, closingParen: Character? = nil) throws -> [Predicate] {
        var predicates: [Predicate] = []
        while true {
            cursor.skipSpaces()
            if cursor.isAtEnd { break }
            if let close = closingParen, cursor.peek() == close {
                cursor.advance()
                return predicates
            }
            let term = try parseTerm(&cursor)
            predicates.append(contentsOf: term)
        }
        if closingParen != nil {
            throw QueryError.malformedPredicate("(", reason: "unclosed group")
        }
        return predicates
    }

    /// Parse one term. Returns an array because negation of a group needs to
    /// flip polarity on every predicate inside. Non-group terms return a
    /// single-element array.
    private static func parseTerm(_ cursor: inout Cursor) throws -> [Predicate] {
        cursor.skipSpaces()
        guard let c = cursor.peek() else {
            throw QueryError.malformedPredicate("", reason: "expected term")
        }

        // Negation — applies to the single term that follows.
        if c == "!" {
            cursor.advance()
            let inner = try parseTerm(&cursor)
            return inner.map(negate)
        }

        // Grouping — yields the AND-union of the group's predicates.
        if c == "(" {
            cursor.advance()
            let inner = try parseSelector(&cursor, closingParen: ")")
            if inner.isEmpty {
                throw QueryError.malformedPredicate("()", reason: "empty group")
            }
            return inner
        }

        // Bare @eN ref.
        if c == "@" {
            let ref = try parseRef(&cursor)
            return [.refEquals(ref)]
        }

        // field <op> value
        let field = cursor.readFieldName()
        if field.isEmpty {
            let snippet = String(cursor.peekRemaining().prefix(8))
            throw QueryError.malformedPredicate(snippet, reason: "expected field name")
        }

        // Peek the operator.
        guard let opChar = cursor.peek() else {
            throw QueryError.malformedPredicate(field, reason: "missing operator after field")
        }

        switch opChar {
        case ":":
            cursor.advance()
            return try parseColonValue(field: field, cursor: &cursor)
        case "=":
            cursor.advance()
            return try parseColonValue(field: field, cursor: &cursor, exactEqualsOverride: true)
        case "~":
            cursor.advance()
            return try parseRegexValue(field: field, cursor: &cursor)
        case "*":
            cursor.advance()
            let value = try cursor.readValueToken()
            return try makeContainsPredicate(field: field, value: value)
        case "^":
            cursor.advance()
            let value = try cursor.readValueToken()
            return try makeStartsWithPredicate(field: field, value: value)
        case ">":
            cursor.advance()
            let value = try cursor.readValueToken()
            return try makeComparisonPredicate(field: field, op: ">", value: value)
        case "<":
            cursor.advance()
            let value = try cursor.readValueToken()
            return try makeComparisonPredicate(field: field, op: "<", value: value)
        default:
            throw QueryError.malformedPredicate(
                String(opChar),
                reason: "unknown operator after field '\(field)'"
            )
        }
    }

    // MARK: - Field/value dispatch

    /// Handles `field:value` and `field=value`. The two forms differ only for
    /// `label` — `=` requests case-sensitive equals; `:` stays case-insensitive
    /// for parity with the stub fallback parser.
    private static func parseColonValue(
        field: String,
        cursor: inout Cursor,
        exactEqualsOverride: Bool = false
    ) throws -> [Predicate] {
        // Peek for state/confidence/depth modifier forms like
        //   state:!disabled      → lacksState(.disabled)
        //   state:enabled        → hasState(.enabled)
        //   depth:>3             → depthGreater(3)
        //   depth:<5             → depthLess(5)
        //   confidence:>0.8      → confidenceAbove(0.8)
        //
        // These are convenience grammar sugar that consumers asked for (see
        // `Rank 6` spec, § examples); without them the user has to write
        // `depth>3` which is ugly next to `label:"x"`.
        let preview = cursor.peek()
        if preview == "!" && field == "state" {
            cursor.advance()
            let value = try cursor.readValueToken()
            guard let state = stateLookup(value) else {
                throw QueryError.invalidStateValue(value)
            }
            return [.lacksState(state)]
        }
        if preview == ">" && (field == "depth" || field == "confidence") {
            cursor.advance()
            let value = try cursor.readValueToken()
            return try makeComparisonPredicate(field: field, op: ">", value: value)
        }
        if preview == "<" && field == "depth" {
            cursor.advance()
            let value = try cursor.readValueToken()
            return try makeComparisonPredicate(field: field, op: "<", value: value)
        }

        // `near:@e42:50` — two tokens glued with ':'. Handle before the
        // generic `readValueToken` because the `@eN` value looks like a plain
        // unquoted word.
        if field == "near" {
            return try parseNearValue(&cursor)
        }

        let value = try cursor.readValueToken()

        // `ref:@e42` — accept either a plain number or the full `@eN` form.
        if field == "ref" {
            return try makeRefEqualsPredicate(value: value)
        }

        return try makeEqualsPredicate(
            field: field,
            value: value,
            exactEquals: exactEqualsOverride
        )
    }

    /// `field~/pattern/` — regex literal bounded by `/`.
    private static func parseRegexValue(field: String, cursor: inout Cursor) throws -> [Predicate] {
        guard field == "label" || field == "value" else {
            throw QueryError.malformedPredicate(
                field,
                reason: "regex '~/.../' only valid on label or value"
            )
        }
        guard cursor.peek() == "/" else {
            throw QueryError.malformedPredicate(
                field,
                reason: "expected '/' after '~' to start regex"
            )
        }
        cursor.advance() // consume '/'

        var pattern = ""
        while let ch = cursor.peek() {
            if ch == "\\" {
                // Preserve escapes verbatim so `\/` and `\w` both survive.
                cursor.advance()
                if let next = cursor.peek() {
                    pattern.append("\\")
                    pattern.append(next)
                    cursor.advance()
                }
                continue
            }
            if ch == "/" {
                cursor.advance()
                let regex: NSRegularExpression
                do {
                    regex = try NSRegularExpression(pattern: pattern, options: [])
                } catch {
                    throw QueryError.invalidRegex(pattern)
                }
                if field == "label" {
                    return [.labelRegex(regex)]
                } else {
                    // `value~/pattern/` — we only expose label regex in the
                    // Predicate enum, so synthesize a labelRegex on value via
                    // labelContains fallback. To keep tests honest we map
                    // value~/.../ to labelRegex(...) with value-text not label.
                    // Keeping it on label only for now; extending later if
                    // needed. Throw instead of silently coercing.
                    throw QueryError.malformedPredicate(field, reason: "value regex not supported yet")
                }
            }
            pattern.append(ch)
            cursor.advance()
        }
        throw QueryError.invalidRegex(pattern)
    }

    /// `near:@e42:50` form.
    private static func parseNearValue(_ cursor: inout Cursor) throws -> [Predicate] {
        cursor.skipSpacesInline()
        let ref = try parseRef(&cursor)
        // Optional `:radius`.
        if cursor.peek() == ":" {
            cursor.advance()
            let radiusStr = try cursor.readValueToken()
            guard let r = Double(radiusStr) else {
                throw QueryError.malformedPredicate("near", reason: "radius '\(radiusStr)' is not a number")
            }
            return [.nearRef(ref, radius: CGFloat(r))]
        }
        // Default radius — 64pt matches typical click-target slop.
        return [.nearRef(ref, radius: 64)]
    }

    // MARK: - Predicate constructors

    private static func makeEqualsPredicate(
        field: String,
        value: String,
        exactEquals: Bool
    ) throws -> [Predicate] {
        switch field {
        case "role":
            guard let role = roleLookup(value) else {
                throw QueryError.invalidRoleValue(value)
            }
            return [.role(role)]
        case "label":
            // `:` → case-insensitive (default), `=` → case-sensitive.
            return [.labelEquals(value, caseInsensitive: !exactEquals)]
        case "value":
            // `value:x` is "value contains x" — exact match on element.value
            // is almost never useful, and the spec's example grammar maps
            // value:x → substring match.
            return [.valueContains(value, caseInsensitive: true)]
        case "parent":
            return [.parentLabel(value, caseInsensitive: true)]
        case "in":
            return [.inContainer(value, caseInsensitive: true)]
        case "depth":
            guard let n = Int(value) else {
                throw QueryError.malformedPredicate("depth:\(value)", reason: "depth value must be integer")
            }
            return [.depthEquals(n)]
        case "visible":
            guard let b = boolLookup(value) else {
                throw QueryError.malformedPredicate("visible:\(value)", reason: "expected true/false")
            }
            return [.visible(b)]
        case "interactive":
            guard let b = boolLookup(value) else {
                throw QueryError.malformedPredicate("interactive:\(value)", reason: "expected true/false")
            }
            return [.interactive(b)]
        case "state":
            guard let state = stateLookup(value) else {
                throw QueryError.invalidStateValue(value)
            }
            return [.hasState(state)]
        case "action":
            guard let action = actionLookup(value) else {
                throw QueryError.malformedPredicate("action:\(value)", reason: "unknown action")
            }
            return [.hasAction(action)]
        case "display":
            guard let n = Int(value) else {
                throw QueryError.malformedPredicate("display:\(value)", reason: "display index must be integer")
            }
            return [.displayIndex(n)]
        case "ref":
            return try makeRefEqualsPredicate(value: value)
        case "tier":
            guard let tier = tierLookup(value) else {
                throw QueryError.malformedPredicate("tier:\(value)", reason: "unknown tier")
            }
            return [.tier(tier)]
        case "confidence":
            guard let f = Float(value) else {
                throw QueryError.malformedPredicate("confidence:\(value)", reason: "confidence must be number")
            }
            return [.confidenceAbove(f)]
        default:
            throw QueryError.unknownField(field)
        }
    }

    private static func makeContainsPredicate(field: String, value: String) throws -> [Predicate] {
        switch field {
        case "label":
            return [.labelContains(value, caseInsensitive: true)]
        case "value":
            return [.valueContains(value, caseInsensitive: true)]
        default:
            throw QueryError.malformedPredicate(
                field,
                reason: "'*' (contains) only valid on label/value"
            )
        }
    }

    private static func makeStartsWithPredicate(field: String, value: String) throws -> [Predicate] {
        switch field {
        case "label":
            return [.labelStartsWith(value, caseInsensitive: true)]
        default:
            throw QueryError.malformedPredicate(
                field,
                reason: "'^' (starts-with) only valid on label"
            )
        }
    }

    private static func makeComparisonPredicate(
        field: String,
        op: String,
        value: String
    ) throws -> [Predicate] {
        switch (field, op) {
        case ("depth", ">"):
            guard let n = Int(value) else {
                throw QueryError.malformedPredicate("depth>\(value)", reason: "depth must be integer")
            }
            return [.depthGreater(n)]
        case ("depth", "<"):
            guard let n = Int(value) else {
                throw QueryError.malformedPredicate("depth<\(value)", reason: "depth must be integer")
            }
            return [.depthLess(n)]
        case ("confidence", ">"):
            guard let f = Float(value) else {
                throw QueryError.malformedPredicate("confidence>\(value)", reason: "confidence must be number")
            }
            return [.confidenceAbove(f)]
        default:
            throw QueryError.malformedPredicate(
                "\(field)\(op)",
                reason: "comparison '\(op)' not valid on field '\(field)'"
            )
        }
    }

    private static func makeRefEqualsPredicate(value: String) throws -> [Predicate] {
        let normalized = value.hasPrefix("@e") ? value : "@e\(value)"
        guard let ref = ElementRef.parse(normalized) else {
            throw QueryError.malformedPredicate("ref:\(value)", reason: "not a valid @eN ref")
        }
        return [.refEquals(ref)]
    }

    /// Parse a standalone `@eN` token (no leading field name).
    private static func parseRef(_ cursor: inout Cursor) throws -> ElementRef {
        cursor.skipSpacesInline()
        guard cursor.peek() == "@" else {
            throw QueryError.malformedPredicate("", reason: "expected '@' to start ref")
        }
        let start = cursor.index
        cursor.advance() // '@'
        guard cursor.peek() == "e" else {
            throw QueryError.malformedPredicate("@", reason: "expected 'e' after '@'")
        }
        cursor.advance() // 'e'
        var digits = ""
        while let c = cursor.peek(), c.isASCII && c.isNumber {
            digits.append(c)
            cursor.advance()
        }
        guard !digits.isEmpty, let idx = Int(digits) else {
            let snippet = String(cursor.source[start..<cursor.index])
            throw QueryError.malformedPredicate(snippet, reason: "ref missing digits")
        }
        return ElementRef(index: idx)
    }

    // MARK: - Lookups

    private static func roleLookup(_ raw: String) -> ElementRole? {
        // Case-insensitive match on the rawValue. `ElementRole` stores camel
        // case (`textField`, `radioButton`), but users will naturally type
        // lowercase or dashed forms — normalize both.
        let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        for role in allRoles() {
            if role.rawValue.lowercased() == normalized { return role }
        }
        return nil
    }

    private static func allRoles() -> [ElementRole] {
        [
            .button, .textField, .textArea, .checkbox, .radioButton,
            .popUpButton, .comboBox, .slider, .stepper, .toggle, .link,
            .tab, .menuItem, .menuBarItem, .toolbarItem, .colorWell,
            .window, .group, .scrollArea, .table, .outline, .list,
            .tabGroup, .toolbar, .menuBar, .splitGroup, .sheet, .dialog,
            .staticText, .image, .webArea, .progressIndicator,
            .ocrText, .ocrButton, .unknown,
        ]
    }

    private static func stateLookup(_ raw: String) -> ElementState? {
        switch raw.lowercased() {
        case "enabled":   return .enabled
        case "disabled":  return .disabled
        case "focused":   return .focused
        case "selected":  return .selected
        case "expanded":  return .expanded
        case "checked":   return .checked
        case "loading":   return .loading
        case "offscreen", "off_screen", "off-screen": return .offScreen
        case "password":  return .password
        case "required":  return .required
        default:          return nil
        }
    }

    private static func actionLookup(_ raw: String) -> ElementAction? {
        switch raw.lowercased() {
        case "press":     return .press
        case "increment": return .increment
        case "decrement": return .decrement
        case "confirm":   return .confirm
        case "cancel":    return .cancel
        case "showmenu", "show_menu", "show-menu": return .showMenu
        case "pick":      return .pick
        case "scroll":    return .scroll
        case "delete":    return .delete
        case "raise":     return .raise
        default:          return nil
        }
    }

    private static func tierLookup(_ raw: String) -> IdentityTier? {
        switch raw.lowercased() {
        case "identifier", "id": return .identifier
        case "label":            return .label
        case "position", "pos":  return .position
        case "fallback":         return .fallback
        default:                 return nil
        }
    }

    private static func boolLookup(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "yes", "1":  return true
        case "false", "no", "0":  return false
        default:                  return nil
        }
    }

    // MARK: - Negation

    /// Invert one predicate. Used when `!term` negates the inner term.
    ///
    /// Some predicates have a natural inverse (`visible(true)` ↔
    /// `visible(false)`, `hasState` ↔ `lacksState`, `depthGreater(n)` ↔
    /// `depthLess(n+1)`). For the rest (`role`, `label*`, `ref`, `near`, etc.)
    /// we register the original predicate in `NegationTable` and emit a
    /// sentinel `.valueContains` that the engine intercepts. This avoids
    /// widening the public `Predicate` enum with a `case not(Predicate)` that
    /// would leak implementation detail into every call site.
    private static func negate(_ p: Predicate) -> Predicate {
        switch p {
        case .visible(let v):     return .visible(!v)
        case .interactive(let v): return .interactive(!v)
        case .hasState(let s):    return .lacksState(s)
        case .lacksState(let s):  return .hasState(s)
        default:
            let token = NegationTable.register(p)
            return .valueContains(token, caseInsensitive: true)
        }
    }
}

/// Parallel table mapping a sentinel string to the original predicate the
/// parser wanted to negate. When the engine sees a `.valueContains(sentinel)`
/// whose string begins with the magic prefix, it looks up the original
/// predicate and evaluates the negation. This keeps the `Predicate` public
/// enum exactly as specified while supporting `!term` in the grammar.
///
/// The table is bounded (LRU-style, ~1024 entries) so long-running processes
/// don't accumulate unbounded state as users fire thousands of negated
/// selectors. In practice every negation consumes one entry and releases it
/// when the `Selector` that holds the sentinel goes out of scope — but we
/// can't observe that deterministically from here, so the cap is the
/// backstop.
internal enum NegationTable {
    /// Prefix reserved on `.valueContains` strings to indicate a negated
    /// predicate lookup. The prefix is not valid in any user-typed value (the
    /// parser would have quoted it), so round-trip safety holds.
    static let sentinelPrefix = "\u{0001}_NOT_\u{0001}_"

    /// Hard cap. When exceeded, oldest entries are evicted. 1024 is 4 orders of
    /// magnitude above a realistic hot-query workload; we just want a ceiling.
    private static let maxEntries = 1024

    private static let lock = NSLock()
    private static var table: [String: Predicate] = [:]
    /// FIFO order for eviction; each register appends, evict from head when
    /// over cap.
    private static var order: [String] = []
    private static var counter: Int = 0

    static func register(_ inner: Predicate) -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        let key = "\(sentinelPrefix)\(counter)"
        table[key] = inner
        order.append(key)
        while order.count > maxEntries {
            let oldest = order.removeFirst()
            table.removeValue(forKey: oldest)
        }
        return key
    }

    static func lookup(_ key: String) -> Predicate? {
        lock.lock()
        defer { lock.unlock() }
        return table[key]
    }

    static func isSentinel(_ s: String) -> Bool {
        s.hasPrefix(sentinelPrefix)
    }
}

// MARK: - Cursor

/// Character-by-character scanner with a minimal API for the parser. Uses
/// `String.Index` so it's safe on Unicode strings (curly quotes, emoji labels).
private struct Cursor {
    let source: String
    var index: String.Index

    init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    var isAtEnd: Bool { index >= source.endIndex }

    func peek() -> Character? {
        isAtEnd ? nil : source[index]
    }

    mutating func advance() {
        if !isAtEnd { index = source.index(after: index) }
    }

    mutating func skipSpaces() {
        while let c = peek(), c.isWhitespace { advance() }
    }

    /// Skip only horizontal whitespace (space/tab) without consuming newlines.
    /// Used inside `near:@e42:50` where a trailing newline shouldn't be eaten.
    mutating func skipSpacesInline() {
        while let c = peek(), c == " " || c == "\t" { advance() }
    }

    /// Read the field name on the LHS of the operator. Field chars are
    /// `[a-zA-Z_]`. Stops at the first non-field character (the operator).
    mutating func readFieldName() -> String {
        var name = ""
        while let c = peek() {
            if c.isLetter || c == "_" {
                name.append(c)
                advance()
            } else {
                break
            }
        }
        return name
    }

    /// Read a value token — quoted ("..." with embedded escapes) or
    /// whitespace-delimited. Stops at whitespace or the group close paren.
    mutating func readValueToken() throws -> String {
        if peek() == "\"" {
            return try readQuoted()
        }
        var out = ""
        while let c = peek() {
            if c.isWhitespace { break }
            if c == ")" { break }
            out.append(c)
            advance()
        }
        if out.isEmpty {
            throw QueryError.malformedPredicate("", reason: "expected value")
        }
        return out
    }

    private mutating func readQuoted() throws -> String {
        guard peek() == "\"" else {
            throw QueryError.malformedPredicate("\"", reason: "expected '\"'")
        }
        advance()
        var out = ""
        while let c = peek() {
            if c == "\\" {
                advance()
                if let next = peek() {
                    switch next {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default:
                        out.append("\\")
                        out.append(next)
                    }
                    advance()
                }
                continue
            }
            if c == "\"" {
                advance()
                return out
            }
            out.append(c)
            advance()
        }
        throw QueryError.malformedPredicate(out, reason: "unterminated quoted string")
    }

    func peekRemaining() -> Substring {
        source[index...]
    }
}
