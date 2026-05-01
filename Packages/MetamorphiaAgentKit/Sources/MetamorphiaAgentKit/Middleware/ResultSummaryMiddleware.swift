import Foundation

/// After executing a series of actions, generates a clear, human-readable summary
/// of what was changed, what state the system is in, and what results were achieved.
/// The summary is appended to the final response so users always know exactly
/// what the agent did.
///
/// Tracks changes across iterations and categorizes them (files changed, apps
/// opened, data fetched, etc.) for structured reporting.
public final class ResultSummaryMiddleware: AgentMiddleware {
    public let name = "ResultSummary"

    public init() {}

    // MARK: - Storage Keys

    private static let changesKey = "ResultSummary.changes"
    private static let actionsKey = "ResultSummary.actions"

    // MARK: - Change Tracking

    public struct ChangeRecord {
        public let category: ChangeCategory
        public let description: String
        public let toolName: String
        public let timestamp: Date
        public let reversible: Bool

        public enum ChangeCategory: String {
            case fileModified
            case appLaunched
            case dataFetched
            case contentCreated
            case settingChanged
            case communication
            case uiAction
            case webAction
            case mediaAction
            case other
        }
    }

    // MARK: - Tool to Category Mapping

    private static let categoryMap: [String: ChangeRecord.ChangeCategory] = [
        "file_operation": .fileModified,
        "find_files": .dataFetched,
        "batch_rename_files": .fileModified,
        "write_file": .fileModified,
        "launch_app": .appLaunched,
        "search_web": .dataFetched,
        "open_url": .webAction,
        "browser_task": .webAction,
        "browser_extract": .dataFetched,
        "create_presentation": .contentCreated,
        "create_word_document": .contentCreated,
        "create_spreadsheet": .contentCreated,
        "create_blender_model": .contentCreated,
        "window_control": .uiAction,
        "keyboard_action": .uiAction,
        "click": .uiAction, "click_element": .uiAction, "click_ref": .uiAction,
        "run_applescript": .other,
        "run_script": .other,
        "capture_screen": .dataFetched,
        "notion_create_page": .contentCreated,
        "notion_update_page": .fileModified,
        "notion_append_blocks": .fileModified,
        "notion_add_to_database": .contentCreated,
        "notion_search": .dataFetched,
        "notion_read_page": .dataFetched,
        "query_calendar_events": .dataFetched,
        "create_calendar_event": .communication,
        "ffmpeg_edit_video": .contentCreated,
        "create_video": .contentCreated,
        "create_audio": .contentCreated,
        "quick_video": .contentCreated,
        "create_podcast": .contentCreated,
        "music_play_song": .mediaAction,
    ]

    /// Tools that make reversible changes.
    private static let reversibleTools: Set<String> = [
        "file_operation", "window_control", "launch_app",
        "keyboard_action",
    ]

    // MARK: - Hooks

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        var changes = ctx.storage[Self.changesKey] as? [ChangeRecord] ?? []

        for result in results where !result.result.hasPrefix("Error") {
            let category = Self.categoryMap[result.toolName] ?? .other
            let description = summarizeToolResult(
                toolName: result.toolName,
                result: result.result
            )
            let isReversible = Self.reversibleTools.contains(result.toolName)

            changes.append(ChangeRecord(
                category: category,
                description: description,
                toolName: result.toolName,
                timestamp: Date(),
                reversible: isReversible
            ))
        }

        ctx.storage[Self.changesKey] = changes
        return .continue
    }

    // MARK: - Summary Generation

    /// Generate a structured execution summary from all tracked changes.
    /// Called after the agent loop completes.
    public static func generateSummary(from storage: [String: Any]) -> String? {
        guard let changes = storage[changesKey] as? [ChangeRecord], !changes.isEmpty else {
            return nil
        }

        guard changes.count > 2 else { return nil }

        var sections: [String] = []
        let grouped = Dictionary(grouping: changes, by: { $0.category })

        if let fileChanges = grouped[.fileModified], !fileChanges.isEmpty {
            sections.append("Files: \(fileChanges.map { $0.description }.joined(separator: "; "))")
        }
        if let created = grouped[.contentCreated], !created.isEmpty {
            sections.append("Created: \(created.map { $0.description }.joined(separator: "; "))")
        }
        if let fetched = grouped[.dataFetched], !fetched.isEmpty {
            sections.append("Looked up: \(fetched.count) item\(fetched.count == 1 ? "" : "s")")
        }
        if let comms = grouped[.communication], !comms.isEmpty {
            sections.append("Sent: \(comms.map { $0.description }.joined(separator: "; "))")
        }
        if let apps = grouped[.appLaunched], !apps.isEmpty {
            let appNames = apps.map { $0.description }
            sections.append("Opened: \(appNames.joined(separator: ", "))")
        }
        if let settings = grouped[.settingChanged], !settings.isEmpty {
            sections.append("Changed: \(settings.map { $0.description }.joined(separator: "; "))")
        }

        guard !sections.isEmpty else { return nil }

        var summary = "\n---\nActions taken (\(changes.count) total):\n"
        for section in sections {
            summary += "- \(section)\n"
        }
        return summary
    }

    // MARK: - Tool Result Summarization

    private func summarizeToolResult(toolName: String, result: String) -> String {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = String(trimmed.prefix(150))

        switch toolName {
        case "file_operation":
            if result.contains("moved") { return "Moved file" }
            if result.contains("copied") { return "Copied file" }
            if result.contains("trashed") { return "Trashed file" }
            if result.contains("renamed") { return "Renamed file" }
            if result.contains("created folder") { return "Created folder" }
            if result.contains("Opened") { return "Opened file" }
            return first

        case "launch_app":
            if let range = result.range(of: "Launched ") {
                return String(result[range.upperBound...].prefix(50))
            }
            return first

        case "create_presentation", "create_word_document", "create_spreadsheet":
            if let pathRange = result.range(of: "saved to ") ?? result.range(of: "Created ") {
                return String(result[pathRange.lowerBound...].prefix(80))
            }
            return "Document created"

        case "notion_create_page":
            return "Notion page created"
        case "notion_update_page", "notion_append_blocks":
            return "Notion page updated"

        case "create_calendar_event":
            return "Calendar event created"

        case "create_video", "ffmpeg_edit_video", "quick_video":
            return "Video created"
        case "create_audio", "create_podcast":
            return "Audio created"

        default:
            return String(first.prefix(80))
        }
    }

    // MARK: - Public API

    public static func currentChanges(from storage: [String: Any]) -> [ChangeRecord] {
        storage[changesKey] as? [ChangeRecord] ?? []
    }
}
