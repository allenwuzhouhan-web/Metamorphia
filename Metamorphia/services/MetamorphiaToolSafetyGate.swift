/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import Foundation
import MetamorphiaAgentKit

/// Concrete `ToolSafetyGate` that asks the user to confirm before the LLM runs
/// any `.critical`-tier tool (shell, AppleScript, scripting languages, HTTP,
/// destructive file ops). `.elevated` and `.safe` tiers pass silently so the
/// agent stays fast on everyday tasks; only the blast-radius moves block on a
/// confirmation.
///
/// The user has four choices per prompt:
///   - **Allow Once** — this single invocation.
///   - **Allow for This Session** — the whole app lifetime (reset on quit).
///   - **Always Allow** — persisted in `UserDefaults`.
///   - **Deny** — returns an Error: ... string to the LLM so it can re-plan.
///
/// Argument-aware tiering: `file_operation` is demoted to `.elevated` for
/// read-ish actions (`open`, `reveal`, `info`, `get_downloads_path`,
/// `get_finder_path`, `create_folder`) and treated as `.critical` only for
/// actions that mutate paths the user didn't type (`move`, `copy`, `trash`,
/// `rename`). This matches user expectation — "open Downloads" shouldn't
/// prompt, but "trash report.pdf" should.
///
/// `@unchecked Sendable` because the dictionaries + sets are only mutated under
/// `lock`; the class has no mutable state visible outside that critical section.
final class MetamorphiaToolSafetyGate: ToolSafetyGate, @unchecked Sendable {

    static let shared = MetamorphiaToolSafetyGate()

    private let lock = NSLock()
    private var dynamicTiers: [String: ToolRiskTier] = [:]
    private var sessionAllowed: Set<String> = []
    /// Registered argument inspectors (Phase 3c). Each is consulted *before*
    /// the static tier table on every call. A non-nil result from any inspector
    /// overrides the static tier — used by `PerceptionSafetyInspector` to
    /// auto-escalate clicks on "Delete account"-style targets to `.critical`.
    private var inspectors: [any ToolArgumentSafetyInspector] = []
    private let defaults = UserDefaults.standard

    private static let alwaysAllowKeyPrefix = "MetamorphiaToolSafetyGate.alwaysAllow."

    /// Known tool names whose default tier is `.critical` regardless of
    /// arguments. Keep in sync with the tools registered in ``MetamorphiaBootstrap``.
    ///
    /// AUDIT: `computer_batch` runs an arbitrary sequence of presses/types/menu
    /// invokes in one atomic span. Each sub-action would individually be subject
    /// to the inspector, but the batch executes them without re-entering the gate
    /// per step, so the batch itself is gated `.critical` (a single confirmation
    /// covers the whole flow). Scripting/file/process tools below have an
    /// unbounded blast radius and are always `.critical`.
    private static let defaultCriticalTools: Set<String> = [
        "run_shell_command",
        "run_applescript",
        "run_python",
        "run_node",
        "run_ruby",
        "http_request",
        "kill_process",
        "write_file",
        "edit_file",
        "computer_batch",
    ]

    /// Autonomous input tools that synthesize real HID events (mouse/keyboard)
    /// into whatever is frontmost. They are NOT read-only, so they must never
    /// fall through to `.safe`. Baseline is `.elevated` — silent but non-`safe` —
    /// so `PerceptionSafetyInspector` can escalate the specific click/keystroke
    /// to `.critical` when it lands on a destructive element or a sensitive field
    /// (e.g. "Delete account", a password box). A blanket `.critical` here would
    /// prompt on every benign click and wreck UX, which the safety design
    /// explicitly avoids. Names mirror the tools registered in `GestureTools`
    /// plus the `computer_batch` sub-action verbs for defense in depth.
    ///
    /// AUDIT: closes the fail-open hole where destructive input fired at `.safe`.
    private static let defaultElevatedTools: Set<String> = [
        "click_at",
        "double_click_at",
        "right_click_at",
        "long_press",
        "drag",
        "swipe",
        "type_text",
        "key_combo",
        "move_mouse",
        // `computer_batch` sub-action verbs / audit aliases — harmless if a tool
        // by this exact name isn't registered, but keeps the set authoritative.
        "type",
        "press",
        "invoke_menu",
        "click",
    ]

    /// Friendly display names for the confirmation dialog. Falls back to the
    /// registered ``ToolDisplayName`` mapping, then to the raw tool name.
    private static let friendlyNames: [String: String] = [
        "run_shell_command": "Run a shell command",
        "run_applescript": "Run an AppleScript",
        "run_python": "Run a Python script",
        "run_node": "Run a Node.js script",
        "run_ruby": "Run a Ruby script",
        "http_request": "Make an HTTP request",
        "file_operation": "Modify a file",
        "kill_process": "Kill a process",
        "write_file": "Write a file",
        "edit_file": "Edit a file",
    ]

    private init() {}

    // MARK: - ToolSafetyGate

    func register(toolName: String, tier: ToolRiskTier) {
        lock.lock()
        dynamicTiers[toolName] = tier
        lock.unlock()
    }

    /// Register an argument-aware inspector. Inspectors run sequentially on
    /// every permission check; the first non-nil response wins. Safe to call
    /// from any thread.
    func register(inspector: any ToolArgumentSafetyInspector) {
        lock.lock()
        inspectors.append(inspector)
        lock.unlock()
    }

    func checkPermission(toolName: String, arguments: String) async -> ToolPermissionDecision {
        // Phase 3c: consult registered inspectors first. Any non-nil override
        // wins against the static tier table — this is how a click on a
        // destructive element gets auto-escalated even if `click_at`'s baseline
        // tier is `.elevated` or lower.
        let snapshot: [any ToolArgumentSafetyInspector]
        lock.lock()
        snapshot = inspectors
        lock.unlock()

        var inspectorTier: ToolRiskTier?
        for inspector in snapshot {
            if let t = await inspector.inspect(toolName: toolName, arguments: arguments) {
                inspectorTier = t
                break
            }
        }

        let tier = inspectorTier ?? resolveTier(toolName: toolName, arguments: arguments)

        switch tier {
        case .safe, .elevated:
            return .allow
        case .critical:
            break
        }

        lock.lock()
        let sessionOK = sessionAllowed.contains(toolName)
        lock.unlock()

        if sessionOK { return .allow }
        if defaults.bool(forKey: Self.alwaysAllowKeyPrefix + toolName) { return .allow }

        return await promptUser(toolName: toolName, arguments: arguments)
    }

    // MARK: - Session Control

    /// Reset the "Allow for this session" cache. Called from `CommandBarCoordinator`
    /// when the user explicitly resets permissions (menu item or Settings button).
    func resetSession() {
        lock.lock()
        sessionAllowed.removeAll()
        lock.unlock()
    }

    /// Revoke a previously-granted "Always allow" decision. Exposed so the
    /// Settings UI can clear it per-tool.
    func revokeAlwaysAllow(for toolName: String) {
        defaults.removeObject(forKey: Self.alwaysAllowKeyPrefix + toolName)
    }

    // MARK: - Tier Resolution

    private func resolveTier(toolName: String, arguments: String) -> ToolRiskTier {
        // `file_operation`'s tier depends on the `action` argument.
        if toolName == "file_operation" {
            if let data = arguments.data(using: .utf8),
               let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let action = args["action"] as? String {
                let destructive: Set<String> = ["move", "copy", "trash", "rename"]
                return destructive.contains(action) ? .critical : .elevated
            }
            return .critical // unparseable — be conservative
        }

        if Self.defaultCriticalTools.contains(toolName) {
            return .critical
        }

        // AUTONOMOUS-INPUT tools that drive real HID events are never read-only.
        // They sit at `.elevated` by default so the inspector (consulted before
        // this table in `checkPermission`) can escalate the dangerous ones to
        // `.critical`. They must NOT reach the `.safe` fallback below.
        if Self.defaultElevatedTools.contains(toolName) {
            return .elevated
        }

        lock.lock()
        let dynamic = dynamicTiers[toolName]
        lock.unlock()
        if let dynamic { return dynamic }

        // MCP tools (identified by their `mcp__` prefix) default to elevated —
        // they touch external systems but aren't inherently destructive. The
        // registry's `inferredTier(forMCPToolName:)` may have bumped individual
        // ones to `.critical` via `register(toolName:tier:)` above.
        if toolName.hasPrefix("mcp__") {
            return .elevated
        }

        // AUDIT: `.safe` is the fallback ONLY for genuinely read-only tools
        // (perception/query/web-read tools that have no side effect). It is
        // intentionally NOT a blanket allow — every side-effecting tool above is
        // classified explicitly so an unlisted *read-only* tool stays fast while
        // a newly added *dangerous* tool must be added to a set above to ship.
        return .safe
    }

    // MARK: - Prompt

    private func promptUser(toolName: String, arguments: String) async -> ToolPermissionDecision {
        await MainActor.run {
            self.showAlert(toolName: toolName, arguments: arguments)
        }
    }

    @MainActor
    private func showAlert(toolName: String, arguments: String) -> ToolPermissionDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow Metamorphia to \(Self.friendlyName(for: toolName))?"
        alert.informativeText = Self.informativeText(toolName: toolName, arguments: arguments)
        // Pre-loaded icon — see comment in MemoryUsageMonitor. NSAlert's default
        // caution icon goes through _NSAsynchronousPreparation; an off-main
        // accessibility query while the modal is up will trip the main-thread
        // assert and SIGABRT the app.
        alert.icon = Self.cautionIcon

        // Button order in NSAlert is right-to-left; the first one added is the
        // default (rightmost, highlighted). "Deny" is the cancel key so Esc
        // denies. We want "Allow Once" as the common-case default: if the user
        // hits Return without thinking, they at least don't grant blanket
        // access.
        let allowOnce = alert.addButton(withTitle: "Allow Once")
        allowOnce.keyEquivalent = "\r"
        _ = alert.addButton(withTitle: "Allow for This Session")
        _ = alert.addButton(withTitle: "Always Allow")
        let deny = alert.addButton(withTitle: "Deny")
        deny.keyEquivalent = "\u{1b}" // Escape

        // Bring the app + alert forward so the user notices. The agent loop
        // runs on a detached task; without activation, the alert can appear
        // behind other windows.
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn: // Allow Once
            return .allow

        case .alertSecondButtonReturn: // Allow for This Session
            lock.lock()
            sessionAllowed.insert(toolName)
            lock.unlock()
            return .allow

        case .alertThirdButtonReturn: // Always Allow
            defaults.set(true, forKey: Self.alwaysAllowKeyPrefix + toolName)
            lock.lock()
            sessionAllowed.insert(toolName)
            lock.unlock()
            return .allow

        default: // Deny (including Esc)
            return .deny(reason: "User denied permission for this tool.")
        }
    }

    // MARK: - Display Helpers

    private static func friendlyName(for toolName: String) -> String {
        if let mapped = friendlyNames[toolName] { return mapped }
        let display = ToolDisplayName.display(toolName)
        return display.isEmpty ? toolName : display.lowercased()
    }

    /// Build the informative body. For arg-heavy tools like shell/AppleScript,
    /// surface the command itself so the user can judge intent at a glance.
    /// Truncates to ~800 chars to keep the dialog readable.
    private static func informativeText(toolName: String, arguments: String) -> String {
        let preview: String
        if let data = arguments.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch toolName {
            case "run_shell_command":
                preview = (args["command"] as? String) ?? arguments
            case "run_applescript":
                preview = (args["script"] as? String) ?? arguments
            case "run_python", "run_node", "run_ruby":
                preview = (args["code"] as? String) ?? arguments
            case "http_request":
                let method = (args["method"] as? String) ?? "GET"
                let url = (args["url"] as? String) ?? "?"
                preview = "\(method) \(url)"
            case "file_operation":
                let action = (args["action"] as? String) ?? "?"
                let path = (args["path"] as? String) ?? "?"
                let dest = (args["destination"] as? String).map { " → \($0)" } ?? ""
                preview = "\(action) \(path)\(dest)"
            case "kill_process":
                preview = (args["pid"].map { "pid \($0)" }) ?? (args["name"] as? String) ?? arguments
            case "write_file", "edit_file":
                preview = (args["path"] as? String) ?? arguments
            default:
                preview = arguments
            }
        } else {
            preview = arguments
        }

        let maxLen = 800
        let clipped: String
        if preview.count > maxLen {
            clipped = String(preview.prefix(maxLen)) + "\n… (truncated)"
        } else {
            clipped = preview
        }

        return "The AI agent wants to:\n\n\(clipped)"
    }

    private static let cautionIcon: NSImage = {
        let image = NSImage(systemSymbolName: "exclamationmark.shield.fill",
                            accessibilityDescription: "Permission required")
            ?? NSImage(named: NSImage.cautionName)
            ?? NSImage()
        _ = image.size
        return image
    }()
}
