import Foundation

/// Raw tool outputs (unstructured text, logs, JSON, tables) are automatically
/// parsed, cleaned, and restructured into consistent, semantically meaningful
/// formats. This normalized data is fed back to the AI for better reasoning.
public final class OutputParsingMiddleware: AgentMiddleware {
    public let name = "OutputParsing"

    public init() {}

    // MARK: - Storage Keys

    private static let parsedOutputsKey = "OutputParsing.parsed"

    // MARK: - Hooks

    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        var parsedOutputs = ctx.storage[Self.parsedOutputsKey] as? [String: StructuredOutput] ?? [:]

        for result in results where !result.result.hasPrefix("Error") {
            if let parsed = parseOutput(toolName: result.toolName, rawOutput: result.result) {
                parsedOutputs[result.toolName] = parsed
            }
        }

        ctx.storage[Self.parsedOutputsKey] = parsedOutputs
        return .continue
    }

    // MARK: - Structured Output Model

    public struct StructuredOutput {
        public let type: OutputType
        public let data: Any
        public let summary: String

        public enum OutputType {
            case json
            case fileList
            case table
            case keyValue
            case text
            case numeric
            case boolean
            case calendarData
            case webResults
        }
    }

    // MARK: - Output Parsers

    private func parseOutput(toolName: String, rawOutput: String) -> StructuredOutput? {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        if let jsonParsed = tryParseJSON(trimmed) {
            return jsonParsed
        }

        switch toolName {
        case "find_files", "find_files_by_age":
            return parseFileList(trimmed)
        case "list_windows":
            return parseWindowList(trimmed)
        case "query_calendar_events":
            return parseCalendarEvents(trimmed)
        case "search_web":
            return parseSearchResults(trimmed)
        case "ffmpeg_probe":
            return parseMediaProbe(trimmed)
        case "capture_screen", "ocr_image":
            return parseScreenCapture(trimmed)
        default:
            return parseGeneric(trimmed)
        }
    }

    // MARK: - JSON Parser

    private func tryParseJSON(_ text: String) -> StructuredOutput? {
        var cleaned = text
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: data) {
            let summary: String
            if let dict = json as? [String: Any] {
                summary = "JSON object with \(dict.count) keys: \(dict.keys.prefix(5).joined(separator: ", "))"
            } else if let arr = json as? [Any] {
                summary = "JSON array with \(arr.count) items"
            } else {
                summary = "JSON value"
            }
            return StructuredOutput(type: .json, data: json, summary: summary)
        }
        return nil
    }

    // MARK: - File List Parser

    private func parseFileList(_ text: String) -> StructuredOutput? {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 1 else { return nil }

        struct FileEntry {
            let path: String
            let size: String?
            let date: String?
        }

        var files: [FileEntry] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("(") && trimmed.hasSuffix(")") {
                let parts = trimmed.components(separatedBy: " (")
                let path = parts[0]
                let meta = parts.count > 1 ? String(parts[1].dropLast()) : nil
                files.append(FileEntry(path: path, size: meta, date: nil))
            } else if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") {
                files.append(FileEntry(path: trimmed, size: nil, date: nil))
            }
        }

        guard !files.isEmpty else { return nil }

        let summary = "\(files.count) file\(files.count == 1 ? "" : "s") found"
        return StructuredOutput(type: .fileList, data: files, summary: summary)
    }

    // MARK: - Window List Parser

    private func parseWindowList(_ text: String) -> StructuredOutput? {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 1 else { return nil }

        let summary = "\(lines.count) window\(lines.count == 1 ? "" : "s") found"
        return StructuredOutput(type: .table, data: lines, summary: summary)
    }

    // MARK: - Calendar Events Parser

    private func parseCalendarEvents(_ text: String) -> StructuredOutput? {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count >= 1 else { return nil }

        let eventLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^\d{1,2}[:/]\d{2}"#, options: .regularExpression) != nil
                || trimmed.contains("AM") || trimmed.contains("PM")
                || trimmed.hasPrefix("-") || trimmed.hasPrefix("*")
        }

        let count = max(eventLines.count, 1)
        let summary = "\(count) calendar event\(count == 1 ? "" : "s")"
        return StructuredOutput(type: .calendarData, data: lines, summary: summary)
    }

    // MARK: - Search Results Parser

    private func parseSearchResults(_ text: String) -> StructuredOutput? {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let urlLines = lines.filter { $0.contains("http://") || $0.contains("https://") }

        let summary = "\(urlLines.count) result\(urlLines.count == 1 ? "" : "s") found"
        return StructuredOutput(type: .webResults, data: lines, summary: summary)
    }

    // MARK: - Media Probe Parser

    private func parseMediaProbe(_ text: String) -> StructuredOutput? {
        var properties: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let lower = line.lowercased()
            if lower.contains("duration") {
                properties["duration"] = line.trimmingCharacters(in: .whitespaces)
            } else if lower.contains("codec") || lower.contains("format") {
                properties["format"] = line.trimmingCharacters(in: .whitespaces)
            } else if lower.contains("resolution") || lower.contains("size") {
                properties["resolution"] = line.trimmingCharacters(in: .whitespaces)
            }
        }

        let summary = properties.isEmpty ? "Media info" : properties.values.prefix(3).joined(separator: ", ")
        return StructuredOutput(type: .keyValue, data: properties, summary: summary)
    }

    // MARK: - Screen Capture Parser

    private func parseScreenCapture(_ text: String) -> StructuredOutput? {
        if text.contains("/") && (text.contains(".png") || text.contains(".jpg")) {
            return StructuredOutput(type: .text, data: text, summary: "Screenshot captured")
        }
        return StructuredOutput(type: .text, data: text, summary: String(text.prefix(80)))
    }

    // MARK: - Generic Parser

    private func parseGeneric(_ text: String) -> StructuredOutput? {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let kvLines = lines.filter { $0.contains(": ") || $0.contains(" = ") }

        if kvLines.count > lines.count / 2 && kvLines.count >= 2 {
            var dict: [String: String] = [:]
            for line in kvLines {
                if let colonIdx = line.firstIndex(of: ":") {
                    let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    dict[key] = val
                }
            }
            if !dict.isEmpty {
                return StructuredOutput(type: .keyValue, data: dict, summary: "\(dict.count) properties")
            }
        }

        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["true", "false", "yes", "no", "ok", "done", "success", "completed"].contains(lower) {
            let success = ["true", "yes", "ok", "done", "success", "completed"].contains(lower)
            return StructuredOutput(type: .boolean, data: success, summary: success ? "Success" : "Failed")
        }

        if let num = Double(lower) {
            return StructuredOutput(type: .numeric, data: num, summary: "\(num)")
        }

        return nil
    }

    // MARK: - Public API

    public static func parsedOutputs(from storage: [String: Any]) -> [String: StructuredOutput] {
        storage[parsedOutputsKey] as? [String: StructuredOutput] ?? [:]
    }
}
