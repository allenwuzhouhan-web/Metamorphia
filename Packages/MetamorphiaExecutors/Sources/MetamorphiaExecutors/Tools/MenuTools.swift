import Foundation
import AppKit
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - MenuListTool

/// Enumerate the menu bar of the frontmost app.
///
/// Complements the existing `invoke_menu` tool (which fires a specific menu
/// item): this one returns the full menu bar tree so the agent can *discover*
/// what's available. Crucial for canvas apps (Blender, DaVinci Resolve,
/// CapCut) whose main content view is opaque to Accessibility but whose menu
/// bar exposes nearly every operation.
///
/// The output is a JSON array of menu paths — e.g. `["File > New",
/// "File > Open…", "Edit > Undo", …]`. Leaf items have a `shortcut` field
/// when one is bound (e.g. `"⌘N"`).
public struct MenuListTool: ToolDefinition {
    public let name = "menu_list"
    public let description = "List every menu bar item of the frontmost app as a flat array of `{path, shortcut}` entries. Pairs with `invoke_menu` (which fires a chosen path). Use this when you need to *discover* what's available — critical for canvas-drawn apps (Blender, DaVinci, CapCut) whose main window is opaque to the Accessibility API but whose menu bar is fully enumerable. Optionally filter by top-level menu title (e.g. 'File' or 'Edit')."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "top_level": JSONSchema.string(
                description: "Optional top-level menu title to restrict the listing to (e.g. 'File', 'Edit', 'Tools'). Case-insensitive. Omit to list every menu."
            ),
            "include_disabled": JSONSchema.boolean(
                description: "Include disabled menu items. Defaults to false."
            ),
        ])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            args = (try? parseArguments(arguments)) ?? [:]
        }
        let topFilter = (args["top_level"] as? String)?.lowercased()
        let includeDisabled = (args["include_disabled"] as? Bool) ?? false

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return "Error: no frontmost application."
        }
        let pid = frontmost.processIdentifier

        let items = MenuBarReader.readMenuBar(pid: pid)

        var entries: [[String: Any]] = []
        for item in items {
            let pathJoined = item.path.joined(separator: " > ")
            if let topFilter,
               let first = item.path.first?.lowercased(),
               first != topFilter {
                continue
            }
            if !includeDisabled && !item.enabled {
                continue
            }
            // Skip submenu container rows — only leaves can be fired via
            // `invoke_menu`. Leaves are what the agent actually wants listed.
            if item.hasSubmenu { continue }

            var entry: [String: Any] = [
                "path": pathJoined,
                "enabled": item.enabled,
            ]
            if let shortcut = item.shortcut, !shortcut.isEmpty {
                entry["shortcut"] = shortcut
            }
            entries.append(entry)
        }

        let payload: [String: Any] = [
            "app": frontmost.localizedName ?? frontmost.bundleIdentifier ?? "",
            "pid": Int(pid),
            "count": entries.count,
            "items": entries,
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "Error: failed to serialize menu bar listing."
        }
        return json
    }
}
