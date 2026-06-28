import Foundation

// MARK: - ActivityCue

/// Package-local projection of activity context. MetamorphiaPerception has no
/// dependency on MetamorphiaAgentKit, so the Executors layer is responsible for
/// mapping ActivityEvent → ActivityCue before calling RitualSegmenter.
public struct ActivityCue: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case focusChanged
        case querySubmitted
        case idle
        case resumed
    }

    public let kind: Kind
    public let bundleID: String?
    public let at: Date

    public init(kind: Kind, bundleID: String?, at: Date) {
        self.kind = kind
        self.bundleID = bundleID
        self.at = at
    }
}

// MARK: - RitualWindow

/// A contiguous slice of SkillSteps that the segmenter identified as a
/// self-contained ritual: a bounded, purposeful sequence of actions that
/// occurs repeatedly and may be worth compiling into a skill.
public struct RitualWindow: Sendable, Hashable {
    /// The step sequence that defines the ritual.
    public let steps: [SkillStep]
    /// Ordered join of "op|identityKey" per step, separated by "›". Matches
    /// the key format used by SkillCompiler so signatures are directly comparable.
    public let signature: String
    /// Wall-clock span from first step to last step in seconds.
    public let span: TimeInterval

    public init(steps: [SkillStep], signature: String, span: TimeInterval) {
        self.steps = steps
        self.signature = signature
        self.span = span
    }
}

// MARK: - RitualSegmenter

/// Slices an ambient SkillStep log into candidate RitualWindows by detecting
/// natural boundaries: idle gaps, home-app returns, agent query pivots, and
/// unrecovered bundle switches.
///
/// `segment(steps:activityCues:)` is a pure function — no I/O, no stored state.
/// Callers supply the full step log and the corresponding ActivityCue slice for
/// the same time range. The actor wrapper is present for Swift concurrency
/// compatibility with callers that hold this on an actor.
public actor RitualSegmenter {

    // MARK: - Tunables

    public struct Tunables: Sendable {
        /// Consecutive seconds of inactivity that ends a ritual window.
        public var idleGapSeconds: TimeInterval = 45
        /// If focus leaves an app but returns within this window, it is treated
        /// as a cmd-tab flicker rather than a genuine context switch.
        public var flickerWindowSeconds: TimeInterval = 30
        /// Minimum number of steps for a window to be kept.
        public var minRitualSteps: Int = 2
        /// Minimum wall-clock span (seconds) for a window to be kept.
        public var minRitualSpanSeconds: TimeInterval = 3
        /// Maximum wall-clock span (seconds) for a window to be kept.
        public var maxRitualSpanSeconds: TimeInterval = 180
        /// Used by RitualRecurrenceStore (passed in at construction); not
        /// consumed by segment() itself.
        public var minRepetitions: Int = 3
        /// Used by RitualRecurrenceStore; not consumed by segment() itself.
        public var recurrenceWindowDays: Int = 7
        /// Bundle IDs that count as "home" — a step targeting one of these
        /// is a natural ritual boundary (user returned to home base).
        public var homeBundleIDs: Set<String> = [
            "com.apple.finder",
            "com.apple.dock",
        ]

        public init() {}
    }

    private let tunables: Tunables

    public init(tunables: Tunables = Tunables()) {
        self.tunables = tunables
    }

    // MARK: - Public API

    /// Segment a step log into candidate ritual windows.
    ///
    /// - Parameters:
    ///   - steps: All recorded SkillSteps, ideally in ascending timestamp order.
    ///            The method sorts defensively.
    ///   - activityCues: ActivityCues covering at least the time range of `steps`.
    ///                   Used for boundary detection (focus switches, query pivots).
    /// - Returns: Filtered RitualWindows, each passing the span and step-count thresholds.
    public func segment(steps: [SkillStep], activityCues: [ActivityCue]) -> [RitualWindow] {
        guard steps.count >= tunables.minRitualSteps else { return [] }

        let s = steps.sorted { $0.ts < $1.ts }
        let cues = activityCues.sorted { $0.at < $1.at }

        // Find cut points between adjacent step pairs.
        var boundaries: [Int] = [] // index i means "cut BEFORE step i+1"
        for i in 0..<(s.count - 1) {
            if shouldCut(before: i + 1, in: s, cues: cues) {
                boundaries.append(i)
            }
        }

        // Slice into raw windows.
        let rawWindows = sliceWindows(steps: s, boundaries: boundaries)

        // Post-filter and build RitualWindows.
        var result: [RitualWindow] = []
        for window in rawWindows {
            if let ritual = validate(window: window) {
                result.append(ritual)
            }
        }
        return result
    }

    // MARK: - Boundary Detection

    /// Returns true if there should be a cut before step at `index`.
    private func shouldCut(before index: Int, in steps: [SkillStep], cues: [ActivityCue]) -> Bool {
        let prev = steps[index - 1]
        let next = steps[index]

        // 1. Idle gap.
        if next.ts.timeIntervalSince(prev.ts) > tunables.idleGapSeconds {
            return true
        }

        // 2. Home app return — next step targets Finder / Dock.
        if let bundle = next.appBundleID, tunables.homeBundleIDs.contains(bundle) {
            return true
        }

        // 3. querySubmitted cue between the two steps.
        if cuesBetween(start: prev.ts, end: next.ts, cues: cues).contains(where: { $0.kind == .querySubmitted }) {
            return true
        }

        // 4. Bundle switch without flicker-return.
        if let prevBundle = prev.appBundleID,
           let nextBundle = next.appBundleID,
           prevBundle != nextBundle {
            // Check for a flicker-return: focus cue with prevBundle within
            // flickerWindowSeconds after prev.ts AND before next.ts.
            let flickerEnd = prev.ts.addingTimeInterval(tunables.flickerWindowSeconds)
            let effectiveEnd = min(flickerEnd, next.ts)
            let hasFlicker = cuesBetween(start: prev.ts, end: effectiveEnd, cues: cues).contains {
                $0.kind == .focusChanged && $0.bundleID == prevBundle
            }
            if !hasFlicker {
                return true
            }
        }

        return false
    }

    // MARK: - Windowing

    /// Slice the step array at boundary indices. Boundaries mark the last step
    /// index of each window (cut BEFORE i+1 means window ends at i).
    private func sliceWindows(steps: [SkillStep], boundaries: [Int]) -> [[SkillStep]] {
        var windows: [[SkillStep]] = []
        var start = 0
        for boundary in boundaries {
            let end = boundary // inclusive
            windows.append(Array(steps[start...end]))
            start = end + 1
        }
        // Tail window.
        if start < steps.count {
            windows.append(Array(steps[start...]))
        }
        return windows
    }

    // MARK: - Post-Filter & Build

    /// Validates a raw window slice and builds a RitualWindow if it passes all
    /// thresholds. Returns nil if the window should be discarded.
    private func validate(window: [SkillStep]) -> RitualWindow? {
        guard window.count >= tunables.minRitualSteps,
              let first = window.first,
              let last = window.last else { return nil }

        let span = last.ts.timeIntervalSince(first.ts)
        guard span >= tunables.minRitualSpanSeconds,
              span <= tunables.maxRitualSpanSeconds else { return nil }

        // Idle-cadence discard: if the mean inter-step gap exceeds idleGapSeconds/2,
        // the sequence is too draggy to be a ritual.
        if window.count > 1 {
            let gapSum = zip(window, window.dropFirst()).reduce(0.0) { acc, pair in
                acc + pair.1.ts.timeIntervalSince(pair.0.ts)
            }
            let meanGap = gapSum / Double(window.count - 1)
            if meanGap > tunables.idleGapSeconds / 2 {
                return nil
            }
        }

        let signature = window
            .map { "\($0.op.rawValue)|\($0.identityKey ?? "")" }
            .joined(separator: "›")

        return RitualWindow(steps: window, signature: signature, span: span)
    }

    // MARK: - Cue Lookup

    /// Returns cues strictly after `start` and up to and including `end`
    /// (half-open on the lower bound so a cue at exactly step boundary time
    /// counts toward the gap after that step).
    private func cuesBetween(start: Date, end: Date, cues: [ActivityCue]) -> [ActivityCue] {
        cues.filter { $0.at > start && $0.at <= end }
    }
}
