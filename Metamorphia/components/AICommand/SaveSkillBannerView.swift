import SwiftUI

/// Non-blocking banner shown at the top of the command bar when the chain
/// observer detects a long workflow. Lets the user name the skill and save
/// it; otherwise the banner is dismissable and won't reappear for the same
/// workflow.
///
/// Owned and driven entirely by `AICommandViewModel.pendingSkillProposal`.
/// The view itself holds zero state — it's a pure presentation layer.
struct SaveSkillBannerView: View {
    let proposal: AICommandViewModel.SkillProposal
    @State private var name: String = ""
    let onSave: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 12, weight: .medium))
                Text("Save this workflow as a new skill?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            // Brief justification — chain length, tool count — so the user
            // knows *why* the banner appeared without needing to expand the
            // trace view.
            Text(proposal.justification)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)

            HStack(spacing: 6) {
                TextField("skill-name (kebab-case)", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.06))
                    )
                    .onSubmit { commit() }

                Button(action: commit) {
                    Text("Save")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.accentColor.opacity(0.7))
                        )
                }
                .buttonStyle(.plain)
                .disabled(sanitized.isEmpty)
                .opacity(sanitized.isEmpty ? 0.4 : 1.0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                )
        )
        .onAppear {
            // Pre-seed with the LLM-suggested name if we have one, so a single
            // Return commits in the common case.
            if name.isEmpty, let suggested = proposal.suggestedName {
                name = suggested
            }
        }
    }

    private var sanitized: String {
        SaveSkillBannerView.kebab(name)
    }

    private func commit() {
        guard !sanitized.isEmpty else { return }
        onSave(sanitized)
    }

    /// Lightweight kebab-case sanitiser. Strips disallowed characters,
    /// collapses runs of `-`, lower-cases, and trims leading/trailing dashes.
    /// Skill ids must be filesystem-safe — this is the gate.
    static func kebab(_ raw: String) -> String {
        let lower = raw.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
