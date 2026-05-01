import Foundation

/// Clusters ambient-recorded `SkillStep`s into runnable `CompiledSkill`s.
///
/// The clustering heuristic is deliberately narrow on first ship: look for
/// contiguous sequences of steps that repeat at least `minRepetitions`
/// times within a rolling window, share the same bundle ID, and span under
/// `maxSpan` seconds per repetition. Slot detection compares text payloads
/// across repetitions — fields that vary become `SkillParam`s, fields that
/// stay constant become fixed step text.
///
/// This is intentionally not ML-backed. The Phase-E goal is to turn
/// observed repetition into one-tap tools; a heuristic that produces
/// obvious-to-the-user skills (e.g. "Post daily standup — 3 recent uses")
/// is more valuable than a sophisticated clusterer that produces
/// surprising results. The confidence bar is "did I see this same
/// sequence 3 times recently?" — the user judges whether to register.
public enum SkillCompiler {

    // MARK: - Tunables

    public struct Tunables: Sendable {
        public var minRepetitions: Int = 3
        public var minSuccessRate: Double = 0.8
        public var maxSpanSeconds: TimeInterval = 120
        /// Target sequence length — clusterer looks for runs of 2…maxLen
        /// consecutive steps that repeat. Longer sequences add clutter
        /// without much real coverage.
        public var minSequenceLength: Int = 2
        public var maxSequenceLength: Int = 8
        public init() {}
    }

    // MARK: - Public API

    /// Run one compile pass over `steps` and return any CompiledSkills
    /// that cleared the thresholds. Pure function on the input array —
    /// callers own clearing the recorder buffer after a successful
    /// compile so the same sequences don't re-emit.
    public static func compile(
        _ steps: [SkillStep],
        tunables: Tunables = Tunables()
    ) -> [CompiledSkill] {
        guard steps.count >= tunables.minRepetitions * tunables.minSequenceLength else {
            return []
        }

        // Group by bundle first — skills don't span apps, so we never
        // want a cluster to bridge Slack → Safari → Slack.
        let grouped = Dictionary(grouping: steps, by: { $0.appBundleID ?? "" })
        var results: [CompiledSkill] = []

        for (bundleID, bundleSteps) in grouped where bundleID != "" {
            let bundleResults = compileForBundle(
                steps: bundleSteps,
                bundleID: bundleID,
                tunables: tunables
            )
            results.append(contentsOf: bundleResults)
        }
        return results
    }

    // MARK: - Per-bundle clustering

    private static func compileForBundle(
        steps: [SkillStep],
        bundleID: String,
        tunables: Tunables
    ) -> [CompiledSkill] {
        // Build a signature-per-step that collapses only the stable
        // identity signal (op + identityKey) — the text payload is
        // explicitly excluded so runs that differ only in typed content
        // still cluster together. That's how we discover SkillParams.
        let signatures = steps.map { step in
            "\(step.op.rawValue)|\(step.identityKey ?? "")"
        }

        // Sliding-window sequence detection. For every length L in
        // [min, max], collect `[(startIndex, endIndex)]` of every L-gram,
        // group by signature sequence, and keep groups whose count ≥
        // minRepetitions. Bounded O(N * maxLen) which is fine at N ≤ 500.
        var compiled: [CompiledSkill] = []
        var claimedRanges: [ClosedRange<Int>] = []

        for length in (tunables.minSequenceLength...tunables.maxSequenceLength).reversed() {
            guard length <= signatures.count else { continue }
            var sequenceMap: [String: [Int]] = [:] // seq-signature → start indices
            for start in 0...(signatures.count - length) {
                // Reject a candidate if any of its indices is already
                // claimed by a longer compiled sequence.
                let range = start...(start + length - 1)
                if claimedRanges.contains(where: { $0.overlaps(range) }) { continue }
                let key = signatures[start..<(start + length)].joined(separator: "›")
                sequenceMap[key, default: []].append(start)
            }

            for (_, starts) in sequenceMap where starts.count >= tunables.minRepetitions {
                // Span check: each run's wall-clock span stays under
                // the threshold. Variance beyond 120s means these aren't
                // the same intent — they're unrelated press sequences
                // that happened to share a signature.
                let spansValid = starts.allSatisfy { start in
                    let span = steps[start + length - 1].ts
                        .timeIntervalSince(steps[start].ts)
                    return span <= tunables.maxSpanSeconds
                }
                guard spansValid else { continue }

                let compiledSkill = buildCompiled(
                    starts: starts,
                    length: length,
                    steps: steps,
                    bundleID: bundleID
                )
                compiled.append(compiledSkill)

                // Claim every matched range so shorter sub-sequences
                // inside this cluster don't double-emit as separate skills.
                for s in starts {
                    claimedRanges.append(s...(s + length - 1))
                }
            }
        }
        return compiled
    }

    // MARK: - Building a CompiledSkill from cluster matches

    private static func buildCompiled(
        starts: [Int],
        length: Int,
        steps: [SkillStep],
        bundleID: String
    ) -> CompiledSkill {
        // Pick the first run as the canonical template; override its text
        // fields with SkillParam placeholders where the text varied across
        // repetitions.
        let canonical: [SkillStep] = (0..<length).map { offset in
            steps[starts[0] + offset]
        }

        var params: [SkillParam] = []
        var finalSteps: [SkillStep] = canonical

        for offset in 0..<length {
            let texts: [String] = starts.compactMap { start in
                steps[start + offset].params["text"]
            }
            let uniqueTexts = Set(texts)
            // Slot criterion: more than one distinct text across the
            // observed runs. Fully-identical runs skip this branch and
            // the step text stays hard-coded.
            if uniqueTexts.count > 1 {
                let paramName = "slot_\(offset)"
                let defaultValue = texts.sorted().first
                params.append(SkillParam(
                    name: paramName,
                    description: "Text payload at step \(offset + 1)",
                    sourceStepIndex: offset,
                    defaultValue: defaultValue
                ))
                // Rewrite the canonical step to reference the slot instead
                // of carrying a fixed text.
                let original = canonical[offset]
                finalSteps[offset] = SkillStep(
                    ts: original.ts,
                    op: original.op,
                    identityKey: original.identityKey,
                    appBundleID: original.appBundleID,
                    params: original.params,
                    paramRef: paramName,
                    resultDigest: original.resultDigest
                )
            }
        }

        // Derive a human-readable name from the first step's op + bundle.
        // The user can rename on accept. Deliberately short so the Whisper
        // Card's rationale line stays readable.
        let appName = bundleID.split(separator: ".").last.map(String.init) ?? "app"
        let opSummary = canonical.first.map { String(describing: $0.op).capitalized } ?? "Action"
        let name = "\(opSummary) in \(appName)"

        return CompiledSkill(
            name: name,
            description: "Learned from \(starts.count) recent observations (\(length) steps).",
            parameters: params,
            steps: finalSteps,
            observedRepetitions: starts.count
        )
    }
}
