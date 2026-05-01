import SwiftUI

struct ResearchChoiceCard: View {
    let query: String
    let onPickDeep: () -> Void
    let onPickLight: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ChoicePillButton(
                    systemImage: "magnifyingglass.circle.fill",
                    title: "Deep Research",
                    tint: .accentColor,
                    isPrimary: true,
                    action: onPickDeep
                )
                ChoicePillButton(
                    systemImage: "bolt.circle.fill",
                    title: "Quick Lookup",
                    tint: .secondary,
                    isPrimary: false,
                    action: onPickLight
                )
            }
            CancelLink(action: onCancel)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct BrowserChoiceCard: View {
    let query: String
    let onPickVisible: () -> Void
    let onPickBackground: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ChoicePillButton(
                    systemImage: "eye.circle.fill",
                    title: "Watch",
                    tint: .blue,
                    isPrimary: true,
                    action: onPickVisible
                )
                ChoicePillButton(
                    systemImage: "eye.slash.circle.fill",
                    title: "Background",
                    tint: .secondary,
                    isPrimary: false,
                    action: onPickBackground
                )
            }
            CancelLink(action: onCancel)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct ChoicePillButton: View {
    let systemImage: String
    let title: String
    let tint: Color
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(isPrimary ? tint : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPrimary
                          ? tint.opacity(0.15)
                          : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isPrimary ? tint.opacity(0.30) : Color.white.opacity(0.08),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CancelLink: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                Text("Cancel (Esc)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel choice, return to editor")
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }
}
