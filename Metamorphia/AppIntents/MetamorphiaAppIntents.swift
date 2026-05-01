import AppIntents
import AppKit
import Foundation
#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

// MARK: - RunAgentIntent

struct RunAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Metamorphia"
    static var description = IntentDescription(
        "Send a prompt to the Metamorphia AI agent and return its reply. Use this to pipe agent output into any Shortcut.",
        categoryName: "Agent"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Prompt",
        description: "What you want Metamorphia to do.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var prompt: String

    @Parameter(
        title: "Show in notch",
        description: "Open the command bar so the run streams live. Turn off for fully background runs.",
        default: true
    )
    var showNotch: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Metamorphia \(\.$prompt)") {
            \.$showNotch
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await MetamorphiaIntentEngine.run(prompt: prompt, showNotch: showNotch)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - AnalyzeFileIntent

struct AnalyzeFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Analyze File with Metamorphia"
    static var description = IntentDescription(
        "Send a file to the Metamorphia agent for analysis. Also available as a right-click Services action in Finder.",
        categoryName: "Agent"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "File", description: "The file to analyze.")
    var file: IntentFile

    @Parameter(
        title: "Question",
        description: "Optional — what should Metamorphia look for? Leave blank for a general summary.",
        default: "",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var question: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Analyze \(\.$file) with Metamorphia") {
            \.$question
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let path = Self.resolvedPath(for: file)
        let prompt = MetamorphiaIntentEngine.analyzeFilePrompt(
            paths: path.map { [$0] } ?? [],
            question: question
        )
        let text = await MetamorphiaIntentEngine.run(prompt: prompt, showNotch: true)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }

    /// IntentFile can be backed by a security-scoped URL OR raw data. If it's
    /// the latter, spill the bytes into a temp file so the agent's shell tools
    /// can reach them by path like any other file.
    static func resolvedPath(for file: IntentFile) -> String? {
        if let url = file.fileURL {
            return url.standardizedFileURL.path
        }
        let filename = file.filename
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("metamorphia-intent-\(UUID().uuidString)-\(filename)")
        do {
            try file.data.write(to: tmp, options: .atomic)
            return tmp.path
        } catch {
            NSLog("[AnalyzeFileIntent] failed to materialize IntentFile: \(error)")
            return nil
        }
    }
}

// MARK: - StartTimerIntent

struct StartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Metamorphia Timer"
    static var description = IntentDescription(
        "Start a timer in the notch.",
        categoryName: "Timer"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes", default: 5, controlStyle: .field, inclusiveRange: (1, 600))
    var minutes: Int

    @Parameter(title: "Label", default: "Timer")
    var label: String

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$minutes)-minute \(\.$label)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let duration = TimeInterval(max(1, minutes) * 60)
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        TimerManager.shared.startTimer(
            duration: duration,
            name: name.isEmpty ? "Timer" : name
        )
        return .result()
    }
}

// MARK: - ToggleNotchIntent

enum NotchAction: String, AppEnum {
    case toggle, open, close

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Notch Action"
    static var caseDisplayRepresentations: [NotchAction: DisplayRepresentation] = [
        .toggle: "Toggle",
        .open: "Open",
        .close: "Close"
    ]
}

struct ToggleNotchIntent: AppIntent {
    static var title: LocalizedStringResource = "Peek Metamorphia Notch"
    static var description = IntentDescription(
        "Open, close, or toggle the notch.",
        categoryName: "UI"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Action", default: .toggle)
    var action: NotchAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) the Metamorphia notch")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let vm = AppDelegate.shared?.vm else { return .result() }
        switch action {
        case .open:
            vm.open()
        case .close:
            vm.close()
        case .toggle:
            switch vm.notchState {
            case .open: vm.close()
            case .closed, .minimized: vm.open()
            }
        }
        return .result()
    }
}

// MARK: - AddToShelfIntent

struct AddToShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Metamorphia Shelf"
    static var description = IntentDescription(
        "Drop files onto the notch shelf from any Shortcut.",
        categoryName: "Shelf"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$files) to the Metamorphia shelf")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let urls: [URL] = files.compactMap { file in
            if let url = file.fileURL { return url }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("metamorphia-shelf-\(UUID().uuidString)-\(file.filename)")
            do {
                try file.data.write(to: tmp, options: .atomic)
                return tmp
            } catch {
                NSLog("[AddToShelfIntent] failed to materialize \(file.filename): \(error)")
                return nil
            }
        }
        let items = await ShelfDropService.items(from: urls)
        ShelfStateViewModel.shared.add(items)
        return .result(value: items.count)
    }
}

// MARK: - PickColorIntent

struct PickColorIntent: AppIntent {
    static var title: LocalizedStringResource = "Pick Color with Metamorphia"
    static var description = IntentDescription(
        "Open the Metamorphia color picker.",
        categoryName: "UI"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        ColorPickerPanelManager.shared.showColorPickerPanel()
        return .result()
    }
}

// MARK: - CaptureNowPlayingIntent

struct CaptureNowPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Now Playing"
    static var description = IntentDescription(
        "Return what Metamorphia currently sees playing (title, artist, album).",
        categoryName: "Music"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let music = MusicManager.shared
        guard music.hasActiveSession else {
            return .result(value: "Nothing is playing.", dialog: "Nothing is playing.")
        }
        let pieces = [music.songTitle, music.artistName, music.album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let summary = pieces.joined(separator: " — ")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}
