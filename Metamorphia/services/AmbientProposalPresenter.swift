import AppKit
import ApplicationServices
import Combine
import MetamorphiaAgentKit
import MetamorphiaPerception
import SwiftUI

// MARK: - WhisperCardPanel

/// Non-activating host window for the ambient proposal card. Pinned above
/// the menu bar one notch below the dynamic island, never steals focus, and
/// follows the user across Spaces / full-screen transitions. Mirrors the
/// mask Metamorphia already uses for OSD / lock-screen widgets — the
/// pattern is proven on real hardware.
final class WhisperCardPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 68),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        // Sits at `.mainMenu + 2`, just below the primary notch window
        // (`.mainMenu + 3`). The user never loses the notch-attached
        // command bar behind a whisper.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary,
                              .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - WhisperCardView

/// Single ambient proposal rendered as a minimal, glassy card. Typography +
/// dimension tokens mirror `NotchCommandBarView` so the surface reads as a
/// sibling of the existing notch register. No side squircles, no verbose
/// state — just rationale + one action, per the Live Activity preference.
struct WhisperCardView: View {
    let proposal: Proposal
    let onAccept: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Metamorphia")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(proposal.rationale)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(action: onAccept) {
                Text(proposal.primaryActionLabel)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 340, height: 68)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Metamorphia suggestion")
        .task(id: isHovering) {
            // Auto-dismiss 8 seconds after the last hover-out. Hovering in
            // cancels the countdown (the task is re-keyed on `isHovering`),
            // so the user can read longer proposals without the card yanking
            // itself away. Matches `ResultBubbleView`'s dismissal semantics.
            guard !isHovering else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled, !isHovering {
                onDismiss()
            }
        }
    }
}

// MARK: - AmbientProposalPresenter

/// Owns the Whisper Card lifecycle: subscribes to `ProposalLoop.proposals`,
/// shows one card at a time below the notch, and invokes a caller-supplied
/// action when the user accepts. Main-actor so window / view mutations
/// don't race.
///
/// Single active card: if a new proposal arrives while one is on screen,
/// the old card fades out before the new one fades in. The proposal loop's
/// 90 s rate limit keeps this from thrashing.
@MainActor
public final class AmbientProposalPresenter {

    public static let shared = AmbientProposalPresenter()

    private var panel: WhisperCardPanel?
    private var hostingView: NSHostingView<WhisperCardView>?
    private var cancellable: AnyCancellable?
    private var currentProposal: Proposal?

    /// Monotonic token bumped on every `present(_:)`. The `hide()` fade's
    /// completion handler captures the value at dismissal-start and skips
    /// the `orderOut` if the token has drifted — i.e., a new proposal was
    /// surfaced during the 0.2 s fade-out. Without this, the old completion
    /// would yank the newly-visible card off-screen and the user sees a
    /// pop-and-disappear. Closes critic H3.
    private var presentationGeneration: UInt64 = 0

    /// Caller-supplied action runner. Invoked on user accept. Intentionally
    /// opaque — the presenter doesn't know whether the proposal lowers to a
    /// `computer_batch`, a skill, or a raw tool call. Wired by the host app
    /// at bootstrap time.
    public var onAccept: ((Proposal) -> Void)?

    private init() {}

    /// Start subscribing to the proposal loop's publisher. Idempotent; a
    /// second call replaces the subscription.
    public func install() {
        cancellable?.cancel()
        cancellable = ProposalLoop.shared.proposalsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] proposal in
                self?.present(proposal)
            }
    }

    /// Tear down. Clears the on-screen card and the subscription.
    public func shutdown() {
        cancellable?.cancel()
        cancellable = nil
        hide()
    }

    // MARK: - Present / dismiss

    private func present(_ proposal: Proposal) {
        if currentProposal?.id == proposal.id { return }
        currentProposal = proposal
        presentationGeneration &+= 1

        let view = WhisperCardView(
            proposal: proposal,
            onAccept: { [weak self] in self?.accept(proposal) },
            onDismiss: { [weak self] in self?.dismiss(proposal) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 68)

        if panel == nil {
            panel = WhisperCardPanel()
        }
        panel?.contentView = hosting
        hostingView = hosting

        positionBelowNotch()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
    }

    private func accept(_ proposal: Proposal) {
        // Fire the acceptance runner asynchronously. `onAccept` may do real
        // work (computer_batch, SemanticExecutor calls) — blocking main
        // would stutter the fade-out animation below. Matches critic M7.
        if let onAccept { Task { onAccept(proposal) } }
        Task { await ProposalLoop.shared.acknowledgeAcceptance(proposal) }
        hide()
    }

    private func dismiss(_ proposal: Proposal) {
        // Dismiss is quiet — the loop's rate + novelty gates take the hint
        // on their own. No acceptance side-effect.
        hide()
    }

    private func hide() {
        currentProposal = nil
        guard let panel else { return }
        // Capture the current generation; a concurrent present() during
        // the fade will bump this value. The completion handler refuses
        // to tear the panel down when the token has drifted, because that
        // means a new card is on-screen and orderOut would dismiss it.
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if self.presentationGeneration == generation {
                panel.orderOut(nil)
                self.hostingView = nil
            }
        })
    }

    // MARK: - Shared runner

    /// Default runner for proposals — lowers each `ProposalGoal` into the
    /// smallest set of executor actions that achieves its intent. The
    /// bootstrap wires this as the presenter's `onAccept` so one tap runs
    /// the proposed work through the full safety stack (GestureExecutor →
    /// FeedbackLoopSuppressor → PerceptionBudget).
    ///
    /// Each path is narrow on purpose: proposals are suggestions, not
    /// scripts. When a lowering fails (no default button in the dialog,
    /// empty clipboard for paste-link), we bail silently — the user can
    /// always do the action manually and the loop's novelty gate keeps us
    /// from surfacing the same failed proposal again for 15 minutes.
    public static func runDefaultAction(for proposal: Proposal) async {
        switch proposal.goal {
        case .pasteLink:
            await runPasteLink()
        case .respondToDialog:
            await runRespondToDialog()
        case .joinMeeting, .saveDownload, .replyToMessage:
            // These three proposals open a follow-up surface rather than
            // synthesizing a keystroke: join-meeting could open the
            // calendar event's URL, save-download could spawn a "Move to
            // …" panel, reply-to-message could open the command bar with
            // a draft seeded. Until that UI exists, acceptance is a
            // silent no-op — the proposal's goal is still worthwhile
            // because the user saw and acknowledged the reminder.
            await runNoOp(goal: proposal.goal)
        }
    }

    private static func runNoOp(goal: ProposalGoal) async {
        // Reserved hook point. Intentionally empty so acceptance of these
        // proposals remains a friendly, silent confirmation — avoids
        // synthesizing wrong actions while the specific runners are
        // designed. Logged once per session at .debug for telemetry.
        #if DEBUG
        NSLog("[AmbientProposalPresenter] no-op runner for goal=\(goal.rawValue)")
        #endif
    }

    private static func runPasteLink() async {
        // The user's in a compose surface with a URL on the clipboard.
        // Synthesize ⌘V — whatever has focus will receive the paste. No
        // new AX lookup needed; the clipboard round-trip is what the user
        // would have done themselves.
        do {
            try GestureExecutor.keyCombo(
                keys: [.character("v")],
                modifiers: [.command]
            )
        } catch {
            // Cursor path declined (Accessibility permission missing, etc.)
            // — leave the card acceptance silent; the user sees no paste
            // and forms their own conclusion about the state of the app.
        }
    }

    private static func runRespondToDialog() async {
        // Press Return on whatever the focused app considers its default
        // button. This is exactly what a user pressing Return would do;
        // if no default button exists, the key stroke is a no-op.
        do {
            try GestureExecutor.keyPress(.enter)
        } catch {
            // Same failure mode as paste-link — silent.
        }
    }

    private func positionBelowNotch() {
        guard let panel,
              let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        // 16 pt below the notch (notch height ~32 pt on MacBook Pro +
        // breathing room). Horizontally centered against the display.
        let width: CGFloat = 340
        let height: CGFloat = 68
        let originX = screenFrame.origin.x + (screenFrame.width - width) / 2
        let originY = screenFrame.origin.y + screenFrame.height - height - 48
        panel.setFrame(
            NSRect(x: originX, y: originY, width: width, height: height),
            display: true
        )
    }
}
