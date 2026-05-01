import CoreGraphics
import CryptoKit
import Foundation

// MARK: - Element Reference

/// Compact, stable reference to a screen element. Uses `@e1` format for token efficiency.
public struct ElementRef: Hashable, Sendable, CustomStringConvertible {
    public let index: Int

    public var description: String { "@e\(index)" }

    public init(index: Int) {
        self.index = index
    }

    /// Parse "@e5" back into an ElementRef.
    public static func parse(_ string: String) -> ElementRef? {
        guard string.hasPrefix("@e"),
              let idx = Int(string.dropFirst(2)) else { return nil }
        return ElementRef(index: idx)
    }
}

// MARK: - Identity Tier

/// Which signal produced this ref's identity. Higher tiers = more stable.
/// Downstream ranks (delta encoding, vision diffs) use this to decide how aggressively
/// to trust a ref for cross-snapshot matching.
public enum IdentityTier: Sendable, Equatable {
    /// Developer-assigned AX identifier attribute. Most stable.
    case identifier
    /// CSS selector joined from a browser DOM node. Drives Phase-C browser
    /// flows — `#id` / `[data-testid]` / `[aria-label]` selectors are
    /// near-permanent within a site's lifetime.
    case dom
    /// Hierarchical menu-bar path (`File > Save`). Stable for the app's
    /// lifetime; exact strings are a natural ref.
    case menu
    /// Non-empty label + ancestry hash. Survives layout shifts; siblings disambiguated.
    case label
    /// Parent-anchored relative position (10% grid of parent bounds) + sibling index.
    case position
    /// Perceptual visual fingerprint (dHash of the element pixel crop) plus
    /// a SHA-1 prefix of the OCR text and a 50 px screen-grid bucket.
    /// The fallback for canvas-drawn apps and OCR-only regions where the
    /// AX tree and DOM are both absent.
    case visual
    /// Pure (bundle, role, 50px grid, depth) fallback. Unstable across reflows.
    case fallback

    /// Tier code used in the cross-session identity-key grammar.
    /// Mapping per the design doc: identifier=t1, dom=t2, menu=t3,
    /// label=t4, position=t5, visual=t6, fallback=tF.
    public var code: String {
        switch self {
        case .identifier: return "t1"
        case .dom:        return "t2"
        case .menu:       return "t3"
        case .label:      return "t4"
        case .position:   return "t5"
        case .visual:     return "t6"
        case .fallback:   return "tF"
        }
    }
}

// MARK: - Ref Assignment Input

/// Full identity context required by `RefStabilizer.assign`.
///
/// The stabilizer walks a tier cascade (identifier → label → position → fallback),
/// picking the strongest signal available for each element. Callers (e.g.
/// `PerceptionPipeline.buildElements`) are responsible for gathering this context
/// before each assign.
public struct RefAssignment: Sendable {
    public let bundleID: String?
    public let role: ElementRole
    public let label: String
    /// AX `AXIdentifier` attribute — developer-assigned stable ID. Empty if unavailable.
    public let identifier: String
    public let bounds: CGRect?
    /// Parent element's bounds, for Tier-3 anchored-position computation.
    public let parentBounds: CGRect?
    /// Rolling hash of ancestor (role, label-prefix) chain. See `AncestryHash.compute`.
    public let ancestryHash: UInt64
    /// Depth in the element tree (matches `ScreenElement.depth`).
    public let depth: Int
    /// Ordinal among same-role siblings under this parent. Deterministic tiebreaker.
    public let siblingIndex: Int
    /// CSS selector built by `BrowserDOMJoiner` when the element is inside a
    /// browser window and a matching DOM node was found. Drives Tier 2
    /// (`.dom`) identity — the most stable rank for web elements with a
    /// durable id / data-testid / aria-label.
    public let domSelector: String?
    /// Hierarchical menu-bar path like `["File", "Save"]`. Drives Tier 3
    /// (`.menu`) identity. Nil for non-menu elements.
    public let menuPath: [String]?
    /// 8×8 difference hash (`ScreenCapture.dHash`) of the element's pixel
    /// region. Drives Tier 6 (`.visual`) identity for OCR elements and
    /// AX-sparse apps where the tree alone doesn't disambiguate. Nil when
    /// the screenshot wasn't retained or the region could not be cropped.
    public let visualDHash: UInt64?
    /// OCR text for which we computed the visual hash. Included in the
    /// Tier-6 body as a SHA-1 prefix so the identity key stays stable
    /// across reflows that preserve the text label.
    public let visualText: String?
    /// Screen-space bucket `(bx, by) = (midX/50, midY/50)` used alongside
    /// `visualDHash` in the Tier-6 body. Tolerates sub-bucket motion
    /// without invalidating the key.
    public let visualGridBucket: VisualGridBucket?

    /// Optional tuple-free wrapper so `RefAssignment` stays pure-value.
    public struct VisualGridBucket: Sendable, Hashable {
        public let x: Int
        public let y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    public init(
        bundleID: String?,
        role: ElementRole,
        label: String,
        identifier: String,
        bounds: CGRect?,
        parentBounds: CGRect?,
        ancestryHash: UInt64,
        depth: Int,
        siblingIndex: Int,
        domSelector: String? = nil,
        menuPath: [String]? = nil,
        visualDHash: UInt64? = nil,
        visualText: String? = nil,
        visualGridBucket: VisualGridBucket? = nil
    ) {
        self.bundleID = bundleID
        self.role = role
        self.label = label
        self.identifier = identifier
        self.bounds = bounds
        self.parentBounds = parentBounds
        self.ancestryHash = ancestryHash
        self.depth = depth
        self.siblingIndex = siblingIndex
        self.domSelector = domSelector
        self.menuPath = menuPath
        self.visualDHash = visualDHash
        self.visualText = visualText
        self.visualGridBucket = visualGridBucket
    }
}

// MARK: - Ancestry Hash

/// Deterministic rolling hash over a chain of `(role, label)` ancestor tuples.
///
/// Used by `RefStabilizer` as part of the identity key for Tier 2 and Tier 3 elements,
/// so that two elements with the same label in different container hierarchies get
/// distinct refs. Caps at 6 ancestors and truncates labels to 20 chars to keep the
/// hash cheap and resilient to deep trees with noisy labels.
public enum AncestryHash {
    /// Maximum ancestors considered. Beyond this, deeper context is truncated.
    public static let maxDepth = 6
    /// Maximum label prefix length mixed into the hash.
    public static let labelPrefix = 20

    /// Empty-chain hash (root element). Stable sentinel so callers can pass `[]`.
    public static let empty: UInt64 = 5381

    /// Rolling djb2 over `[(role.rawValue, label[:20])]`, oldest ancestor first.
    ///
    /// - Parameter chain: The ancestor chain, root-first. Truncated to the last 6 entries
    ///   if longer (keeps the immediate parents, which are more discriminative).
    public static func compute(from chain: [(role: ElementRole, label: String)]) -> UInt64 {
        var hash: UInt64 = empty
        // Keep the LAST maxDepth entries (immediate parents carry more signal than root).
        let effective = chain.suffix(maxDepth)
        for entry in effective {
            mixString(entry.role.rawValue, into: &hash)
            // Separator byte to prevent "ab"+"c" colliding with "a"+"bc".
            hash = ((hash &<< 5) &+ hash) &+ 0x1F
            let prefix = String(entry.label.prefix(labelPrefix))
            mixString(prefix, into: &hash)
            // End-of-entry separator.
            hash = ((hash &<< 5) &+ hash) &+ 0x1E
        }
        return hash
    }

    @inline(__always)
    fileprivate static func mixString(_ s: String, into hash: inout UInt64) {
        for byte in s.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
    }
}

// MARK: - Ref Stabilizer

/// Maintains stable `@e` indices across snapshots so the same element keeps the same ref
/// even through layout reflows, parent resizes, and duplicate-label ambiguities.
///
/// Identity is computed via a tiered cascade (see `IdentityTier`). For each element the
/// stabilizer picks the strongest tier whose key is not yet claimed in this snapshot,
/// then reuses the previous snapshot's index if that key was seen before. This yields
/// deterministic, collision-free refs that only rebase when an element truly changes
/// identity (e.g., a fallback-tier element crosses a 50 px bucket).
///
/// Thread-safe via `NSLock`. All public methods are safe from concurrent queues.
public final class RefStabilizer: @unchecked Sendable {

    // MARK: Per-tier mappings (current snapshot being built)

    // Per-tier maps let us probe each tier independently during assignment.
    // Keys are tier-specific hashes; values are the ref index chosen for that key.
    private var currentByIdentifier: [UInt64: Int] = [:]
    private var currentByDom: [UInt64: Int] = [:]
    private var currentByMenu: [UInt64: Int] = [:]
    private var currentByLabel: [UInt64: Int] = [:]
    private var currentByPosition: [UInt64: Int] = [:]
    private var currentByVisual: [UInt64: Int] = [:]
    private var currentByFallback: [UInt64: Int] = [:]

    // Per-tier label-occurrence counters (scope: current snapshot, cleared on commit).
    // Key is the pre-occurrence-disambiguation label hash; value is the next occurrence ordinal.
    private var labelOccurrenceCounter: [UInt64: Int] = [:]

    // MARK: Per-tier mappings (last committed snapshot)

    private var previousByIdentifier: [UInt64: Int] = [:]
    private var previousByDom: [UInt64: Int] = [:]
    private var previousByMenu: [UInt64: Int] = [:]
    private var previousByLabel: [UInt64: Int] = [:]
    private var previousByPosition: [UInt64: Int] = [:]
    private var previousByVisual: [UInt64: Int] = [:]
    private var previousByFallback: [UInt64: Int] = [:]

    // MARK: Per-ref metadata

    // Ref index → (tier, score) for the current snapshot.
    private var currentTierByRef: [Int: IdentityTier] = [:]
    private var currentScoreByRef: [Int: Float] = [:]

    // Ref index → (tier, score) for the last committed snapshot. Introspection reads
    // these so callers can query `identityTier(for:)` between snapshots.
    private var previousTierByRef: [Int: IdentityTier] = [:]
    private var previousScoreByRef: [Int: Float] = [:]

    // Ref index → canonical identity-key string, and its reverse map. Populated during
    // `assign` alongside the tier choice so downstream callers can serialize refs to
    // a cross-session durable form (ElementDatabase upserts, WorkflowRecorder steps)
    // and resolve a stored key back to the ref issued this snapshot.
    private var currentBodyByRef: [Int: String] = [:]
    private var previousBodyByRef: [Int: String] = [:]
    private var currentByKey: [String: Int] = [:]
    private var previousByKey: [String: Int] = [:]

    // MARK: Ref allocation

    private var nextIndex: Int = 1
    private let lock = NSLock()

    public init() {}

    // MARK: - Assignment

    /// Assign a stable ref for an element with full identity context. Same identity
    /// across snapshots → same ref. Thread-safe.
    public func assign(_ input: RefAssignment) -> ElementRef {
        lock.lock()
        defer { lock.unlock() }

        // Tier 1: explicit AX identifier.
        if !input.identifier.isEmpty {
            let key = hashIdentifier(
                bundleID: input.bundleID,
                role: input.role,
                identifier: input.identifier,
                ancestryHash: input.ancestryHash
            )
            if let idx = claim(key: key, in: &currentByIdentifier, previous: previousByIdentifier) {
                recordTier(idx, tier: .identifier)
                recordBody(idx, tier: .identifier, input: input, occurrence: 0, positionBucket: nil)
                return ElementRef(index: idx)
            }
            // Collision inside this snapshot at tier 1 (two elements with same identifier
            // under same ancestry — rare but possible in broken AX trees). Fall through.
        }

        // Tier 3: menu-bar path. Menu items have stable hierarchical strings
        // that are a natural ref — re-walking the live menu bar by path is
        // exactly how `MenuBarReader.invoke` dispatches. Probe before DOM
        // because a menu item is structurally unambiguous: it can't also be
        // a DOM node.
        if let menuPath = input.menuPath, !menuPath.isEmpty {
            let key = hashMenu(bundleID: input.bundleID, path: menuPath)
            if let idx = claim(key: key, in: &currentByMenu, previous: previousByMenu) {
                recordTier(idx, tier: .menu)
                recordBody(idx, tier: .menu, input: input, occurrence: 0, positionBucket: nil)
                return ElementRef(index: idx)
            }
        }

        // Tier 2: DOM selector (browser elements joined via BrowserDOMJoiner).
        // Probe after menu/identifier because `#id` + data-testid selectors
        // are stable across reflows but still less stable than an explicit
        // AXIdentifier (which implies the developer shipped a named hook).
        if let domSelector = input.domSelector, !domSelector.isEmpty {
            let key = hashDom(
                bundleID: input.bundleID,
                role: input.role,
                selector: domSelector
            )
            if let idx = claim(key: key, in: &currentByDom, previous: previousByDom) {
                recordTier(idx, tier: .dom)
                recordBody(idx, tier: .dom, input: input, occurrence: 0, positionBucket: nil)
                return ElementRef(index: idx)
            }
        }

        // Tier 4: non-empty label + ancestry + occurrence disambiguator.
        if !input.label.isEmpty {
            let baseLabelKey = hashLabelBase(
                bundleID: input.bundleID,
                role: input.role,
                label: input.label,
                ancestryHash: input.ancestryHash
            )
            // Count occurrences of this base key in the current snapshot — deterministic
            // tiebreaker for duplicate-label siblings (e.g., two "Close" buttons in the
            // same dialog).
            let occurrence = labelOccurrenceCounter[baseLabelKey, default: 0]
            labelOccurrenceCounter[baseLabelKey] = occurrence + 1
            let key = mixInOccurrence(baseLabelKey, occurrence: occurrence)
            if let idx = claim(key: key, in: &currentByLabel, previous: previousByLabel) {
                recordTier(idx, tier: .label)
                recordBody(idx, tier: .label, input: input, occurrence: occurrence, positionBucket: nil)
                return ElementRef(index: idx)
            }
            // Tier-2 collision within the snapshot shouldn't happen given the occurrence
            // counter, but fall through defensively.
        }

        // Tier 6: visual fingerprint. Probe BEFORE position so elements with
        // a real pixel signature (dHash over their cropped region, SHA-1 of
        // their OCR text, 50 pt screen bucket) get a stable key instead of
        // being bucketed by coarse position. The cascade's goal is "most
        // specific signal wins" — visual is strictly more specific than the
        // position tier's parent-anchored 10% grid. Stability score is
        // still 0.35 because pixel-level features are noisier than AX
        // structure, but the ordering here is about *preference*, not
        // confidence.
        if let dhash = input.visualDHash {
            let key = hashVisual(
                bundleID: input.bundleID,
                role: input.role,
                dHash: dhash,
                text: input.visualText ?? "",
                bucket: input.visualGridBucket
            )
            if let idx = claim(key: key, in: &currentByVisual, previous: previousByVisual) {
                recordTier(idx, tier: .visual)
                recordBody(idx, tier: .visual, input: input, occurrence: 0, positionBucket: nil)
                return ElementRef(index: idx)
            }
        }

        // Tier 5: parent-anchored position + sibling index. Fires when
        // visual wasn't available and the other signals (label, dom, menu,
        // identifier) already failed. Requires bounds — without them the
        // position hash has nothing to hold onto and we fall to tier F.
        if let bounds = input.bounds {
            let key = hashPosition(
                bundleID: input.bundleID,
                role: input.role,
                ancestryHash: input.ancestryHash,
                bounds: bounds,
                parentBounds: input.parentBounds,
                siblingIndex: input.siblingIndex
            )
            if let idx = claim(key: key, in: &currentByPosition, previous: previousByPosition) {
                recordTier(idx, tier: .position)
                let bucket = parentAnchoredBucket(bounds: bounds, parentBounds: input.parentBounds)
                recordBody(idx, tier: .position, input: input, occurrence: 0, positionBucket: bucket)
                return ElementRef(index: idx)
            }
        }

        // Tier F: coarse (bundle, role, 50 px grid, depth). Weakest — marked fallback.
        let key = hashFallback(
            bundleID: input.bundleID,
            role: input.role,
            bounds: input.bounds,
            depth: input.depth,
            siblingIndex: input.siblingIndex
        )
        if let idx = claim(key: key, in: &currentByFallback, previous: previousByFallback) {
            recordTier(idx, tier: .fallback)
            recordBody(idx, tier: .fallback, input: input, occurrence: 0, positionBucket: nil)
            return ElementRef(index: idx)
        }

        // Last-resort: guaranteed-unique by stepping the counter. Nothing routes here
        // in normal code paths — the tier 4 key already incorporates a sibling index —
        // but we keep a safety net so assign() never returns a ref that collides within
        // the current snapshot.
        let idx = nextIndex
        nextIndex += 1
        recordTier(idx, tier: .fallback)
        recordBody(idx, tier: .fallback, input: input, occurrence: 0, positionBucket: nil)
        return ElementRef(index: idx)
    }

    // MARK: - Snapshot lifecycle

    /// Rotate current → previous so the next snapshot can reuse refs by identity.
    ///
    /// Also rebases `nextIndex` to one past the highest ref index *actually
    /// issued* in the previous snapshot. Without this, every skipped index
    /// (elements that failed the claim cascade, or a call pattern that
    /// stepped the counter without storing) was permanently burned — after
    /// an hour of 10 Hz ticks the LLM was seeing refs like `@e52394`,
    /// inflating every token budget. Rebasing reclaims unused indices
    /// while preserving the cross-snapshot stability that `previousByKey`
    /// already depends on (identity keys revive their last-issued index
    /// via `claim` regardless of the counter's starting point).
    public func commitSnapshot() {
        lock.lock()
        defer { lock.unlock() }

        previousByIdentifier = currentByIdentifier
        previousByDom = currentByDom
        previousByMenu = currentByMenu
        previousByLabel = currentByLabel
        previousByPosition = currentByPosition
        previousByVisual = currentByVisual
        previousByFallback = currentByFallback
        previousTierByRef = currentTierByRef
        previousScoreByRef = currentScoreByRef
        previousBodyByRef = currentBodyByRef
        previousByKey = currentByKey

        // Reclaim unused indices. The next snapshot starts its counter one
        // past the largest index *still in use*; keys that were seen in
        // the just-committed snapshot still revive their exact index via
        // the previous* maps in claim().
        if let maxIssued = currentTierByRef.keys.max() {
            nextIndex = maxIssued + 1
        } else {
            nextIndex = 1
        }

        currentByIdentifier.removeAll(keepingCapacity: true)
        currentByDom.removeAll(keepingCapacity: true)
        currentByMenu.removeAll(keepingCapacity: true)
        currentByLabel.removeAll(keepingCapacity: true)
        currentByPosition.removeAll(keepingCapacity: true)
        currentByVisual.removeAll(keepingCapacity: true)
        currentByFallback.removeAll(keepingCapacity: true)
        labelOccurrenceCounter.removeAll(keepingCapacity: true)
        currentTierByRef.removeAll(keepingCapacity: true)
        currentScoreByRef.removeAll(keepingCapacity: true)
        currentBodyByRef.removeAll(keepingCapacity: true)
        currentByKey.removeAll(keepingCapacity: true)
    }

    /// Clear all state. Call when switching apps or after a major screen change so
    /// stale refs don't try to match into a totally different element tree.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        currentByIdentifier.removeAll()
        currentByDom.removeAll()
        currentByMenu.removeAll()
        currentByLabel.removeAll()
        currentByPosition.removeAll()
        currentByVisual.removeAll()
        currentByFallback.removeAll()
        previousByIdentifier.removeAll()
        previousByDom.removeAll()
        previousByMenu.removeAll()
        previousByLabel.removeAll()
        previousByPosition.removeAll()
        previousByVisual.removeAll()
        previousByFallback.removeAll()
        labelOccurrenceCounter.removeAll()
        currentTierByRef.removeAll()
        currentScoreByRef.removeAll()
        previousTierByRef.removeAll()
        previousScoreByRef.removeAll()
        currentBodyByRef.removeAll()
        previousBodyByRef.removeAll()
        currentByKey.removeAll()
        previousByKey.removeAll()
        nextIndex = 1
    }

    // MARK: - Introspection

    /// The identity tier used for `ref` during the current or last committed snapshot.
    /// Returns `nil` if the stabilizer never issued this ref.
    public func identityTier(for ref: ElementRef) -> IdentityTier? {
        lock.lock()
        defer { lock.unlock() }
        if let t = currentTierByRef[ref.index] { return t }
        return previousTierByRef[ref.index]
    }

    /// A numeric 0–1 score correlated with how confident we are that this ref will
    /// survive the next snapshot. Downstream (Rank 2 delta encoding, Rank 8 vision
    /// diffs) use this threshold to decide delta-vs.-full payloads.
    public func stabilityScore(for ref: ElementRef) -> Float {
        lock.lock()
        defer { lock.unlock() }
        if let s = currentScoreByRef[ref.index] { return s }
        if let s = previousScoreByRef[ref.index] { return s }
        return 0.0
    }

    /// Canonical cross-session identity key for this ref. Built at `assign` time so
    /// the string is stable for the whole snapshot lifetime. Shape:
    /// `app=<bundle>|<tierCode>|<tier-specific body>`. Returns nil if the
    /// stabilizer never issued this ref.
    public func identityKey(for ref: ElementRef) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return currentBodyByRef[ref.index] ?? previousBodyByRef[ref.index]
    }

    /// Reverse lookup: given an identity key issued by this stabilizer in the
    /// current or previous snapshot, return the ref currently associated with
    /// it. Used by `ElementResolver` when the agent hands a stale `@eN`
    /// alongside a stored identity_key from ElementDatabase or a recorded
    /// `WorkflowStep`.
    ///
    /// Aliasing safety (critic H1): the previous-snapshot path is only valid
    /// when the returned index has not already been re-issued to a different
    /// element this tick. If it has, the stored key is stale — downstream
    /// would resolve it to the wrong element. Returning nil forces the
    /// caller to fall through to fuzzy disambiguation via
    /// `ElementResolver`'s later cascade steps.
    public func resolve(key: String) -> ElementRef? {
        lock.lock()
        defer { lock.unlock() }
        if let idx = currentByKey[key] { return ElementRef(index: idx) }
        if let idx = previousByKey[key], currentTierByRef[idx] == nil {
            return ElementRef(index: idx)
        }
        return nil
    }

    /// Snapshot of every ref's currently-known identity tier. Merges the
    /// in-flight snapshot with the last committed one, preferring the
    /// in-flight value when a ref was re-issued this pass. Used by
    /// downstream filters (Rank 1 visibility filter, Rank 2 delta encoder)
    /// to consult tier without hammering `identityTier(for:)` under the
    /// stabilizer lock.
    public func tierSnapshot() -> [ElementRef: IdentityTier] {
        lock.lock()
        defer { lock.unlock() }
        var out: [ElementRef: IdentityTier] = [:]
        out.reserveCapacity(previousTierByRef.count + currentTierByRef.count)
        for (idx, tier) in previousTierByRef {
            out[ElementRef(index: idx)] = tier
        }
        // Current wins on collision (ref was re-issued this snapshot).
        for (idx, tier) in currentTierByRef {
            out[ElementRef(index: idx)] = tier
        }
        return out
    }

    // MARK: - Internal helpers

    /// Claim a ref for `key` in the given current-tier map, preferring the previous
    /// snapshot's index if it exists (stability across snapshots). Returns `nil` if
    /// `key` is already claimed in the current snapshot (caller should try next tier).
    private func claim(
        key: UInt64,
        in current: inout [UInt64: Int],
        previous: [UInt64: Int]
    ) -> Int? {
        // Collision in current snapshot → caller cascades to a lower tier.
        if current[key] != nil { return nil }

        // Prefer the previous snapshot's index for this key. But if that index is
        // already taken in the current snapshot (some other element at a different
        // tier claimed it first — e.g., its identifier beat our label key), we must
        // allocate fresh to avoid aliasing two elements to the same @e.
        if let prev = previous[key], !currentTierByRef.keys.contains(prev) {
            current[key] = prev
            // Bump nextIndex past the revived index so we never issue a duplicate.
            if prev >= nextIndex { nextIndex = prev + 1 }
            return prev
        }

        let idx = nextIndex
        nextIndex += 1
        current[key] = idx
        return idx
    }

    private func recordTier(_ idx: Int, tier: IdentityTier) {
        currentTierByRef[idx] = tier
        currentScoreByRef[idx] = Self.score(for: tier)
    }

    /// Build and store the canonical identity-key body for `idx` under the chosen
    /// tier. Writes into both `currentBodyByRef` (ref → key) and `currentByKey`
    /// (key → ref) so `identityKey(for:)` / `resolve(key:)` are both O(1).
    ///
    /// The body grammar is intentionally a flat key=value,... blob so downstream
    /// persistence layers (ElementDatabase.identity_key column, WorkflowStep JSON)
    /// can pattern-match with `hasPrefix` and simple splits without a parser.
    private func recordBody(
        _ idx: Int,
        tier: IdentityTier,
        input: RefAssignment,
        occurrence: Int,
        positionBucket: (Int, Int)?
    ) {
        let body = Self.buildIdentityKey(
            tier: tier,
            input: input,
            occurrence: occurrence,
            positionBucket: positionBucket
        )
        currentBodyByRef[idx] = body
        // If two different assignments produce the same body (shouldn't in practice —
        // tiers are disjoint by hash — but defensive), prefer the first one so refs
        // remain deterministic. A subsequent assign() with the same body returns
        // the same index via `claim`.
        if currentByKey[body] == nil {
            currentByKey[body] = idx
        }
    }

    /// Deterministic construction of the identity-key body from the full
    /// assignment input. Exposed `fileprivate`-esque via `static` so tests and
    /// callers that want to preview the key before `assign` can invoke the
    /// same builder.
    static func buildIdentityKey(
        tier: IdentityTier,
        input: RefAssignment,
        occurrence: Int,
        positionBucket: (Int, Int)?
    ) -> String {
        let app = input.bundleID ?? "unknown"
        let prefix = "app=\(app)|\(tier.code)|"
        let ancHex = String(input.ancestryHash, radix: 16)
        let role = input.role.rawValue

        switch tier {
        case .identifier:
            return prefix + "axid=\(input.identifier),role=\(role),anc=\(ancHex)"

        case .dom:
            let sel = input.domSelector ?? ""
            return prefix + "dom=\(sel),role=\(role)"

        case .menu:
            // Encode the path as base64url-of-JSON so menu items with
            // commas/quotes/unicode round-trip without ambiguity.
            let path = input.menuPath ?? []
            let encoded = base64URLEncode(menuPath: path)
            return prefix + "menu=\(encoded)"

        case .label:
            let normalized = normalizeLabel(input.label)
            return prefix + "label=\(normalized),role=\(role),anc=\(ancHex),occ=\(occurrence)"

        case .position:
            let bx: Int
            let by: Int
            if let pb = positionBucket {
                bx = pb.0; by = pb.1
            } else {
                bx = 0; by = 0
            }
            return prefix + "pos=x\(bx)y\(by),sib=\(input.siblingIndex),role=\(role),anc=\(ancHex)"

        case .visual:
            let dhashHex = input.visualDHash.map { String($0, radix: 16) } ?? "0"
            let paddedHash = String(repeating: "0", count: max(0, 16 - dhashHex.count)) + dhashHex
            let ocrSHA = sha1Prefix12(input.visualText ?? "")
            let bx = input.visualGridBucket?.x ?? 0
            let by = input.visualGridBucket?.y ?? 0
            return prefix + "ocr=\(ocrSHA),grid=x\(bx)y\(by),dhash=\(paddedHash),role=\(role)"

        case .fallback:
            let gx: Int
            let gy: Int
            if let b = input.bounds {
                gx = Int((b.midX / 50).rounded(.down))
                gy = Int((b.midY / 50).rounded(.down))
            } else {
                gx = 0; gy = 0
            }
            return prefix + "grid=x\(gx)y\(gy),depth=\(input.depth),sib=\(input.siblingIndex),role=\(role)"
        }
    }

    // MARK: - Helpers for the new tier bodies

    /// First 12 hex chars of SHA-1(text). Stable across sessions — used as
    /// the compact "did we see this OCR text before?" probe in the Tier-6
    /// body. Empty input maps to the SHA-1 of the empty string's prefix.
    private static func sha1Prefix12(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = Insecure.SHA1.hash(data: data)
        return digest.prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// base64url without padding — safer than raw JSON in the key body
    /// because identity keys get stuffed into SQL columns and log lines
    /// where commas/quotes would fight the outer format.
    private static func base64URLEncode(menuPath: [String]) -> String {
        guard let json = try? JSONSerialization.data(
            withJSONObject: menuPath, options: []
        ) else { return "" }
        return json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercased, whitespace-collapsed, 40-char-truncated label. Keeps the key
    /// stable across trivial presentation changes (trailing ellipsis, casing).
    private static func normalizeLabel(_ raw: String) -> String {
        let lower = raw.lowercased()
        let collapsed = lower
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(40))
    }

    private static func score(for tier: IdentityTier) -> Float {
        switch tier {
        case .identifier: return 1.0
        case .menu:       return 0.9
        case .dom:        return 0.85
        case .label:      return 0.75
        case .position:   return 0.5
        case .visual:     return 0.35
        case .fallback:   return 0.2
        }
    }

    // MARK: - Hashing (per-tier)

    private func hashIdentifier(
        bundleID: String?,
        role: ElementRole,
        identifier: String,
        ancestryHash: UInt64
    ) -> UInt64 {
        var h: UInt64 = 1_125_899_906_842_597 // salt to separate tiers
        mixString(bundleID ?? "", into: &h)
        mixString(role.rawValue, into: &h)
        mixString(identifier, into: &h)
        mixUInt64(ancestryHash, into: &h)
        return h
    }

    private func hashDom(
        bundleID: String?,
        role: ElementRole,
        selector: String
    ) -> UInt64 {
        var h: UInt64 = 9_007_199_254_740_997 // fresh salt per tier
        mixString(bundleID ?? "", into: &h)
        mixString(role.rawValue, into: &h)
        mixString(selector, into: &h)
        return h
    }

    private func hashMenu(bundleID: String?, path: [String]) -> UInt64 {
        var h: UInt64 = 618_033_988_749_894_848 // another distinct salt
        mixString(bundleID ?? "", into: &h)
        for segment in path {
            mixString(segment, into: &h)
        }
        return h
    }

    private func hashVisual(
        bundleID: String?,
        role: ElementRole,
        dHash: UInt64,
        text: String,
        bucket: RefAssignment.VisualGridBucket?
    ) -> UInt64 {
        var h: UInt64 = 577_215_664_901_532_860 // Euler-Mascheroni-ish salt
        mixString(bundleID ?? "", into: &h)
        mixString(role.rawValue, into: &h)
        mixUInt64(dHash, into: &h)
        mixString(text, into: &h)
        if let bucket {
            mixUInt64(UInt64(bitPattern: Int64(bucket.x)), into: &h)
            mixUInt64(UInt64(bitPattern: Int64(bucket.y)), into: &h)
        }
        return h
    }

    private func hashLabelBase(
        bundleID: String?,
        role: ElementRole,
        label: String,
        ancestryHash: UInt64
    ) -> UInt64 {
        var h: UInt64 = 14_695_981_039_346_656_037 // different salt
        mixString(bundleID ?? "", into: &h)
        mixString(role.rawValue, into: &h)
        mixString(label, into: &h)
        mixUInt64(ancestryHash, into: &h)
        return h
    }

    private func mixInOccurrence(_ base: UInt64, occurrence: Int) -> UInt64 {
        var h = base
        mixUInt64(UInt64(bitPattern: Int64(occurrence)), into: &h)
        return h
    }

    private func hashPosition(
        bundleID: String?,
        role: ElementRole,
        ancestryHash: UInt64,
        bounds: CGRect,
        parentBounds: CGRect?,
        siblingIndex: Int
    ) -> UInt64 {
        var h: UInt64 = 2_654_435_761 // yet another salt
        mixString(bundleID ?? "", into: &h)
        mixString(role.rawValue, into: &h)
        mixUInt64(ancestryHash, into: &h)

        // Parent-anchored bucket: relative position bucketed to a 10% grid so the
        // child's ref survives when the parent reflows/resizes.
        let (bx, by) = parentAnchoredBucket(bounds: bounds, parentBounds: parentBounds)
        mixString("\(bx),\(by)", into: &h)
        mixUInt64(UInt64(bitPattern: Int64(siblingIndex)), into: &h)
        return h
    }

    /// Position bucket relative to parent (0–9 in each axis). Falls back to a coarse
    /// screen-space bucket if `parentBounds` is absent or has zero area.
    private func parentAnchoredBucket(bounds: CGRect, parentBounds: CGRect?) -> (Int, Int) {
        if let p = parentBounds, p.width > 0, p.height > 0 {
            let rx = (bounds.midX - p.minX) / p.width
            let ry = (bounds.midY - p.minY) / p.height
            let bx = max(0, min(9, Int((rx * 10).rounded(.down))))
            let by = max(0, min(9, Int((ry * 10).rounded(.down))))
            return (bx, by)
        }
        // No parent bounds — coarse screen bucket at 100 px so tier 3 still gives a
        // meaningful key (better than nothing for top-level windows).
        let bx = Int((bounds.midX / 100).rounded(.down))
        let by = Int((bounds.midY / 100).rounded(.down))
        return (bx, by)
    }

    private func hashFallback(
        bundleID: String?,
        role: ElementRole,
        bounds: CGRect?,
        depth: Int,
        siblingIndex: Int
    ) -> UInt64 {
        var h: UInt64 = 11_400_714_819_323_198_485 // fallback salt
        mixString(bundleID ?? "", into: &h)
        mixString(role.rawValue, into: &h)
        if let b = bounds {
            let gx = Int((b.midX / 50).rounded(.down))
            let gy = Int((b.midY / 50).rounded(.down))
            mixString("\(gx),\(gy)", into: &h)
        }
        mixUInt64(UInt64(bitPattern: Int64(depth)), into: &h)
        mixUInt64(UInt64(bitPattern: Int64(siblingIndex)), into: &h)
        return h
    }

    // MARK: - Primitives

    @inline(__always)
    private func mixString(_ s: String, into hash: inout UInt64) {
        for byte in s.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        // Field separator so adjacent mixes don't alias (e.g. "a"+"bc" vs "ab"+"c").
        hash = ((hash &<< 5) &+ hash) &+ 0x1F
    }

    @inline(__always)
    private func mixUInt64(_ v: UInt64, into hash: inout UInt64) {
        var x = v
        // 8 byte-mixes keeps the utf8 path uniform.
        for _ in 0..<8 {
            hash = ((hash &<< 5) &+ hash) &+ (x & 0xFF)
            x >>= 8
        }
        hash = ((hash &<< 5) &+ hash) &+ 0x1F
    }
}
