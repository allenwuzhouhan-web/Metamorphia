import AppKit
import Defaults

/// A small, restraint-first haptic vocabulary for the whole app.
///
/// The Mac only has one system performer and a handful of feedback patterns, so
/// premium feel comes from consistency, not volume: the same gesture always
/// produces the same tap. Every call routes through here and honors the master
/// `enableHaptics` switch, replacing the scattered ad-hoc
/// `NSHapticFeedbackManager.defaultPerformer.perform(...)` calls with four named
/// intents.
enum Haptics {
    /// Light, incidental feedback — a list item continued, a value copied.
    static func tick() { perform(.generic) }

    /// A soft "settle" for something blooming into place — a panel, a tile.
    static func bloom() { perform(.levelChange) }

    /// Success / commit — an agent finished, a note saved.
    static func confirm() { perform(.levelChange) }

    /// A selection or state change — a tab switch, a checkbox, an indent shift.
    static func select() { perform(.alignment) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Defaults[.enableHaptics] else { return }
        // `.now` fires immediately so the tap lands with the visible change,
        // rather than being coalesced to the next idle moment.
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
