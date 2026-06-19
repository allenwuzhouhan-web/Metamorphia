import Foundation

/// Aggregates all safety subsystems (danger detection, sensitive fields) into a unified SafetyReport.
public enum SafetyScanner {

    /// Run all safety checks on a set of elements and produce a SafetyReport.
    public static func scan(elements: [ScreenElement], appBundleID: String?, windowTitle: String) -> SafetyReport {
        // Danger detection
        let dangerContext = DangerDetector.ScanContext(
            appBundleID: appBundleID,
            windowTitle: windowTitle
        )
        let dangerResults = DangerDetector.scan(elements: elements, context: dangerContext)
        let dangerRefs = dangerResults
            .filter { $0.level >= .dangerous }
            .map { $0.ref }

        // Sensitive field detection
        let sensitiveResults = SensitiveFieldDetector.scan(elements: elements)
        let sensitiveRefs = sensitiveResults.map { $0.ref }

        return SafetyReport(
            dangers: dangerRefs,
            sensitive: sensitiveRefs,
            driftDetected: false // Phase 3 will add drift detection
        )
    }

    /// Redact sensitive values in elements based on scan results.
    public static func redactSensitiveValues(elements: inout [ScreenElement], sensitiveResults: [SensitiveFieldDetector.SensitiveResult]) {
        let sensitiveByRef = Dictionary(
            sensitiveResults.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for i in 0..<elements.count {
            if let result = sensitiveByRef[elements[i].ref] {
                let redacted = SensitiveFieldDetector.redact(elements[i].value, type: result.type)
                let el = elements[i]
                elements[i] = ScreenElement(
                    ref: el.ref, role: el.role, subrole: el.subrole,
                    label: el.label, value: redacted,
                    bounds: el.bounds, clickPoint: el.clickPoint,
                    state: el.state.union(.password), actions: el.actions,
                    parentRef: el.parentRef, depth: el.depth,
                    source: el.source, confidence: el.confidence,
                    appBundleID: el.appBundleID, windowIndex: el.windowIndex,
                    displayIndex: el.displayIndex,
                    // Preserve DOM addressing — only the value is redacted, so a
                    // browser element keeps its CDP/querySelector execution path.
                    domSelector: el.domSelector, domNodeId: el.domNodeId
                )
            }
        }
    }
}
