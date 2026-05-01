import Defaults
import Foundation
import MetamorphiaAgentKit

// MARK: - Defaults key

extension Defaults.Keys {
    /// Master switch for the activity-observation spine (``ActivityStream`` +
    /// ``ActivityJournal`` + all sensors). When `false`, every sensor stops
    /// emitting and the journal stops growing. Default: `true` — the spine
    /// records only the typed, redacted event envelopes, never raw content.
    static let activityStreamEnabled = Key<Bool>(
        "metamorphia.activityStream.enabled",
        default: true
    )
}

// MARK: - Gate

/// Gate implementation that reads ``Defaults/Keys/activityStreamEnabled`` on
/// every check. No caching — flipping the toggle in Settings takes effect on
/// the next emit.
struct DefaultsBackedActivityGate: ActivityStreamGate, Sendable {
    var isEnabled: Bool { Defaults[.activityStreamEnabled] }
}
