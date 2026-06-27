import SwiftUI
import AppKit
import MetamorphiaAgentKit

/// Ported from Executer's `ResultBubbleView`. Renders a completed agent
/// response with markdown, typewriter animation for short messages, math-
/// aware serif fallback, read-aloud, copy, trace-inspector, Open-in-
/// Pages/Word for long answers, and haptic feedback.
///
/// Wiring notes vs Executer:
///   - Executer passed an explicit `trace: AgentTrace?` and `onDismiss`.
///     Metamorphia pulls both from `AICommandViewModel`: the trace proxy
///     is `viewModel.agentTree` (a snapshot of the ASCII tree — the full
///     `AgentTrace` model lands with T12), and dismiss is
///     `viewModel.clearConversation()`.
///   - Liquid-glass helpers don't exist in Metamorphia. We use plain
///     `RoundedRectangle` fills + borders, matching the existing pill.
///   - `NSSpeechSynthesizer` is created here; Metamorphia has no shared
///     speech util yet (see T5 / Risks §7.a).
struct ResultBubbleView: View {
    let message: String
    let agentTree: AgentTreeSnapshot?
    let trace: AgentTrace?
    let isLive: Bool
    let isResearchResult: Bool
    let onDismiss: () -> Void
    let onOpenAsDocument: () -> Void

    @State private var isSpeaking = false
    @State private var showCopied = false
    @State private var isHoveringResult = false
    @State private var typewriterText = ""
    @State private var showTraceSheet = false
    @State private var isExporting = false
    @State private var showExportedCheck = false
    @State private var typewriterTimer: Timer?

    /// Shared so repeated open/close of the bubble doesn't leak voices.
    private static let synthesizer = NSSpeechSynthesizer()

    /// Detects responses containing Unicode math symbols for serif font
    /// rendering. Same character set as Executer.
    private var isMathHeavy: Bool {
        let mathChars: Set<Character> = ["∫", "∑", "√", "θ", "π", "∞", "±", "≤", "≥", "≠", "²", "³",
                                          "λ", "Δ", "Σ", "Ω", "α", "β", "γ", "ε", "μ", "σ", "ω", "φ",
                                          "ℏ", "∂", "∇", "→", "⊥", "∈", "⊂", "∪", "∩", "ⁿ", "ₙ"]
        return message.contains(where: { mathChars.contains($0) })
    }

    private var isShort: Bool { message.count < 100 }

    init(
        message: String,
        agentTree: AgentTreeSnapshot?,
        trace: AgentTrace? = nil,
        isLive: Bool = true,
        isResearchResult: Bool = false,
        onDismiss: @escaping () -> Void,
        onOpenAsDocument: @escaping () -> Void = {}
    ) {
        self.message = message
        self.agentTree = agentTree
        self.trace = trace
        self.isLive = isLive
        self.isResearchResult = isResearchResult
        self.onDismiss = onDismiss
        self.onOpenAsDocument = onOpenAsDocument
    }

    /// Long-form answers and any research-mode turn earn the
    /// "open as Word doc" affordance. Threshold intentionally forgiving —
    /// once a paragraph spills past the visible notch area, exporting is
    /// faster than scrolling.
    private var showOpenAsDocument: Bool {
        guard isLive else { return false }
        return isResearchResult || message.count >= 900
    }

    private var exportIconName: String {
        if showExportedCheck { return "checkmark" }
        if isExporting { return "hourglass" }
        return "doc.text"
    }

    var body: some View {
        let displayText = isShort ? typewriterText : message

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)

            // Let the text lay out at its natural height. The outer
            // `TranscriptView` owns the scroll region, so a nested
            // `ScrollView` here would create a second scroll surface the
            // user can't discover — and cap long responses at a fixed
            // height the user can't see past.
            Group {
                if let attributed = try? AttributedString(
                    markdown: isShort ? displayText : message,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed)
                } else {
                    Text(isShort ? displayText : message)
                }
            }
            .font(.system(size: 12, weight: .regular,
                          design: isMathHeavy ? .serif : .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

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

                // Trace-inspector button — available when a completed trace exists.
                if trace != nil {
                    Button { showTraceSheet = true } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("View execution trace")
                }

                // Read aloud
                Button { toggleSpeech(message) } label: {
                    Image(systemName: isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isSpeaking ? "Stop reading" : "Read aloud")

                // Copy
                Button { copyToClipboard(message) } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(showCopied ? .green : .white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .animation(.spring(response: 0.25), value: showCopied)
                }
                .buttonStyle(.plain)
                .help("Copy response")

                // Open as Word document — long answers and research turns.
                if showOpenAsDocument {
                    Button {
                        isExporting = true
                        onOpenAsDocument()
                        // Flash a checkmark, then restore the icon. The VM
                        // owns the actual file open; this is just user
                        // feedback that the tap registered.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            isExporting = false
                            showExportedCheck = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            showExportedCheck = false
                        }
                    } label: {
                        Image(systemName: exportIconName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(showExportedCheck ? .green : .white.opacity(0.55))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                            .animation(.spring(response: 0.25), value: showExportedCheck)
                    }
                    .buttonStyle(.plain)
                    .help("Open as Word document")
                }
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 8, y: 4)
        .onHover { hovering in
            isHoveringResult = hovering
        }
        .sheet(isPresented: $showTraceSheet) {
            if let trace {
                AgentTraceCard(trace: trace, onDismiss: { showTraceSheet = false })
            }
        }
        .onAppear {
            if isLive {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                if isShort {
                    startTypewriter(message)
                }
            } else {
                // Past turn: show full text immediately, no animation.
                typewriterText = message
            }
        }
        .onDisappear {
            stopSpeech()
            typewriterTimer?.invalidate()
            typewriterTimer = nil
        }
        // No auto-dismiss. Previously responses under 30 chars evaporated
        // after 8 s, which stole the reply before the user could read it.
        // Dismissal is now explicit (xmark / Esc / clearConversation).
    }

    // MARK: - Actions

    private func toggleSpeech(_ text: String) {
        if isSpeaking {
            stopSpeech()
        } else {
            let plain = text
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "##", with: "")
                .replacingOccurrences(of: "`",  with: "")
                .replacingOccurrences(of: "*",  with: "")
                .replacingOccurrences(of: "_",  with: "")
            Self.synthesizer.startSpeaking(plain)
            isSpeaking = true
            // Poll for completion so the button icon flips back.
            Task {
                while Self.synthesizer.isSpeaking {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await MainActor.run { isSpeaking = false }
            }
        }
    }

    private func stopSpeech() {
        Self.synthesizer.stopSpeaking()
        isSpeaking = false
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }

    private func startTypewriter(_ message: String) {
        // Cancel any timer still running from a prior .onAppear so two
        // timers can't append to `typewriterText` concurrently and garble
        // the output.
        typewriterTimer?.invalidate()
        typewriterText = ""
        let chars = Array(message)
        guard !chars.isEmpty else { return }
        let totalDuration = min(0.5, Double(chars.count) * 0.015)
        let interval = max(0.01, totalDuration / Double(chars.count))
        var index = 0

        // Keyed off the view's lifetime: the reference is stored in
        // `typewriterTimer` and torn down in .onDisappear, so the timer
        // stops if the bubble is dismissed before it self-terminates at
        // `index >= chars.count`.
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            if index < chars.count {
                typewriterText.append(chars[index])
                index += 1
            } else {
                timer.invalidate()
                typewriterTimer = nil
            }
        }
    }

}
