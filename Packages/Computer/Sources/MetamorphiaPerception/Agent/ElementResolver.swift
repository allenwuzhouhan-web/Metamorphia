import CoreGraphics
import Foundation

/// Resolves a session-scoped `@eN` ref, an optional cross-session `identity_key`,
/// or a last-known click point into the live `ScreenElement` the caller actually
/// wants to act on.
///
/// The cascade is deliberately forgiving: UI trees reflow between snapshots, apps
/// restart, labels get localized, and the LLM may carry a ref from a stale
/// capture. Each step is independent — the first hit returns; the last step
/// falls through into a structured `AmbiguityError` so the LLM can retry.
///
/// Design notes:
/// - This is a pure function on an already-captured `ScreenMap`. It does not
///   drive perception. Callers that want to refresh the map first should call
///   `DefaultComputerPerception.shared.capture(...)` themselves.
/// - `Disambiguator` does the heavy lifting for fuzzy label matches. This type
///   only orchestrates the cascade; do not duplicate ranking logic here.
/// - The hit-test (`hitTest(point:in:)`) mirrors
///   `PerceptionSafetyInspector.inspectPointGesture` — smallest interactive
///   element whose bounds contain the point wins. Kept here so both the
///   safety inspector and the executor use the same resolution rule.
public enum ElementResolver {

    // MARK: - Cascade result

    /// Result of `resolve`. `element` is the target to act on; `tier` reports
    /// which step of the cascade found it so callers can log / adapt.
    public struct Resolution: Sendable {
        public enum Source: String, Sendable {
            /// Direct hit on `ref` in the current snapshot.
            case snapshot
            /// Re-bound via `RefStabilizer.resolve(key:)` from a stored
            /// identity_key (cross-tick, and cross-session when Phase-1
            /// persistence lands).
            case identityKey
            /// Found via fuzzy label disambiguation, same window scope.
            case windowDisambiguation
            /// Found via fuzzy label disambiguation across the focused app.
            case appDisambiguation
            /// Resolved by hit-testing a last-known click point.
            case hitTest
        }

        public let element: ScreenElement
        public let source: Source
    }

    /// Returned when the cascade cannot unambiguously select one element.
    /// Carries ranked candidates so the LLM can reissue the call with a
    /// specific ref instead of looping blindly.
    public struct AmbiguityError: Error, Sendable {
        public struct Candidate: Sendable {
            public let ref: ElementRef
            public let identityKey: String?
            public let label: String
            public let role: ElementRole
            public let windowIndex: Int
            public let score: Float
            public let reason: String
        }

        public let requestedRef: ElementRef?
        public let requestedIdentityKey: String?
        public let requestedLabel: String?
        public let candidates: [Candidate]
        public let advice: String
    }

    // MARK: - Main entry

    /// Resolve a ref (and optional identity key) against `map`.
    ///
    /// - Parameters:
    ///   - ref: The `@eN` the agent received at the time of capture.
    ///   - identityKey: Optional durable key stored alongside the ref. Accept
    ///     when the caller has persisted or cached one (ElementDatabase,
    ///     WorkflowRecorder step). Used in step 2 of the cascade.
    ///   - label: Optional human-readable label — enables steps 3–4 (fuzzy
    ///     disambiguation) if ref lookup fails.
    ///   - preferredRole: Optional role hint to disambiguate between elements
    ///     that share a label (button vs. menuItem).
    ///   - nearPoint: Optional last-known click point — step 5 hit-test.
    ///   - map: The ScreenMap to resolve against.
    ///   - stabilizer: Optional RefStabilizer for step 2. When nil, step 2 is
    ///     skipped and the cascade proceeds directly to label-based lookup.
    ///   - db: Optional ElementDatabase forwarded to Disambiguator for
    ///     learned-preference boost.
    public static func resolve(
        ref: ElementRef?,
        identityKey: String? = nil,
        label: String? = nil,
        preferredRole: ElementRole? = nil,
        nearPoint: CGPoint? = nil,
        in map: ScreenMap,
        stabilizer: RefStabilizer? = nil,
        db: ElementDatabase? = nil
    ) -> Result<Resolution, AmbiguityError> {

        // Step 1 — direct snapshot lookup.
        if let ref, let hit = map.elements.first(where: { $0.ref == ref }) {
            return .success(Resolution(element: hit, source: .snapshot))
        }

        // Step 2 — re-stabilize via durable identity key.
        if let key = identityKey,
           let stabilizer,
           let reboundRef = stabilizer.resolve(key: key),
           let hit = map.elements.first(where: { $0.ref == reboundRef }) {
            return .success(Resolution(element: hit, source: .identityKey))
        }

        // Steps 3 & 4 — fuzzy label disambiguation.
        // Scope narrows before widening: same window first, then whole app.
        if let label, !label.isEmpty {
            let nearRef = ref
            let ranked = Disambiguator.disambiguate(
                label: label,
                in: map,
                preferredRole: preferredRole,
                nearRef: nearRef,
                db: db
            )
            if let top = ranked.first {
                // If the caller held a ref with a known windowIndex, prefer
                // candidates from the same window for step 3. Step 4 widens.
                if let ref, let originalWindow = windowIndex(for: ref, in: map) {
                    let sameWindow = ranked.first { $0.element.windowIndex == originalWindow }
                    if let hit = sameWindow {
                        return .success(Resolution(element: hit.element, source: .windowDisambiguation))
                    }
                }
                // No window scope — take the top across the app.
                return .success(Resolution(element: top.element, source: .appDisambiguation))
            }
            // Label was supplied but nothing resembled it → fall through to
            // hit-test or ambiguity error with no candidates.
        }

        // Step 5 — hit-test a last-known click point.
        if let point = nearPoint, let hit = hitTest(point: point, in: map) {
            return .success(Resolution(element: hit, source: .hitTest))
        }

        // Cascade exhausted — build an ambiguity error with best-effort hints.
        let candidates = buildCandidates(
            forLabel: label,
            preferredRole: preferredRole,
            in: map,
            stabilizer: stabilizer,
            limit: 5
        )
        let advice: String = {
            if candidates.isEmpty {
                return "No elements resolved. Call screen_perceive for a fresh snapshot."
            }
            return "Reissue with one of the suggested refs. If none fit, call screen_perceive and try again."
        }()
        return .failure(AmbiguityError(
            requestedRef: ref,
            requestedIdentityKey: identityKey,
            requestedLabel: label,
            candidates: candidates,
            advice: advice
        ))
    }

    // MARK: - Hit test

    /// Smallest interactive element whose bounds contain `point`. Mirrors
    /// `PerceptionSafetyInspector.inspectPointGesture` so the safety layer
    /// and the executor see identical elements under the same coordinates.
    public static func hitTest(point: CGPoint, in map: ScreenMap) -> ScreenElement? {
        map.elements
            .filter { ($0.bounds?.contains(point) ?? false) && $0.role.isInteractive }
            .min(by: { area(of: $0) < area(of: $1) })
    }

    // MARK: - Helpers

    private static func area(of element: ScreenElement) -> CGFloat {
        guard let b = element.bounds else { return .greatestFiniteMagnitude }
        return b.width * b.height
    }

    private static func windowIndex(for ref: ElementRef, in map: ScreenMap) -> Int? {
        map.elements.first(where: { $0.ref == ref })?.windowIndex
    }

    private static func buildCandidates(
        forLabel label: String?,
        preferredRole: ElementRole?,
        in map: ScreenMap,
        stabilizer: RefStabilizer?,
        limit: Int
    ) -> [AmbiguityError.Candidate] {
        let ranked: [Disambiguator.RankedMatch] = {
            guard let label, !label.isEmpty else { return [] }
            return Disambiguator.disambiguate(
                label: label,
                in: map,
                preferredRole: preferredRole,
                nearRef: nil,
                db: nil
            )
        }()
        return Array(ranked.prefix(limit)).map { match in
            // Without the durable identity_key the LLM can only re-issue the
            // same @eN — which is exactly what the cascade already rejected.
            // Populating this field is what makes self-correction actually
            // self-correcting: the agent can switch from a stale ref to a
            // stored key on the retry.
            let key = stabilizer?.identityKey(for: match.element.ref)
            return AmbiguityError.Candidate(
                ref: match.element.ref,
                identityKey: key,
                label: match.element.label,
                role: match.element.role,
                windowIndex: match.element.windowIndex,
                score: match.score,
                reason: match.reason
            )
        }
    }
}
