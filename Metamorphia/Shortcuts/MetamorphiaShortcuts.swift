import AppKit
import KeyboardShortcuts

/// Additional keyboard shortcuts introduced for Metamorphia. Defined in a separate
/// file so they can be added without touching Metamorphia's existing
/// `ShortcutConstants.swift` enum (which is extended by app upgrades).
///
/// - `.commandBar` = Cmd+Shift+Space — summons the AI Command Bar.
/// - `.toggleNotchOpen` is reused from Metamorphia for the Metamorphia widget UI.
///
/// Registration happens in `AppDelegate.applicationDidFinishLaunching`:
/// ```
/// KeyboardShortcuts.onKeyDown(for: .commandBar) {
///     CommandBarCoordinator.shared.toggle()
/// }
/// ```
public extension KeyboardShortcuts.Name {
    /// Cmd+Shift+Space summons the AI Command Bar.
    static let commandBar = Self(
        "commandBar",
        default: .init(.space, modifiers: [.shift, .command])
    )

    /// Ctrl+Option+W opens Writing Tools on the current text selection.
    static let writingTools = Self(
        "writingTools",
        default: .init(.w, modifiers: [.control, .option])
    )
}
