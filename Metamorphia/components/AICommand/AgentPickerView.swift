import SwiftUI

struct AgentPickerView: View {
    let activeAgent: AgentProfile
    let profiles: [AgentProfile]
    let onSelect: (AgentProfile) -> Void

    var body: some View {
        Menu {
            ForEach(profiles, id: \.id) { profile in
                Button {
                    onSelect(profile)
                } label: {
                    HStack {
                        Image(systemName: profile.iconSymbol)
                        Text(profile.displayName)
                        Spacer()
                        if profile.id == activeAgent.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(activeAgent.color)
                    .frame(width: 6, height: 6)
                Text(activeAgent.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch agent")
    }
}
