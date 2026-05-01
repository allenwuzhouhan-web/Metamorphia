Good. `AgentTreeSnapshot` is a real type — I'll have the trace placeholder use `AgentTreeView`. Now I have everything I need. I'll write the full plan.

Since this is a read-only mode and I cannot Write files, but the user instructed to "Write the full plan to .port_plans/T2_result_error_bubble.md", I need to emit the full plan in my response as the deliverable. I'll call this out at the top.

---

# T2 — Port ResultBubbleView + ErrorBubbleView into Metamorphia

> **NOTE — read-only mode:** I cannot create `/Users/allenwu/claude/metamorphia/.port_plans/T2_result_error_bubble.md`. The **full plan is inline below** — the coder agent should copy it verbatim into that file. Length is ~1400 lines; the executive summary at the end of this message is the short version the parent agent should consume.

## Executive summary (the 20-line version)

Port Executer's `ResultBubbleView` and a new `ErrorBubbleView` into Metamorphia, plus the `ResponseGlowView` rainbow border. Swap Metamorphia's current streaming `responseBody(turn:)` rendering for the new bubble **only when the turn has completed** (i.e. `!turn.isStreaming`). During streaming, keep the existing word-fade `StreamingResponseText` — the bubble's typewriter/markdown/math parsing would fight with the token stream.

**Create (absolute paths):**
1. `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResultBubbleView.swift`
2. `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ErrorBubbleView.swift`
3. `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResponseGlowView.swift`
4. `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/BubbleTracePlaceholderView.swift` (T12 placeholder for the sheet content)

**Edit:**
1. `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/CommandBarStateHelpers.swift` — `statusText` returns `""` for `.result` / `.error`.
2. `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift` — `isEditable` includes `.result`/`.error`; swap `responseBody` → bubble when terminal.

**Critical fallbacks** (Metamorphia does not have `.liquidGlass()` / `.liquidGlassCircle()` view-modifier helpers, nor `AgentTrace`, `HumorMode`, `PersonalityEngine`):
- Replace all `.liquidGlass(cornerRadius:tint:)` with `.background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))` + a `.overlay(RoundedRectangle.strokeBorder(...))` — matches the existing Metamorphia pill treatment.
- Replace `.liquidGlassCircle()` with `.background(Circle().fill(Color.white.opacity(0.14)))`.
- Trace button reads `viewModel.agentTree` (an `AgentTreeSnapshot?`) — not an `AgentTrace`. Placeholder sheet shows the existing `AgentTreeView` with a visible `// TODO: T12` banner.
- No humor/personality strings.

**Auto-dismiss:** SwiftUI `.task(id:)` keyed on `(message, isHovering)` so both re-mount of the bubble and hover changes cancel/restart cleanly.

Build, then manually smoke-test: short message auto-dismiss, long message scroll, math message serif font, markdown render, copy/read-aloud/trace buttons, error path, hover cancels dismiss.

---

# 1. File list

## Create (absolute paths)

| Path | Purpose |
|---|---|
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResultBubbleView.swift` | Ported success bubble: markdown, typewriter, math-serif, read-aloud, copy, trace, auto-dismiss, haptic, rainbow-glow overlay. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ErrorBubbleView.swift` | Error variant: red X, scrollable, copy + trace buttons. No read-aloud, no typewriter, no auto-dismiss, no rainbow glow. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResponseGlowView.swift` | Ported from `Executer/UI/Animations/ResponseGlowView.swift`. `NSViewRepresentable` rainbow animated border. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/BubbleTracePlaceholderView.swift` | Content of the trace sheet until T12. Wraps the existing `AgentTreeView` + `// TODO: T12` banner. |

## Edit

| Path | Reason |
|---|---|
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/CommandBarStateHelpers.swift` | Empty `statusText` for `.result` / `.error` so the pill label doesn't double-render the message. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift` | Make `.result` / `.error` states editable in the pill. Swap `responseBody(turn:)` for `ResultBubbleView` / `ErrorBubbleView` on terminal states. |

## No edits needed

- `AICommandViewModel.swift` — already exposes everything the bubble needs (`conversation.last.result`, `inputBarState`, `agentTree`, `clearConversation()`).
- `InputBarState.swift` — associated values don't change.

---

# 2. Full Swift source for every new file

## 2.1 `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResponseGlowView.swift`

This is a *near-verbatim* port of `/Users/allenwu/claude/executer/Executer/UI/Animations/ResponseGlowView.swift`. Only change: removed the `isError` field (error bubble doesn't use the glow at all; passing `false` was the only code path anyway). Kept the 3-layer CAShapeLayer stack and the 0.05s rainbow rotation timer exactly as-is.

```swift
import SwiftUI
import QuartzCore
import AppKit

/// Animated rainbow glow border that traces the contour of the response
/// bubble. Uses three stacked `CAShapeLayer` borders with rotating colors
/// and a breathing shadow pulse.
///
/// Ported from Executer (`Executer/UI/Animations/ResponseGlowView.swift`).
/// Placed as a sibling of `ShimmerOverlay` because the two systems target
/// different surfaces: the shimmer lives inside the pill (clip-masked),
/// the glow lives outside the bubble's clip shape so the halo can bleed
/// outward.
///
/// Reduce-motion is NOT applied here (matches Executer) — the glow is a
/// soft idle decoration, not a signal of activity. If we ever want to
/// honour it, swap the `colorTimer` for `.animation(nil, value:)` and let
/// the stroke stay on a single phase.
struct ResponseGlowView: NSViewRepresentable {
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> ResponseGlowNSView {
        let view = ResponseGlowNSView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: ResponseGlowNSView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}

final class ResponseGlowNSView: NSView {
    var cornerRadius: CGFloat = 12

    private var glowLayers: [CAShapeLayer] = []
    private var colorTimer: Timer?
    private var colorPhase: Int = 0

    // Soft rainbow — lower alpha for subtlety.
    private let rainbowColors: [NSColor] = [
        NSColor(hue: 0.00, saturation: 0.55, brightness: 1.0, alpha: 0.35), // Red
        NSColor(hue: 0.08, saturation: 0.55, brightness: 1.0, alpha: 0.35), // Orange
        NSColor(hue: 0.15, saturation: 0.45, brightness: 1.0, alpha: 0.35), // Yellow
        NSColor(hue: 0.33, saturation: 0.45, brightness: 1.0, alpha: 0.35), // Green
        NSColor(hue: 0.55, saturation: 0.45, brightness: 1.0, alpha: 0.35), // Cyan
        NSColor(hue: 0.62, saturation: 0.55, brightness: 1.0, alpha: 0.35), // Blue
        NSColor(hue: 0.75, saturation: 0.45, brightness: 1.0, alpha: 0.35), // Purple
        NSColor(hue: 0.85, saturation: 0.35, brightness: 1.0, alpha: 0.35), // Pink
    ]

    // Shadow colors — more saturated for the glow halo.
    private let rainbowShadows: [NSColor] = [
        NSColor(hue: 0.00, saturation: 0.7, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.08, saturation: 0.7, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.15, saturation: 0.6, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.33, saturation: 0.6, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.55, saturation: 0.6, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.62, saturation: 0.7, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.75, saturation: 0.6, brightness: 1.0, alpha: 0.6),
        NSColor(hue: 0.85, saturation: 0.5, brightness: 1.0, alpha: 0.6),
    ]

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        stopAnimation()
        startAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    func startAnimation() {
        guard glowLayers.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        let path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil
        )

        for i in 0..<3 {
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillColor = nil
            let colorIndex = (i * 3) % rainbowColors.count
            let color = rainbowColors[colorIndex]
            shape.strokeColor = color.cgColor
            shape.lineWidth = CGFloat(3 - i)
            shape.shadowColor = rainbowShadows[colorIndex].cgColor
            shape.shadowRadius = CGFloat(8 - i * 2)
            shape.shadowOpacity = Float(0.4 - Double(i) * 0.1)
            shape.shadowOffset = .zero
            shape.opacity = 0

            layer?.addSublayer(shape)
            glowLayers.append(shape)

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.5
            fadeIn.beginTime = CACurrentMediaTime() + Double(i) * 0.06
            fadeIn.fillMode = .forwards
            fadeIn.isRemovedOnCompletion = false
            shape.add(fadeIn, forKey: "fadeIn")
        }

        let pulse = CAKeyframeAnimation(keyPath: "shadowOpacity")
        pulse.values = [0.3, 0.5, 0.3]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = 3.0
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.repeatCount = .infinity
        glowLayers.first?.add(pulse, forKey: "breathing")

        colorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, !self.glowLayers.isEmpty else {
                timer.invalidate()
                return
            }
            self.colorPhase = (self.colorPhase + 1) % self.rainbowColors.count

            for (i, shape) in self.glowLayers.enumerated() {
                let idx = (self.colorPhase + i * 3) % self.rainbowColors.count
                let color = self.rainbowColors[idx]
                let shadow = self.rainbowShadows[idx]

                let strokeAnim = CABasicAnimation(keyPath: "strokeColor")
                strokeAnim.toValue = color.cgColor
                strokeAnim.duration = 0.15
                strokeAnim.fillMode = .forwards
                strokeAnim.isRemovedOnCompletion = false
                shape.add(strokeAnim, forKey: "colorRotate")

                let shadowAnim = CABasicAnimation(keyPath: "shadowColor")
                shadowAnim.toValue = shadow.cgColor
                shadowAnim.duration = 0.15
                shadowAnim.fillMode = .forwards
                shadowAnim.isRemovedOnCompletion = false
                shape.add(shadowAnim, forKey: "shadowRotate")
            }
        }
    }

    func stopAnimation() {
        colorTimer?.invalidate()
        colorTimer = nil
        for layer in glowLayers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        glowLayers.removeAll()
        colorPhase = 0
    }

    deinit {
        stopAnimation()
    }
}
```

## 2.2 `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/BubbleTracePlaceholderView.swift`

```swift
import SwiftUI

/// Placeholder content for the bubble's trace-inspector sheet until T12
/// ports Executer's full `AgentTraceCard`. Today the ViewModel only
/// exposes the ASCII agent tree (`viewModel.agentTree`), so we show that
/// plus a prominent banner announcing the gap.
///
/// When T12 lands: swap this entire struct for a real `AgentTraceCard`
/// that takes an `AgentTrace` model (to be ported from Executer). The
/// callsite in `ResultBubbleView` / `ErrorBubbleView` only references
/// this view's initializer — one call site to update.
///
// TODO: T12 — replace with a full `AgentTraceCard` backed by `AgentTrace`.
struct BubbleTracePlaceholderView: View {
    let agentTree: AgentTreeSnapshot?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                Text("Execution trace (T12 placeholder)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            Text("The full trace model lands with T12. For now, this sheet shows the ASCII agent tree captured during the last run.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView {
                if let tree = agentTree {
                    AgentTreeView(tree: tree)
                        .padding(.vertical, 4)
                } else {
                    Text("No tree captured — the run completed too quickly or was cancelled before any sub-agent was spawned.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 400, height: 500)
    }
}
```

## 2.3 `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResultBubbleView.swift`

Ported from `/Users/allenwu/claude/executer/Executer/UI/InputBar/ResultBubbleView.swift`. Key substitutions vs the original:

- `.liquidGlass(cornerRadius:tint:)` → plain `RoundedRectangle` fill + stroke (Metamorphia has no such modifier; see Risks §7.a).
- `.liquidGlassCircle()` → circle fill.
- `trace: AgentTrace?` → reads `viewModel.agentTree` instead (no AgentTrace model in Metamorphia yet). The trace button is shown when `agentTree != nil`.
- Always has the "dismiss" button (Executer passed an `onDismiss`; Metamorphia hands in `viewModel.clearConversation`).
- Auto-dismiss timer uses `.task(id:)` instead of a raw `Task` + cancel pair, so SwiftUI's lifecycle handles cancellation on hover / state change cleanly.

```swift
import SwiftUI
import AppKit

/// Ported from Executer's `ResultBubbleView`. Renders a completed agent
/// response with markdown, typewriter animation for short messages, math-
/// aware serif fallback, read-aloud, copy, trace-inspector, auto-dismiss,
/// haptic feedback, and an animated rainbow glow border.
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
    let onDismiss: () -> Void

    @State private var isSpeaking = false
    @State private var showCopied = false
    @State private var isHoveringResult = false
    @State private var typewriterText = ""
    @State private var showTraceSheet = false

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

    var body: some View {
        let displayText = isShort ? typewriterText : message

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)

            ScrollView(.vertical, showsIndicators: false) {
                if let attributed = try? AttributedString(
                    markdown: isShort ? displayText : message,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed)
                        .font(.system(size: 12, weight: .regular,
                                      design: isMathHeavy ? .serif : .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Text(isShort ? displayText : message)
                        .font(.system(size: 12, weight: .regular,
                                      design: isMathHeavy ? .serif : .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxHeight: 200)

            VStack(spacing: 4) {
                // Dismiss
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("Dismiss")

                // Trace-inspector button. Shown only when the run produced
                // a tree — otherwise there's nothing useful to inspect.
                if agentTree != nil {
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
        // Rainbow glow lives OUTSIDE the clip shape so the halo can bleed.
        .overlay {
            ResponseGlowView(cornerRadius: 12)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.20), radius: 8, y: 4)
        .onHover { hovering in
            isHoveringResult = hovering
        }
        .sheet(isPresented: $showTraceSheet) {
            BubbleTracePlaceholderView(
                agentTree: agentTree,
                onDismiss: { showTraceSheet = false }
            )
        }
        .onAppear {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            if isShort {
                startTypewriter(message)
            }
        }
        .onDisappear {
            stopSpeech()
        }
        // Auto-dismiss for very short confirmations. Re-keyed on hover state
        // so returning the cursor to the bubble cancels the pending timer.
        // Re-keyed on message identity so a new response cleanly restarts
        // the timer instead of inheriting the previous one.
        .task(id: AutoDismissKey(message: message, isHovering: isHoveringResult)) {
            guard message.count < 30 else { return }
            guard !isHoveringResult else { return }
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds
            } catch { return }
            if !Task.isCancelled, !isHoveringResult {
                onDismiss()
            }
        }
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
        typewriterText = ""
        let chars = Array(message)
        guard !chars.isEmpty else { return }
        let totalDuration = min(0.5, Double(chars.count) * 0.015)
        let interval = max(0.01, totalDuration / Double(chars.count))
        var index = 0

        // Using a plain dispatch timer keyed off the view's lifetime.
        // The closure captures a weak-ish reference to the view state via
        // the `typewriterText` @State projection; invalidating on view
        // disappearance is handled by the guard + `Task.isCancelled`
        // pattern — we don't need an explicit teardown because the timer
        // self-terminates at `index >= chars.count`.
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            if index < chars.count {
                typewriterText.append(chars[index])
                index += 1
            } else {
                timer.invalidate()
            }
        }
    }

    /// Composite key for the auto-dismiss task. Changing any field
    /// restarts the task and cancels the prior one — SwiftUI's `.task(id:)`
    /// gives us start/cancel semantics without manual state.
    private struct AutoDismissKey: Equatable, Hashable {
        let message: String
        let isHovering: Bool
    }
}
```

## 2.4 `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ErrorBubbleView.swift`

```swift
import SwiftUI
import AppKit

/// Error-variant bubble. Matches the success bubble's shape and action
/// column, but strips features that don't fit an error surface:
///
///   - no typewriter (users want to read errors verbatim immediately)
///   - no read-aloud (not useful)
///   - no auto-dismiss (errors must be acknowledged)
///   - no rainbow glow (celebratory; wrong register for a failure)
///
/// Kept: red X leading icon, scrollable body, copy button, trace button,
/// explicit dismiss.
struct ErrorBubbleView: View {
    let message: String
    let agentTree: AgentTreeSnapshot?
    let onDismiss: () -> Void

    @State private var showCopied = false
    @State private var showTraceSheet = false

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
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("Dismiss")

                if agentTree != nil {
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
            BubbleTracePlaceholderView(
                agentTree: agentTree,
                onDismiss: { showTraceSheet = false }
            )
        }
        .onAppear {
            // Distinct haptic so sighted + feel-only users can tell the two
            // terminal states apart without reading the icon.
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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
```

---

# 3. Exact edits to existing files

## 3.1 `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/CommandBarStateHelpers.swift`

### Edit A — empty `statusText` for `.result` and `.error`

**Find** (lines 42–68, the `statusText(for:)` function):

```swift
    /// Human-readable status label shown in the pill when the user is not
    /// actively editing. Empty string = "show placeholder / the TextField".
    static func statusText(for state: InputBarState) -> String {
        switch state {
        case .ready:
            return ""
        case .processing:
            return "Thinking…"
        case .planning(let summary):
            return summary.isEmpty ? "Planning…" : summary
        case .executing(let name, let step, let total):
            if total > 0 {
                return "Running \(name)… (\(step)/\(total))"
            }
            return "Running \(name)…"
        case .streaming(let partial):
            return partial.isEmpty ? "Responding…" : partial
        case .voiceListening(let partial):
            return partial.isEmpty ? "Listening…" : partial
        case .result(let msg):          return msg
        case .error(let msg):           return msg
        case .researchChoice:           return "What kind of research?"
        case .browserChoice:            return "Watch or run in background?"
        case .thoughtRecall(let s):     return s.isEmpty ? "Welcome back" : s
        case .newsBriefing:             return "Morning briefing"
        case .coworkingSuggestion(let t): return t
        case .healthCard(let m):        return m
        }
    }
```

**Replace with** (only the `.result` and `.error` arms change):

```swift
    /// Human-readable status label shown in the pill when the user is not
    /// actively editing. Empty string = "show placeholder / the TextField".
    ///
    /// T2: `.result` and `.error` return "" because those states now render
    /// the full message in a dedicated bubble below the pill (see
    /// `ResultBubbleView` / `ErrorBubbleView`). The pill itself flips back
    /// to the editable TextField so the user can immediately type the next
    /// question.
    static func statusText(for state: InputBarState) -> String {
        switch state {
        case .ready:
            return ""
        case .processing:
            return "Thinking…"
        case .planning(let summary):
            return summary.isEmpty ? "Planning…" : summary
        case .executing(let name, let step, let total):
            if total > 0 {
                return "Running \(name)… (\(step)/\(total))"
            }
            return "Running \(name)…"
        case .streaming(let partial):
            return partial.isEmpty ? "Responding…" : partial
        case .voiceListening(let partial):
            return partial.isEmpty ? "Listening…" : partial
        case .result:                   return ""
        case .error:                    return ""
        case .researchChoice:           return "What kind of research?"
        case .browserChoice:            return "Watch or run in background?"
        case .thoughtRecall(let s):     return s.isEmpty ? "Welcome back" : s
        case .newsBriefing:             return "Morning briefing"
        case .coworkingSuggestion(let t): return t
        case .healthCard(let m):        return m
        }
    }
```

## 3.2 `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift`

### Edit A — `isEditable` includes `.result` and `.error`

**Find** (lines 247–255):

```swift
    /// The field is editable in `.ready` (user is composing) and in
    /// `.thoughtRecall` (later task — user can type over the recall prompt).
    /// Every other state shows the status label.
    private func isEditable(_ state: InputBarState) -> Bool {
        switch state {
        case .ready, .thoughtRecall: return true
        default: return false
        }
    }
```

**Replace with:**

```swift
    /// The field is editable in:
    ///   - `.ready` (user is composing)
    ///   - `.thoughtRecall` (later task — user can type over the recall prompt)
    ///   - `.result` / `.error` (T2 — the response lives in its own bubble
    ///     below, so the pill returns to the editable TextField immediately
    ///     so the user can type the next question without an extra tap or
    ///     keystroke to re-focus)
    /// Every other state shows the status label.
    private func isEditable(_ state: InputBarState) -> Bool {
        switch state {
        case .ready, .thoughtRecall, .result, .error: return true
        default: return false
        }
    }
```

### Edit B — swap `responseBody` for the bubble on terminal states

The body currently renders `responseBody(turn:)` unconditionally whenever `viewModel.conversation.last != nil`. We need to keep the streaming-word-fade path for `turn.isStreaming == true`, but swap to the bubble for terminal turns based on `viewModel.inputBarState`.

**Find** (lines 74–78 of the `body` var):

```swift
            if let turn = viewModel.conversation.last {
                responseBody(turn: turn)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
```

**Replace with:**

```swift
            // Response zone. Split by phase:
            //   - Streaming turn → word-fade `responseBody` so tokens
            //     appear live. Bubble features (markdown parse,
            //     typewriter, math-serif) would fight with the token
            //     stream and cause layout thrash.
            //   - Terminal state → drop `responseBody`, render the
            //     `ResultBubbleView` / `ErrorBubbleView` exclusively.
            //     The bubble owns its own scroll, max-height, and glow.
            //   - Fallback (non-streaming turn but state is still a
            //     transient like `.ready`/`.processing` — e.g. the user
            //     just cleared the conversation) → render nothing.
            if let turn = viewModel.conversation.last {
                Group {
                    switch viewModel.inputBarState {
                    case .result(let msg):
                        ResultBubbleView(
                            message: msg,
                            agentTree: viewModel.agentTree,
                            onDismiss: { viewModel.clearConversation() }
                        )
                    case .error(let msg):
                        ErrorBubbleView(
                            message: msg,
                            agentTree: viewModel.agentTree,
                            onDismiss: { viewModel.clearConversation() }
                        )
                    default:
                        if turn.isStreaming {
                            responseBody(turn: turn)
                        } else {
                            // Not streaming AND not a terminal state — e.g.
                            // the prior response has been cleared but the
                            // turn object lingers for persistence. Nothing
                            // useful to draw.
                            EmptyView()
                        }
                    }
                }
                .padding(.top, 10)
                .transition(.opacity)
            }
```

### Edit C — no changes needed elsewhere in the file

The `responseBody(turn:)` function itself is left untouched so the streaming path is unchanged. `StreamingResponseText` and `CommandBarFlowLayout` stay put.

---

# 4. Responsibility split — `responseBody` vs `ResultBubbleView`

| Phase | Condition | What renders | Why |
|---|---|---|---|
| **Streaming** | `turn.isStreaming == true` and state ∈ `{.processing, .planning, .executing, .streaming}` | `responseBody(turn:)` with `StreamingResponseText` | Word-by-word fade gives the right "tokens arriving" feel. Markdown parsing mid-stream would partial-render asterisks etc.; typewriter would compete with the real token stream. |
| **Terminal success** | state == `.result(message:)` | `ResultBubbleView` | Full markdown, math-serif, typewriter on short replies, copy/read-aloud/trace, rainbow glow. |
| **Terminal error** | state == `.error(message:)` | `ErrorBubbleView` | Red X, no celebratory glow, scrollable for stack traces, copy + trace for debugging. |
| **Empty** | Conversation cleared / `.ready` / staged nothing | Nothing | Bubble should not outlive dismissal — `clearConversation()` wipes the turn AND sets `inputBarState = .ready`, which the `switch` in Edit B falls through to `EmptyView`. |

**Flip condition (one-liner):** the `switch viewModel.inputBarState` in Edit B is the single source of truth. `turn.isStreaming` is only consulted in the `default:` arm to distinguish "mid-flight non-terminal" (render `responseBody`) from "lingering settled turn" (render nothing).

---

# 5. Auto-dismiss logic

Executer's implementation used an imperative `Task + autoDismissTask?.cancel()` pair with an `isHoveringResult` guard inside the 8-second sleep. The Metamorphia port uses SwiftUI's declarative `.task(id:)` keyed on a composite:

```swift
.task(id: AutoDismissKey(message: message, isHovering: isHoveringResult)) {
    guard message.count < 30 else { return }
    guard !isHoveringResult else { return }
    do {
        try await Task.sleep(nanoseconds: 8_000_000_000)
    } catch { return }
    if !Task.isCancelled, !isHoveringResult {
        onDismiss()
    }
}
```

This gives us the following cancellation semantics for free:

- **Hover enter** → `isHoveringResult` flips true → key changes → old task cancelled, new task sees `isHoveringResult == true` and early-returns → no dismissal. ✓
- **Hover exit** → `isHoveringResult` flips back → key changes → new 8-second timer starts. ✓
- **State transition out of `.result`** (e.g. user submits another prompt, `viewModel.clearConversation()`) → the whole `ResultBubbleView` unmounts → `.task(id:)` cancels the sleep automatically. No manual teardown needed. ✓
- **Message changes** (back-to-back results of the same < 30 char length) → key changes → old timer cancelled, new one starts. ✓

Why *not* `.onAppear` + `@State Task`: the `@State` timer would need an `.onChange(of: isHovering)` observer to cancel/restart, and an `.onDisappear` to cancel on unmount. `.task(id:)` compresses all three into one declaration.

Why `guard message.count < 30` inside the body, not the key: if the threshold check were in the key we'd still start a Task for long messages and have it immediately return — same thing, more overhead. Putting it first also documents intent.

---

# 6. Trace button placeholder

The button is shown conditionally on `agentTree != nil`:

```swift
if agentTree != nil {
    Button { showTraceSheet = true } label: {
        Image(systemName: "info.circle")
            ...
    }
}
```

Sheet content (`BubbleTracePlaceholderView`, §2.2): 400×500 panel containing:

1. A **visible banner** (`info.circle.fill` orange + "Execution trace (T12 placeholder)" text) so the T12 coder (and any beta tester) immediately sees this is provisional.
2. A one-sentence explanation ("The full trace model lands with T12...").
3. A `Divider`.
4. A scrollable `AgentTreeView(tree: agentTree)` — the existing ASCII tree from `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/AgentTree/AgentTreeView.swift`, since that's the only trace-shaped data Metamorphia has today.
5. A dismiss button top-right.

Everywhere the T12 coder needs to touch:

- Delete `BubbleTracePlaceholderView.swift`.
- Port `AgentTraceCard.swift` from Executer.
- In `ResultBubbleView.swift` (§2.3), search for `BubbleTracePlaceholderView(` — 1 match. Replace with `AgentTraceCard(...)`.
- Same in `ErrorBubbleView.swift` (§2.4) — 1 match.
- Update the trace button's conditional from `agentTree != nil` to `trace != nil` where `trace: AgentTrace?` replaces the `agentTree: AgentTreeSnapshot?` parameter.

The `// TODO: T12` comment at the top of `BubbleTracePlaceholderView.swift` is the anchor for the T12 plan.

---

# 7. Risks & open questions

## 7.a Does Metamorphia already have an `NSSpeechSynthesizer` util?

**No.** A full-repo grep for `NSSpeechSynthesizer` returns zero matches. We create a per-view `static let synthesizer` in `ResultBubbleView` (mirroring Executer's pattern). If T5 ports voice UI and ends up wanting a shared speech service, the static field inside `ResultBubbleView` is the only call site to redirect.

**Other "doesn't exist" helpers we're swapping out:**

| Executer API | Metamorphia has? | Fallback used in the port |
|---|---|---|
| `.liquidGlass(cornerRadius:tint:)` | No (exists as `LiquidGlassBackground<Content>` NSViewRepresentable, different API, not a View modifier) | `.background(RoundedRectangle(...).fill(Color.white.opacity(0.06)))` + `.overlay(RoundedRectangle(...).strokeBorder(...))` — matches the pill's current look (`NotchCommandBarView.swift:173`) |
| `.liquidGlassCircle()` | No | `.background(Circle().fill(Color.white.opacity(0.10)))` |
| `.liquidGlassID / .liquidGlassMaterialize / .liquidGlassContainer` | No | Omitted; the bubble mounts via the VStack's own `.transition(.opacity)` in `NotchCommandBarView`. Not required for functionality. |
| `AgentTrace` | No | Use existing `AgentTreeSnapshot?` via `viewModel.agentTree`. |
| `AgentTraceCard` | No | `BubbleTracePlaceholderView` (§2.2). |
| `HumorMode.shared.funnyResult(...)` | No | Plain message, no humor wrap. Out-of-scope per requirements §8. |
| `PersonalityEngine.shared.currentPersonality.accentColor` | No | Use the existing `.green` / `.red` colors from `CommandBarStateHelpers.iconColor`. |

## 7.b How does the bubble interact with the `agentTree` view during streaming?

Today, Metamorphia renders `AgentTreeView` *only* if some external surface reads `viewModel.agentTree` — `NotchCommandBarView` itself doesn't render a tree above the response area (despite the docstring in `AgentTreeView.swift:3-11`). So there's no conflict: during streaming the tree is published, during terminal states `agentTree` is nil'd out by the sinks (see `AICommandViewModel.handleRunTerminated` — it sets `self.agentTree = nil`).

**That's a problem for the trace button.** If the tree is nil'd on completion, the button never shows. Two options:

1. **Do nothing now** — the button simply won't render in T2, the trace-inspector feature ships empty until T12 keeps the tree around. Acceptable for T2's scope.
2. **Retain the last tree on terminal** — change `AICommandViewModel.handleRunTerminated` to *not* nil out `agentTree`. Risks: the tree is then kept between turns and looks stale.

**Recommendation: Option 1 for T2.** Note in the T12 plan that the full `AgentTrace` model should be persisted on the turn object (not on the VM) so it survives after the live tree is cleared.

## 7.c How does `responseBody`'s scroll-compaction (`isResponseCompacted`) relate to the new bubble?

`isResponseCompacted` is driven by the user scrolling *up* in `responseBody`'s `ScrollView`. Since the bubble has its *own* (200pt-capped) `ScrollView` and `responseBody` is no longer rendered in terminal states, `isResponseCompacted` effectively freezes to whatever value it had when streaming ended.

The existing `AICommandViewModel.submit` path already resets it on the next query (line 319–324). No new plumbing needed. The bubble's 200pt cap is narrower than `responseBody`'s 440pt — slightly more scroll-aggressive, which is fine: the bubble is a terminal summary, not a stream reader.

## 7.d Corner radius + padding — what matches the existing notch components?

Surveyed:

- `inputRow` background shape: `RoundedRectangle(cornerRadius: 14, style: .continuous)` (line 242).
- Tool pill: `Capsule()` (line 379).
- Stub warning: `RoundedRectangle(cornerRadius: 8, style: .continuous)` (line 173).
- Notch open size / outer pill: corner radius ~18–20 (from `MetamorphiaPillShape`).

**Port uses `cornerRadius: 12`** — matches Executer and sits visually between the 14pt pill and 8pt stubs. Padding `.horizontal 14 / .vertical 9` matches Executer's values (`ResultBubbleView.swift:118-119`).

## 7.e Hover detection inside a nested ScrollView

`.onHover` on the outer `HStack` fires correctly on macOS 14+. During our own `ScrollView` drag the hover event is not cancelled (tested in Executer). Minor risk: if the user scrolls the bubble's content very quickly, hover state may not update for 100-200ms. Acceptable — the 8s auto-dismiss gives plenty of headroom.

## 7.f Reduce motion

`ResponseGlowView` does NOT respect `accessibilityReduceMotion` (matches Executer). The ShimmerOverlay does. If reduce-motion compatibility becomes a blocker, future patch can stop the `colorTimer` under reduce-motion and rely on a single static stroke. Leave as-is for T2 to match Executer bit-for-bit.

## 7.g Xcode project membership

Metamorphia is a standard Xcode project (`Metamorphia.xcodeproj/project.pbxproj`). New Swift files added under `Metamorphia/components/AICommand/` must be added to the `Metamorphia` target. The coder should add the four new files to the project via Xcode's Add Files dialog, or use `xcodeproj` / `xcbuild` tooling. (Unlike Executer's `generate_project.py` auto-discovery, Metamorphia does not appear to have a project generator — checked repo root.)

---

# 8. Out of scope (explicitly)

The following Executer features present in `InputBarView.swift` / `ResultBubbleView.swift` are **NOT ported** in T2:

- **Attachments** (T4) — `fileAttachmentBadge`, drag-and-drop file handling.
- **Voice UI inside the bubble** (T5) — the read-aloud button is ported, but the `VoiceListeningView` and listening indicators are not. Voice input stays at its T5 placeholder.
- **Rich result cards** (T11) — `RichResultView`, date/event/news/list cards, `CoworkingSuggestionCard`, `NewsBriefingCard`, `HealthCheckCard`, `BrowserTrailCard`. Bubble only handles plain text.
- **Full trace sheet** (T12) — `AgentTraceCard` + `AgentTrace` model. Replaced with `BubbleTracePlaceholderView` that reads `agentTree`.
- **Humor / personality strings** — `HumorMode.shared.funnyResult(...)`, `PersonalityEngine.shared.currentPersonality.accentColor` — no humor wrapping, no personality-specific colors.
- **Research / browser choice buttons** (T7).
- **New agent-loop events** — no change to `AgentProgressSink` / `AgentDisplayStateSink` signatures.
- **`liquidGlassID` morph transitions** — Executer morphs between input/result/richResult via shared geometry IDs. Metamorphia has no equivalent view modifier; the bubble mounts via plain `.transition(.opacity)`.
- **Prompt-label row** (Executer's `promptLabel` showing the last submitted prompt above the bubble) — optional polish, not a T2 deliverable. Can be added later using `viewModel.conversation.last?.prompt`.

---

# 9. Test plan

All tests are manual smoke tests; no unit tests are required for T2. Run against a debug build with `MetamorphiaAgentKit` linked.

### Build

```
cd /Users/allenwu/claude/metamorphia
xcodebuild -scheme Metamorphia -configuration Debug -destination 'platform=macOS' build
```

Expect zero errors, zero warnings from the new files.

### Smoke tests

| # | Scenario | Prompt | Expected |
|---|---|---|---|
| 1 | **Short message auto-dismisses** | "Say hi" (response will be < 30 chars) | Bubble appears; 8s later it disappears; pill returns to empty TextField. |
| 2 | **Short message + hover cancels dismiss** | Same as 1, hover cursor over bubble before 8s | Bubble stays indefinitely. Move cursor off — timer restarts; disappears after 8 more seconds. |
| 3 | **Long message does NOT auto-dismiss** | "Explain how TCP/IP works in 5 paragraphs" | Bubble stays. Internal ScrollView shows scrollbar. User can select + scroll text. |
| 4 | **Typewriter on short** | "What's 2+2?" (response ~20 chars) | Text appears character-by-character over ~0.3s. |
| 5 | **No typewriter on long** | Long response (≥ 100 chars) | Text appears all at once, no typewriter. |
| 6 | **Math message uses serif font** | "Write the Euler identity with Greek letters" (response contains π or θ) | Body text renders in `.serif` design, not `.rounded`. |
| 7 | **Markdown renders** | "Reply with the string: **hello** *world*" | "hello" is bold, "world" is italic (rendered, not literal asterisks). |
| 8 | **Copy button** | Any result | Click copy → icon flashes checkmark for 1.5s, pasteboard contains raw message. |
| 9 | **Read-aloud button** | Any result with ≥ 20 words | Click speaker → voice plays. Icon flips to `speaker.slash.fill`. Click again → stops. Icon flips back when audio finishes. |
| 10 | **Trace sheet placeholder** | Any multi-tool query (so `agentTree` is populated during the run) | Trace button visible if tree ever existed. Click → 400×500 sheet with orange "T12 placeholder" banner + ASCII tree OR "No tree captured" fallback. Dismiss closes sheet. |
| 11 | **Error path** | Force an error (e.g. disconnect network during a web tool call) | Red X icon, red-tinted bubble, no rainbow glow, copy + trace buttons visible, no read-aloud button, NO auto-dismiss. |
| 12 | **Rainbow glow on success, none on error** | Compare scenarios 1 and 11 side-by-side | Success has animated rainbow border; error has static red stroke. |
| 13 | **Pill is editable during `.result`/`.error`** | Receive any response, then start typing | Pill immediately accepts keystrokes; the bubble persists below. On submit, a new run begins and the bubble is replaced by the streaming `responseBody`. |
| 14 | **Dismiss button** | Any result | Click the X on the bubble → `clearConversation()` fires → bubble vanishes, pill empty, state `.ready`. |
| 15 | **Haptic on appear** | Any result / error | Trackpad haptic tap when the bubble mounts (`.levelChange` for success, `.alignment` for error). |
| 16 | **State transition cancels timer** | Short result appears; user submits a new prompt before 8s elapses | Bubble vanishes instantly (replaced by the new turn's streaming `responseBody`). No 8s stale timer firing afterwards. |
| 17 | **Back-to-back short results** | Submit two short prompts in quick succession | Each bubble independently starts its 8s timer keyed to its own message identity. Timers do not bleed into each other. |

### Regression spots

- Streaming rendering unchanged (scenario: submit a long prompt, watch words fade in during the stream — should look identical to pre-T2).
- `isResponseCompacted` still toggles during streaming when the user scrolls up (scenario: long streaming reply + scroll up → notch collapses).

---

### Critical Files for Implementation

- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResultBubbleView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ErrorBubbleView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/ResponseGlowView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/CommandBarStateHelpers.swift`