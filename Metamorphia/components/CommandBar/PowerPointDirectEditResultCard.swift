import SwiftUI

struct PowerPointDirectEditResultCard: View {
    let result: PowerPointDirectEditResult
    let onAction: ((PowerPointDirectEditControlAction) async -> Void)?

    @State private var activeAction: PowerPointDirectEditControlAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "paintbrush")
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
                chip("\(result.affectedShapeCount) changed")
            }

            Text(result.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(result.actions) { action in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(action.property.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                        Text(action.value)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Text("\(action.affectedShapeIndexes.count) box\(action.affectedShapeIndexes.count == 1 ? "" : "es")")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.42))
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
                actionButton("Restore", systemImage: "arrow.uturn.backward.circle", action: .restore)
                actionButton("Undo", systemImage: "arrow.counterclockwise.circle", action: .undo)
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

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.green.opacity(0.22)))
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: PowerPointDirectEditControlAction
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
