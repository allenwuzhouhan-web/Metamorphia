/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Metamorphia
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import SwiftUI

struct EditPanelView: View {
    @State var wallpaperPath: URL?
    @Default(.observeAppFocus) var observeAppFocus
    @Default(.observeBrowserTabs) var observeBrowserTabs
    @Default(.observePlace) var observePlace

    var body: some View {
        VStack {
            HStack {
                Text("Edit layout")
                    .font(.system(.largeTitle, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Button {
                    NSApp.keyWindow?.close()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .controlSize(.extraLarge)
                .buttonStyle(AccessoryBarButtonStyle())
            }
            .padding()

            Form {
                Section("Observation") {
                    Toggle("Track frontmost app & window title", isOn: $observeAppFocus)
                        .help("Records which app is in focus. Titles for password managers are always redacted.")

                    NavigationLink("Window-title privacy") {
                        AppFocusDenylistView()
                    }
                    .disabled(!observeAppFocus)

                    Toggle("Track browser tab URL + title", isOn: $observeBrowserTabs)
                        .help("Off by default. Only reads Safari / Chrome / Arc / Edge / Brave, never saves full URLs — only a hash + host.")

                    NavigationLink("Domain allowlist") {
                        BrowserDomainAllowlistView()
                    }
                    .disabled(!observeBrowserTabs)

                    Toggle("Track place (Wi-Fi-based)", isOn: $observePlace)
                        .help("Records a salted hash of the current Wi-Fi SSID — never the SSID itself. Label hashes as 'home' / 'office' to make briefings more contextual.")

                    NavigationLink("Place labels") {
                        PlaceLabelsView()
                    }
                    .disabled(!observePlace)
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview {
    EditPanelView()
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = NSVisualEffectView.State.active
        visualEffectView.isEmphasized = true
        return visualEffectView
    }
    
    func updateNSView(_ visualEffectView: NSVisualEffectView, context _: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}
