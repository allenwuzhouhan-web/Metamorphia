import SwiftUI

/// Renders the post-deletion verification pass: a clear "all clear" when the
/// document is clean, or a short list of anything that genuinely remains.
struct DocumentRecheckResultCard: View {
    let result: DocumentRecheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: result.isClean ? "checkmark.seal.fill" : "exclamationmark.bubble")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(result.isClean ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.documentTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(result.isClean ? "Re-check · clean" : "Re-check · \(result.remainingFindings.count) left")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
            }

            Text(result.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)

            if !result.isClean {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.remainingFindings.prefix(5)) { finding in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(finding.location)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Text(finding.rationale)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                            if let revision = finding.trimmedSuggestedRevision {
                                Text("Change to: \(revision)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    (result.isClean ? Color.green : Color.orange).opacity(0.18),
                    lineWidth: 0.5
                )
        )
    }
}
