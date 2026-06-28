import Foundation

// MARK: - MCP Tool Definitions for Computer

/// Exposes Computer's capabilities as MCP-compatible tool definitions.
/// Executer (or any MCP client) can discover and call these tools.
public enum ComputerMCPServer {

    // MARK: - Tool Catalog

    /// All MCP tool definitions that Computer exposes.
    public static func toolDefinitions() -> [[String: Any]] {
        [
            captureTool,
            diffTool,
            elementTool,
            actionSuggestTool,
            correctTool,
            shortcutsTool,
            undoTool,
            profileTool,
            healthTool,
        ]
    }

    // MARK: - Tool Definitions

    private static let captureTool: [String: Any] = [
        "name": "computer_capture",
        "description": "Capture the current screen state. Returns a semantic ScreenMap with all visible UI elements, their roles, labels, states, and safety assessments. Use this to see what's on screen before acting.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "force_ocr": ["type": "boolean", "description": "Force OCR even if AX tree is sufficient. Default false."],
                "app_filter": ["type": "string", "description": "Only capture a specific app by name."],
                "format": ["type": "string", "enum": ["text", "json"], "description": "Output format. 'text' is compact (~120 tokens), 'json' is structured. Default: text."],
            ],
        ] as [String: Any],
    ]

    private static let diffTool: [String: Any] = [
        "name": "computer_diff",
        "description": "Compare the current screen to the last captured state. Returns what changed (added, removed, changed elements). Useful after performing an action to verify it worked.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
        ] as [String: Any],
    ]

    private static let elementTool: [String: Any] = [
        "name": "computer_element",
        "description": "Get detailed information about a specific screen element by @e reference (e.g., @e5). Returns role, label, value, bounds, danger level, reversibility.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "ref": ["type": "string", "description": "Element reference in @eN format (e.g., '@e5')."],
            ],
            "required": ["ref"],
        ] as [String: Any],
    ]

    private static let actionSuggestTool: [String: Any] = [
        "name": "computer_suggest_action",
        "description": "Given a goal, suggest which screen elements to interact with and how. Returns a ranked action plan with confidence scores.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "goal": ["type": "string", "description": "What you want to accomplish (e.g., 'click the Save button', 'open Settings')."],
            ],
            "required": ["goal"],
        ] as [String: Any],
    ]

    private static let correctTool: [String: Any] = [
        "name": "computer_correct",
        "description": "Report that an element's label was wrong or that the wrong element was selected. This helps Computer learn and improve future suggestions.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "ref": ["type": "string", "description": "The element reference that was incorrect or selected wrongly."],
                "correct_label": ["type": "string", "description": "The correct label for the element."],
                "correct_ref": ["type": "string", "description": "If a different element should have been selected, its ref."],
                "intended_action": ["type": "string", "description": "What the agent was trying to do."],
            ],
            "required": ["ref"],
        ] as [String: Any],
    ]

    private static let shortcutsTool: [String: Any] = [
        "name": "computer_shortcuts",
        "description": "Discover all keyboard shortcuts for the frontmost app. Returns shortcuts with menu paths and key combinations.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
        ] as [String: Any],
    ]

    private static let undoTool: [String: Any] = [
        "name": "computer_undo_state",
        "description": "Check the current undo/redo state of the frontmost app. Returns whether undo/redo is available and a summary.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
        ] as [String: Any],
    ]

    private static let profileTool: [String: Any] = [
        "name": "computer_app_profile",
        "description": "Get Computer's learned profile for an app — whether it needs OCR, AX coverage quality, known confusion patterns.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "bundle_id": ["type": "string", "description": "App bundle ID (e.g., 'com.apple.Safari')."],
            ],
            "required": ["bundle_id"],
        ] as [String: Any],
    ]

    private static let healthTool: [String: Any] = [
        "name": "computer_health",
        "description": "Get Computer's database stats: element count, patterns, corrections, workflows.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
        ] as [String: Any],
    ]

    // MARK: - Tool Execution

    /// Execute an MCP tool call. Returns JSON result string.
    public static func execute(
        toolName: String,
        arguments: [String: Any],
        perception: ComputerPerception
    ) async -> String {
        switch toolName {
        case "computer_capture":
            return await executeCapture(arguments: arguments, perception: perception)
        case "computer_diff":
            return await executeDiff(perception: perception)
        case "computer_element":
            return executeElement(arguments: arguments, perception: perception)
        case "computer_suggest_action":
            return await executeSuggestAction(arguments: arguments, perception: perception)
        case "computer_correct":
            return await executeCorrect(arguments: arguments, perception: perception)
        case "computer_shortcuts":
            return executeShortcuts(perception: perception)
        case "computer_undo_state":
            return executeUndoState(perception: perception)
        case "computer_app_profile":
            return executeAppProfile(arguments: arguments, perception: perception)
        case "computer_health":
            return executeHealth()
        default:
            return "{\"error\": \"Unknown tool: \(toolName)\"}"
        }
    }

    // MARK: - Execution Implementations

    /// Track last captured map for diff operations.
    /// Serialized via `cacheLock` so concurrent MCP tool calls don't race on
    /// this shared mutable static (`ScreenMap` is a `Sendable` value type).
    private static var _lastCapturedMap: ScreenMap?
    private static let cacheLock = NSLock()

    private static var lastCapturedMap: ScreenMap? {
        get { cacheLock.withLock { _lastCapturedMap } }
        set { cacheLock.withLock { _lastCapturedMap = newValue } }
    }

    private static func executeCapture(arguments: [String: Any], perception: ComputerPerception) async -> String {
        let forceOCR = arguments["force_ocr"] as? Bool ?? false
        let appFilter = arguments["app_filter"] as? String
        let format = arguments["format"] as? String ?? "text"

        let map = await perception.capture(forceOCR: forceOCR, appFilter: appFilter)
        lastCapturedMap = map

        if format == "json" {
            return perception.formatAsJSON(map)
        } else {
            return perception.formatForLLM(map)
        }
    }

    private static func executeDiff(perception: ComputerPerception) async -> String {
        guard let previous = lastCapturedMap else {
            return "{\"error\": \"No previous capture. Call computer_capture first.\"}"
        }

        let current = await perception.capture(forceOCR: false, appFilter: nil)
        lastCapturedMap = current

        let diff = perception.diff(previous: previous, current: current)
        var result: [String: Any] = [
            "changed": !diff.isEmpty,
            "summary": diff.summary,
            "app_switched": diff.appSwitched,
            "major_change": diff.hasMajorChange,
            "added_count": diff.added.count,
            "removed_count": diff.removed.count,
            "changed_count": diff.changed.count,
        ]
        if diff.appSwitched {
            result["previous_app"] = diff.previousApp
            result["current_app"] = diff.currentApp
        }
        return jsonString(result)
    }

    private static func executeElement(arguments: [String: Any], perception: ComputerPerception) -> String {
        guard let refStr = arguments["ref"] as? String else {
            return "{\"error\": \"Missing 'ref' parameter.\"}"
        }
        guard let map = lastCapturedMap else {
            return "{\"error\": \"No capture available. Call computer_capture first.\"}"
        }
        guard let element = perception.findByRef(refStr, in: map) else {
            return "{\"error\": \"Element \(refStr) not found.\"}"
        }

        let windowTitle = map.windows.first(where: { $0.isFocused })?.title ?? ""
        let danger = perception.classifyDanger(
            element: element, appBundleID: map.focusedApp.bundleID, windowTitle: windowTitle
        )

        var result: [String: Any] = [
            "ref": element.ref.description,
            "role": element.role.rawValue,
            "label": element.label,
            "value": element.value,
            "state": element.state.names,
            "actions": element.actions.map { $0.rawValue },
            "depth": element.depth,
            "source": element.source.rawValue,
            "confidence": element.confidence,
            "danger_level": danger.level.rawValue,
        ]
        if let bounds = element.bounds {
            result["bounds"] = ["x": Int(bounds.origin.x), "y": Int(bounds.origin.y),
                                "w": Int(bounds.size.width), "h": Int(bounds.size.height)]
        }
        if let click = element.clickPoint {
            result["click"] = ["x": Int(click.x), "y": Int(click.y)]
        }
        if let reason = danger.reason { result["danger_reason"] = reason }

        return jsonString(result)
    }

    private static func executeSuggestAction(arguments: [String: Any], perception: ComputerPerception) async -> String {
        guard let goal = arguments["goal"] as? String else {
            return "{\"error\": \"Missing 'goal' parameter.\"}"
        }

        let map: ScreenMap
        if let cached = lastCapturedMap {
            map = cached
        } else {
            map = await perception.capture(forceOCR: false, appFilter: nil)
            lastCapturedMap = map
        }

        let plan = perception.suggestActions(goal: goal, map: map)
        return ActionSuggester.formatPlan(plan)
    }

    private static func executeCorrect(arguments: [String: Any], perception: ComputerPerception) async -> String {
        guard let refStr = arguments["ref"] as? String,
              let ref = ElementRef.parse(refStr) else {
            return "{\"error\": \"Missing or invalid 'ref' parameter.\"}"
        }
        guard let map = lastCapturedMap else {
            return "{\"error\": \"No capture available. Call computer_capture first.\"}"
        }

        if let correctLabel = arguments["correct_label"] as? String {
            CorrectionLoop.correctLabel(
                ref: ref, correctLabel: correctLabel,
                currentMap: map, db: ElementDatabase.shared
            )
        }

        if let correctRefStr = arguments["correct_ref"] as? String,
           let correctRef = ElementRef.parse(correctRefStr) {
            let intendedAction = arguments["intended_action"] as? String ?? "click"
            let correction = CorrectionLoop.Correction(
                intendedAction: intendedAction,
                selectedRef: ref,
                correctRef: correctRef,
                appBundleID: map.focusedApp.bundleID,
                windowTitle: map.windows.first(where: { $0.isFocused })?.title
            )
            perception.processCorrection(correction, map: map)
        }

        return "{\"status\": \"ok\", \"message\": \"Correction recorded. Computer will learn from this.\"}"
    }

    private static func executeShortcuts(perception: ComputerPerception) -> String {
        let shortcuts = perception.discoverShortcuts()
        if shortcuts.isEmpty { return "{\"shortcuts\": []}" }
        return perception.formatShortcuts(shortcuts)
    }

    private static func executeUndoState(perception: ComputerPerception) -> String {
        let state = perception.checkUndoState()
        return jsonString([
            "can_undo": state.canUndo,
            "can_redo": state.canRedo,
            "summary": state.summary,
        ] as [String: Any])
    }

    private static func executeAppProfile(arguments: [String: Any], perception: ComputerPerception) -> String {
        guard let bundleID = arguments["bundle_id"] as? String else {
            return "{\"error\": \"Missing 'bundle_id' parameter.\"}"
        }
        guard let profile = perception.appProfile(bundleID: bundleID) else {
            return "{\"error\": \"No profile found for '\(bundleID)'. Computer hasn't observed this app yet.\"}"
        }
        var result: [String: Any] = [
            "bundle_id": bundleID,
            "app_name": profile.appName,
            "needs_ocr": profile.needsOCR,
        ]
        if let axCov = profile.axCoveragePct { result["ax_coverage_percent"] = axCov }
        if let elemCount = profile.elementCountAvg { result["element_count_avg"] = elemCount }
        return jsonString(result)
    }

    private static func executeHealth() -> String {
        let stats = ElementDatabase.shared.stats()
        return jsonString([
            "elements": stats.elementCount,
            "patterns": stats.patternCount,
            "corrections": stats.correctionCount,
            "workflows": stats.workflowCount,
            "failures": stats.failureCount,
            "app_profiles": stats.appProfileCount,
        ] as [String: Any])
    }

    // MARK: - Helpers

    private static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
