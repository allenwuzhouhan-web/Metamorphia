/*
 * Metamorphia
 *
 * The Pulse — transient agent presence in the closed notch.
 *
 * Rendered ONLY while the agent is working (`isProcessing == true`) and only
 * from the single `else if` branch in ContentView's NotchLayout that sits
 * immediately above the idle-face branch. The two are mutually exclusive: when
 * the agent goes idle this view disappears and the face takes over. There is no
 * always-on face here — presence is earned by activity, not assumed.
 *
 * Built as a SUPERSET. A single computed `posture` maps every working
 * `InputBarState` to a breathing posture for SiriOrbView. Move 6 extends the
 * switch (richer streaming / executing detail) without reshaping this file.
 *
 * Like AgentRunningLiveActivity, this does NOT take over the notch: it occupies
 * the right region (music owns left, camera/mic the middle) and tapping it
 * re-opens the Command Bar with the stream intact.
 */

import SwiftUI

struct AgentPresenceLiveActivity: View {
    @ObservedObject var agentViewModel: AICommandViewModel

    /// One posture per working state. Drives the SiriOrbView breathing + tint.
    /// This is the single extension point for Move 6.
    private enum Posture {
        case slowBreath   // processing / planning — gentle, dim
        case fastBreath   // streaming — faster, brighter
        case steadyTool   // executing — steady, tool-tinted
        case blink        // result — one settle blink
        case flinch       // error — red retint
        case dormant      // any non-working state (defensive; not normally shown)

        /// Whether SiriOrbView should run its breathing animation. The flinch
        /// (error) posture breathes too so the red retint is visible against the
        /// `hasError` channel; the blink/dormant postures hold still.
        var isBreathing: Bool {
            switch self {
            case .slowBreath, .fastBreath, .steadyTool, .flinch:
                return true
            case .blink, .dormant:
                return false
            }
        }
    }

    var body: some View {
        HStack {
            Spacer()
            if agentViewModel.isProcessing {
                indicator
                    .transition(.opacity)
            } else if let summary = agentViewModel.lastResultSummary {
                resultChip(summary)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            CommandBarCoordinator.shared.toggle()
        }
        .animation(.smooth(duration: 0.45), value: agentViewModel.inputBarState)
        .animation(.smooth(duration: 0.45), value: agentViewModel.lastResultSummary)
    }

    private var indicator: some View {
        HStack(spacing: 5) {
            if let symbol = toolSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.symbolEffect)
                    .transition(.opacity)
            }

            SiriOrbView(
                isProcessing: posture.isBreathing,
                hasError: posture == .flinch,
                diameter: 18
            )
            .frame(width: 20, height: 20)
            .overlay { progressArc }
        }
        .padding(.trailing, 8)
    }

    /// Thin trailing progress arc hugging the orb. Determinate when `total > 0`
    /// (Circle().trim driven by step/total); an indeterminate breathing arc
    /// otherwise. Hidden unless we're in the executing posture.
    @ViewBuilder
    private var progressArc: some View {
        if case .executing(_, let step, let total) = agentViewModel.inputBarState {
            if total > 0 {
                Circle()
                    .trim(from: 0, to: min(1, CGFloat(step) / CGFloat(total)))
                    .stroke(.white.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 22, height: 22)
                    .animation(.smooth(duration: 0.4), value: step)
            } else {
                IndeterminateArc()
                    .frame(width: 22, height: 22)
            }
        }
    }

    /// Brief glanceable chip shown on terminal success (`lastResultSummary`).
    private func resultChip(_ summary: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.green)
            Text(summary)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.trailing, 8)
    }

    /// The leading symbol for the currently-executing tool, via the catalog.
    /// Nil unless executing so the symbol only appears when a tool is running.
    private var toolSymbol: String? {
        if case .executing(let toolName, _, _) = agentViewModel.inputBarState {
            return AgentToolSymbolCatalog.symbol(for: toolName)
        }
        return nil
    }

    /// SUPERSET switch — maps the current input-bar state to a posture.
    /// Move 6 enriches the streaming / executing cases (associated values are
    /// already available here) without changing the call sites above.
    private var posture: Posture {
        switch agentViewModel.inputBarState {
        case .processing, .planning:
            return .slowBreath
        case .streaming:
            return .fastBreath
        case .executing:
            return .steadyTool
        case .result:
            return .blink
        case .error:
            return .flinch
        case .ready, .voiceListening, .researchChoice, .browserChoice,
             .purposeQuestion, .thoughtRecall, .newsBriefing, .coworkingSuggestion, .healthCard:
            return .dormant
        }
    }
}

/// Indeterminate breathing arc — used when total step count is unknown
/// (`total == 0`). A short arc that rotates continuously.
private struct IndeterminateArc: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(.white.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
        }
    }
}

// Note: no #Preview — AICommandViewModel requires a real AgentLoop to construct
// once MetamorphiaAgentKit is linked. Preview via ContentView's canvas instead.
