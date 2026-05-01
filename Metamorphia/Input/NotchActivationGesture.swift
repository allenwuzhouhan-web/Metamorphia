import AppKit
import Combine
import Foundation

/// The core dual-activation state machine for notch click/long-press handling.
///
/// **Current integration status (2026-04-15)**: This class is intentionally
/// **not** wired into `ContentView` today. `ContentView.swift` routes
/// notch clicks directly through `.onTapGesture { CommandBarCoordinator.shared.toggle() }`
/// and long-press through `.onLongPressGesture { openNotch() }`, with the
/// user's `notchActivationModesSwapped` default swapping the two. The state
/// machine below (haptic ticks, progress-bar during hold, <300ms vs >=300ms
/// branching) is preserved here for the richer next-pass integration planned
/// in witty-singing-sketch.md. **Do not rewire ContentView to use this
/// without also wiring haptic feedback and the visual compress animation** —
/// doing so partially will regress the perceived quality of the dual gesture.
///
/// Rules:
/// - **Short click (< `commitDuration`, default 300ms)** → `.summonCommandBar`.
/// - **Hold ≥ `commitDuration`** → `.committedToMetamorphia` (swallow the eventual mouseUp).
/// - Haptic pulses at mousedown, every 100ms during hold, and a stronger alignment
///   feedback at the commit threshold.
/// - `progress` (0.0–1.0) drives a visual "compress back toward the notch" animation
///   so the user sees the trade-off physically.
///
/// The gesture only owns the state machine. `NotchDetector` / `ContentView` wire
/// hover + mouse events into `begin()` / `pressDown()` / `pressUp()`, observe
/// `@Published` state, and call `CommandBarCoordinator.shared.toggle(...)` or
/// `MetamorphiaViewModel.openMetamorphiaTabs()` at the appropriate transitions.
public final class NotchActivationGesture: ObservableObject {

    public enum State: Equatable {
        case idle
        case hovering
        /// Press in progress. `startedAt` is used to compute elapsed time.
        case pressing(startedAt: Date)
        /// User released before the commit threshold — summon the Command Bar.
        case summoningCommandBar
        /// User held past the commit threshold — open Metamorphia tabs.
        case committedToMetamorphia
    }

    // MARK: - Public state

    @Published public private(set) var state: State = .idle
    /// 0.0 on press-start, 1.0 at `commitDuration`. Drives the visual shrink animation.
    @Published public private(set) var progress: Double = 0

    // MARK: - Configuration

    /// Time the user must hold to commit to Metamorphia tabs. Defaults to 300ms.
    /// Exposed to Settings so the user can tune it (see Phase 7 notes).
    public var commitDuration: TimeInterval = 0.30
    /// Haptic intensity. `.off` disables every haptic call; `.light` skips the
    /// periodic ticks; `.full` fires everything.
    public var hapticIntensity: HapticIntensity = .full

    public enum HapticIntensity: String, Sendable {
        case off, light, full
    }

    // MARK: - Callbacks (wired by CommandBarCoordinator)

    /// Called when the user's short-click releases before the commit threshold.
    public var onSummonCommandBar: (() -> Void)?
    /// Called when the press crosses the commit threshold (still held).
    public var onCommitToMetamorphia: (() -> Void)?

    // MARK: - Private

    private var commitTimer: Timer?
    private var tickTimer: Timer?
    private let haptic = NSHapticFeedbackManager.defaultPerformer

    public init() {}

    // MARK: - Events

    /// Mouse entered the notch hit region.
    public func hoverBegan() {
        guard state == .idle else { return }
        state = .hovering
    }

    /// Mouse left the notch hit region without clicking.
    public func hoverEnded() {
        if case .pressing = state {
            // User was holding and dragged away — cancel without committing.
            cancelPress()
        } else {
            state = .idle
        }
    }

    /// Mouse button went down on the notch.
    public func pressDown() {
        cancelTimers()
        fireHaptic(.generic)
        state = .pressing(startedAt: Date())
        progress = 0

        // Periodic tick for progress animation + haptic feedback.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.tickProgress()
        }

        // Commit timer fires once at commitDuration.
        commitTimer = Timer.scheduledTimer(withTimeInterval: commitDuration, repeats: false) { [weak self] _ in
            self?.handleCommit()
        }
    }

    /// Mouse button went up on the notch. If we're still in `.pressing`, this
    /// was a short-click — summon the Command Bar.
    public func pressUp() {
        guard case .pressing = state else {
            // Timer already fired — commit handler owns the transition.
            return
        }
        cancelTimers()
        fireHaptic(.generic)
        progress = 0
        state = .summoningCommandBar
        onSummonCommandBar?()
        // Return to hovering (mouse is still on the notch) after a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if case .summoningCommandBar = self?.state { self?.state = .hovering }
        }
    }

    private func cancelPress() {
        cancelTimers()
        progress = 0
        state = .idle
    }

    // MARK: - Tick / commit

    private func tickProgress() {
        guard case .pressing(let startedAt) = state else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let pct = min(elapsed / commitDuration, 1.0)
        progress = pct

        // Haptic ticks at 100ms intervals (not every frame — too jittery).
        // `lastTick` stored via progress rounding: fire when the 100ms boundary crosses.
        let tickIdx = Int(elapsed / 0.1)
        if tickIdx > lastHapticTickIdx {
            lastHapticTickIdx = tickIdx
            fireTickHaptic()
        }
    }
    private var lastHapticTickIdx: Int = 0

    private func handleCommit() {
        guard case .pressing = state else { return }
        cancelTimers()
        fireHaptic(.alignment)
        progress = 1.0
        state = .committedToMetamorphia
        onCommitToMetamorphia?()
        lastHapticTickIdx = 0
    }

    private func cancelTimers() {
        commitTimer?.invalidate()
        commitTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        lastHapticTickIdx = 0
    }

    // MARK: - Haptics

    private func fireHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard hapticIntensity != .off else { return }
        haptic.perform(pattern, performanceTime: .now)
    }

    private func fireTickHaptic() {
        guard hapticIntensity == .full else { return }
        haptic.perform(.generic, performanceTime: .now)
    }
}
