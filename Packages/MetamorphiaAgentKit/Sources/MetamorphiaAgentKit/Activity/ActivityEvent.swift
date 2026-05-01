import Foundation

// MARK: - ActivitySource

/// Identifies which sensor or subsystem produced an ``ActivityEvent``.
public enum ActivitySource: String, Codable, Sendable, CaseIterable {
    case appFocusSensor
    case browserTabSensor
    case inputIdleSensor
    case meetingDetector
    case placeSensor
    case cameraMonitor
    case microphoneMonitor
    case focusMode
    case clipboard
    case commandBar
    case surface
    case sessionSegmenter
    case system
    case selectionTracker
    case documentWatcher

    // Retrace ingestors — each emits a privacy-preserving receipt (sizes or
    // hashes only) whenever it writes content into the searchable index.
    case screenHarvest
    case fileHarvest
    case clipArchive
    case browserArchive
    case messageArchive
    case mailArchive
    case calendarArchive
    case agentTurnArchive
}

// MARK: - Supporting types

/// The variety of content that was copied to the clipboard.
/// No payload data is captured — only the shape and byte count.
public enum ClipboardKind: String, Codable, Sendable {
    case text, url, image, file, other
}

/// How a clipboard change originated.
public enum PasteOrigin: String, Sendable, Codable, Hashable {
    /// Normal local copy by the user on this device.
    case local
    /// Universal Clipboard — item arrived from another Apple device via Handoff.
    case remote
    /// Password manager or other app wrote a concealed item.
    case concealed
    /// Frontmost app is in the password-manager denylist; data read suppressed.
    case denylist
}

/// Coarse file-size bucket emitted with each `documentOpened` event.
/// Buckets are stable across versions — never remove or reorder existing cases.
public enum DocSizeBucket: String, Sendable, Codable, Hashable {
    case tiny   // < 10 KB
    case small  // 10 KB – 1 MB
    case medium // 1 MB – 10 MB
    case large  // 10 MB – 100 MB
    case xlarge // >= 100 MB

    public static func classify(bytes: Int64) -> DocSizeBucket {
        switch bytes {
        case ..<10_240:        return .tiny
        case ..<1_048_576:     return .small
        case ..<10_485_760:    return .medium
        case ..<104_857_600:   return .large
        default:               return .xlarge
        }
    }
}

/// How the user interacted with a surface element.
public enum SurfaceAction: String, Codable, Sendable {
    case viewed, engaged, dismissed, ignored
}

/// Broad usage tier for a closed session, derived by the session segmenter.
public enum CadenceTier: String, Codable, Sendable {
    case idle, light, heavy
}

// MARK: - ActivityEvent

/// A typed, privacy-respecting activity signal emitted by Metamorphia's sensors.
///
/// Design constraints (load-bearing, do not broaden):
/// - No raw URLs, SSIDs, or clipboard content. `urlVisited` carries a SHA-256
///   hash of the URL plus its public host only. `placeChanged` carries a hash only.
///   `clipboardCopied` carries kind + byte count only.
/// - `querySubmitted` carries a stable UUID + entity count, not the prompt text.
///   Prompt text is persisted separately by `ConversationPersistenceService`.
/// - All cases are `Codable` and `Hashable` so they can be serialised to the
///   `ActivityJournal` and used as dictionary keys in de-duplication passes.
public enum ActivityEvent: Codable, Sendable, Hashable {

    // MARK: - Cases

    /// The foreground application changed.
    case focusChanged(bundleID: String, appName: String, windowTitle: String?, pid: Int32, at: Date)

    /// The user has been idle (no input) for `idleSeconds`.
    case inputIdle(idleSeconds: Int, at: Date)

    /// Input activity resumed after an idle stretch of `afterIdleSeconds`.
    case inputResumed(afterIdleSeconds: Int, at: Date)

    /// A browser tab navigated to a URL (hash-only; host is the eTLD+1).
    case urlVisited(urlHash: String, host: String, title: String?, browserBundleID: String, at: Date)

    /// A video-conferencing session started.
    case meetingStarted(app: String, at: Date)

    /// A video-conferencing session ended.
    case meetingEnded(durationSeconds: Int, at: Date)

    /// The inferred physical place changed (network / location fingerprint hash).
    case placeChanged(placeHash: String, label: String?, at: Date)

    /// The device camera was activated or deactivated.
    case cameraToggled(isActive: Bool, at: Date)

    /// The device microphone was activated or deactivated.
    case microphoneToggled(isActive: Bool, at: Date)

    /// The system Focus mode changed (`nil` means Focus is now off).
    case focusModeChanged(mode: String?, at: Date)

    /// Text or data was copied to the clipboard (no content — kind + size + origin only).
    case clipboardCopied(kind: ClipboardKind, byteCount: Int, origin: PasteOrigin, at: Date)

    /// A command-bar query was submitted (UUID + entity count only — no prompt text).
    case querySubmitted(queryID: UUID, entityCount: Int, at: Date)

    /// A Metamorphia surface received a discrete interaction.
    case surfaceEngaged(surface: String, action: SurfaceAction, durationMs: Int, at: Date)

    /// An app or document session was closed by the segmenter.
    /// - Note: `docHint` is a short window-title snippet only — never a URL,
    ///   file path, or clipboard content. Redacted upstream by the segmenter.
    case sessionClosed(bundleID: String, docHint: String?, durationSeconds: Int, cadenceTier: CadenceTier, at: Date)

    // MARK: - Retrace ingestion receipts

    /// A frame of on-screen text was indexed by `ScreenHarvest`. Bytes only —
    /// the content lives in the Retrace index, not the activity stream.
    case screenFrameIngested(bundleID: String, bodyBytes: Int, at: Date)

    /// A file's text content was indexed by `FileHarvest`. No raw path —
    /// only the bundle/volume owner and byte count.
    case fileIndexed(pathHash: String, bytes: Int, at: Date)

    /// A clipboard item was archived. Kind + size only (mirrors `clipboardCopied`).
    case clipIndexed(kind: ClipboardKind, bytes: Int, at: Date)

    /// A browser page was archived after dwell threshold. Host only.
    case browserPageIndexed(host: String, bytes: Int, at: Date)

    /// A messaging row was indexed. Sender hash only.
    case messageIndexed(senderHash: String, at: Date)

    /// An email was indexed. `fromHash` is a short hash of the sender address.
    case mailIndexed(fromHash: String, subjectBytes: Int, at: Date)

    /// A calendar event was indexed.
    case calendarIndexed(at: Date)

    /// An agent conversation turn was indexed.
    case agentTurnIndexed(turnKind: String, at: Date)

    /// The user's text selection changed in a focused application.
    /// `role` is the AX role of the element (e.g. "AXTextField", "AXTextArea").
    /// `selectionLength` is the character count of the selected range (never the text itself).
    case selectionChanged(bundleID: String, role: String, selectionLength: Int, at: Date)

    /// A file was opened or created in a watched directory.
    /// `bundleID` is the opener application (nil if unknown). No file path is stored.
    case documentOpened(bundleID: String?, fileExtension: String, sizeBucket: DocSizeBucket, at: Date)

    // MARK: - Derived properties

    /// The wall-clock time at which this event was observed.
    public var timestamp: Date {
        switch self {
        case .focusChanged(_, _, _, _, let at):        return at
        case .inputIdle(_, let at):                    return at
        case .inputResumed(_, let at):                 return at
        case .urlVisited(_, _, _, _, let at):          return at
        case .meetingStarted(_, let at):               return at
        case .meetingEnded(_, let at):                 return at
        case .placeChanged(_, _, let at):              return at
        case .cameraToggled(_, let at):                return at
        case .microphoneToggled(_, let at):            return at
        case .focusModeChanged(_, let at):             return at
        case .clipboardCopied(_, _, _, let at):        return at
        case .querySubmitted(_, _, let at):            return at
        case .surfaceEngaged(_, _, _, let at):         return at
        case .sessionClosed(_, _, _, _, let at):       return at
        case .screenFrameIngested(_, _, let at):       return at
        case .fileIndexed(_, _, let at):               return at
        case .clipIndexed(_, _, let at):               return at
        case .browserPageIndexed(_, _, let at):        return at
        case .messageIndexed(_, let at):               return at
        case .mailIndexed(_, _, let at):               return at
        case .calendarIndexed(let at):                 return at
        case .agentTurnIndexed(_, let at):             return at
        case .selectionChanged(_, _, _, let at):       return at
        case .documentOpened(_, _, _, let at):         return at
        }
    }

    /// The sensor or subsystem that produced this event.
    ///
    /// The switch is exhaustive by design — the compiler will flag any new case
    /// added to `ActivityEvent` that has no mapping here.
    public var source: ActivitySource {
        switch self {
        case .focusChanged:      return .appFocusSensor
        case .inputIdle:         return .inputIdleSensor
        case .inputResumed:      return .inputIdleSensor
        case .urlVisited:        return .browserTabSensor
        case .meetingStarted:    return .meetingDetector
        case .meetingEnded:      return .meetingDetector
        case .placeChanged:      return .placeSensor
        case .cameraToggled:     return .cameraMonitor
        case .microphoneToggled: return .microphoneMonitor
        case .focusModeChanged:  return .focusMode
        case .clipboardCopied:   return .clipboard
        case .querySubmitted:    return .commandBar
        case .surfaceEngaged:    return .surface
        case .sessionClosed:     return .sessionSegmenter
        case .screenFrameIngested: return .screenHarvest
        case .fileIndexed:         return .fileHarvest
        case .clipIndexed:         return .clipArchive
        case .browserPageIndexed:  return .browserArchive
        case .messageIndexed:      return .messageArchive
        case .mailIndexed:         return .mailArchive
        case .calendarIndexed:     return .calendarArchive
        case .agentTurnIndexed:    return .agentTurnArchive
        case .selectionChanged:    return .selectionTracker
        case .documentOpened:      return .documentWatcher
        }
    }
}
