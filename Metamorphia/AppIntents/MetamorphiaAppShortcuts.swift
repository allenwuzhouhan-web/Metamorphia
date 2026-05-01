import AppIntents

/// AppShortcut phrases only allow `AppEntity` / `AppEnum` parameter
/// substitutions — free-form `String`, `Int`, and `IntentFile` parameters
/// can't be interpolated into a spoken phrase. Shortcuts still prompts for
/// those params when the user invokes the action, so we keep the phrases
/// unparameterized and let the dialog fill in the rest.
struct MetamorphiaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAgentIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Run a \(.applicationName) prompt"
            ],
            shortTitle: "Ask Metamorphia",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: AnalyzeFileIntent(),
            phrases: [
                "Analyze a file with \(.applicationName)",
                "Let \(.applicationName) look at this file"
            ],
            shortTitle: "Analyze File",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: StartTimerIntent(),
            phrases: [
                "Start a \(.applicationName) timer",
                "Set a \(.applicationName) timer"
            ],
            shortTitle: "Start Timer",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: ToggleNotchIntent(),
            phrases: [
                "Peek \(.applicationName)",
                "Toggle the \(.applicationName) notch",
                "\(.applicationName) \(\.$action)"
            ],
            shortTitle: "Peek Notch",
            systemImageName: "rectangle.topthird.inset.filled"
        )
        AppShortcut(
            intent: AddToShelfIntent(),
            phrases: [
                "Add to \(.applicationName) shelf",
                "Drop this on the \(.applicationName) shelf"
            ],
            shortTitle: "Add to Shelf",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: PickColorIntent(),
            phrases: [
                "Pick a color with \(.applicationName)",
                "Open the \(.applicationName) color picker"
            ],
            shortTitle: "Pick Color",
            systemImageName: "eyedropper"
        )
        AppShortcut(
            intent: CaptureNowPlayingIntent(),
            phrases: [
                "What is \(.applicationName) playing",
                "\(.applicationName) now playing"
            ],
            shortTitle: "Now Playing",
            systemImageName: "music.note"
        )
    }
}
