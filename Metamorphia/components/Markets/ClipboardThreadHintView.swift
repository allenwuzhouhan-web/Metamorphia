/*
 * Metamorphia
 * Continuum Phase 8 — Clipboard thread-hint banner.
 *
 * Renders a one-line ambient banner for `ClipboardInsightsSurface.currentHint`.
 * Styled to match the existing hint cards in NotchMarketsView (doc icon, blue
 * tint). Place this inside a `banners`-style @ViewBuilder wherever ambient
 * notch content lives — currently wired into NotchMarketsView.
 */

import SwiftUI

struct ClipboardThreadHintView: View {
    let hint: ClipboardThreadHint
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Card body — tap records engagement and dismisses.
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue.opacity(0.9))

                VStack(alignment: .leading, spacing: 1) {
                    Text(hint.primaryEntity.localizedCapitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(hint.reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer()

                Text(relativeTime(hint.publishedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                AttentionModel.shared.recordSurfaceEngagement()
                onDismiss()
            }

            // xmark — dismiss only, no engagement signal.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue.opacity(0.08))
        )
    }

    // MARK: - Formatting

    private func relativeTime(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        switch elapsed {
        case ..<120:          return "just now"
        case ..<3600:         return "\(Int(elapsed / 60))m ago"
        case ..<86_400:       return "\(Int(elapsed / 3600))h ago"
        default:              return "\(Int(elapsed / 86_400))d ago"
        }
    }
}
