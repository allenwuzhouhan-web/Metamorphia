/*
 * Metamorphia
 *
 * Collapsed-state indicator shown in the notch when an AI agent is streaming
 * in the background. Modeled on PrivacyLiveActivity — renders in the right
 * region of the closed notch (music owns left, camera/mic the middle).
 *
 * Important: this does NOT take over the notch. Existing live activities
 * (music art, recording pulse, privacy indicators) keep rendering; the agent
 * dot just occupies whatever real estate is left on the right.
 *
 * Tapping the indicator re-opens the Command Bar with the stream intact.
 */

import SwiftUI

struct AgentRunningLiveActivity: View {
    @ObservedObject var agentViewModel: AICommandViewModel

    /// Matching the 8×8 dot + PulsingModifier pattern used by PrivacyLiveActivity.
    var body: some View {
        HStack {
            Spacer()
            if agentViewModel.isProcessing {
                indicator
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            CommandBarCoordinator.shared.toggle()
        }
    }

    private var indicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.15))

            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .modifier(PulsingModifier())
        }
        .frame(width: 20, height: 20)
        .padding(.trailing, 8)
    }
}

// Note: no #Preview because AICommandViewModel requires a real `AgentLoop` to
// construct once MetamorphiaAgentKit is linked. Use Xcode's normal preview canvas
// inside ContentView instead.
