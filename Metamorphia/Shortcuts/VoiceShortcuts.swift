import AppKit
import KeyboardShortcuts

/// Cmd+Shift+V summons Metamorphia's voice input. Added here (not inside
/// `MetamorphiaShortcuts.swift`) so T5 can land without touching the T1
/// hotkey file. Registration happens in `MetamorphiaBootstrap.configure()`.
public extension KeyboardShortcuts.Name {
    /// Cmd+Shift+V toggles voice listening.
    static let voiceInput = Self(
        "voiceInput",
        default: .init(.v, modifiers: [.shift, .command])
    )
}
