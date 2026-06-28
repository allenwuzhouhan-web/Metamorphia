//
// Metamorphia — Metamorphia Tool Bindings
//
// Exposes Metamorphia's native managers (TimerManager, ClipboardManager, NotesStore,
// ShelfStateViewModel, ColorPickerManager, CalendarManager, StatsManager) as
// `ToolDefinition`s the AI agent can invoke. This is the "Agent-drives-Metamorphia"
// integration layer — when the user says "start a 5 minute timer", the AI
// actually calls TimerManager.shared.startTimer(...) instead of telling the
// user how to do it manually.
//

import Foundation
import AppKit
import Defaults
import MetamorphiaAgentKit

// MARK: - Timer Tools

public struct StartTimerTool: ToolDefinition {
    public let name = "start_timer"
    public let description = "Start a timer for a specified duration with an optional label. Use when the user says things like 'remind me in 5 minutes' or 'set a 10 minute timer for the pasta'."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "duration_seconds": JSONSchema.integer(description: "Duration in seconds", minimum: 1),
            "label": JSONSchema.string(description: "Optional label shown in the notch"),
        ], required: ["duration_seconds"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let duration: TimeInterval = try {
            if let d = args["duration_seconds"] as? Int { return TimeInterval(d) }
            if let d = args["duration_seconds"] as? Double { return d }
            throw MetamorphiaError.invalidArguments("duration_seconds required")
        }()
        let label = optionalString("label", from: args) ?? "Timer"

        await MainActor.run {
            TimerManager.shared.startTimer(duration: duration, name: label, preset: nil)
        }
        return "Started timer for \(Int(duration))s — \(label)"
    }
}

public struct ListActiveTimersTool: ToolDefinition {
    public let name = "list_timers"
    public let description = "Check whether a timer is currently active and how much time is left."
    public var parameters: [String: Any] { JSONSchema.object(properties: [:]) }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        let snapshot: (active: Bool, remaining: TimeInterval, elapsed: TimeInterval) = await MainActor.run {
            let mgr = TimerManager.shared
            return (mgr.isTimerActive, mgr.remainingTime, mgr.elapsedTime)
        }
        guard snapshot.active else { return "No active timer." }
        let mins = Int(snapshot.remaining) / 60
        let secs = Int(snapshot.remaining) % 60
        return "Active timer: \(mins)m \(secs)s remaining (\(Int(snapshot.elapsed))s elapsed)."
    }
}

public struct CancelTimerTool: ToolDefinition {
    public let name = "cancel_timer"
    public let description = "Cancel the currently-running timer."
    public var parameters: [String: Any] { JSONSchema.object(properties: [:]) }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        await MainActor.run {
            TimerManager.shared.stopTimer()
        }
        return "Timer cancelled."
    }
}

// MARK: - Clipboard Tools

public struct ReadClipboardHistoryTool: ToolDefinition {
    public let name = "read_clipboard_history"
    public let description = "Read recent clipboard entries the user copied. Returns most recent first."
    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "count": JSONSchema.integer(description: "Number of recent items to return", minimum: 1, maximum: 50),
        ])
    }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let count = max(1, min(50, optionalInt("count", from: args) ?? 10))

        let items: [String] = await MainActor.run {
            ClipboardManager.shared.clipboardHistory.prefix(count).map { item in
                String(describing: item).prefix(120).description
            }
        }
        guard !items.isEmpty else { return "Clipboard history is empty." }
        return items.enumerated().map { idx, txt in "\(idx + 1). \(txt)" }.joined(separator: "\n")
    }
}

public struct SearchClipboardHistoryTool: ToolDefinition {
    public let name = "search_clipboard_history"
    public let description = "Search the clipboard history for entries containing a query string."
    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Substring to match (case-insensitive)"),
        ], required: ["query"])
    }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args).lowercased()

        let matches: [String] = await MainActor.run {
            ClipboardManager.shared.clipboardHistory
                .compactMap { item -> String? in
                    let s = String(describing: item)
                    return s.lowercased().contains(query) ? String(s.prefix(200)) : nil
                }
                .prefix(10)
                .map { $0 }
        }
        guard !matches.isEmpty else { return "No clipboard entries matching '\(query)'." }
        return matches.enumerated().map { idx, txt in "\(idx + 1). \(txt)" }.joined(separator: "\n")
    }
}

// MARK: - Notes Tools (Defaults-backed)

public struct AppendNoteTool: ToolDefinition {
    public let name = "append_note"
    public let description = "Append a new note to the user's saved notes. Use to capture important information the user wants to remember."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "title": JSONSchema.string(description: "Optional title"),
            "body": JSONSchema.string(description: "The note content"),
        ], required: ["body"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let title = optionalString("title", from: args)
        let body = try requiredString("body", from: args)

        await MainActor.run {
            var current = Defaults[.savedNotes]
            let note = NoteItem(
                id: UUID(),
                title: title ?? String(body.prefix(40)),
                content: body,
                creationDate: Date(),
                colorIndex: 0,
                isPinned: false,
                imageFileName: nil
            )
            current.append(note)
            Defaults[.savedNotes] = current
        }
        return "Saved note\(title.map { " '\($0)'" } ?? "")."
    }
}

public struct ReadRecentNotesTool: ToolDefinition {
    public let name = "read_recent_notes"
    public let description = "Return the user's most recent saved notes."
    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "limit": JSONSchema.integer(description: "Max notes to return", minimum: 1, maximum: 50),
        ])
    }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let limit = max(1, min(50, optionalInt("limit", from: args) ?? 10))

        let formatted: String = await MainActor.run {
            let notes = Defaults[.savedNotes]
                .sorted { $0.creationDate > $1.creationDate }
                .prefix(limit)
            guard !notes.isEmpty else { return "No notes saved yet." }
            return notes.enumerated().map { idx, note in
                "\(idx + 1). [\(note.title)] \(String(note.content.prefix(160)))"
            }.joined(separator: "\n")
        }
        return formatted
    }
}

// MARK: - Shelf Tools

public struct AddToShelfTool: ToolDefinition {
    public let name = "add_to_shelf"
    public let description = "Drop a file into the Metamorphia Shelf so the user can drag it out later."
    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Absolute or ~/-relative path to the file"),
        ], required: ["path"])
    }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Error: file not found at \(url.path)"
        }

        // Build a security-scoped bookmark so the shelf can resolve the path later.
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        await MainActor.run {
            let item = ShelfItem(kind: .file(bookmark: bookmark))
            ShelfStateViewModel.shared.add([item])
        }
        return "Added \(url.lastPathComponent) to Shelf."
    }
}

public struct ListShelfTool: ToolDefinition {
    public let name = "list_shelf"
    public let description = "List items currently in the Metamorphia Shelf."
    public var parameters: [String: Any] { JSONSchema.object(properties: [:]) }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        let names: [String] = await MainActor.run {
            ShelfStateViewModel.shared.items.map(\.displayName)
        }
        guard !names.isEmpty else { return "Shelf is empty." }
        return names.enumerated().map { idx, name in "\(idx + 1). \(name)" }.joined(separator: "\n")
    }
}

// MARK: - Color Picker

public struct PickColorFromScreenTool: ToolDefinition {
    public let name = "pick_color_from_screen"
    public let description = "Activate the screen color picker so the user can sample a pixel. Returns immediately; the picker is interactive."
    public var parameters: [String: Any] { JSONSchema.object(properties: [:]) }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        await MainActor.run {
            ColorPickerManager.shared.startColorPicking()
        }
        return "Color picker activated. Click anywhere on screen to sample a color."
    }
}

// MARK: - Calendar

public struct ReadMetamorphiaCalendarTool: ToolDefinition {
    public let name = "read_metamorphia_calendar"
    public let description = "Read upcoming calendar events from the user's calendars."
    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "for_today": JSONSchema.boolean(description: "If true, return today's events; otherwise return upcoming events"),
        ])
    }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        let summary: String = await MainActor.run {
            let events = CalendarManager.shared.events
            guard !events.isEmpty else { return "No upcoming events." }
            return events.prefix(10).enumerated().map { idx, event in
                "\(idx + 1). \(String(describing: event).prefix(120))"
            }.joined(separator: "\n")
        }
        return summary
    }
}

// MARK: - System Stats

public struct GetSystemStatsTool: ToolDefinition {
    public let name = "get_metamorphia_system_stats"
    public let description = "Return current CPU, GPU, memory, network, and disk stats from Metamorphia's stats monitor."
    public var parameters: [String: Any] { JSONSchema.object(properties: [:]) }
    public init() {}
    public func execute(arguments: String) async throws -> String {
        let snapshot: String = await MainActor.run {
            let s = StatsManager.shared
            return """
            CPU: \(String(format: "%.1f", s.cpuUsage))%
            Memory: \(String(format: "%.1f", s.memoryUsage))%
            GPU: \(String(format: "%.1f", s.gpuUsage))%
            Network ↓ \(String(format: "%.2f", s.networkDownload)) MB/s · ↑ \(String(format: "%.2f", s.networkUpload)) MB/s
            Disk read \(String(format: "%.2f", s.diskRead)) MB/s · write \(String(format: "%.2f", s.diskWrite)) MB/s
            """
        }
        return snapshot
    }
}

// MARK: - Registrar

public enum MetamorphiaTools {
    public static let allTools: [(tool: any ToolDefinition, category: ToolCategory)] = [
        (StartTimerTool(), .productivity),
        (ListActiveTimersTool(), .productivity),
        (CancelTimerTool(), .productivity),
        (ReadClipboardHistoryTool(), .clipboardHistory),
        (SearchClipboardHistoryTool(), .clipboardHistory),
        (AppendNoteTool(), .productivity),
        (ReadRecentNotesTool(), .productivity),
        (AddToShelfTool(), .files),
        (ListShelfTool(), .files),
        (PickColorFromScreenTool(), .productivity),
        (ReadMetamorphiaCalendarTool(), .productivity),
        (GetSystemStatsTool(), .systemInfo),
    ]

    public static func register(into registry: ToolRegistry) {
        registry.register(allTools)
    }
}
