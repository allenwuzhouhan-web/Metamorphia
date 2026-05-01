import AppIntents

struct MetamorphiaRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SleepMacIntent(),
            phrases: ["Sleep my Mac", "Sleep Mac with \(.applicationName)"],
            shortTitle: "Sleep Mac",
            systemImageName: "moon.fill"
        )
        AppShortcut(
            intent: LockMacIntent(),
            phrases: ["Lock my Mac", "Lock Mac with \(.applicationName)"],
            shortTitle: "Lock Mac",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: ["Play music on my Mac", "Resume music on my Mac"],
            shortTitle: "Play Music",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PauseMusicIntent(),
            phrases: ["Pause music on my Mac"],
            shortTitle: "Pause Music",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Next track on my Mac", "Skip the song on my Mac"],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: ["Previous track on my Mac"],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: KeepMacAwakeIntent(),
            phrases: ["Keep my Mac awake"],
            shortTitle: "Keep Awake",
            systemImageName: "cup.and.saucer.fill"
        )
        AppShortcut(
            intent: LetMacSleepIntent(),
            phrases: ["Allow my Mac to sleep", "Stop keeping my Mac awake"],
            shortTitle: "Allow Sleep",
            systemImageName: "zzz"
        )
    }
}
