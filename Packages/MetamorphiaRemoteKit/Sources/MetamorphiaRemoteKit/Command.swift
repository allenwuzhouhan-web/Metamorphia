import Foundation

/// A command sent from the iPhone app to the Mac host.
///
/// Encoded into a `PendingCommand` CloudKit record's `kind` + `payload` fields.
/// The Mac listener decodes and dispatches to the appropriate local API.
public enum Command: Codable, Equatable, Sendable {
    case sleepMac
    case lockMac
    case playMusic
    case pauseMusic
    case nextTrack
    case previousTrack
    case setKeepAwake(Bool)

    /// Stable identifier written to `PendingCommand.kind`. Decoupled from
    /// `CodingKeys` so Swift refactors can't silently break records that the
    /// other device wrote at an earlier version.
    public var kind: String {
        switch self {
        case .sleepMac:        return "sleep_mac"
        case .lockMac:         return "lock_mac"
        case .playMusic:       return "play_music"
        case .pauseMusic:      return "pause_music"
        case .nextTrack:       return "next_track"
        case .previousTrack:   return "previous_track"
        case .setKeepAwake:    return "set_keep_awake"
        }
    }

    /// Codable payload for cases that carry parameters. `nil` for parameterless
    /// commands. The Mac listener decodes this from `PendingCommand.payload`.
    public var payload: Data? {
        switch self {
        case .setKeepAwake(let on):
            return try? JSONEncoder().encode(SetKeepAwakePayload(on: on))
        case .sleepMac, .lockMac, .playMusic, .pauseMusic, .nextTrack, .previousTrack:
            return nil
        }
    }

    /// Reconstruct a `Command` from the wire form (kind + payload).
    /// Returns `nil` if the kind is unknown or the payload fails to decode.
    public static func decode(kind: String, payload: Data?) -> Command? {
        switch kind {
        case "sleep_mac":      return .sleepMac
        case "lock_mac":       return .lockMac
        case "play_music":     return .playMusic
        case "pause_music":    return .pauseMusic
        case "next_track":     return .nextTrack
        case "previous_track": return .previousTrack
        case "set_keep_awake":
            guard let payload,
                  let body = try? JSONDecoder().decode(SetKeepAwakePayload.self, from: payload)
            else { return nil }
            return .setKeepAwake(body.on)
        default:
            return nil
        }
    }
}

private struct SetKeepAwakePayload: Codable {
    let on: Bool
}
