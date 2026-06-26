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
import Defaults

/// A floating, non-activating panel that becomes key without activating the app —
/// the standard tool-palette behaviour. Non-activating is essential here: the app
/// the user selected text in must STAY frontmost so "Replace" can write the result
/// back into its focused field (via AX or a synthesized paste).
private final class FloatingToolPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the Writing Tools panel and drives it from the global hotkey. Captures the
/// frontmost app's text selection at invoke time, then floats the panel beside the
/// cursor.
@MainActor
final class WritingToolsWindow: NSObject, NSWindowDelegate {
    static let shared = WritingToolsWindow()

    private var panel: NSPanel?
    private override init() { super.init() }

    var isVisible: Bool { panel != nil }

    func toggle() {
        if isVisible { dismiss() } else { present() }
    }

    func present() {
        guard Defaults[.enableWritingTools] else { return }

        // Capture the selection NOW, before our panel can disturb the focused element.
        let selection = TextFieldAccess.selectedText()
        let initialText = selection ?? TextFieldAccess.focusedWindowText(maxChars: 6000) ?? ""
        guard !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        // For Smart Reply, the surrounding window text is useful context.
        let context = selection != nil ? TextFieldAccess.focusedWindowText(maxChars: 2000) : nil

        dismiss()

        let root = WritingToolsPanelView(
            initialText: initialText,
            sourceContext: context,
            onReplace: { [weak self] result in
                _ = TextFieldAccess.replaceSelection(with: result)
                self?.dismiss()
            },
            onClose: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingController(rootView: root)
        let newPanel = FloatingToolPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.contentViewController = hosting
        newPanel.isMovableByWindowBackground = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.delegate = self

        position(newPanel)
        panel = newPanel
        newPanel.orderFrontRegardless()
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.close()
    }

    // Clear the reference if the panel is closed by any other path.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel {
            panel = nil
        }
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
            origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}
