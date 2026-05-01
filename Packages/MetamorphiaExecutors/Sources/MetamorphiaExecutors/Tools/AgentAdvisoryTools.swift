import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - UndoStateTool

/// Tell the agent whether undo / redo is available in the frontmost app, and
/// which action `⌘Z` would reverse. Useful *before* a potentially regrettable
/// click — the agent can weigh "destructive but reversible" differently from
/// "destructive and permanent".
public struct UndoStateTool: ToolDefinition {
    public let name = "undo_state"
    public let description = "Check the frontmost app's Edit > Undo menu to report whether the most recent user action can be undone and what it would undo. Returns JSON: `{canUndo, undoLabel, canRedo, redoLabel, shortcut}`. Use this before firing destructive actions to decide whether `⌘Z` recovery is available — many apps (Safari form submits, Slack sends, Finder trashes with auto-empty) are not undoable even though the menu exists."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let state = DefaultComputerPerception.shared.checkUndoState()

        var payload: [String: Any] = [
            "canUndo": state.canUndo,
            "canRedo": state.canRedo,
            "summary": state.summary,
        ]
        if let label = state.undoLabel { payload["undoLabel"] = label }
        if let label = state.redoLabel { payload["redoLabel"] = label }
        if let shortcut = state.shortcut { payload["shortcut"] = shortcut }

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "Error: failed to serialize undo state."
        }
        return json
    }
}
