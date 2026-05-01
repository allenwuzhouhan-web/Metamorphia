import Foundation
import CoreGraphics
import MetamorphiaPerception
import MetamorphiaToolProtocol

/// Argument-aware safety inspector that escalates tool risk tiers when a
/// gesture is about to hit a destructive element or a sensitive form field.
///
/// Wired into `MetamorphiaToolSafetyGate` via `register(inspector:)` at
/// bootstrap time. The gate consults this inspector before looking at the
/// static tier table; any non-nil override wins.
///
/// Logic:
///  - `click_at`, `double_click_at`, `right_click_at`, `long_press` — reverse-
///    look-up the element whose bounds contain the click coordinate, run it
///    through `DangerDetector.classify`. `.dangerous` → `.critical` (forces
///    user prompt), `.caution` → `.elevated`, `.safe` → `nil` (fall through).
///  - `type_text` — check whether the currently focused element is classified
///    as sensitive (password, credit card, SSN, API key) by
///    `SensitiveFieldDetector`. If so, escalate to `.critical` so the user
///    explicitly confirms before the LLM types into it.
///  - Other tools — return `nil`, deferring to the existing static tier table.
///
/// Uses a short-TTL cache so a burst of clicks doesn't thrash the full
/// perception pipeline; each inspection re-uses the last ScreenMap if it is
/// less than 1s old.
public final class PerceptionSafetyInspector: ToolArgumentSafetyInspector, @unchecked Sendable {

    private let perception: DefaultComputerPerception
    private let mapCache: ScreenMapCache

    public init(perception: DefaultComputerPerception = .shared) {
        self.perception = perception
        self.mapCache = ScreenMapCache(ttl: 1.0)
    }

    public func inspect(toolName: String, arguments: String) async -> ToolRiskTier? {
        guard let args = Self.parseJSON(arguments) else { return nil }

        switch toolName {
        case "click_at", "double_click_at", "right_click_at", "long_press":
            return await inspectPointGesture(args: args)
        case "type_text":
            return await inspectTextInput()
        default:
            return nil
        }
    }

    // MARK: - Click inspection

    private func inspectPointGesture(args: [String: Any]) async -> ToolRiskTier? {
        guard let x = Self.readDouble(args["x"]), let y = Self.readDouble(args["y"]) else {
            return nil
        }
        let map = await mapCache.current(perception: perception)

        // Find the smallest interactive element whose bounds contain the point —
        // "smallest" wins because leaf buttons nest inside group containers.
        let point = CGPoint(x: x, y: y)
        let hit = map.elements
            .filter { ($0.bounds?.contains(point) ?? false) && $0.role.isInteractive }
            .min(by: { ($0.bounds?.area ?? .greatestFiniteMagnitude) < ($1.bounds?.area ?? .greatestFiniteMagnitude) })
        guard let hit else { return nil }

        let ctx = DangerDetector.ScanContext(
            appBundleID: map.focusedApp.bundleID,
            windowTitle: map.windows.first(where: { $0.isFocused })?.title ?? ""
        )
        let result = DangerDetector.classify(element: hit, context: ctx)
        switch result.level {
        case .dangerous: return .critical
        case .caution: return .elevated
        case .safe: return nil
        }
    }

    // MARK: - Text-input inspection

    private func inspectTextInput() async -> ToolRiskTier? {
        let map = await mapCache.current(perception: perception)
        guard let focused = map.elements.first(where: { $0.state.contains(.focused) }) else {
            return nil
        }
        if SensitiveFieldDetector.classify(element: focused, allElements: map.elements) != nil {
            return .critical
        }
        return nil
    }

    // MARK: - Helpers

    private static func parseJSON(_ arguments: String) -> [String: Any]? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readDouble(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

/// Short-TTL cache for `ScreenMap` lookups by the safety inspector. Using an
/// actor keeps the double-checked capture path race-free without blocking the
/// caller longer than the underlying `capture()` itself.
private actor ScreenMapCache {
    private var cached: ScreenMap?
    private var capturedAt: Date = .distantPast
    private let ttl: TimeInterval

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func current(perception: DefaultComputerPerception) async -> ScreenMap {
        if let cached, Date().timeIntervalSince(capturedAt) < ttl {
            return cached
        }
        let fresh = await perception.capture(forceOCR: false, appFilter: nil)
        cached = fresh
        capturedAt = Date()
        return fresh
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
