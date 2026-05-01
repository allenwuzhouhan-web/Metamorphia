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
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

var openNotchSize: CGSize {
    let storedWidth = Defaults[.openNotchWidth]
    let minWidth = currentRecommendedMinimumNotchWidth()
    let maxWidth = maxAllowedNotchWidth()
    let width = min(max(storedWidth, minWidth), maxWidth)
    return .init(width: width, height: 200)
}

/// Maximum notch width based on the current screen's point width.
/// Prevents the notch from extending beyond the screen on scaled displays.
func maxAllowedNotchWidth(for screenName: String? = nil) -> CGFloat {
    let screen: NSScreen?
    if let screenName {
        screen = NSScreen.screens.first { $0.localizedName == screenName }
    } else {
        screen = NSScreen.main
    }
    guard let screenWidth = screen?.frame.width, screenWidth > 0 else {
        return 900
    }
    return max(screenWidth - 60, 400)
}

/// Convenience for the main screen.
func maxAllowedNotchWidth() -> CGFloat {
    maxAllowedNotchWidth(for: nil)
}

// MARK: - Tab-Based Notch Width

/// Counts the number of currently enabled standard notch tabs.
/// Mirrors the tab-building logic in ``TabSelectionView``.
func enabledStandardTabCount() -> Int {
    var count = 0

    // Home tab
    if Defaults[.showStandardMediaControls] || Defaults[.showCalendar] || Defaults[.showMirror] {
        count += 1
    }

    // Shelf tab
    if Defaults[.dynamicShelf] {
        count += 1
    }

    // Timer tab (only in .tab display mode)
    if Defaults[.enableTimerFeature] && Defaults[.timerDisplayMode] == .tab {
        count += 1
    }

    // Stats tab
    if Defaults[.enableStatsFeature] {
        count += 1
    }

    // Notes / Clipboard tab
    if Defaults[.enableNotes] || (Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .separateTab) {
        count += 1
    }

    // Terminal tab
    if Defaults[.enableTerminalFeature] {
        count += 1
    }

    return count
}

/// Returns the recommended minimum notch width for the given tab count.
func recommendedMinimumNotchWidth(forTabCount count: Int) -> CGFloat {
    if count >= 6 { return 770 }
    if count >= 5 { return 690 }
    return 640
}

/// Returns the recommended minimum notch width for the current tab configuration.
func currentRecommendedMinimumNotchWidth() -> CGFloat {
    recommendedMinimumNotchWidth(forTabCount: enabledStandardTabCount())
}

/// Enforces the minimum notch width based on current tab count.
/// Also clamps to screen width so the notch never exceeds the display.
/// Only adjusts when not in minimalistic mode.
func enforceMinimumNotchWidth() {
    guard !Defaults[.enableMinimalisticUI] else { return }
    let minWidth = currentRecommendedMinimumNotchWidth()
    let maxWidth = maxAllowedNotchWidth()
    var width = Defaults[.openNotchWidth]
    if width < minWidth { width = minWidth }
    if width > maxWidth { width = maxWidth }
    if Defaults[.openNotchWidth] != width {
        Defaults[.openNotchWidth] = width
    }
}
private let minimalisticBaseOpenNotchSize: CGSize = .init(width: 420, height: 180)
private let minimalisticLyricsExtraHeight: CGFloat = 40
let minimalisticTimerCountdownTopPadding: CGFloat = 12
let minimalisticTimerCountdownContentHeight: CGFloat = 82
let minimalisticTimerCountdownBlockHeight: CGFloat = minimalisticTimerCountdownTopPadding + minimalisticTimerCountdownContentHeight
let statsSecondRowContentHeight: CGFloat = 120
let statsGridSpacingHeight: CGFloat = 12
let notchShadowPaddingStandard: CGFloat = 18
let notchShadowPaddingMinimalistic: CGFloat = 12

@MainActor
var minimalisticOpenNotchSize: CGSize {
    var size = minimalisticBaseOpenNotchSize

    if Defaults[.enableLyrics] {
        size.height += minimalisticLyricsExtraHeight
    }
    
    let reminderCount = ReminderLiveActivityManager.shared.activeWindowReminders.count
    if reminderCount > 0 {
        let reminderHeight = ReminderLiveActivityManager.additionalHeight(forRowCount: reminderCount)
        size.height += reminderHeight
    }

    if MetamorphiaViewCoordinator.shared.timerLiveActivityEnabled && TimerManager.shared.isExternalTimerActive {
        size.height += minimalisticTimerCountdownBlockHeight
    }

    return size
}
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))
let minimalisticCornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 35, bottom: 35), closed: cornerRadiusInsets.closed)

/// Concentric-corner geometry. Apple's law for nested rounded rectangles:
/// two corners share a single center of curvature when `r_inner = r_outer − d`,
/// where `d` is the perpendicular offset between the two shapes' edges.
///
/// Proof sketch: a circular arc of radius R centered at C passes through points at
/// distance R from C. For any point P on an arc of radius r centered at the same C,
/// the segment CP has length r, so the perpendicular distance from the outer arc to P
/// is R − r. Setting that distance equal to the inset d yields r = R − d. Quadratic
/// Bézier corners (NotchShape) and continuous squircles (MetamorphiaPillShape) both
/// approximate true circular arcs near their apex, so the same law governs them
/// to the precision of the human eye.
enum ConcentricCorners {
    /// Inner radius that is concentric to an outer corner at perpendicular distance `inset`.
    /// Clamped at zero — when `inset ≥ outer`, the inner corner collapses to a right angle,
    /// which is visually correct (the inner edge has cleared the curved region entirely).
    static func inner(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(0, outer - inset)
    }

    /// Standard vertical inset used by children that ride the `notchHeight − 12` frame:
    /// 12 total = 6 top + 6 bottom. Consumers: Live Activity icons, minimalistic album art.
    static let closedNotchChildInset: CGFloat = 6

    /// Concentric radius for a child centered inside the closed notch with
    /// `notchHeight − 12` framing. Derives from the 14pt outer bottom corner.
    /// 14 − 6 = 8pt — this is the ONLY value that keeps the child's bottom corners
    /// sharing a center of curvature with the notch's bottom outer corners.
    static var closedNotchChildRadius: CGFloat {
        inner(outer: cornerRadiusInsets.closed.bottom, inset: closedNotchChildInset)
    }

    /// The opened-notch content layer is inset by `notchHorizontalPadding + 12`
    /// on the horizontal axis and `12` on the bottom. For a child whose BOTTOM
    /// edge aligns with the opened-notch interior bottom, the concentric radius is
    /// 24 − 12 = 12pt.
    static var openedNotchBottomChildRadius: CGFloat {
        inner(outer: cornerRadiusInsets.opened.bottom, inset: 12)
    }
}

func statsAdjustedNotchSize(
    from baseSize: CGSize,
    isStatsTabActive: Bool,
    secondRowProgress: CGFloat
) -> CGSize {
    guard isStatsTabActive, Defaults[.enableStatsFeature] else {
        return baseSize
    }

    let enabledGraphsCount = [
        Defaults[.showCpuGraph],
        Defaults[.showMemoryGraph],
        Defaults[.showGpuGraph],
        Defaults[.showNetworkGraph],
        Defaults[.showDiskGraph]
    ].filter { $0 }.count

    guard enabledGraphsCount >= 4 else {
        return baseSize
    }

    let clampedProgress = max(0, min(secondRowProgress, 1))
    guard clampedProgress > 0 else {
        return baseSize
    }

    var adjustedSize = baseSize
    let extraHeight = (statsSecondRowContentHeight + statsGridSpacingHeight) * clampedProgress
    adjustedSize.height += extraHeight
    return adjustedSize
}

func notchShadowPaddingValue(isMinimalistic: Bool) -> CGFloat {
    isMinimalistic ? notchShadowPaddingMinimalistic : notchShadowPaddingStandard
}

func addShadowPadding(to size: CGSize, isMinimalistic: Bool) -> CGSize {
    CGSize(width: size.width, height: size.height + notchShadowPaddingValue(isMinimalistic: isMinimalistic))
}

/// Determines whether a specific screen should render the Island pill
/// shape instead of the standard notch shape.
///
/// Returns `true` only when ALL of these conditions are met:
/// 1. The user has selected `.island` in `externalDisplayStyle`
/// 2. The screen does NOT have a physical notch (safeAreaInsets.top == 0)
///
/// Screens with a physical notch always use the standard notch shape.
func shouldUseIslandMode(for screenName: String?) -> Bool {
    guard Defaults[.externalDisplayStyle] == .island else {
        return false
    }

    var selectedScreen: NSScreen? = NSScreen.main
    if let screenName {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == screenName })
    }

    guard let screen = selectedScreen else {
        // No screen found — fallback to standard notch
        return false
    }

    // Physical notch screens always use standard notch shape
    return screen.safeAreaInsets.top <= 0
}

/// Corner radius insets for the Island pill shape.
/// - closed: half the closed notch height for a true capsule look
/// - opened: generous radius for smooth expanded pill
let islandPillCornerRadiusInsets: (opened: CGFloat, closed: (standard: CGFloat, minimalistic: CGFloat)) = (
    opened: 24,
    closed: (standard: 16, minimalistic: 16)
)

/// Vertical offset from the top screen edge for the Island pill.
/// Creates a visual gap so the pill floats below the menu bar, mimicking
/// the iPhone's Dynamic Island detachment from the physical screen edge.
let islandTopOffset: CGFloat = 6

/// Extra horizontal padding applied OUTSIDE the pill clip shape in Dynamic
/// Island mode so the drop shadow has room to render without being clipped
/// by the outer frame constraint.
let islandShadowInset: CGFloat = 14

enum MusicPlayerImageSizes {
    /// Corner radii for the album-art preview. The `opened` value is for the
    /// 90×90 art that floats at the top-left of the opened notch — it does not
    /// hug any outer notch edge (the notch's bottom outer corners sit ~110pt
    /// below it), so concentric math does not apply; this is a tuned aesthetic.
    /// The `closed` value is respected by the "non-scaled" variant when the
    /// user disables corner radius scaling; sites that DO hug the closed
    /// notch edge (`notchHeight − 12` framing) should instead use
    /// `ConcentricCorners.closedNotchChildRadius` so the inner corner keeps
    /// a shared center of curvature with the 14pt outer bottom.
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

func getScreenFrame(_ screen: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let customScreen = screen {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == customScreen })
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

func getClosedNotchSize(screen: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let customScreen = screen {
        selectedScreen = NSScreen.screens.first(where: { $0.localizedName == customScreen })
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
