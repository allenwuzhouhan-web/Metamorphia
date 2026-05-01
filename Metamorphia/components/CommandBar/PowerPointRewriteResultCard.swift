import SwiftUI

struct PowerPointRewriteResultCard: View {
    let result: PowerPointRewriteResult
    let onAction: ((PowerPointRewriteAction) async -> Void)?

    @State private var activeAction: PowerPointRewriteAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.presentationTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Slide \(result.slideIndex)\(slideTitleSuffix)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                chip("\(result.replacements.count) edit\(result.replacements.count == 1 ? "" : "s")")
            }

            Text(result.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.replacements) { replacement in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(replacement.role.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.62))
                            Text("#\(replacement.shapeIndex)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.42))
                            Spacer()
                        }

                        diffText(label: "Before", text: replacement.originalText, opacity: 0.52)
                        diffText(label: "After", text: replacement.replacementText, opacity: 0.86)

                        if let rationale = replacement.rationale,
                           !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(rationale)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.035))
                    )
                }
            }

            HStack(spacing: 6) {
                actionButton("Jump", systemImage: "arrow.right.circle", action: .jump)
                actionButton("Apply", systemImage: "checkmark.circle", action: .apply)
                actionButton("Restore", systemImage: "arrow.uturn.backward.circle", action: .restore)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var slideTitleSuffix: String {
        guard let title = result.slideTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return "" }
        return " - \(title)"
    }

    private func diffText(label: String, text: String, opacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.36))
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(opacity))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.blue.opacity(0.22)))
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: PowerPointRewriteAction
    ) -> some View {
        let isRunning = activeAction == action
        return Button {
            guard activeAction == nil, let onAction else { return }
            activeAction = action
            Task {
                await onAction(action)
                await MainActor.run {
                    activeAction = nil
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isRunning ? "hourglass" : systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(activeAction != nil || onAction == nil)
    }
}
