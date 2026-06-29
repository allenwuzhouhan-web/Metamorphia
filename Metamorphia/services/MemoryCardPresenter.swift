import AppKit
import Combine
import MetamorphiaAgentKit
import SwiftUI

// MARK: - MemoryCardView

/// Featherweight read-only card confirming that something was remembered.
/// Typography mirrors `WhisperCardView` — same size/weight tokens, same
/// glassy register. No action button; the card is purely informational.
private struct MemoryCardView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
            VStack(alignment: .leading, spacing: 2) {
                Text("Metamorphia · Retrace")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320, height: 60)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Metamorphia remembered something")
    }
}

// MARK: - MemoryCardPresenter

/// Featherweight "Memory Card" notch receipt. Subscribes to `ActivityStream`
/// and flashes a small confirmation whenever `RetraceIngest` records something
/// new. Modeled on `AmbientProposalPresenter`'s WhisperCard lifecycle but
/// read-only and shorter-lived — no accept action, 6 s auto-dismiss.
///
/// Uses its own `WhisperCardPanel` instance to avoid contending with
/// `AmbientProposalPresenter`'s card.
@MainActor
public final class MemoryCardPresenter {
    public static let shared = MemoryCardPresenter()

    private var panel: WhisperCardPanel?
    private var hostingView: NSHostingView<MemoryCardView>?
    private var cancellable: AnyCancellable?
    private var presentationGeneration: UInt64 = 0
    private var lastShownAt: Date = .distantPast

    private init() {}

    // MARK: - Lifecycle

    /// Start receiving ingestion receipts from `stream`. Idempotent — a second
    /// call replaces the subscription.
    public func install(stream: ActivityStream) {
        cancellable?.cancel()
        cancellable = stream.events
            .receive(on: RunLoop.main)
            .sink { [weak self] event in self?.handle(event) }
    }

    /// Tear down. Clears the on-screen card and the subscription.
    public func shutdown() {
        cancellable?.cancel()
        cancellable = nil
        hide()
    }

    // MARK: - Event handling

    private func handle(_ event: ActivityEvent) {
        guard let label = Self.summarize(event) else { return }
        // Rate limit so a burst of screen frames doesn't thrash the notch.
        guard Date().timeIntervalSince(lastShownAt) > 20 else { return }
        lastShownAt = .now
        present(label)
    }

    /// Map a Retrace ingestion receipt to one short line. Returns nil for
    /// non-ingest events and for `screenFrameIngested` (too noisy for a card).
    private static func summarize(_ event: ActivityEvent) -> String? {
        switch event {
        case .fileIndexed:
            return "Remembered a file"
        case .clipIndexed:
            return "Remembered clipboard"
        case .browserPageIndexed(let host, _, _):
            return "Remembered \(host)"
        case .messageIndexed:
            return "Remembered a message"
        case .mailIndexed:
            return "Remembered an email"
        case .calendarIndexed:
            return "Remembered a calendar event"
        case .agentTurnIndexed:
            return "Remembered this conversation"
        case .screenFrameIngested:
            return nil  // too noisy
        default:
            return nil
        }
    }

    // MARK: - Present / hide

    private func present(_ text: String) {
        presentationGeneration &+= 1

        let view = MemoryCardView(text: text)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 60)

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

        // Auto-dismiss after 6 s using the generation token so a newer card
        // arriving mid-countdown cancels the old dismiss.
        let generation = presentationGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.presentationGeneration == generation else { return }
            self.hide()
        }
    }

    private func hide() {
        guard let panel else { return }
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

    private func positionBelowNotch() {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let width: CGFloat = 320
        let height: CGFloat = 60
        // 16 pt below the notch (notch height ~32 pt + breathing room).
        // Offset slightly right from center so it doesn't overlap
        // AmbientProposalPresenter which sits at dead center.
        let originX = screenFrame.origin.x + (screenFrame.width - width) / 2 + 20
        let originY = screenFrame.origin.y + screenFrame.height - height - 48
        panel.setFrame(
            NSRect(x: originX, y: originY, width: width, height: height),
            display: true
        )
    }
}
