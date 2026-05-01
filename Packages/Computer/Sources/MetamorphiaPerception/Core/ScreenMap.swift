import Foundation
import CoreGraphics
import AppKit

// MARK: - Screen Map

/// Complete semantic representation of the current screen state.
/// This is the primary output — what agents consume.
public struct ScreenMap: Sendable {
    public let timestamp: Date
    public let captureMs: Int
    /// All attached displays, ordered as `NSScreen.screens` returns them.
    /// Guaranteed non-empty — see `init` precondition.
    public let displays: [DisplayInfo]
    /// Primary display. Backed by the `isMain` entry in `displays`, or the
    /// first display if no entry is flagged main. Kept for API compatibility
    /// with single-display consumers.
    public var display: DisplayInfo {
        displays.first(where: \.isMain) ?? displays[0]
    }
    public let focusedApp: AppInfo
    public let windows: [WindowInfo]
    public let elements: [ScreenElement]
    public let navigation: [String]?
    public let safety: SafetyReport
    public let metadata: CaptureMetadata
    /// Full browser DOM capture when the frontmost app is a supported browser (Safari, Chrome, Edge, Arc, Brave, Vivaldi).
    /// Populated locally — never sent to remote APIs (see Output/TextFormatter.swift for the compact summary).
    public let browserDOM: BrowserDOMCapture?
    /// Full menu bar tree of the frontmost app, populated via `MenuBarReader`.
    /// This is the "non-screenshot" path for canvas-drawn apps (Blender, DaVinci,
    /// CapCut) whose main window is opaque to AX — the menu bar remains fully
    /// accessible and exposes nearly every operation the app can perform. Always
    /// local; zero pixels or API calls involved.
    public let menus: [MenuItem]

    /// Modern multi-display initializer. `displays` must be non-empty.
    public init(
        timestamp: Date,
        captureMs: Int,
        displays: [DisplayInfo],
        focusedApp: AppInfo,
        windows: [WindowInfo],
        elements: [ScreenElement],
        navigation: [String]?,
        safety: SafetyReport,
        metadata: CaptureMetadata,
        browserDOM: BrowserDOMCapture? = nil,
        menus: [MenuItem] = []
    ) {
        precondition(!displays.isEmpty, "ScreenMap requires at least one display")
        self.timestamp = timestamp
        self.captureMs = captureMs
        self.displays = displays
        self.focusedApp = focusedApp
        self.windows = windows
        self.elements = elements
        self.navigation = navigation
        self.safety = safety
        self.metadata = metadata
        self.browserDOM = browserDOM
        self.menus = menus
    }

    /// Legacy single-display initializer. Wraps the sole `display` in a one-element
    /// `displays` array. Callers are encouraged to migrate to the `displays:`
    /// overload when they have multi-display information available.
    public init(
        timestamp: Date,
        captureMs: Int,
        display: DisplayInfo,
        focusedApp: AppInfo,
        windows: [WindowInfo],
        elements: [ScreenElement],
        navigation: [String]?,
        safety: SafetyReport,
        metadata: CaptureMetadata,
        browserDOM: BrowserDOMCapture? = nil,
        menus: [MenuItem] = []
    ) {
        // The legacy shape carries a single DisplayInfo. Force it to the main
        // entry so the computed `display` property finds it. If the caller
        // already passed an isMain-flagged display, pass through as-is.
        let normalizedDisplay: DisplayInfo
        if display.isMain {
            normalizedDisplay = display
        } else {
            normalizedDisplay = DisplayInfo(
                id: display.id,
                index: display.index,
                name: display.name,
                origin: display.origin,
                width: display.width,
                height: display.height,
                scale: display.scale,
                isMain: true
            )
        }
        self.init(
            timestamp: timestamp,
            captureMs: captureMs,
            displays: [normalizedDisplay],
            focusedApp: focusedApp,
            windows: windows,
            elements: elements,
            navigation: navigation,
            safety: safety,
            metadata: metadata,
            browserDOM: browserDOM,
            menus: menus
        )
    }
}

// MARK: - Display Info

public struct DisplayInfo: Sendable {
    public let id: UInt32
    /// 0-based ordinal in `NSScreen.screens`. The main display is not
    /// guaranteed to be index 0 — use `isMain` to find it.
    public let index: Int
    /// Localized display name (e.g. `"Built-in Retina Display"`) on macOS 11+,
    /// or `"Display <index>"` as a fallback.
    public let name: String
    /// Top-left corner of the display in **NSScreen Cartesian** coordinates
    /// (Y-up, global). This is the Apple-native system; see `topLeftOrigin`
    /// for a CGEvent-compatible top-left-origin value.
    public let origin: CGPoint
    public let width: Int
    public let height: Int
    public let scale: Int
    /// True for the primary display (`NSScreen.main` at capture time).
    public let isMain: Bool

    /// Display bounds in NSScreen Cartesian coordinates (Y-up). Combines
    /// `origin` and size.
    public var bounds: CGRect {
        CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// The same display origin converted to **top-left, Y-down** coordinates —
    /// the convention used by CGEvent, CGWindowListCreateImage, and the CG
    /// window bounds we receive in the window enumerator. Computed from the
    /// main screen's height, matching how Apple's sample code flips between
    /// the two spaces.
    public var topLeftOrigin: CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? CGFloat(height)
        // NSScreen origin is bottom-left; flip so Y=0 is the top edge of the
        // primary display.
        return CGPoint(x: origin.x, y: mainHeight - origin.y - CGFloat(height))
    }

    /// Display bounds in top-left, Y-down coordinates. Pair with
    /// `topLeftOrigin` when calling CG APIs that expect the flipped system.
    public var topLeftBounds: CGRect {
        CGRect(origin: topLeftOrigin, size: CGSize(width: width, height: height))
    }

    /// Full designated initializer. Prefer this for new code so the display's
    /// index, name, origin, and main-display flag are all known.
    public init(
        id: UInt32,
        index: Int,
        name: String,
        origin: CGPoint,
        width: Int,
        height: Int,
        scale: Int,
        isMain: Bool
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.origin = origin
        self.width = width
        self.height = height
        self.scale = scale
        self.isMain = isMain
    }

    /// Legacy single-display initializer. Populates `index=0`, `name="Main"`,
    /// `origin=.zero`, and marks the display as `isMain`. Existing test
    /// fixtures and callers that don't have multi-display info yet still work
    /// through this init.
    @available(*, deprecated, message: "Use the full init with index/name/origin/isMain")
    public init(id: UInt32, width: Int, height: Int, scale: Int) {
        self.init(
            id: id,
            index: 0,
            name: "Main",
            origin: .zero,
            width: width,
            height: height,
            scale: scale,
            isMain: true
        )
    }
}

// MARK: - App Info

public struct AppInfo: Sendable {
    public let name: String
    public let bundleID: String?
    public let pid: Int32

    public init(name: String, bundleID: String?, pid: Int32) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }
}

// MARK: - Window Info

public struct WindowInfo: Sendable {
    public let index: Int
    public let appName: String
    public let appBundleID: String?
    public let title: String
    public let bounds: CGRect
    public let isFocused: Bool
    public let layer: Int
    /// Index of the display (into `ScreenMap.displays`) containing this
    /// window's center. Defaults to `0` — the main display — for windows
    /// whose center can't be resolved to a specific display.
    public let displayIndex: Int

    public init(
        index: Int,
        appName: String,
        appBundleID: String?,
        title: String,
        bounds: CGRect,
        isFocused: Bool,
        layer: Int,
        displayIndex: Int = 0
    ) {
        self.index = index
        self.appName = appName
        self.appBundleID = appBundleID
        self.title = title
        self.bounds = bounds
        self.isFocused = isFocused
        self.layer = layer
        self.displayIndex = displayIndex
    }
}

// MARK: - Safety Report

public struct SafetyReport: Sendable {
    public let dangers: [ElementRef]
    public let sensitive: [ElementRef]
    public let driftDetected: Bool

    public init(dangers: [ElementRef], sensitive: [ElementRef], driftDetected: Bool) {
        self.dangers = dangers
        self.sensitive = sensitive
        self.driftDetected = driftDetected
    }

    public static let empty = SafetyReport(dangers: [], sensitive: [], driftDetected: false)
}

// MARK: - Capture Metadata

public struct CaptureMetadata: Sendable {
    public let axCoveragePercent: Float
    public let ocrUsed: Bool
    public let elementCount: Int
    public let interactiveCount: Int
    public let offScreenHint: String?
    /// Per-phase wall-clock timings populated by `PerceptionPipeline`. Older
    /// callers that build `CaptureMetadata` directly default this to `nil`.
    public let timing: TimingBreakdown?

    public init(
        axCoveragePercent: Float,
        ocrUsed: Bool,
        elementCount: Int,
        interactiveCount: Int,
        offScreenHint: String?,
        timing: TimingBreakdown? = nil
    ) {
        self.axCoveragePercent = axCoveragePercent
        self.ocrUsed = ocrUsed
        self.elementCount = elementCount
        self.interactiveCount = interactiveCount
        self.offScreenHint = offScreenHint
        self.timing = timing
    }
}

// MARK: - Timing Breakdown

/// Per-phase wall-clock in milliseconds, written by `PerceptionPipeline` to
/// make the parallel capture timing observable. `totalMs` is the outer driver
/// wall-clock; the per-phase values measure their own tasks independently, so
/// in the parallel path `sum(phaseMs) > totalMs` is the expected shape.
public struct TimingBreakdown: Sendable {
    public let totalMs: Int
    public let axMs: Int
    public let windowsMs: Int
    public let displaysMs: Int
    public let menusMs: Int
    public let dHashMs: Int
    /// 0 when OCR was skipped this capture.
    public let ocrMs: Int
    public let fusionMs: Int
    public let safetyMs: Int

    public init(
        totalMs: Int,
        axMs: Int,
        windowsMs: Int,
        displaysMs: Int,
        menusMs: Int,
        dHashMs: Int,
        ocrMs: Int,
        fusionMs: Int,
        safetyMs: Int
    ) {
        self.totalMs = totalMs
        self.axMs = axMs
        self.windowsMs = windowsMs
        self.displaysMs = displaysMs
        self.menusMs = menusMs
        self.dHashMs = dHashMs
        self.ocrMs = ocrMs
        self.fusionMs = fusionMs
        self.safetyMs = safetyMs
    }
}
