import AppIntents
import Foundation
#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

// App Intents must be declared at compile time, so this file is a curated
// hand-picked surface over the runtime ToolRegistry. Each intent maps 1:1
// to a REAL registered tool and dispatches through executeDirectly so the
// side-effects match LLM-driven calls. Tools added to the registry at
// runtime (MCP, etc.) are NOT reachable here by design.

private enum CuratedIntentRunner {
    @MainActor
    static func run(tool: String, args: [String: Any]) async -> String {
        guard let registry = MetamorphiaBootstrap.registry else {
            return "Metamorphia isn't ready yet."
        }
        let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        do { return try await registry.executeDirectly(toolName: tool, arguments: json) }
        catch { return "Couldn't run \(tool): \(error.localizedDescription)" }
    }
}

// MARK: - WebSearchIntent

struct WebSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Search the web with Metamorphia"
    static var description = IntentDescription(
        "Run a web search through Metamorphia.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Query")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search the web for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "search_web", args: ["query": query])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - RecallSceneIntent

struct RecallSceneIntent: AppIntent {
    static var title: LocalizedStringResource = "Recall what I was doing"
    static var description = IntentDescription(
        "Search Metamorphia's Retrace timeline for something you previously worked on.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Query", description: "Describe what you're looking for, e.g. 'the paper I wrote yesterday'")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Recall \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "recall_scene", args: ["query": query])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - ReadClipboardHistoryIntent

struct ReadClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Read Metamorphia clipboard history"
    static var description = IntentDescription(
        "Return the most recent items from Metamorphia's clipboard history.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Count", description: "Number of recent items to return", default: 10, inclusiveRange: (1, 50))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Read \(\.$count) clipboard items")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "read_clipboard_history", args: ["count": count])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - SearchClipboardHistoryIntent

struct SearchClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Search clipboard history"
    static var description = IntentDescription(
        "Search Metamorphia's clipboard history for entries matching a query.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Query")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search clipboard for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "search_clipboard_history", args: ["query": query])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - SystemStatsIntent

struct SystemStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Mac system stats"
    static var description = IntentDescription(
        "Return current CPU, memory, GPU, network, and disk stats from Metamorphia.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "get_metamorphia_system_stats", args: [:])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - PlotFunctionIntent

struct PlotFunctionIntent: AppIntent {
    static var title: LocalizedStringResource = "Plot a function"
    static var description = IntentDescription(
        "Graph a mathematical function of x in Metamorphia.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Expression", description: "A function of x, e.g. 'sin(x)' or 'x^2 - 3'")
    var expression: String

    static var parameterSummary: some ParameterSummary {
        Summary("Plot \(\.$expression)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "plot_function", args: ["expression": expression])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - RenderLatexIntent

struct RenderLatexIntent: AppIntent {
    static var title: LocalizedStringResource = "Render LaTeX"
    static var description = IntentDescription(
        "Render a LaTeX expression in Metamorphia.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "LaTeX")
    var latex: String

    static var parameterSummary: some ParameterSummary {
        Summary("Render LaTeX: \(\.$latex)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "render_latex", args: ["latex": latex])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - AppendNoteIntent

struct AppendNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Append a Metamorphia note"
    static var description = IntentDescription(
        "Save a new note into Metamorphia's note store.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Note", description: "The note content to save", inputOptions: String.IntentInputOptions(multiline: true))
    var body: String

    static var parameterSummary: some ParameterSummary {
        Summary("Append note: \(\.$body)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "append_note", args: ["body": body])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - ReadRecentNotesIntent

struct ReadRecentNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Read recent notes"
    static var description = IntentDescription(
        "Return the most recent saved notes from Metamorphia.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Limit", default: 10, inclusiveRange: (1, 50))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Read \(\.$limit) recent notes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "read_recent_notes", args: ["limit": limit])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - ListShelfIntent

struct ListShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "List shelf items"
    static var description = IntentDescription(
        "List items currently on the Metamorphia shelf.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "list_shelf", args: [:])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - ReadCalendarIntent

struct ReadCalendarIntent: AppIntent {
    static var title: LocalizedStringResource = "Read Metamorphia calendar"
    static var description = IntentDescription(
        "Return upcoming calendar events from Metamorphia.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Today only", default: true)
    var forToday: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Read calendar (today: \(\.$forToday))")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "read_metamorphia_calendar", args: ["for_today": forToday])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - NewsFeedIntent

struct NewsFeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Get news from Metamorphia"
    static var description = IntentDescription(
        "Search for news articles via Metamorphia.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Topic", description: "What to search for, e.g. 'AI regulation'")
    var topic: String

    static var parameterSummary: some ParameterSummary {
        Summary("Get news about \(\.$topic)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // news_feed requires "action"; for a user-supplied topic we use "search" + "query".
        let text = await CuratedIntentRunner.run(tool: "news_feed", args: ["action": "search", "query": topic])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - ListTimersIntent

struct ListTimersIntent: AppIntent {
    static var title: LocalizedStringResource = "List active timers"
    static var description = IntentDescription(
        "Return all active timers running in Metamorphia.",
        categoryName: "Tools"
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CuratedIntentRunner.run(tool: "list_timers", args: [:])
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
