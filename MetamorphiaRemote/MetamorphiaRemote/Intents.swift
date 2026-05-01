import AppIntents
import MetamorphiaRemoteKit

// Each intent maps 1:1 to a `Command` and returns Siri-spoken confirmation.
// Confirmations are optimistic: the iPhone has no synchronous proof the Mac
// executed the command (the channel is CloudKit + ~30 s polling). This matches
// the HomeKit pattern — Siri says "OK, the lights are on" whether or not the
// bulb is reachable.

struct SleepMacIntent: AppIntent {
    static var title: LocalizedStringResource = "Sleep Mac"
    static var description = IntentDescription("Put your Mac to sleep.", categoryName: "Mac")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CommandSender.shared.send(.sleepMac)
        return .result(dialog: "Sleeping your Mac")
    }
}

struct LockMacIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock Mac"
    static var description = IntentDescription("Lock your Mac's screen.", categoryName: "Mac")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CommandSender.shared.send(.lockMac)
        return .result(dialog: "Locking your Mac")
    }
}

struct PlayMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Music on Mac"
    static var description = IntentDescription("Resume playback on your Mac.", categoryName: "Mac")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CommandSender.shared.send(.playMusic)
        return .result(dialog: "Playing music on your Mac")
    }
}

struct PauseMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Music on Mac"
    static var description = IntentDescription("Pause playback on your Mac.", categoryName: "Mac")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CommandSender.shared.send(.pauseMusic)
        return .result(dialog: "Pausing music on your Mac")
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track on Mac"
    static var description = IntentDescription("Skip to the next track on your Mac.", categoryName: "Mac")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CommandSender.shared.send(.nextTrack)
        return .result(dialog: "Skipping to the next track")
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track on Mac"
    static var description = IntentDescription("Go to the previous track on your Mac.", categoryName: "Mac")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CommandSender.shared.send(.previousTrack)
        return .result(dialog: "Going to the previous track")
    }
}

struct KeepMacAwakeIntent: AppIntent {
    static var title: LocalizedStringResource = "Keep Mac Awake"
    static var description = IntentDescription("Prevent your Mac from sleeping.", categoryName: "Mac")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CommandSender.shared.send(.setKeepAwake(true))
        return .result(dialog: "Keeping your Mac awake")
    }
}

struct LetMacSleepIntent: AppIntent {
    static var title: LocalizedStringResource = "Allow Mac to Sleep"
    static var description = IntentDescription("Stop keeping your Mac awake.", categoryName: "Mac")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CommandSender.shared.send(.setKeepAwake(false))
        return .result(dialog: "Letting your Mac sleep normally")
    }
}
