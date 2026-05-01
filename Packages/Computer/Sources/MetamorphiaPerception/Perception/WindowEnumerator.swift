import Foundation
import CoreGraphics
import AppKit

/// Enumerates all visible windows across all apps and monitors.
public enum WindowEnumerator {

    /// Get all visible on-screen windows, sorted by layer (frontmost first).
    /// Each window is tagged with its `displayIndex` — the `NSScreen.screens`
    /// ordinal whose frame contains the window's center. When the center
    /// can't be resolved to any screen (off-screen, zero-size), `displayIndex`
    /// falls back to `0`.
    public static func allWindows() -> [WindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp?.processIdentifier ?? 0

        // Build a display lookup so we can tag windows without recomputing per
        // window. `allDisplays()` uses NSScreen (bottom-left origin), so we
        // convert the CG window bounds' center (top-left origin) into the
        // NSScreen frame to do the containment test.
        let displays = allDisplays()

        var windows: [WindowInfo] = []
        var index = 0

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let layer = window[kCGWindowLayer as String] as? Int else {
                continue
            }

            // Skip window manager chrome and menubar items (layer != 0)
            guard layer == 0 else { continue }

            let title = window[kCGWindowName as String] as? String ?? ""
            let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // Skip tiny windows (likely invisible helper windows)
            guard bounds.width > 50 && bounds.height > 50 else { continue }

            // Look up bundle ID from running apps
            let bundleID = NSWorkspace.shared.runningApplications
                .first(where: { $0.processIdentifier == ownerPID })?
                .bundleIdentifier

            let centerTopLeft = CGPoint(x: bounds.midX, y: bounds.midY)
            let displayIndex = displayIndexForTopLeftPoint(centerTopLeft, displays: displays)

            windows.append(WindowInfo(
                index: index,
                appName: ownerName,
                appBundleID: bundleID,
                title: title,
                bounds: bounds,
                isFocused: ownerPID == frontPID && index == 0,
                layer: layer,
                displayIndex: displayIndex
            ))
            index += 1
        }

        return windows
    }

    /// Enumerate every attached display in `NSScreen.screens` order.
    ///
    /// Coordinate conventions (important for anyone wiring this into a new
    /// coordinate system):
    ///  - `DisplayInfo.origin` is **NSScreen Cartesian** — Y-up, bottom-left origin.
    ///    Main display anchors at (0, 0) with Y growing upward. This matches
    ///    `NSScreen.frame.origin` directly.
    ///  - `DisplayInfo.topLeftOrigin` flips that into the CGEvent / CGWindow
    ///    space (Y-down, top-left origin) for callers targeting CG APIs.
    ///
    /// Ordering from `NSScreen.screens` is **not** guaranteed stable across
    /// display hot-plug events or macOS versions — callers relying on
    /// `displayIndex` as a persistent identity should re-call `allDisplays()`
    /// after detecting a configuration change (NSApplicationDidChangeScreenParameters).
    public static func allDisplays() -> [DisplayInfo] {
        let mainScreen = NSScreen.main
        let screens = NSScreen.screens
        // `NSScreen.screens` is generally non-empty at runtime; if AppKit hasn't
        // initialized yet we return a synthetic fallback so ScreenMap's
        // non-empty precondition can still be honored.
        guard !screens.isEmpty else {
            return [DisplayInfo(
                id: CGMainDisplayID(),
                index: 0,
                name: "Main",
                origin: .zero,
                width: 0,
                height: 0,
                scale: 1,
                isMain: true
            )]
        }

        var results: [DisplayInfo] = []
        results.reserveCapacity(screens.count)

        for (i, screen) in screens.enumerated() {
            let frame = screen.frame
            let scale = Int(screen.backingScaleFactor)

            // Pull the CG display ID out of the screen's device description.
            // The dictionary key is "NSScreenNumber"; the value is a CGDirectDisplayID
            // wrapped as an NSNumber.
            let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
            let rawID = (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()

            // macOS 11+ exposes localizedName. Older SDKs fall back to a
            // synthetic per-index label.
            let name: String
            if #available(macOS 11.0, *) {
                let reported = screen.localizedName
                name = reported.isEmpty ? "Display \(i)" : reported
            } else {
                name = "Display \(i)"
            }

            results.append(DisplayInfo(
                id: rawID,
                index: i,
                name: name,
                origin: frame.origin,
                width: Int(frame.width),
                height: Int(frame.height),
                scale: scale,
                isMain: screen == mainScreen
            ))
        }

        return results
    }

    /// Get the main display info.
    ///
    /// Returns the `isMain == true` entry from `allDisplays()`, or the first
    /// entry if nothing is flagged (e.g., race with a display hot-plug).
    public static func mainDisplay() -> DisplayInfo {
        let all = allDisplays()
        return all.first(where: \.isMain) ?? all[0]
    }

    // MARK: - Coordinate Resolution

    /// Find the index of the display whose bounds contain `point`, where
    /// `point` is in NSScreen Cartesian space (Y-up, bottom-left origin).
    public static func displayIndexForCartesianPoint(
        _ point: CGPoint,
        displays: [DisplayInfo]
    ) -> Int {
        for display in displays where display.bounds.contains(point) {
            return display.index
        }
        return 0
    }

    /// Find the index of the display whose bounds contain `point`, where
    /// `point` is in top-left (CG) space (Y-down, top-left origin). Windows
    /// returned by `CGWindowListCopyWindowInfo` and most AX bounds use this
    /// space, so this is the containment function most call sites want.
    public static func displayIndexForTopLeftPoint(
        _ point: CGPoint,
        displays: [DisplayInfo]
    ) -> Int {
        for display in displays where display.topLeftBounds.contains(point) {
            return display.index
        }
        return 0
    }
}
