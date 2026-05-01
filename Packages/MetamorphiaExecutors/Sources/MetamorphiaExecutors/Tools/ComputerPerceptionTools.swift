import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception
import AppKit

// MARK: - ScreenPerceiveTool

/// Captures the current screen via ComputerLib's semantic perception pipeline.
/// Unlike `capture_screen` (which saves a PNG), this returns a structured,
/// token-efficient description of every interactive element — buttons, fields,
/// menus, link text — with ref ids (`@eN`), roles, labels, bounds, click points
/// and states. Consumers pick `text` for direct LLM consumption (~500-800
/// tokens for a 50-element screen) or `json` for programmatic parsing.
///
/// Rank 2 — when `session_id` is provided, the tool routes through the
/// delta encoder: the first call in a session ships a full baseline, and each
/// subsequent call ships only a ref-partitioned diff (added/removed/changed +
/// retained ref list), dropping token cost ~95 % on sticky screens.
public struct ScreenPerceiveTool: ToolDefinition {
    public let name = "screen_perceive"
    public let description = "Capture a semantic snapshot of the current screen. Returns a structured, ref-addressable description of every interactive element (role, label, bounds, click point, state) via ComputerLib's AX + OCR pipeline. Prefer this over `capture_screen` when the agent needs to read or reason about on-screen UI, not just store a picture. Output format is `text` (compact for LLM) or `json` (for programmatic use). Pass `session_id` to enable ref-delta mode: the first call is a baseline snapshot; subsequent calls in the same session ship only added/removed/changed refs + a retained-ref list, saving ~95% tokens on unchanged screens (call `screen_reset_session` to re-seed). OCR policy via `ocr`: `auto` (default — seed-aware, skips screenshot entirely for AX-rich apps like Safari/Finder), `require` (sync OCR — supersedes `force_ocr`), `skip` (never OCR — fastest), `async` (AX-only return + background OCR for next call)."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "force_ocr": JSONSchema.boolean(
                description: "Legacy flag — equivalent to `ocr: 'require'`. When set with `ocr` also set, `ocr` wins. Default false."
            ),
            "ocr": JSONSchema.enumString(
                description: "OCR policy for this capture. `auto` (default): seed-aware — skips screenshot+OCR entirely when the app's profile says AX is sufficient; runs sync OCR when profile needs it. `require`: always run sync OCR. `skip`: never run OCR, no OCR-use screenshot (fastest). `async`: AX-only return, schedule OCR in background for next capture.",
                values: ["auto", "require", "skip", "async"]
            ),
            "app": JSONSchema.string(
                description: "Optional app name filter (e.g. 'Safari'). When set, only elements from windows owned by that app are returned."
            ),
            "format": JSONSchema.enumString(
                description: "Output format. `text` is indented human-readable tree (default, compact for LLMs). `json` is the full SnapshotEncoder JSON.",
                values: ["text", "json"]
            ),
            "max_elements": JSONSchema.integer(
                description: "Upper bound on elements emitted in `text` format (default 120). Ignored for `json`.",
                minimum: 1,
                maximum: 10_000
            ),
            "session_id": JSONSchema.string(
                description: "Optional session key for Rank 2 delta encoding. When set, the first call ships a full baseline snapshot; subsequent calls in the same session ship only a ref delta (added full-body elements, removed ref list, changed field list, retained ref list). Omit to get the full snapshot every call (legacy behavior)."
            ),
        ])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            do {
                args = try parseArguments(arguments)
            } catch {
                return "Error: failed to parse arguments: \(error.localizedDescription)"
            }
        }

        let forceOCR = (args["force_ocr"] as? Bool) ?? false
        let app = args["app"] as? String
        let format = (args["format"] as? String) ?? "text"
        let maxElements = (args["max_elements"] as? Int)
            ?? ((args["max_elements"] as? Double).map(Int.init))
            ?? 120
        let sessionID = (args["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let policy: OCRPolicy
        switch (args["ocr"] as? String)?.lowercased() {
        case "require":  policy = .require
        case "skip":     policy = .skip
        case "async":    policy = .async
        case "auto", nil: policy = .auto
        case let other?:
            return "Error: unknown ocr policy '\(other)'. Use 'auto', 'require', 'skip', or 'async'."
        }

        // Delta mode — requires a session id.
        if let sessionID {
            // `captureDelta` runs its own capture + cache rotation. OCR-override
            // / app-filter wiring through captureDelta lands in Rank 6 (query
            // engine). Today's delta path goes through the default policy
            // cascade; `policy` / `forceOCR` / `app` are ignored in this branch.
            _ = policy; _ = forceOCR; _ = app
            let payload = await DefaultComputerPerception.shared.captureDelta(
                sessionID: sessionID,
                policy: .default
            )
            switch format {
            case "json":
                return DefaultComputerPerception.shared.formatDeltaAsJSON(payload)
            case "text":
                // Async variant pulls the full baseline tree from the cache
                // when this is the first capture of the session; subsequent
                // captures fall through to the compact delta summary.
                return await DefaultComputerPerception.shared.formatDeltaForLLMAsync(
                    payload, maxElements: maxElements
                )
            default:
                return "Error: unknown format '\(format)'. Use 'text' or 'json'."
            }
        }

        // Legacy (non-delta) path.
        let rawMap = await DefaultComputerPerception.shared.capture(
            forceOCR: forceOCR,
            appFilter: app,
            ocrOverride: policy
        )
        // Phase 3c: mask password / credit-card / SSN / API-key field values
        // before the map leaves ComputerLib for the LLM. Structural data
        // (role, label, bounds, refs) is preserved so the agent can still
        // click or describe the redacted field.
        let map = rawMap.redactedForLLM()

        switch format {
        case "json":
            return SnapshotEncoder.encode(map)
        case "text":
            return TextFormatter.format(map, maxElements: maxElements)
        default:
            return "Error: unknown format '\(format)'. Use 'text' or 'json'."
        }
    }
}

// MARK: - ScreenQueryTool

/// Rank 6 — Full selector-grammar query.
///
/// Routes through `DefaultComputerPerception.query(...)` → `QueryEngine`.
/// Wire protocol stays backward-compatible with the old stub: `selector`
/// string in, JSON array of `{ref, role, label, click}` out. The output
/// dictionary now also carries `bounds`, `displayIndex`, `tier`,
/// `stabilityScore`, and `matchScore` so downstream callers can rank picks.
///
/// Supported grammar (full BNF lives in `SelectorParser.swift`):
///
/// ```
/// selector := term (' '+ term)*
/// term     := field ':' value        // equals (case-insensitive for label)
///           | field '=' value        // equals (case-sensitive for label)
///           | field '~' '/' regex '/'  // regex (label only)
///           | field '*' value        // contains (label/value, case-insensitive)
///           | field '^' value        // starts-with (label)
///           | field '>' number       // depth > n / confidence > n
///           | field '<' number       // depth < n
///           | '!' term               // negation
///           | '@e' digits            // ref literal
///           | '(' selector ')'       // grouping (AND)
/// field    := role | label | value | parent | in | depth
///           | visible | interactive | state | action
///           | display | ref | near | tier | confidence
/// ```
///
/// Examples:
/// - `role:button label*save in:"Toolbar"` — Save button inside the Toolbar container
/// - `role:menuItem label~/^Save/` — any menu item starting with "Save"
/// - `role:button near:@e42:80` — buttons within 80pt of @e42's clickPoint
/// - `!state:disabled interactive:true` — any enabled interactive element
public struct ScreenQueryTool: ToolDefinition {
    public let name = "screen_query"
    public let description = """
Query the current screen for elements matching a selector. Rank 6 full-grammar engine: field:value (equals), label~/regex/, label*substring, label^prefix, depth:>n, depth:<n, visible:true/false, interactive:true/false, state:<name>, state:!<name>, action:<name>, display:<n>, ref:@eN, near:@eN:<radius>, tier:identifier|label|position|fallback, confidence:>0.x, parent:<label>, in:"<container-label>", !<term> for negation, (group) for AND-grouping. Quoted strings support escapes. Returns JSON array of {ref, role, label, click, bounds, displayIndex, tier, stabilityScore, matchScore}. Pass session_id to query the cached map from a prior screen_perceive/screen_delta — avoids a recapture.
"""

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "selector": JSONSchema.string(
                description: "Selector expression. See the tool description for full grammar. Multiple terms are AND-ed via whitespace; use \"!\" for negation and \"(...)\" for grouping. Example: role:button label*save in:\"Toolbar\"."
            ),
            "session_id": JSONSchema.string(
                description: "Optional session key. When set, the tool reuses the cached ScreenMap from SnapshotCache (populated by screen_perceive / screen_delta with the same session_id) instead of capturing fresh. Omit to capture a new map."
            ),
            "max_results": JSONSchema.integer(
                description: "Upper bound on returned matches (default 50). Truncation happens after sort.",
                minimum: 1,
                maximum: 1000
            ),
            "include_non_interactive": JSONSchema.boolean(
                description: "When false, drop non-interactive elements (staticText, group, etc.) after filtering. Default true."
            ),
            "sort": JSONSchema.enumString(
                description: "Result order. 'match' (default — highest matchScore first), 'top' (top-to-bottom by Y), 'left' (left-to-right by X), 'stability' (highest stabilityScore first).",
                values: ["match", "top", "left", "stability"]
            ),
        ], required: ["selector"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do {
            args = try parseArguments(arguments)
        } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }

        guard let selector = args["selector"] as? String, !selector.isEmpty else {
            return "Error: missing required parameter: selector"
        }

        let sessionID = (args["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let maxResults = (args["max_results"] as? Int)
            ?? ((args["max_results"] as? Double).map(Int.init))
            ?? 50
        let includeNonInteractive = (args["include_non_interactive"] as? Bool) ?? true
        let sortOrder: QuerySortOrder
        switch (args["sort"] as? String)?.lowercased() {
        case "top":       sortOrder = .topToBottom
        case "left":      sortOrder = .leftToRight
        case "stability": sortOrder = .stabilityScore
        case "match", nil: sortOrder = .matchScore
        case let other?:
            return Self.errorJSON(message: "unknown sort order '\(other)' (use match/top/left/stability)")
        }

        var options = QueryOptions()
        options.maxResults = maxResults
        options.includeNonInteractive = includeNonInteractive
        options.sortBy = sortOrder
        // `screen_query` should see the same elements `screen_perceive` shows
        // — i.e. the permissive filter. Callers who want the strict default
        // can swap this later via a dedicated `filter_policy` argument.
        options.filterPolicy = .permissive

        let results: [QueryResult]
        do {
            results = try await DefaultComputerPerception.shared.query(
                selector,
                sessionID: sessionID,
                options: options
            )
        } catch let error as QueryError {
            return Self.errorJSON(message: error.description)
        } catch {
            return Self.errorJSON(message: "query failed: \(error.localizedDescription)")
        }

        let payload: [[String: Any]] = results.map { r in
            var dict: [String: Any] = [
                "ref": r.ref.description,
                "role": r.role.rawValue,
                "label": r.label,
                "displayIndex": r.displayIndex,
                "tier": Self.tierString(r.tier),
                "stabilityScore": Double(r.stabilityScore),
                "matchScore": Double(r.matchScore),
            ]
            if let click = r.click {
                dict["click"] = [Int(click.x), Int(click.y)]
            }
            if let bounds = r.bounds {
                dict["bounds"] = [
                    Int(bounds.origin.x),
                    Int(bounds.origin.y),
                    Int(bounds.width),
                    Int(bounds.height),
                ]
            }
            return dict
        }

        return Self.jsonString(payload)
    }

    // MARK: Internals

    private static func tierString(_ t: IdentityTier) -> String {
        switch t {
        case .identifier: return "identifier"
        case .dom:        return "dom"
        case .menu:       return "menu"
        case .label:      return "label"
        case .position:   return "position"
        case .visual:     return "visual"
        case .fallback:   return "fallback"
        }
    }

    /// Structured JSON error matching the spec: `{"error": "...", "at": N}`.
    /// Always falls back to a plain string message if JSON serialization
    /// fails for any reason.
    static func errorJSON(message: String, at: Int = 0) -> String {
        let dict: [String: Any] = ["error": message, "at": at]
        if let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "Error: \(message)"
    }

    private static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[]"
    }
}

// MARK: - ScreenDiffTool (back-compat alias for ScreenDeltaTool)

/// Back-compat name preserved from Rank 0. Internally this is now the
/// Rank-2 delta encoder, keyed by `session_id` (default `"default"`), so
/// existing callers keep working while new callers should prefer
/// `screen_delta` which exposes session controls explicitly.
public struct ScreenDiffTool: ToolDefinition {
    public let name = "screen_diff"
    public let description = "Capture a ref-delta against the most-recent snapshot for the given session. Back-compat alias for `screen_delta` — routes through the same Rank 2 delta encoder. First call in a session ships a full baseline; subsequent calls ship only added/removed/changed refs plus a retained-ref list, dropping token cost ~95% on sticky screens. Use `screen_reset_session` to force a fresh baseline."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "session_id": JSONSchema.string(
                description: "Session key. Defaults to 'default' for callers that don't care about multi-session isolation."
            ),
            "format": JSONSchema.enumString(
                description: "Output format. `json` (default) for programmatic consumers; `text` for LLM-friendly summary.",
                values: ["text", "json"]
            ),
        ])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            do {
                args = try parseArguments(arguments)
            } catch {
                return "Error: failed to parse arguments: \(error.localizedDescription)"
            }
        }
        let sessionID = (args["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let format = (args["format"] as? String) ?? "json"

        let payload = await DefaultComputerPerception.shared.captureDelta(
            sessionID: sessionID,
            policy: .default
        )
        switch format {
        case "text":
            return await DefaultComputerPerception.shared.formatDeltaForLLMAsync(payload, maxElements: 120)
        case "json":
            return DefaultComputerPerception.shared.formatDeltaAsJSON(payload)
        default:
            return "Error: unknown format '\(format)'. Use 'text' or 'json'."
        }
    }
}

// MARK: - ScreenDeltaTool

/// Rank 2 canonical entry point for the delta encoder. Callers who want
/// the token-savings behavior should prefer `screen_delta` over
/// `screen_perceive` with a `session_id` — both hit the same cache under
/// the hood, but `screen_delta` also exposes the text-format delta summary
/// which is easier for the LLM to skim mid-conversation.
public struct ScreenDeltaTool: ToolDefinition {
    public let name = "screen_delta"
    public let description = "Capture a token-efficient delta against the most-recent snapshot in the given session. First call ships a full baseline; subsequent calls ship only ref-partitioned changes (added full-bodies, removedRefs, changed fields, retained refs) plus filter + meta deltas. Typical savings vs. `screen_perceive`: ~95% on unchanged screens. Call `screen_reset_session` to re-seed the baseline when the screen changes radically (app switch, navigation)."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "session_id": JSONSchema.string(
                description: "Session key. Use a stable per-agent-task id so the cache can diff calls inside the same flow. Defaults to 'default'."
            ),
            "format": JSONSchema.enumString(
                description: "Output format. `text` (default) is an LLM-readable summary; `json` ships the full DeltaPayload JSON for programmatic consumers.",
                values: ["text", "json"]
            ),
            "max_elements": JSONSchema.integer(
                description: "Upper bound on elements rendered in `text` format (default 120). Ignored for `json`.",
                minimum: 1,
                maximum: 10_000
            ),
        ])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            do {
                args = try parseArguments(arguments)
            } catch {
                return "Error: failed to parse arguments: \(error.localizedDescription)"
            }
        }
        let sessionID = (args["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let format = (args["format"] as? String) ?? "text"
        let maxElements = (args["max_elements"] as? Int)
            ?? ((args["max_elements"] as? Double).map(Int.init))
            ?? 120

        let payload = await DefaultComputerPerception.shared.captureDelta(
            sessionID: sessionID,
            policy: .default
        )
        switch format {
        case "json":
            return DefaultComputerPerception.shared.formatDeltaAsJSON(payload)
        case "text":
            return await DefaultComputerPerception.shared.formatDeltaForLLMAsync(
                payload, maxElements: maxElements
            )
        default:
            return "Error: unknown format '\(format)'. Use 'text' or 'json'."
        }
    }
}

// MARK: - ScreenResetSessionTool

/// Drop the cached snapshot for a session so the next `screen_delta`
/// / `screen_perceive(session_id:)` call emits a fresh baseline.
public struct ScreenResetSessionTool: ToolDefinition {
    public let name = "screen_reset_session"
    public let description = "Reset the delta-encoding cache for a session. The next `screen_delta` / `screen_perceive(session_id:)` call will ship a fresh baseline instead of a delta. Use after app switches, navigation changes, or whenever the baseline is stale. Returns 'reset' on success."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "session_id": JSONSchema.string(
                description: "Session key to reset. Required — there's no global reset to protect concurrent sessions."
            ),
        ], required: ["session_id"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do {
            args = try parseArguments(arguments)
        } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let sessionID = args["session_id"] as? String, !sessionID.isEmpty else {
            return "Error: missing required parameter: session_id"
        }
        await DefaultComputerPerception.shared.resetDeltaSession(sessionID: sessionID)
        return "reset"
    }
}

// MARK: - InvokeMenuTool

/// Invokes a menu bar item by title path (e.g. `["File","Save"]`) in the
/// target app. Uses ComputerLib's AX-based invocation — no cursor moves, no
/// pixels touched, no clicks synthesized.
public struct InvokeMenuTool: ToolDefinition {
    public let name = "invoke_menu"
    public let description = "Invoke a menu bar item by its title path (e.g. ['File','Save']) in the specified app. Pure AX dispatch — no cursor or click synthesis. When `app` is omitted, targets the frontmost app. Returns 'invoked' on success or a descriptive error string."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "path": JSONSchema.array(
                items: ["type": "string"],
                description: "Menu item title path. e.g. ['File','Save As…']. Must match the exact titles shown in the menu bar."
            ),
            "app": JSONSchema.string(
                description: "Optional target app name (matched against NSRunningApplication.localizedName). Defaults to the frontmost app."
            ),
        ], required: ["path"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do {
            args = try parseArguments(arguments)
        } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }

        guard let rawPath = args["path"] as? [Any] else {
            return "Error: missing required parameter: path (array of strings)"
        }
        let path = rawPath.compactMap { $0 as? String }
        guard !path.isEmpty else {
            return "Error: path must be a non-empty array of strings"
        }

        let appFilter = args["app"] as? String

        let pid: pid_t
        if let appName = appFilter, !appName.isEmpty {
            let match = NSWorkspace.shared.runningApplications.first { app in
                let localized = app.localizedName ?? ""
                return localized.caseInsensitiveCompare(appName) == .orderedSame
            }
            guard let match else {
                return "Error: no running app named '\(appName)'"
            }
            pid = match.processIdentifier
        } else {
            let map = await DefaultComputerPerception.shared.capture()
            pid = pid_t(map.focusedApp.pid)
        }

        let ok = DefaultComputerPerception.shared.invokeMenu(path: path, pid: pid)
        if ok {
            return "invoked"
        }
        return "Error: failed to invoke menu path \(path) on pid \(pid)"
    }
}

// MARK: - FindElementTool

/// Resolves an `@eN` ref string against a freshly captured screen map.
public struct FindElementTool: ToolDefinition {
    public let name = "find_element"
    public let description = "Resolve an element ref (e.g. '@e12') against a fresh screen capture. Returns a JSON object with ref, role, label, bounds, click point, and state — or an error if the ref is not present in the current map."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "ref": JSONSchema.string(
                description: "Element ref string, e.g. '@e12'. Match the format emitted by screen_perceive."
            ),
        ], required: ["ref"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do {
            args = try parseArguments(arguments)
        } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }

        guard let ref = args["ref"] as? String, !ref.isEmpty else {
            return "Error: missing required parameter: ref"
        }

        let map = await DefaultComputerPerception.shared.capture()
        guard let el = DefaultComputerPerception.shared.findByRef(ref, in: map) else {
            return "Error: ref '\(ref)' not found in current screen map"
        }

        var dict: [String: Any] = [
            "ref": el.ref.description,
            "role": el.role.rawValue,
            "label": el.label,
            "value": el.value,
            "state": el.state.names,
            "actions": el.actions.map { $0.rawValue },
            "win": el.windowIndex,
            "depth": el.depth,
            "source": el.source.rawValue,
            "confidence": Double(el.confidence),
        ]
        if let bounds = el.bounds {
            dict["bounds"] = [
                Int(bounds.origin.x),
                Int(bounds.origin.y),
                Int(bounds.width),
                Int(bounds.height),
            ]
        }
        if let click = el.clickPoint {
            dict["click"] = [Int(click.x), Int(click.y)]
        }
        if let parent = el.parentRef {
            dict["parent"] = parent.description
        }
        if let bundle = el.appBundleID {
            dict["bundle"] = bundle
        }

        return Self.jsonString(dict)
    }

    private static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

// MARK: - SuggestActionsTool

/// Given a natural-language goal, returns a ranked plan of element
/// interactions from ComputerLib's ActionSuggester.
public struct SuggestActionsTool: ToolDefinition {
    public let name = "suggest_actions"
    public let description = "Given a natural-language goal (e.g. 'save the document'), return a ranked JSON plan of element interactions and an optional keyboard-shortcut alternative. Uses ComputerLib's ActionSuggester — label matching, parent context, action-verb heuristics, learned preferences."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "goal": JSONSchema.string(
                description: "Natural-language goal. Examples: 'click Save', 'open File menu', 'type in the search box'."
            ),
        ], required: ["goal"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do {
            args = try parseArguments(arguments)
        } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }

        guard let goal = args["goal"] as? String, !goal.isEmpty else {
            return "Error: missing required parameter: goal"
        }

        let map = await DefaultComputerPerception.shared.capture()
        let plan = DefaultComputerPerception.shared.suggestActions(
            goal: goal,
            map: map
        )

        var payload: [String: Any] = [
            "goal": plan.goal,
            "confidence": Double(plan.confidence),
            "steps": plan.steps.map { step -> [String: Any] in
                var dict: [String: Any] = [
                    "ref": step.element.ref.description,
                    "role": step.element.role.rawValue,
                    "label": step.element.label,
                    "action": step.action.rawValue,
                    "rationale": step.rationale,
                    "score": Double(step.score),
                ]
                if let click = step.element.clickPoint {
                    dict["click"] = [Int(click.x), Int(click.y)]
                }
                return dict
            },
        ]
        if let shortcut = plan.shortcutAlternative {
            payload["shortcut"] = [
                "display": shortcut.displayString,
                "menu_path": shortcut.menuPath,
                "key": shortcut.key,
                "modifiers": shortcut.modifiers,
            ]
        }

        return Self.jsonString(payload)
    }

    private static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

// MARK: - ListDisplaysTool

/// Enumerates every attached display with its index, name, origin, size, and
/// `isMain` flag. Pairs with `capture_display` and `screen_perceive` —
/// agents call this first to discover valid display indices.
public struct ListDisplaysTool: ToolDefinition {
    public let name = "list_displays"
    public let description = "List all attached displays with their indices, localized names, bounds (origin in NSScreen cartesian + top-left CG space), backing scale, and main-display flag. Use this to discover valid display indices before calling `capture_display`."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let displays = WindowEnumerator.allDisplays()
        let payload: [[String: Any]] = displays.map { d in
            [
                "index": d.index,
                "id": Int(d.id),
                "name": d.name,
                "width": d.width,
                "height": d.height,
                "scale": d.scale,
                "isMain": d.isMain,
                "origin": [Int(d.origin.x), Int(d.origin.y)],
                "topLeftOrigin": [Int(d.topLeftOrigin.x), Int(d.topLeftOrigin.y)],
            ]
        }
        return Self.jsonString(payload)
    }

    private static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[]"
    }
}

// MARK: - CaptureDisplayTool

/// Captures a specific display to PNG via ComputerLib's per-display screen
/// capture path. Returns the saved file path. Differs from `capture_screen`
/// in that it targets a single display by its `DisplayInfo.index` (from
/// `list_displays`) rather than shelling out to `/usr/sbin/screencapture`.
public struct CaptureDisplayTool: ToolDefinition {
    public let name = "capture_display"
    public let description = "Capture a specific display as PNG via ComputerLib (no screencapture CLI). Accepts a display index from `list_displays` (default: main display). Saves to `path` if provided, else ~/Desktop/metamorphia-display-<index>-<timestamp>.png. Returns the saved path."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "index": JSONSchema.integer(
                description: "Display index from `list_displays` (0-based, NSScreen.screens order). Omit to capture the main display.",
                minimum: 0,
                maximum: 32
            ),
            "path": JSONSchema.string(
                description: "Output file path (supports ~). Default: ~/Desktop/metamorphia-display-<index>-<timestamp>.png"
            ),
        ])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            do {
                args = try parseArguments(arguments)
            } catch {
                return "Error: failed to parse arguments: \(error.localizedDescription)"
            }
        }

        let requestedIndex: Int
        if let i = args["index"] as? Int {
            requestedIndex = i
        } else if let d = args["index"] as? Double {
            requestedIndex = Int(d)
        } else {
            requestedIndex = WindowEnumerator.mainDisplay().index
        }

        guard let image = ScreenCapture.captureDisplay(index: requestedIndex) else {
            return "Error: failed to capture display index \(requestedIndex). Call list_displays to see valid indices."
        }
        guard let pngData = ScreenCapture.toPNGData(image) else {
            return "Error: captured display \(requestedIndex) but PNG conversion failed."
        }

        let rawPath: String
        if let p = args["path"] as? String, !p.isEmpty {
            rawPath = p
        } else {
            let ts = Int(Date().timeIntervalSince1970)
            let desktop = ("~/Desktop" as NSString).expandingTildeInPath as NSString
            rawPath = desktop.appendingPathComponent("metamorphia-display-\(requestedIndex)-\(ts).png")
        }
        let outPath = (rawPath as NSString).expandingTildeInPath

        do {
            try pngData.write(to: URL(fileURLWithPath: outPath))
        } catch {
            return "Error: failed to write PNG to \(outPath): \(error.localizedDescription)"
        }

        let size = ByteCountFormatter().string(fromByteCount: Int64(pngData.count))
        return "Saved \(size) → \(outPath) (display \(requestedIndex), \(image.width)×\(image.height))"
    }
}

// MARK: - ShortcutsTool

/// Enumerates keyboard shortcuts from the frontmost app's menu bar.
public struct ShortcutsTool: ToolDefinition {
    public let name = "list_shortcuts"
    public let description = "List all keyboard shortcuts advertised in the frontmost app's menu bar (via AXMenuItemCmdChar + AXMenuItemCmdModifiers). Returns a newline-delimited 'Shortcuts:' block keyed by menu path. Useful before synthesizing key events — many apps expose essentially every feature as a shortcut."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [:])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let shortcuts = DefaultComputerPerception.shared.discoverShortcuts()
        let formatted = DefaultComputerPerception.shared.formatShortcuts(shortcuts)
        if formatted.isEmpty {
            return "No shortcuts discovered (menu bar may not be readable — check AX permission)."
        }
        return formatted
    }
}

// MARK: - VisionDiffTool (Rank 8)

/// Rank 8 — Cropped vision diff. Captures a fresh screen snapshot, diffs
/// against the session's previous map, and returns a cropped PNG (base64)
/// of the change region — not the full screenshot. Typical byte savings
/// versus `capture_display` on a 3840×2160 display with a 500×400 change
/// region: ~94% (8 MB full → ~0.5 MB cropped).
///
/// The LLM gets the cropped PNG to answer visual questions without the
/// token cost of a full-screen frame every call. For screens with no
/// meaningful change, the tool returns an empty `{}` response so the
/// agent knows to skip the vision call entirely.
public struct VisionDiffTool: ToolDefinition {
    public let name = "vision_diff"
    public let description = "Rank 8 — Capture a cropped visual diff of what changed on screen since the last call. Returns a base64 PNG containing only the bounding box of changed/added/removed elements (+ configurable margin), plus ref lists and a confidence score. Typical savings on a 4K display with localized changes: ~94% fewer bytes than shipping the full screenshot. Session-scoped: the same `session_id` tracks previous state. Returns JSON `{cropped_base64, region:[x,y,w,h], display_index, changed_refs, added_refs, removed_refs, confidence, full_screen_fallback, width, height, path?}` or `{}` when no meaningful change is detected. Set `save_to_path` to also persist the crop to disk."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "session_id": JSONSchema.string(
                description: "Session key. Must match the session you've been using with screen_perceive / screen_delta / vision_diff — the previous map is read from the same cache."
            ),
            "margin_px": JSONSchema.integer(
                description: "Pixels of margin added around the changed region before cropping. Default 32. Larger margin gives the vision model more context but raises payload bytes.",
                minimum: 0,
                maximum: 512
            ),
            "full_screen_threshold": JSONSchema.number(
                description: "Fraction of display area above which the tool emits the full frame instead of a near-full crop (0.0 – 1.0). Default 0.7. Below this, crop wins; above, full frame wins."
            ),
            "save_to_path": JSONSchema.string(
                description: "Optional output path (supports ~). When set, writes the cropped PNG to disk and includes `path` in the response."
            ),
            "policy": JSONSchema.enumString(
                description: "Policy preset: `default` (balanced), `aggressive` (tiny margin, low threshold — minimize payload), `conservative` (wider margin, higher threshold — preserve context).",
                values: ["default", "aggressive", "conservative"]
            ),
        ], required: ["session_id"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do {
            args = try parseArguments(arguments)
        } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let sessionID = args["session_id"] as? String, !sessionID.isEmpty else {
            return "Error: missing required parameter: session_id"
        }

        let policy = Self.buildPolicy(from: args)
        let savePath = args["save_to_path"] as? String

        let diff = await DefaultComputerPerception.shared.visionDiff(
            sessionID: sessionID, policy: policy
        )
        guard let diff else {
            // Either first call in the session (no previous map) or no
            // meaningful change detected. Empty object signals "skip vision".
            return "{}"
        }

        return Self.encode(diff: diff, savePath: savePath)
    }

    /// Build a policy from the incoming args. Applies a preset first (if
    /// supplied) then overrides margin_px / full_screen_threshold when
    /// explicitly set.
    static func buildPolicy(from args: [String: Any]) -> VisionDiffPolicy {
        var policy: VisionDiffPolicy
        switch (args["policy"] as? String)?.lowercased() {
        case "aggressive":   policy = .aggressive
        case "conservative": policy = .conservative
        default:             policy = .default
        }
        if let margin = args["margin_px"] as? Int {
            policy.marginPx = CGFloat(margin)
        } else if let margin = args["margin_px"] as? Double {
            policy.marginPx = CGFloat(margin)
        }
        if let threshold = args["full_screen_threshold"] as? Double {
            policy.fullScreenThreshold = CGFloat(threshold)
        } else if let threshold = args["full_screen_threshold"] as? Int {
            policy.fullScreenThreshold = CGFloat(threshold)
        }
        return policy
    }

    /// Encode a single `VisionDiff` as JSON. Optionally writes the crop PNG
    /// to `savePath` and adds a `path` field.
    static func encode(diff: VisionDiff, savePath: String?) -> String {
        var dict: [String: Any] = [
            "cropped_base64": diff.croppedBase64,
            "region": [
                Int(diff.changeRegion.origin.x),
                Int(diff.changeRegion.origin.y),
                Int(diff.changeRegion.width),
                Int(diff.changeRegion.height),
            ] as [Int],
            "display_index": diff.changeRegionDisplayIndex,
            "changed_refs": diff.changedRefs.map { $0.description },
            "added_refs": diff.addedRefs.map { $0.description },
            "removed_refs": diff.removedRefs.map { $0.description },
            "confidence": Double(diff.confidence),
            "full_screen_fallback": diff.fullScreenFallback,
            "width": diff.imageWidth,
            "height": diff.imageHeight,
        ]
        if let savePath = savePath, !savePath.isEmpty {
            let expanded = (savePath as NSString).expandingTildeInPath
            if let pngData = Data(base64Encoded: diff.croppedBase64) {
                do {
                    try pngData.write(to: URL(fileURLWithPath: expanded))
                    dict["path"] = expanded
                } catch {
                    dict["path_error"] = error.localizedDescription
                }
            }
        }
        return jsonString(dict)
    }

    static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

// MARK: - VisionDiffMultiTool (Rank 8)

/// Rank 8 — Multi-display cropped vision diff. Same semantics as
/// `vision_diff` but partitions per-display, returning a primary crop
/// (the display with the largest change area) and an array of secondary
/// crops (remaining displays with any change). Useful for multi-monitor
/// setups where the agent needs to see changes on both screens.
public struct VisionDiffMultiTool: ToolDefinition {
    public let name = "vision_diff_multi"
    public let description = "Rank 8 — Multi-display variant of `vision_diff`. Returns a JSON object with `primary` (the display containing the largest change area) and `secondary` (an array of per-display crops for the other displays with any change). Each entry has the same shape as `vision_diff`'s output (`cropped_base64`, `region`, `display_index`, `changed_refs`, `confidence`, etc.). Empty `{}` when no display has a meaningful change."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "session_id": JSONSchema.string(
                description: "Session key. Must match the session you've been using with screen_perceive / screen_delta / vision_diff — the previous map is read from the same cache."
            ),
            "margin_px": JSONSchema.integer(
                description: "Pixels of margin added around each per-display changed region. Default 32.",
                minimum: 0,
                maximum: 512
            ),
            "full_screen_threshold": JSONSchema.number(
                description: "Fraction of display area above which the tool emits a full-frame per-display crop instead of a near-full crop (0.0 – 1.0). Default 0.7."
            ),
            "save_to_path": JSONSchema.string(
                description: "Optional directory path (supports ~). When set, writes each display's cropped PNG as `<dir>/vision-diff-<display_index>.png` and includes `path` in each entry."
            ),
            "policy": JSONSchema.enumString(
                description: "Policy preset: `default` (balanced), `aggressive`, `conservative`.",
                values: ["default", "aggressive", "conservative"]
            ),
        ], required: ["session_id"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        do {
            args = try parseArguments(arguments)
        } catch {
            return "Error: failed to parse arguments: \(error.localizedDescription)"
        }
        guard let sessionID = args["session_id"] as? String, !sessionID.isEmpty else {
            return "Error: missing required parameter: session_id"
        }

        let policy = VisionDiffTool.buildPolicy(from: args)
        let saveDir = args["save_to_path"] as? String

        let multi = await DefaultComputerPerception.shared.visionDiffMultiDisplay(
            sessionID: sessionID, policy: policy
        )
        guard let multi else {
            return "{}"
        }

        let primaryPath = saveDir.map { Self.savePathFor(dir: $0, displayIndex: multi.primary.changeRegionDisplayIndex) }
        let primaryJSON = VisionDiffTool.encode(diff: multi.primary, savePath: primaryPath)
        let secondaryJSONs: [String] = multi.secondary.map { d in
            let path = saveDir.map { Self.savePathFor(dir: $0, displayIndex: d.changeRegionDisplayIndex) }
            return VisionDiffTool.encode(diff: d, savePath: path)
        }

        // Compose the outer JSON by parsing each encoded inner JSON back to a
        // dictionary — keeps the payload a single well-formed document without
        // double-escaping the inner objects.
        let primaryObj = Self.parseJSON(primaryJSON) ?? [:]
        let secondaryObjs = secondaryJSONs.compactMap(Self.parseJSON)
        let outer: [String: Any] = [
            "primary": primaryObj,
            "secondary": secondaryObjs,
        ]
        return VisionDiffTool.jsonString(outer)
    }

    private static func savePathFor(dir: String, displayIndex: Int) -> String {
        let expanded = (dir as NSString).expandingTildeInPath as NSString
        return expanded.appendingPathComponent("vision-diff-\(displayIndex).png")
    }

    private static func parseJSON(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
