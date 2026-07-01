import SwiftUI

/// The members-only gate shown at launch when the app has no valid license.
/// Minimal, dark, on-brand: paste a key, activate, relaunch.
struct LicenseActivationView: View {
    /// Called after a successful activation when the user chooses to relaunch.
    var onRelaunch: () -> Void

    @State private var keyText: String = ""
    @State private var error: String?
    @State private var activated = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: activated ? "checkmark.seal.fill" : "lock.fill")
                .font(.system(size: 38))
                .foregroundStyle(activated ? Color.green : Color.white.opacity(0.9))
                .padding(.top, 6)

            Text(activated ? "Activated" : "Members Only")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(activated
                 ? "Welcome, \(LicenseManager.shared.licenseeName ?? "member"). Relaunch to start using Metamorphia."
                 : "Enter your Metamorphia license key to unlock the app.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)

            if activated {
                Button(action: onRelaunch) {
                    Text("Relaunch Metamorphia")
                        .frame(maxWidth: 360)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                TextEditor(text: $keyText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(height: 68)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                    .frame(maxWidth: 380)

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                Button(action: activate) {
                    Text("Activate")
                        .frame(maxWidth: 360)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(Color.black)
    }

    private func activate() {
        if LicenseManager.shared.activate(with: keyText) {
            error = nil
            activated = true
            Haptics.confirm()
        } else {
            error = "That key isn't valid. Check for stray spaces or a truncated copy, then try again."
        }
    }
}
