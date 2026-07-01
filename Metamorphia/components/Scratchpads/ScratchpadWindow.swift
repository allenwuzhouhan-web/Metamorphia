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

import AppKit
import SwiftUI
import QuartzCore

/// A floating scratchpad panel. Unlike Writing Tools (read-only), scratchpads accept
/// keyboard input (regex/JSON/translate editing), so this panel becomes key.
private final class FloatingScratchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Esc dismisses the floating scratchpad / tool picker.
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Floats scratchpad tiles as small always-on-top panels. Several can be open at
/// once — dragging a tile out of the notch tray spawns one at the drop point.
@MainActor
final class ScratchpadWindow: NSObject, NSWindowDelegate {
    static let shared = ScratchpadWindow()

    private var panels: Set<NSWindow> = []
    private override init() { super.init() }

    /// Open `tool` as a floating panel. `screenPoint` is the AppKit global location
    /// (bottom-left origin) to place it near — typically the drag drop point. nil centers it.
    func present(tool: ScratchTool, at screenPoint: CGPoint?) {
        // The palette tile hosts a color wheel + variants, so it needs more room.
        let size = tool == .palette ? NSSize(width: 430, height: 680) : NSSize(width: 380, height: 460)
        let panel = makePanel(size: size)
        let root = ScratchpadHostView(tool: tool, onClose: { [weak self, weak panel] in
            if let panel { self?.close(panel) }
        })
        panel.contentViewController = NSHostingController(rootView: root)
        animateIn(panel, at: screenPoint)
    }

    // MARK: - Window plumbing

    private func makePanel(size: NSSize) -> FloatingScratchPanel {
        let panel = FloatingScratchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    /// Position, track, and animate the panel in with a smooth fade + grow.
    private func animateIn(_ panel: NSWindow, at screenPoint: CGPoint?) {
        position(panel, at: screenPoint)
        panels.insert(panel)

        let target = panel.frame
        let start = target.insetBy(dx: target.width * 0.06, dy: target.height * 0.06)
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    private func close(_ window: NSWindow) {
        window.delegate = nil
        panels.remove(window)
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            panels.remove(window)
        }
    }

    private func position(_ panel: NSWindow, at screenPoint: CGPoint?) {
        let size = panel.frame.size
        // Pick the host screen from the actual drop point, not the offset origin,
        // so a drop near a monitor edge can't clamp the panel onto the wrong screen.
        let host: NSScreen?
        if let point = screenPoint {
            host = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        } else {
            host = NSScreen.main
        }

        var origin: NSPoint
        if let point = screenPoint {
            // Treat the drop point as the panel's top-left.
            origin = NSPoint(x: point.x, y: point.y - size.height)
        } else if let visible = host?.visibleFrame {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        } else {
            origin = NSPoint(x: 200, y: 200)
        }

        if let visible = host?.visibleFrame {
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
            origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}
