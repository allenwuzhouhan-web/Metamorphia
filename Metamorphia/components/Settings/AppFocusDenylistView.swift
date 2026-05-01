/*
 * Metamorphia
 * Settings view for the user-extensible app-focus denylist.
 *
 * AppFocusSensor hard-codes a set of password managers that are always
 * redacted. This view lets the user add any additional apps whose window
 * titles they want kept private.
 */

import AppKit
import SwiftUI

// MARK: - AppFocusDenylistView

struct AppFocusDenylistView: View {
    @ObservedObject private var store = AppFocusDenylistStore.shared
    @State private var addError: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("Password managers (1Password, Bitwarden, Dashlane, KeePassXC, Proton Pass, Enpass, Keychain Access, LastPass) are hard-coded and always redacted regardless of this list. Redaction hides only the window title — the app name and bundle ID are still recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hidden from title tracking") {
                if store.entries.isEmpty {
                    Text("No apps added yet.")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(store.entries) { entry in
                        HStack {
                            Text(entry.bundleID)
                                .font(.system(.body))
                            Spacer()
                            Button("Remove") {
                                store.remove(id: entry.id)
                            }
                            .foregroundStyle(.red)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Add current frontmost app…") {
                        addFrontmostApp()
                    }
                    if let err = addError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } footer: {
                Text("Brings the bundle ID of whichever app is in front right now into the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Private-title denylist")
    }

    // MARK: - Private

    private func addFrontmostApp() {
        addError = nil
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            addError = "Could not resolve frontmost app bundle ID."
            return
        }
        if store.contains(bundleID: bundleID) {
            addError = "\(bundleID) is already in the list."
            return
        }
        store.add(bundleID: bundleID)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AppFocusDenylistView()
    }
}
