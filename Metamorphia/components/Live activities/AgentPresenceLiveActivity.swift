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
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            CommandBarCoordinator.shared.toggle()
        }
        .animation(.smooth(duration: 0.45), value: agentViewModel.inputBarState)
    }

    private var indicator: some View {
        SiriOrbView(
            isProcessing: posture.isBreathing,
            hasError: posture == .flinch,
            diameter: 18
        )
        .frame(width: 20, height: 20)
        .padding(.trailing, 8)
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
             .thoughtRecall, .newsBriefing, .coworkingSuggestion, .healthCard:
            return .dormant
        }
    }
}

// Note: no #Preview — AICommandViewModel requires a real AgentLoop to construct
// once MetamorphiaAgentKit is linked. Preview via ContentView's canvas instead.
