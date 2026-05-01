/*
 * Metamorphia
 * Defaults keys for Retrace (temporal-recall indexing). All sources default
 * to opt-in (off) except Clipboard and Agent turns, matching the onboarding
 * copy's privacy-first stance.
 */

import Defaults
import Foundation

public extension Defaults.Keys {

    // MARK: - Master switch

    /// When `false`, no Retrace ingestion happens and queries return empty.
    /// Kill switch; takes effect on the next archiver event (no restart).
    static let retraceIngestionEnabled = Key<Bool>(
        "metamorphia.retrace.ingestion.enabled",
        default: true
    )

    // MARK: - Per-source toggles

    static let retraceScreenEnabled   = Key<Bool>("metamorphia.retrace.screen.enabled",   default: false)
    static let retraceFilesEnabled    = Key<Bool>("metamorphia.retrace.files.enabled",    default: false)
    static let retraceClipboardEnabled = Key<Bool>("metamorphia.retrace.clipboard.enabled", default: true)
    static let retraceBrowserEnabled  = Key<Bool>("metamorphia.retrace.browser.enabled",  default: false)
    static let retraceMessagesEnabled = Key<Bool>("metamorphia.retrace.messages.enabled", default: false)
    static let retraceMailEnabled     = Key<Bool>("metamorphia.retrace.mail.enabled",     default: false)
    static let retraceCalendarEnabled = Key<Bool>("metamorphia.retrace.calendar.enabled", default: true)
    static let retraceAgentTurnsEnabled = Key<Bool>("metamorphia.retrace.agentTurns.enabled", default: true)

    // MARK: - Retention

    /// Days to retain indexed items before pruning. Default 60.
    static let retraceRetentionDays = Key<Int>(
        "metamorphia.retrace.retention.days",
        default: 60
    )

    // MARK: - Watched folders (file harvest)

    static let retraceWatchDocuments = Key<Bool>("metamorphia.retrace.watch.documents", default: true)
    static let retraceWatchDownloads = Key<Bool>("metamorphia.retrace.watch.downloads", default: true)
    static let retraceWatchDesktop   = Key<Bool>("metamorphia.retrace.watch.desktop",   default: false)
    static let retraceWatchICloud    = Key<Bool>("metamorphia.retrace.watch.icloud",    default: false)
}
