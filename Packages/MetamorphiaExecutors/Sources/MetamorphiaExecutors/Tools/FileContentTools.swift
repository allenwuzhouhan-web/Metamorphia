import Foundation
import MetamorphiaAgentKit

/// Read a file's contents as UTF-8 text, with optional line-range slicing and
/// size guard. Binary files are detected and refused rather than returning
/// garbage — the agent can fall back to `run_shell_command` + `file` / `xxd`
/// if binary inspection is genuinely needed.
public struct ReadFileTool: ToolDefinition {
    public let name = "read_file"
    public let description = "Read a text file's contents. Supports line range (1-indexed, inclusive). Refuses files that look binary. Returns content preceded by a single-line header showing path + line count."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Path to read (supports ~)."),
            "start_line": JSONSchema.integer(description: "First line to include, 1-indexed. Omit for start-of-file.", minimum: 1),
            "end_line": JSONSchema.integer(description: "Last line to include, 1-indexed inclusive. Omit for end-of-file.", minimum: 1),
            "max_bytes": JSONSchema.integer(description: "Max bytes to read before erroring (default 2 MiB).", minimum: 1),
        ], required: ["path"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let path = (rawPath as NSString).expandingTildeInPath
        let maxBytes = optionalInt("max_bytes", from: args) ?? (2 * 1024 * 1024)

        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return "Error: file not found at \(path)"
        }
        let attrs = try fm.attributesOfItem(atPath: path)
        if let size = attrs[.size] as? Int, size > maxBytes {
            return "Error: file is \(size) bytes, exceeding max_bytes (\(maxBytes)). Raise max_bytes or read a slice."
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if looksBinary(data) {
            return "Error: \(path) appears to be binary. Use `run_shell_command` with `file` or `xxd` to inspect."
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            return "Error: \(path) is not valid UTF-8."
        }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let startIdx = max(0, (optionalInt("start_line", from: args) ?? 1) - 1)
        let endIdx: Int = {
            if let end = optionalInt("end_line", from: args) { return min(lines.count, end) }
            return lines.count
        }()
        guard startIdx < endIdx else {
            return "Error: start_line (\(startIdx + 1)) must be <= end_line (\(endIdx))."
        }

        let slice = lines[startIdx..<endIdx].joined(separator: "\n")
        let header = "\(path) (\(lines.count) line\(lines.count == 1 ? "" : "s"))"
        if startIdx == 0 && endIdx == lines.count {
            return "\(header)\n\(slice)"
        }
        return "\(header), lines \(startIdx + 1)-\(endIdx):\n\(slice)"
    }

    /// Crude but reliable binary detection: if any of the first 512 bytes is a
    /// NUL, treat it as binary. False-positive rate on real text files is ~0.
    private func looksBinary(_ data: Data) -> Bool {
        let probe = data.prefix(512)
        return probe.contains(0)
    }
}

/// Write a file, creating or overwriting. Optionally creates parent directories.
public struct WriteFileTool: ToolDefinition {
    public let name = "write_file"
    public let description = "Write a string to a file (creates or overwrites). Use for saving generated content, scripts, configs. Supports ~ in paths. Creates parent directories by default."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "Destination path (supports ~)."),
            "content": JSONSchema.string(description: "File contents."),
            "create_parents": JSONSchema.boolean(description: "Create missing parent directories (default true)."),
            "overwrite": JSONSchema.boolean(description: "Overwrite if the file exists (default true). Set false to error on existing files."),
        ], required: ["path", "content"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let content = try requiredString("content", from: args)
        let path = (rawPath as NSString).expandingTildeInPath
        let createParents = optionalBool("create_parents", from: args) ?? true
        let overwrite = optionalBool("overwrite", from: args) ?? true

        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        if fm.fileExists(atPath: url.path) && !overwrite {
            return "Error: \(path) already exists and overwrite=false."
        }
        if createParents {
            let dir = url.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return "Wrote \(content.utf8.count) bytes (\(lineCount) line\(lineCount == 1 ? "" : "s")) to \(path)"
    }
}

/// Surgical edits on an existing file. Two modes:
/// - `replace` + `with`: exact-string find-and-replace. Errors if the needle
///   isn't present, or if it appears multiple times (unless `replace_all=true`).
/// - `start_line` + `end_line` + `with`: replace a line range with `with`.
public struct EditFileTool: ToolDefinition {
    public let name = "edit_file"
    public let description = "Edit a file in place. Mode A: exact string replace (pass `replace` + `with`, plus optional `replace_all`). Mode B: line-range replace (pass `start_line`, `end_line`, `with`). Errors if the target string doesn't match uniquely; the agent should read the file first to pick a unique anchor."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.string(description: "File to edit (supports ~)."),
            "replace": JSONSchema.string(description: "Mode A: exact string to find. Include enough context to be unique."),
            "with": JSONSchema.string(description: "Replacement text (for both modes)."),
            "replace_all": JSONSchema.boolean(description: "Mode A: replace every occurrence. Default false (errors on ambiguity)."),
            "start_line": JSONSchema.integer(description: "Mode B: first line to replace, 1-indexed.", minimum: 1),
            "end_line": JSONSchema.integer(description: "Mode B: last line to replace, 1-indexed inclusive.", minimum: 1),
        ], required: ["path", "with"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let rawPath = try requiredString("path", from: args)
        let path = (rawPath as NSString).expandingTildeInPath
        let replacement = try requiredString("with", from: args)

        let url = URL(fileURLWithPath: path)
        let existing = try String(contentsOf: url, encoding: .utf8)

        // Mode A: exact-string replace.
        if let needle = optionalString("replace", from: args) {
            let replaceAll = optionalBool("replace_all", from: args) ?? false
            let occurrences = countOccurrences(of: needle, in: existing)
            guard occurrences > 0 else {
                return "Error: `replace` string not found in \(path)."
            }
            if occurrences > 1 && !replaceAll {
                return "Error: `replace` string appears \(occurrences) times in \(path). Provide a longer unique anchor, or pass replace_all=true."
            }
            let updated: String
            if replaceAll {
                updated = existing.replacingOccurrences(of: needle, with: replacement)
            } else if let range = existing.range(of: needle) {
                updated = existing.replacingCharacters(in: range, with: replacement)
            } else {
                updated = existing
            }
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return "Replaced \(occurrences) occurrence\(occurrences == 1 ? "" : "s") in \(path)."
        }

        // Mode B: line-range replace.
        guard let startLine = optionalInt("start_line", from: args),
              let endLine = optionalInt("end_line", from: args) else {
            throw MetamorphiaError.invalidArguments("edit_file needs either `replace`+`with` or `start_line`+`end_line`+`with`.")
        }
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard startLine >= 1, endLine >= startLine, endLine <= lines.count else {
            return "Error: invalid line range \(startLine)-\(endLine) for \(path) (\(lines.count) lines)."
        }
        let newLines = replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.replaceSubrange((startLine - 1)..<endLine, with: newLines)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return "Replaced lines \(startLine)-\(endLine) (\(endLine - startLine + 1) lines) with \(newLines.count) new line\(newLines.count == 1 ? "" : "s") in \(path)."
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = r.upperBound
        }
        return count
    }
}
