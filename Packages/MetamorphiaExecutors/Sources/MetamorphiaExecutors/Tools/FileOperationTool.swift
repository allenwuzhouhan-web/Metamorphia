import Foundation
import AppKit
import MetamorphiaAgentKit

/// Consolidated file-operation tool. Replaces ~11 individual file tools (open,
/// move, copy, trash, create_folder, info, reveal, get_downloads_path, rename,
/// get_finder_path) with a single `action` parameter.
public struct FileOperationTool: ToolDefinition {
    public let name = "file_operation"
    public let description = "Perform file system operations: open, move, copy, trash, create_folder, info, reveal, rename, get_downloads_path, get_finder_path. The `action` parameter chooses which."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "action": JSONSchema.enumString(
                description: "Operation to perform",
                values: ["open", "move", "copy", "trash", "create_folder", "info", "reveal", "rename", "get_downloads_path", "get_finder_path"]
            ),
            "path": JSONSchema.string(description: "Source/target path (required for most actions)"),
            "destination": JSONSchema.string(description: "Destination path (for move/copy)"),
            "new_name": JSONSchema.string(description: "New filename (for rename)"),
        ], required: ["action"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let action = try requiredString("action", from: args)
        let fm = FileManager.default

        switch action {
        case "open":
            let path = try expandedPath(from: args)
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { return "Error: file not found at \(url.path)" }
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else {
                return "Error: NSWorkspace refused to open \(url.path) (no default app registered?)"
            }
            return "Opened \(url.lastPathComponent)"

        case "reveal":
            let path = try expandedPath(from: args)
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { return "Error: file not found at \(url.path)" }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return "Revealed \(url.lastPathComponent) in Finder"

        case "move":
            let src = URL(fileURLWithPath: try expandedPath(from: args))
            let dest = URL(fileURLWithPath: try expandedPath(from: args, key: "destination"))
            try fm.moveItem(at: src, to: dest)
            return "Moved \(src.lastPathComponent) to \(dest.path)"

        case "copy":
            let src = URL(fileURLWithPath: try expandedPath(from: args))
            let dest = URL(fileURLWithPath: try expandedPath(from: args, key: "destination"))
            try fm.copyItem(at: src, to: dest)
            return "Copied \(src.lastPathComponent) to \(dest.path)"

        case "trash":
            let url = URL(fileURLWithPath: try expandedPath(from: args))
            var trashed: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashed)
            return "Trashed \(url.lastPathComponent)"

        case "create_folder":
            let url = URL(fileURLWithPath: try expandedPath(from: args))
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return "Created folder at \(url.path)"

        case "rename":
            let src = URL(fileURLWithPath: try expandedPath(from: args))
            let newName = try requiredString("new_name", from: args)
            let dest = src.deletingLastPathComponent().appendingPathComponent(newName)
            try fm.moveItem(at: src, to: dest)
            return "Renamed \(src.lastPathComponent) → \(newName)"

        case "info":
            let url = URL(fileURLWithPath: try expandedPath(from: args))
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int) ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? Date()
            let formatter = ByteCountFormatter()
            return """
            \(url.lastPathComponent)
            Path: \(url.path)
            Size: \(formatter.string(fromByteCount: Int64(size)))
            Modified: \(modified.formatted())
            """

        case "get_downloads_path":
            return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"

        case "get_finder_path":
            // Frontmost Finder window's directory.
            let script = """
            tell application "Finder"
                if (count of windows) > 0 then
                    return POSIX path of (target of front window as alias)
                else
                    return POSIX path of (path to desktop folder)
                end if
            end tell
            """
            return try await AppleScriptRunner.runThrowing(script)

        default:
            throw MetamorphiaError.invalidArguments("unknown file action: \(action)")
        }
    }

    private func expandedPath(from args: [String: Any], key: String = "path") throws -> String {
        let raw = try requiredString(key, from: args)
        return (raw as NSString).expandingTildeInPath
    }
}
