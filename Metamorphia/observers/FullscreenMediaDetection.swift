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

import Defaults
import MacroVisionKit
import SwiftUI

class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    // MacroVisionKit 0.2.0 exposes the detector as the `FullScreenMonitor` actor.
    private let detector: FullScreenMonitor
    @ObservedObject private var musicManager = MusicManager.shared
    @MainActor @Published private(set) var fullscreenStatus: [String: Bool] = [:]
    private var notificationTask: Task<Void, Never>?

    private init() {
        self.detector = FullScreenMonitor.shared
        setupNotificationObservers()
        Task { [weak self] in await self?.updateFullScreenStatus() }
    }

    private func setupNotificationObservers() {
        notificationTask = Task { @Sendable [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let activeSpaceNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named: NSWorkspace.activeSpaceDidChangeNotification
                    )

                    for await _ in activeSpaceNotifications {
                        await self?.handleChange()
                    }
                }

                group.addTask {
                    let screenParameterNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named:  NSApplication.didChangeScreenParametersNotification
                    )

                    for await _ in screenParameterNotifications {
                        await  self?.handleChange()
                    }
                }
            }
        }
    }

    private func handleChange() async {
        try? await Task.sleep(for: .milliseconds(500))
        await updateFullScreenStatus()
    }

    private func updateFullScreenStatus() async {
        let screenNames = await MainActor.run { NSScreen.screens.map { $0.localizedName } }

        guard Defaults[.enableFullscreenMediaDetection] else {
            // Two identical external monitors report the same localizedName, so
            // collapse duplicate keys instead of trapping (matches the subscript
            // assignment used by the enabled branch below).
            let reset = Dictionary(screenNames.map { ($0, false) }, uniquingKeysWith: { current, _ in current })
            await MainActor.run {
                if reset != self.fullscreenStatus {
                    self.fullscreenStatus = reset
                }
            }
            return
        }

        // SpaceInfo carries the fullscreen apps' bundle IDs + the display UUID; the
        // monitor resolves the UUID back to an NSScreen on the main actor.
        let spaces = await detector.detectFullscreenApps(debug: false)
        let hideAlways = Defaults[.hideNotchOption] == .always
        let musicBundleID = await MainActor.run { self.musicManager.bundleIdentifier }

        var fullscreenScreenNames: Set<String> = []
        for space in spaces {
            guard let screenName = await detector.screen(for: space)?.localizedName else { continue }
            let qualifies = space.runningApps.contains { bundleID in
                bundleID != "com.apple.finder" && (bundleID == musicBundleID || hideAlways)
            }
            if qualifies { fullscreenScreenNames.insert(screenName) }
        }

        var newStatus: [String: Bool] = [:]
        for name in screenNames {
            newStatus[name] = fullscreenScreenNames.contains(name)
        }

        await MainActor.run {
            if newStatus != self.fullscreenStatus {
                self.fullscreenStatus = newStatus
                #if DEBUG
                NSLog("✅ Fullscreen status: \(newStatus)")
                #endif
            }
        }
    }

    private func cleanupNotificationObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
