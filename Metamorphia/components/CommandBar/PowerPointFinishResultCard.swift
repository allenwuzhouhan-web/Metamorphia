import SwiftUI

/// Preview of the content Metamorphia will author into a half-finished deck:
/// one row per operation (fill / complete / add slide) in the deck's own style.
struct PowerPointFinishResultCard: View {
    let result: PowerPointFinishResult
    let onAction: ((PowerPointFinishAction) async -> Void)?

    @State private var activeKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.presentationTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(result.operations.count) to finish · \(result.slideCount) slides")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                paletteSwatches
            }

            Text("\(result.typography.titleFont) · \(result.typography.bodyFont) \(Int(result.typography.bodySize))pt")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))

            if !result.summary.isEmpty {
                Text(result.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.operations) { op in
                    operationRow(op)
                }
            }

            HStack(spacing: 6) {
                actionButton(title: "Apply", systemImage: "wand.and.stars", key: "apply", action: .apply)
                actionButton(title: "Restore", systemImage: "arrow.uturn.backward", key: "restore", action: .restore)
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var paletteSwatches: some View {
        HStack(spacing: 3) {
            ForEach([result.palette.primary, result.palette.accent, result.palette.text], id: \.self) { hex in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color(from: hex))
                    .frame(width: 12, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
            }
        }
    }

    private func color(from hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let raw = Int(cleaned, radix: 16) else {
            return .white.opacity(0.35)
        }
        return Color(
            red: Double((raw >> 16) & 0xFF) / 255.0,
            green: Double((raw >> 8) & 0xFF) / 255.0,
            blue: Double(raw & 0xFF) / 255.0
        )
    }

    private func operationRow(_ op: PowerPointFinishOperation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(op.kind.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                Text(target(for: op))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button {
                    fire("jump-\(op.slideIndex)", .jump(slideIndex: op.slideIndex))
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            Text(preview(for: op))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    private func target(for op: PowerPointFinishOperation) -> String {
        switch op.kind {
        case .addSlide:
            if let ref = op.outlineReference, !ref.isEmpty { return "after slide \(op.slideIndex) · \(ref)" }
            return "after slide \(op.slideIndex)"
        case .fillPlaceholder, .completeSlide:
            return "slide \(op.slideIndex)"
        }
    }

    private func preview(for op: PowerPointFinishOperation) -> String {
        let title = op.spans.first(where: { $0.role == .title })?.text
        let body = op.spans.first(where: { $0.role == .body })?.text
        return [title, body].compactMap { $0 }.joined(separator: "\n").ifEmpty(op.combinedText)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        key: String,
        action: PowerPointFinishAction
    ) -> some View {
        let isRunning = activeKey == key
        return Button {
            fire(key, action)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isRunning ? "hourglass" : systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(isRunning || onAction == nil)
    }

    private func fire(_ key: String, _ action: PowerPointFinishAction) {
        guard activeKey == nil, let onAction else { return }
        activeKey = key
        Task {
            await onAction(action)
            await MainActor.run { activeKey = nil }
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
