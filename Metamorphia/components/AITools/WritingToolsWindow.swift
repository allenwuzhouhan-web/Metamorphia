/*
 * Metamorphia – Intelligence Glass
 *
 * Borderless non-activating floating panel that hosts WritingToolsPanelView.
 *
 * Positioning: tries to anchor near the current text selection using the AX
 * parameterized attribute kAXBoundsForRangeParameterizedAttribute (new to this
 * codebase). If that fails or times out, falls back to NSEvent.mouseLocation.
 *
 * Lifecycle follows ClipboardWindowManager: singleton, lazy panel creation,
 * orderFrontRegardless for above-fullscreen behavior.
 */

#if os(macOS)
import AppKit
import ApplicationServices
import SwiftUI
import MetamorphiaPerception

// MARK: - WritingToolsWindow

@MainActor
final class WritingToolsWindow {

    static let shared = WritingToolsWindow()
    private var panel: NSPanel?

    private init() {}

    // MARK: - Present / Dismiss

    /// Show the Writing Tools panel near the current text selection.
    func present() {
        let view = WritingToolsPanelView { [weak self] in
            self?.dismiss()
        }

        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }

        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        // Size to fit the SwiftUI intrinsic size before positioning.
        let fittingSize = hosting.fittingSize
        panel.setContentSize(fittingSize)

        panel.setFrameOrigin(anchorPoint(panelSize: fittingSize))
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    // MARK: - Panel factory

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        return p
    }

    // MARK: - Anchor point

    /// Returns the bottom-left origin (in screen coords) for the panel,
    /// positioned just below the current text selection when available.
    private func anchorPoint(panelSize: NSSize) -> NSPoint {
        if let selectionRect = selectionScreenRect() {
            // Place 6 pt below the selection's bottom edge.
            let x = selectionRect.minX
            let y = selectionRect.minY - panelSize.height - 6
            return clampToScreen(NSPoint(x: x, y: y), panelSize: panelSize)
        }

        // Fallback: near the mouse cursor.
        let mouse = NSEvent.mouseLocation
        return clampToScreen(
            NSPoint(x: mouse.x, y: mouse.y - panelSize.height - 6),
            panelSize: panelSize
        )
    }

    /// Attempt to read the screen rect of the focused element's selected range
    /// via the parameterized AX attribute kAXBoundsForRangeParameterizedAttribute.
    private func selectionScreenRect() -> NSRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }

        do {
            return try AXTimeoutQueue.shared.run(pid: pid, timeout: 0.1) { () -> NSRect? in
                let app = AXUIElementCreateApplication(pid)
                var focusedRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    app, kAXFocusedUIElementAttribute as CFString, &focusedRef
                ) == .success, let focusedRef else { return nil }
                let focused = focusedRef as! AXUIElement  // swiftlint:disable:this force_cast

                // Read the selected range.
                var rangeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
                ) == .success, let rangeRef else { return nil }
                guard CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
                var cfRange = CFRange()
                guard AXValueGetValue(
                    rangeRef as! AXValue,  // swiftlint:disable:this force_cast
                    .cfRange, &cfRange
                ) else { return nil }

                // Build an AXValue wrapping the range for the parameterized call.
                guard let axRangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }

                var boundsRef: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(
                    focused,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    axRangeValue,
                    &boundsRef
                ) == .success, let boundsRef else { return nil }
                guard CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }

                var rect = CGRect.zero
                guard AXValueGetValue(
                    boundsRef as! AXValue,  // swiftlint:disable:this force_cast
                    .cgRect, &rect
                ) else { return nil }

                // AX returns rects in top-left screen space; convert to AppKit bottom-left.
                guard let screenHeight = NSScreen.main?.frame.height else { return nil }
                let flipped = NSRect(
                    x: rect.origin.x,
                    y: screenHeight - rect.origin.y - rect.height,
                    width: rect.width,
                    height: rect.height
                )
                return flipped
            }
        } catch {
            return nil
        }
    }

    // MARK: - Screen clamping

    private func clampToScreen(_ origin: NSPoint, panelSize: NSSize) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(origin.x, screen.minX), screen.maxX - panelSize.width)
        let y = min(max(origin.y, screen.minY), screen.maxY - panelSize.height)
        return NSPoint(x: x, y: y)
    }
}
#endif
