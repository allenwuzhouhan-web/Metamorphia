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
        NSLog("✍️ [Metamorphia/WritingTools] hotkey ⌃⌥W pressed")

        // No Accessibility permission yet → trigger the system prompt AND show a
        // clear notice, instead of silently doing nothing.
        guard TextFieldAccess.isTrusted else {
            AccessibilityPermissionStore.shared.requestAuthorizationPrompt()
            showHosting(
                WritingToolsNoticeView(
                    systemImage: "lock.shield",
                    title: "Enable Accessibility",
                    message: "Writing Tools needs Accessibility access to read your selection and write the result back. Approve Metamorphia in System Settings, then press ⌃⌥W again.",
                    actionTitle: "Open Settings",
                    action: { AccessibilityPermissionStore.shared.openSystemSettings() },
                    onClose: { [weak self] in self?.dismiss() }
                ),
                width: 330, height: 210, activating: true
            )
            return
        }

        // Capture the selection NOW, before our panel can disturb the focused element.
        let selection = TextFieldAccess.selectedText()
        let initialText = selection ?? TextFieldAccess.focusedWindowText(maxChars: 6000) ?? ""
        guard !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showHosting(
                WritingToolsNoticeView(
                    systemImage: "text.cursor",
                    title: "Select some text",
                    message: "Highlight text in any app, then press ⌃⌥W to proofread, rewrite, summarize, or draft a reply.",
                    actionTitle: nil,
                    action: nil,
                    onClose: { [weak self] in self?.dismiss() }
                ),
                width: 330, height: 180, activating: false
            )
            return
        }

        // For Smart Reply, the surrounding window text is useful context.
        let context = selection != nil ? TextFieldAccess.focusedWindowText(maxChars: 2000) : nil
        let root = WritingToolsPanelView(
            initialText: initialText,
            sourceContext: context,
            onReplace: { [weak self] result in
                _ = TextFieldAccess.replaceSelection(with: result)
                self?.dismiss()
            },
            onClose: { [weak self] in self?.dismiss() }
        )
        showHosting(root, width: 400, height: 460, activating: false)
    }

    /// Builds and floats a borderless panel hosting `rootView`. `activating` makes the
    /// panel take focus (used for the permission notice, which has a button); the
    /// Writing-Tools panel itself stays non-activating so the source app keeps focus
    /// for write-back.
    private func showHosting<V: View>(_ rootView: V, width: CGFloat, height: CGFloat, activating: Bool) {
        dismiss()
        let hosting = NSHostingController(rootView: rootView)
        let style: NSWindow.StyleMask = activating
            ? [.borderless, .fullSizeContentView]
            : [.nonactivatingPanel, .borderless, .fullSizeContentView]
        let newPanel = FloatingToolPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        newPanel.contentViewController = hosting
        newPanel.isMovableByWindowBackground = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = !activating
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.delegate = self

        position(newPanel)
        panel = newPanel
        if activating {
            newPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            newPanel.orderFrontRegardless()
        }
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

/// Small dark panel shown when Writing Tools can't run yet — either Accessibility
/// permission is missing or nothing is selected. Keeps the hotkey from feeling dead.
private struct WritingToolsNoticeView: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
            Text(message)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }
}
