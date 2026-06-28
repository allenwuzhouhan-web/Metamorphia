/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
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

import Foundation
import MetamorphiaAgentKit

/// `SystemContextProvider` decorator that surfaces a single short line
/// describing Metamorphia's own island state (current tab, active timer,
/// shelf count) so the agent has ambient awareness of the app it lives in.
///
/// Lives in the app target (not MetamorphiaExecutors) because it reads
/// `@MainActor`-isolated singletons: `TimerManager`, `ShelfStateViewModel`,
/// and `MetamorphiaViewCoordinator`.
///
/// Wrap around the perception provider at bootstrap:
///
///     let islandContext = IslandStateContextProvider(inner: perceptionContext)
///
/// Then pass `islandContext` to `makeDefaultMiddlewareChain(systemContext:)`.
public final class IslandStateContextProvider: SystemContextProvider, @unchecked Sendable {

    private let inner: any SystemContextProvider

    public init(inner: any SystemContextProvider = NullSystemContextProvider()) {
        self.inner = inner
    }

    // MARK: - SystemContextProvider

    public func currentContext() async -> SystemContextSnapshot {
        let base = await inner.currentContext()
        let line = await MainActor.run { Self.islandLine() }
        return SystemContextSnapshot(
            frontmostApp: base.frontmostApp,
            currentTime: base.currentTime,
            isDarkMode: base.isDarkMode,
            volumeLevel: base.volumeLevel,
            clipboardPreview: base.clipboardPreview,
            frontmostWindowTitle: base.frontmostWindowTitle,
            terminalCWD: base.terminalCWD,
            finderSelection: base.finderSelection,
            batteryLevel: base.batteryLevel,
            wifiNetworkName: base.wifiNetworkName,
            activeDisplayCount: base.activeDisplayCount,
            focusMode: base.focusMode,
            perceptionSummary: base.perceptionSummary,
            islandState: line.isEmpty ? base.islandState : line
        )
    }

    public var lastCapturedAppName: String? {
        get async { await inner.lastCapturedAppName }
    }

    // MARK: - Island line builder

    /// Reads three `@MainActor` singletons and returns a compact status line,
    /// e.g. `"tab=notes, timer 4m left, shelf=3"`. Called via `MainActor.run`
    /// from `currentContext()`.
    @MainActor
    private static func islandLine() -> String {
        var parts: [String] = []

        // Current tab.
        let tab = tabName(MetamorphiaViewCoordinator.shared.currentView)
        parts.append("tab=\(tab)")

        // Active timer.
        let mgr = TimerManager.shared
        if mgr.isTimerActive {
            let remaining = mgr.remainingTime
            let mins = Int(remaining) / 60
            let secs = Int(remaining) % 60
            if mins > 0 {
                parts.append("timer \(mins)m \(secs)s left")
            } else {
                parts.append("timer \(secs)s left")
            }
        }

        // Shelf item count (only if non-empty to save tokens).
        let shelfCount = ShelfStateViewModel.shared.items.count
        if shelfCount > 0 {
            parts.append("shelf=\(shelfCount)")
        }

        return parts.joined(separator: ", ")
    }

    @MainActor
    private static func tabName(_ view: NotchViews) -> String {
        switch view {
        case .home:                return "home"
        case .shelf:               return "shelf"
        case .timer:               return "timer"
        case .stats:               return "stats"
        case .colorPicker:         return "color_picker"
        case .notes:               return "notes"
        case .clipboard:           return "clipboard"
        case .terminal:            return "terminal"
        case .extensionExperience: return "extension"
        case .commandBar:          return "command_bar"
        case .markets:             return "markets"
        case .news:                return "news"
        case .retrace:             return "retrace"
        case .capabilities:        return "capabilities"
        }
    }
}
