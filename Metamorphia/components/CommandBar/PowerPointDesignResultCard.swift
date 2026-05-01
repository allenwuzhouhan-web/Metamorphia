import SwiftUI

struct PowerPointDesignResultCard: View {
    let result: PowerPointDesignResult
    let onAction: ((PowerPointDesignAction) async -> Void)?

    @State private var activeAction: PowerPointDesignAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.presentationTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(scopeLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                chip(result.palette.name)
            }

            Text(result.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                swatch("Primary", hex: result.palette.primary)
                swatch("Support", hex: result.palette.secondary)
                swatch("Accent", hex: result.palette.accent)
                swatch("Text", hex: result.palette.text)
            }

            if result.isWholeDeck {
                deckPreview
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(result.typography.titleFont)
                        .font(.custom(result.typography.titleFont, size: 10).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("\(Int(result.typography.titleSize))pt")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("/")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.28))
                    Text(result.typography.bodyFont)
                        .font(.custom(result.typography.bodyFont, size: 10).weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                    Text("\(Int(result.typography.bodySize))pt")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                }
                Text(result.motif)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                if !result.textBlocks.isEmpty {
                    Text("\(result.recipe) · \(result.textBlocks.count) structured text block\(result.textBlocks.count == 1 ? "" : "s")")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                } else {
                    Text(result.recipe)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )

            VStack(alignment: .leading, spacing: 6) {
                ForEach(result.operations) { operation in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(operation.kind.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                        Text(operation.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                        Spacer()
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

    private var scopeLine: String {
        if result.isWholeDeck {
            return "\(result.slideCount ?? result.slidePreviews?.count ?? 0) slides · whole-deck redesign"
        }
        return "Slide \(result.slideIndex)\(slideTitleSuffix)"
    }

    private var deckPreview: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
            ForEach((result.slidePreviews ?? []).prefix(8)) { preview in
                slideThumbnail(preview)
            }
        }
        .blur(radius: 0.35)
    }

    private func slideThumbnail(_ preview: PowerPointDeckSlidePreview) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color(from: result.palette.background).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                )
            Rectangle()
                .fill(color(from: result.palette.accent))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Capsule()
                    .fill(color(from: result.palette.primary))
                    .frame(width: preview.titleShapeCount > 0 ? 42 : 26, height: 5)
                ForEach(0..<min(max(preview.bodyShapeCount, 1), 3), id: \.self) { row in
                    Capsule()
                        .fill(color(from: result.palette.text).opacity(0.55))
                        .frame(width: CGFloat(28 + row * 8), height: 3)
                }
                Spacer(minLength: 0)
                Text("\(preview.slideIndex)")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(color(from: result.palette.mutedText))
            }
            .padding(6)
        }
        .frame(height: 46)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.purple.opacity(0.22)))
    }

    private func swatch(_ label: String, hex: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color(from: hex))
                .frame(width: 34, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(from hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6,
              let raw = Int(cleaned, radix: 16) else {
            return .white.opacity(0.35)
        }
        return Color(
            red: Double((raw >> 16) & 0xFF) / 255.0,
            green: Double((raw >> 8) & 0xFF) / 255.0,
            blue: Double(raw & 0xFF) / 255.0
        )
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: PowerPointDesignAction
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
