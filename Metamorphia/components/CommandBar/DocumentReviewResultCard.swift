import SwiftUI

struct DocumentReviewResultCard: View {
    let result: DocumentReviewResult
    let onAction: ((DocumentReviewAction) async -> Void)?

    @State private var activeActionKey: String?

    private var severityCounts: [DocumentReviewSeverity: Int] {
        Dictionary(grouping: result.findings, by: \.severity).mapValues(\.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: result.documentKind.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.documentTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(result.sourceDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                }
                Spacer()
                chip(result.documentKind.displayName, tint: .white.opacity(0.14))
            }

            Text(result.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                severityChip(.high)
                severityChip(.medium)
                severityChip(.low)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.findings.prefix(5)) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(finding.location)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            chip(finding.severity.displayName, tint: tint(for: finding.severity))
                            Spacer()
                        }

                        Text(finding.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))

                        Text(finding.rationale)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)

                        if let suggestedRevision = finding.suggestedRevision,
                           !suggestedRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Suggested rewrite: \(suggestedRevision)")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 6) {
                            actionButton(
                                title: "Jump",
                                systemImage: "arrow.right.circle",
                                action: .jump(findingID: finding.id),
                                enabled: finding.trimmedAnchorText != nil
                            )
                            actionButton(
                                title: "Comment",
                                systemImage: "text.bubble",
                                action: .insertComment(findingID: finding.id),
                                enabled: finding.trimmedAnchorText != nil
                            )
                            actionButton(
                                title: "Apply",
                                systemImage: "wand.and.stars",
                                action: .applySuggestedRevision(findingID: finding.id),
                                enabled: result.documentKind == .document &&
                                    finding.trimmedAnchorText != nil &&
                                    finding.trimmedSuggestedRevision != nil
                            )
                        }
                        .padding(.top, 2)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.035))
                    )
                }
            }

            if let nextStep = result.nextStep,
               !nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(nextStep)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func severityChip(_ severity: DocumentReviewSeverity) -> some View {
        chip("\(severityCounts[severity, default: 0]) \(severity.displayName)", tint: tint(for: severity))
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint))
    }

    private func tint(for severity: DocumentReviewSeverity) -> Color {
        switch severity {
        case .high:
            return Color.red.opacity(0.24)
        case .medium:
            return Color.orange.opacity(0.24)
        case .low:
            return Color.blue.opacity(0.24)
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: DocumentReviewAction,
        enabled: Bool
    ) -> some View {
        let key = actionKey(action)
        let isRunning = activeActionKey == key

        return Button {
            guard enabled, !isRunning, let onAction else { return }
            activeActionKey = key
            Task {
                await onAction(action)
                await MainActor.run {
                    activeActionKey = nil
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isRunning ? "hourglass" : systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(enabled ? .white.opacity(0.84) : .white.opacity(0.35))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(enabled ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isRunning || onAction == nil)
    }

    private func actionKey(_ action: DocumentReviewAction) -> String {
        switch action {
        case .jump(let id):
            return "jump-\(id.uuidString)"
        case .insertComment(let id):
            return "comment-\(id.uuidString)"
        case .applySuggestedRevision(let id):
            return "apply-\(id.uuidString)"
        }
    }
}
