import SwiftUI

/// One-line elicitation card shown before a proofread runs: asks what the
/// document is for so every comment can be framed to that purpose. Mirrors the
/// research/browser choice cards' look, but takes a free-text answer.
struct PurposeQuestionCard: View {
    let question: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var answer: String = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("e.g. a board update to win budget approval", text: $answer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.95))
                    .focused($focused)
                    .onSubmit { submit() }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    )

                Button(action: submit) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Continue")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .foregroundStyle(trimmed.isEmpty ? Color.primary.opacity(0.4) : Color.accentColor)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(trimmed.isEmpty
                                  ? Color.secondary.opacity(0.08)
                                  : Color.accentColor.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                trimmed.isEmpty ? Color.white.opacity(0.06) : Color.accentColor.opacity(0.30),
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
            }

            HStack {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Text("Skip (Esc)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip purpose question, return to editor")
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .onAppear { focused = true }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}
