import AppIntents

struct MetamorphiaRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SleepMacIntent(),
            phrases: ["Sleep my Mac with \(.applicationName)", "Sleep Mac with \(.applicationName)"],
            shortTitle: "Sleep Mac",
            systemImageName: "moon.fill"
        )
        AppShortcut(
            intent: LockMacIntent(),
            phrases: ["Lock my Mac with \(.applicationName)", "Lock Mac with \(.applicationName)"],
            shortTitle: "Lock Mac",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: ["Play music on my Mac with \(.applicationName)", "Resume music with \(.applicationName)"],
            shortTitle: "Play Music",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PauseMusicIntent(),
            phrases: ["Pause music on my Mac with \(.applicationName)"],
            shortTitle: "Pause Music",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Next track on my Mac with \(.applicationName)", "Skip the song with \(.applicationName)"],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: ["Previous track on my Mac with \(.applicationName)"],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: KeepMacAwakeIntent(),
            phrases: ["Keep my Mac awake with \(.applicationName)"],
            shortTitle: "Keep Awake",
            systemImageName: "cup.and.saucer.fill"
        )
        AppShortcut(
            intent: LetMacSleepIntent(),
            phrases: ["Allow my Mac to sleep with \(.applicationName)", "Stop keeping my Mac awake with \(.applicationName)"],
            shortTitle: "Allow Sleep",
            systemImageName: "zzz"
        )
    }
}
