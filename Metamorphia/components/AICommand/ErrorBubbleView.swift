import SwiftUI
import AppKit
import MetamorphiaAgentKit

/// Error-variant bubble. Matches the success bubble's shape and action
/// column, but strips features that don't fit an error surface:
///
///   - no typewriter (users want to read errors verbatim immediately)
///   - no read-aloud (not useful)
///   - no auto-dismiss (errors must be acknowledged)
///   - no rainbow glow (celebratory; wrong register for a failure)
///
/// Kept: red X leading icon, scrollable body, copy button, trace button,
/// explicit dismiss (live only).
struct ErrorBubbleView: View {
    let message: String
    let agentTree: AgentTreeSnapshot?
    let trace: AgentTrace?
    let isLive: Bool
    let onDismiss: () -> Void

    @State private var showCopied = false
    @State private var showTraceSheet = false

    init(
        message: String,
        agentTree: AgentTreeSnapshot?,
        trace: AgentTrace? = nil,
        isLive: Bool = true,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.agentTree = agentTree
        self.trace = trace
        self.isLive = isLive
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)

            ScrollView(.vertical, showsIndicators: false) {
                Text(message)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 200)

            VStack(spacing: 4) {
                // Dismiss — live only
                if isLive {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }

                // Trace — available when a completed trace exists.
                if trace != nil {
                    Button { showTraceSheet = true } label: {
                        Image(systemName: "exclamationmark.magnifyingglass")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.red.opacity(0.85))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("View error details")
                }

                // Copy — always available
                Button { copyToClipboard(message) } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(showCopied ? .green : .white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .animation(.spring(response: 0.25), value: showCopied)
                }
                .buttonStyle(.plain)
                .help("Copy error")
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 8, y: 4)
        .sheet(isPresented: $showTraceSheet) {
            if let trace {
                AgentTraceCard(trace: trace, onDismiss: { showTraceSheet = false })
            }
        }
        .onAppear {
            if isLive {
                // Distinct haptic so sighted + feel-only users can tell the two
                // terminal states apart without reading the icon.
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}
