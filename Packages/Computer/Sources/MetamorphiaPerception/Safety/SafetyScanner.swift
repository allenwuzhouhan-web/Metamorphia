import Foundation

/// Aggregates all safety subsystems (danger detection, sensitive fields) into a unified SafetyReport.
public enum SafetyScanner {

    /// Run all safety checks on a set of elements and produce a SafetyReport.
    public static func scan(elements: [ScreenElement], appBundleID: String?, windowTitle: String) -> SafetyReport {
        scanWithSensitiveResults(elements: elements, appBundleID: appBundleID, windowTitle: windowTitle).report
    }

    /// Same as `scan`, but also surfaces the sensitive-field results computed
    /// during the pass so callers that need to redact values can reuse them
    /// instead of running a second full `SensitiveFieldDetector.scan`.
    public static func scanWithSensitiveResults(
        elements: [ScreenElement],
        appBundleID: String?,
        windowTitle: String
    ) -> (report: SafetyReport, sensitiveResults: [SensitiveFieldDetector.SensitiveResult]) {
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

        let report = SafetyReport(
            dangers: dangerRefs,
            sensitive: sensitiveRefs,
            driftDetected: false // Phase 3 will add drift detection
        )
        return (report, sensitiveResults)
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
                    displayIndex: el.displayIndex
                )
            }
        }
    }
}
