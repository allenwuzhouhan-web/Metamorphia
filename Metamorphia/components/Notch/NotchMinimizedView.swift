import SwiftUI

/// The "set aside" state for the AI command bar. Collapses the open notch
/// down to idle-height while the agent run continues in the background.
/// Layout, left to right:
///   - 8pt pulse dot (blue while running, solid green once the run finishes
///     while minimized)
///   - 4pt spacer
///   - live status label (80pt, ellipsized)
///   - 4pt spacer
///   - tiny music widget when something is playing
///
/// Tapping anywhere on the view restores the full command bar.
struct NotchMinimizedView: View {
    @EnvironmentObject var vm: MetamorphiaViewModel
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var coordinator = MetamorphiaViewCoordinator.shared

    private var commandVM: AICommandViewModel? {
        CommandBarCoordinator.shared.viewModel
    }

    var body: some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: vm.effectiveClosedNotchHeight)
                .mask { NotchShape() }

            HStack(spacing: 6) {
                pulseDot
                if let status = commandVM?.liveStatus {
                    Text(status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 120, alignment: .leading)
                        .id(status)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Text("Working…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                if musicManager.isPlaying {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 6)
            .animation(.easeInOut(duration: 0.18), value: commandVM?.liveStatus)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            vm.restore()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI task in progress — tap to expand")
    }

    // MARK: - Pulse dot

    @State private var pulsePhase = false

    private var pulseDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(dotColor.opacity(0.35), lineWidth: 4)
                    .opacity(shouldPulse ? 1 : 0)
                    .scaleEffect(shouldPulse && pulsePhase ? 2.6 : 1)
                    .animation(
                        shouldPulse
                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            : .default,
                        value: pulsePhase
                    )
            )
            .onAppear {
                pulsePhase = true
            }
    }

    private var shouldPulse: Bool {
        guard let vm = commandVM else { return false }
        return vm.isProcessing
    }

    private var dotColor: Color {
        guard let vm = commandVM else { return .white.opacity(0.3) }
        if vm.hasUnseenCompletion && !vm.isProcessing {
            return .green
        }
        return vm.isProcessing ? Color.accentColor : .white.opacity(0.3)
    }
}
