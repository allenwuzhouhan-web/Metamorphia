import Foundation
import ApplicationServices
import AppKit

/// Detects temporal UI states: progress bars, loading spinners, busy indicators, animations.
public enum TemporalState {

    // MARK: - Temporal Info

    /// Summary of temporal states on screen.
    public struct TemporalInfo: Sendable {
        public let progressIndicators: [ProgressInfo]
        public let isBusy: Bool
        public let busyApp: String?
        public let shouldWait: Bool
        public let summary: String?

        public init(
            progressIndicators: [ProgressInfo],
            isBusy: Bool,
            busyApp: String?,
            shouldWait: Bool,
            summary: String?
        ) {
            self.progressIndicators = progressIndicators
            self.isBusy = isBusy
            self.busyApp = busyApp
            self.shouldWait = shouldWait
            self.summary = summary
        }
    }

    /// Info about a single progress indicator.
    public struct ProgressInfo: Sendable {
        public let label: String
        public let value: Float?        // 0.0-1.0 for determinate, nil for indeterminate
        public let isIndeterminate: Bool
        public let bounds: CGRect?

        public init(label: String, value: Float?, isIndeterminate: Bool, bounds: CGRect?) {
            self.label = label
            self.value = value
            self.isIndeterminate = isIndeterminate
            self.bounds = bounds
        }

        public var percentString: String? {
            guard let v = value else { return nil }
            return "\(Int(v * 100))%"
        }
    }

    // MARK: - Detection

    /// Detect temporal states from the frontmost app's AX tree.
    public static func detect() -> TemporalInfo {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return TemporalInfo(progressIndicators: [], isBusy: false, busyApp: nil, shouldWait: false, summary: nil)
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        guard let window = AXAttributes.getFocusedWindow(appElement) else {
            return TemporalInfo(progressIndicators: [], isBusy: false, busyApp: nil, shouldWait: false, summary: nil)
        }

        // Check app-level busy indicator
        let appBusy = AXAttributes.getBool(appElement, "AXBusy") ?? false

        // Find progress indicators
        var progressInfos: [ProgressInfo] = []
        findProgressIndicators(element: window, depth: 0, maxDepth: 8, results: &progressInfos)

        // Check for spinning wheels / beach balls via busy state
        let isBusy = appBusy || progressInfos.contains(where: { $0.isIndeterminate })

        // Should the agent wait before acting?
        let shouldWait = isBusy || progressInfos.contains(where: { ($0.value ?? 0) < 0.95 })

        // Build summary
        let summary = buildSummary(
            progressInfos: progressInfos,
            isBusy: isBusy,
            appName: frontApp.localizedName ?? "Unknown"
        )

        return TemporalInfo(
            progressIndicators: progressInfos,
            isBusy: isBusy,
            busyApp: isBusy ? frontApp.localizedName : nil,
            shouldWait: shouldWait,
            summary: summary
        )
    }

    /// Annotate elements in a ScreenMap with loading state.
    public static func annotateLoadingState(elements: inout [ScreenElement], info: TemporalInfo) {
        guard !info.progressIndicators.isEmpty else { return }

        // Find elements that correspond to progress indicators and add .loading state
        for i in 0..<elements.count {
            if elements[i].role == .progressIndicator {
                let el = elements[i]
                var newState = el.state
                newState.insert(.loading)
                elements[i] = ScreenElement(
                    ref: el.ref, role: el.role, subrole: el.subrole,
                    label: el.label, value: el.value,
                    bounds: el.bounds, clickPoint: el.clickPoint,
                    state: newState, actions: el.actions,
                    parentRef: el.parentRef, depth: el.depth,
                    source: el.source, confidence: el.confidence,
                    appBundleID: el.appBundleID, windowIndex: el.windowIndex,
                    displayIndex: el.displayIndex
                )
            }
        }
    }

    // MARK: - Progress Indicator Discovery

    private static func findProgressIndicators(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        results: inout [ProgressInfo]
    ) {
        guard depth < maxDepth, results.count < 10 else { return }

        let role = AXAttributes.getRole(element) ?? ""

        if role == "AXProgressIndicator" {
            let label = AXAttributes.bestLabel(element)
            let valueStr = AXAttributes.getValue(element) ?? ""
            let position = AXAttributes.getPosition(element)
            let size = AXAttributes.getSize(element)

            let bounds: CGRect?
            if let pos = position, let sz = size {
                bounds = CGRect(origin: pos, size: sz)
            } else {
                bounds = nil
            }

            // Parse value — AX progress indicators report value as a number 0-100 or 0-1
            var value: Float? = nil
            var isIndeterminate = true

            if let floatVal = Float(valueStr) {
                if floatVal > 1.0 {
                    value = floatVal / 100.0  // Normalize 0-100 to 0-1
                } else {
                    value = floatVal
                }
                isIndeterminate = false
            }

            // Check for indeterminate attribute
            if let indet = AXAttributes.getBool(element, "AXIndeterminate"), indet {
                isIndeterminate = true
                value = nil
            }

            results.append(ProgressInfo(
                label: label.isEmpty ? "Loading" : label,
                value: value,
                isIndeterminate: isIndeterminate,
                bounds: bounds
            ))
        }

        // Also detect AXBusyIndicator role (used by some apps for spinners)
        if role == "AXBusyIndicator" {
            let label = AXAttributes.bestLabel(element)
            let position = AXAttributes.getPosition(element)
            let size = AXAttributes.getSize(element)
            let bounds: CGRect?
            if let pos = position, let sz = size {
                bounds = CGRect(origin: pos, size: sz)
            } else {
                bounds = nil
            }

            results.append(ProgressInfo(
                label: label.isEmpty ? "Loading..." : label,
                value: nil,
                isIndeterminate: true,
                bounds: bounds
            ))
        }

        guard let children = AXAttributes.getChildren(element) else { return }
        for child in children {
            findProgressIndicators(element: child, depth: depth + 1, maxDepth: maxDepth, results: &results)
        }
    }

    // MARK: - Summary

    private static func buildSummary(progressInfos: [ProgressInfo], isBusy: Bool, appName: String) -> String? {
        if progressInfos.isEmpty && !isBusy { return nil }

        var parts: [String] = []

        if isBusy {
            parts.append("\(appName) is busy")
        }

        for progress in progressInfos {
            if let pct = progress.percentString {
                parts.append("\(progress.label): \(pct)")
            } else if progress.isIndeterminate {
                parts.append("\(progress.label): loading...")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
