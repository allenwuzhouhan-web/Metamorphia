/*
 * Metamorphia
 * User-facing preferences for the Market Lens feature. Kept in a sibling file
 * to `MarketModels.swift` rather than piled into `Constants.swift` so the
 * feature's configuration lives alongside its domain types.
 */

import Foundation
import Defaults

extension Defaults.Keys {
    /// Master switch for the Market Lens feature. When false, the polling
    /// timer halts, the closed-notch ticker hides, and the Markets tab is
    /// still visible (so the user can re-enable via the empty-state CTA) but
    /// inert.
    static let marketsEnabled = Key<Bool>("marketsEnabled", default: true)

    /// Poll interval while the notch is open (seconds). Lower values mean
    /// fresher quotes at the cost of Yahoo request volume.
    static let marketsPollIntervalOpen = Key<TimeInterval>("marketsPollIntervalOpen", default: 15.0)

    /// Poll interval while the notch is closed (seconds). Conservative default
    /// since the data just drives the ambient ticker.
    static let marketsPollIntervalClosed = Key<TimeInterval>("marketsPollIntervalClosed", default: 60.0)

    /// Rotating ticker in the closed-notch glance surface.
    static let marketsAmbientTickerEnabled = Key<Bool>("marketsAmbientTickerEnabled", default: true)

    /// One-line morning brief on first unlock of the day.
    static let marketsMorningBriefEnabled = Key<Bool>("marketsMorningBriefEnabled", default: true)

    /// Price-alert Live Activity inside the closed notch. Suppressed during
    /// Do Not Disturb regardless of this flag.
    static let marketsLiveActivityEnabled = Key<Bool>("marketsLiveActivityEnabled", default: true)

    /// Clipboard reflex — when a finance URL lands on the clipboard containing
    /// a watchlist ticker, offer a quiet analyze-this toast.
    static let marketsClipboardReflexEnabled = Key<Bool>("marketsClipboardReflexEnabled", default: true)
}
