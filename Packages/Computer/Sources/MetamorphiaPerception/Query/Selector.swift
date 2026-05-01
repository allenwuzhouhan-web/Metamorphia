import Foundation
import CoreGraphics

// MARK: - Selector
//
// Rank 6 — Query API.
//
// `Selector` is the parsed form of a raw selector string (e.g.
// `"role:button label*save in:\"Toolbar\""`). The string is lowered into a
// flat list of `Predicate`s that the query engine evaluates per element. All
// predicates are AND-ed at the top level — use multiple queries if you need
// OR. Grouping via `()` also produces an AND-set of the inner predicates.
//
// Grammar (full BNF lives in `SelectorParser.swift`):
//
// ```
// selector := term (' '+ term)*
// term     := field ':' value
//           | field '~' '/' regex '/'
//           | field '*' value
//           | field '^' value
//           | field '=' value
//           | field '>' number
//           | field '<' number
//           | '!' term
//           | ref
//           | '(' selector ')'
// ```
//
// The parser is hand-written — no regex shortcuts, no `components(separatedBy:)`
// tokenizing — so quoted strings with spaces, nested groups and chained
// modifiers (`!role:button`, `!(role:button label:Save)`) all round-trip.

/// A parsed, validated selector. The `raw` property is retained for telemetry /
/// error reporting so callers can quote back the user's original string.
public struct Selector: Sendable {
    /// Exactly the input string the parser was given (whitespace + quoting
    /// preserved). Useful for logs, errors, and "echo the selector" output.
    public let raw: String

    /// Flattened list of predicates to AND. A group `(...)` contributes its
    /// predicates directly into this list — there's no explicit `AND` node.
    public let predicates: [Predicate]

    public init(raw: String, predicates: [Predicate]) {
        self.raw = raw
        self.predicates = predicates
    }
}

// MARK: - Predicate

/// One per-element match rule. `QueryEngine.execute` evaluates every predicate
/// against each candidate element and emits the element only when every
/// predicate scores > 0.
///
/// Most predicates are strict (score = 1.0 or 0.0). `labelFuzzyMatches` is the
/// one soft predicate — it produces a 0…1 similarity and the element's
/// `matchScore` is the product across all predicates. The grammar doesn't
/// expose fuzzy matching directly; callers opt in by constructing the
/// `Predicate.labelFuzzyMatches` variant manually.
public enum Predicate: Sendable {
    /// Role equals (strict, case-insensitive on raw value).
    case role(ElementRole)

    /// Role is in a set (strict). Convenience for unions —
    /// `role:button role:link` would be contradictory in AND, so the parser
    /// never emits this variant. Exposed for API callers.
    case roleIn(Set<ElementRole>)

    /// Label exact-match (`label="Save"` syntax). `caseInsensitive: true` is
    /// the default for the shortcut `label:` and `label=`; the parser emits
    /// `false` only for `label="..."` when the grammar flags a sensitive match.
    case labelEquals(String, caseInsensitive: Bool)

    /// Label regex match (`label~/pattern/`). The regex is compiled at parse
    /// time; invalid patterns raise `QueryError.invalidRegex` at parse time
    /// rather than deferring to execute.
    case labelRegex(NSRegularExpression)

    /// Label contains substring (`label*save`). Case-insensitive by default
    /// because "contains" is almost always used fuzzy-ly.
    case labelContains(String, caseInsensitive: Bool)

    /// Label starts-with (`label^Open`). Matches on normalized case.
    case labelStartsWith(String, caseInsensitive: Bool)

    /// Value contains substring (free-text match against `element.value`).
    case valueContains(String, caseInsensitive: Bool)

    /// Immediate parent's label matches. Looks up `parentRef` in the filtered
    /// map; no ancestor chain climbing. `in:` is the ancestor-climbing form.
    case parentLabel(String, caseInsensitive: Bool)

    /// Some ancestor's label matches (walks `parentRef` chain).
    case inContainer(String, caseInsensitive: Bool)

    /// Element.depth > n.
    case depthGreater(Int)

    /// Element.depth < n.
    case depthLess(Int)

    /// Element.depth == n. Used when the user types `depth:3`.
    case depthEquals(Int)

    /// `true` → element has no `.offScreen` state bit and has non-zero
    /// bounds. `false` → the inverse.
    case visible(Bool)

    /// `true` → role.isInteractive. `false` → everything else.
    case interactive(Bool)

    /// Element's state contains this bit.
    case hasState(ElementState)

    /// Element's state does NOT contain this bit.
    case lacksState(ElementState)

    /// Element's actions include this action kind.
    case hasAction(ElementAction)

    /// Element.displayIndex == n.
    case displayIndex(Int)

    /// Element.ref == ref — used to anchor a query on a known pick.
    case refEquals(ElementRef)

    /// Element.clickPoint (or bounds center) lies within `radius` of the
    /// matching element's clickPoint. Two-pass: the engine resolves `ref`
    /// inside the filtered map before scoring.
    case nearRef(ElementRef, radius: CGFloat)

    /// Element's bounds contains the given point (screen coordinates).
    case boundsContains(CGPoint)

    /// Stabilizer tier equals this value.
    case tier(IdentityTier)

    /// Element.confidence > threshold. Shortcut via `confidence:>0.8`.
    case confidenceAbove(Float)

    /// Explicit soft match: trigram/Jaccard similarity between tokenized
    /// labels. Emitted only by direct API consumers (see `Selector.init`).
    case labelFuzzyMatches(String, threshold: Float)
}

// MARK: - QueryError

/// All failure modes from the parser. Callers typically surface the
/// `description` back to the user; CLI consumers may want structured access to
/// `reason` for pretty-print formatting.
public enum QueryError: Error, Sendable, CustomStringConvertible, Equatable {
    /// Empty or whitespace-only input. Parsers should treat this as invalid;
    /// a no-op selector has to be expressed as a specific field-value pair.
    case emptySelector

    /// General "I couldn't parse this term" with the offending token and a
    /// human hint. `reason` is intentionally freeform.
    case malformedPredicate(String, reason: String)

    /// The field name (LHS of `:`) isn't one the grammar knows about.
    case unknownField(String)

    /// A regex pattern in `label~/.../` failed `NSRegularExpression` compile.
    case invalidRegex(String)

    /// A role value (RHS of `role:`) didn't match any `ElementRole` rawValue.
    case invalidRoleValue(String)

    /// A state value (RHS of `state:`) didn't match any `ElementState` name.
    case invalidStateValue(String)

    public var description: String {
        switch self {
        case .emptySelector:
            return "selector is empty"
        case .malformedPredicate(let token, let reason):
            return "malformed predicate near '\(token)': \(reason)"
        case .unknownField(let field):
            return "unknown field '\(field)' (try role, label, value, parent, in, depth, visible, interactive, state, action, display, ref, near, tier, confidence)"
        case .invalidRegex(let pattern):
            return "invalid regex '\(pattern)'"
        case .invalidRoleValue(let value):
            return "unknown role '\(value)'"
        case .invalidStateValue(let value):
            return "unknown state '\(value)'"
        }
    }

    /// A coarse `at` offset into the source selector string for error output.
    /// The parser fills this in at throw-site for `malformedPredicate` errors
    /// by wrapping in `QueryEngine.parse`'s error shape — kept as 0 here.
    public var at: Int { 0 }
}
