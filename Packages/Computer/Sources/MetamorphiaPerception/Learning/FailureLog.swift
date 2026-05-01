import Foundation

/// Records agent failures: what the agent expected vs what actually happened.
/// Stored in the database for analysis and pattern extraction.
public enum FailureLog {

    /// Log a failure from an agent action.
    public static func log(
        expectedMap: ScreenMap?,
        actualMap: ScreenMap,
        elementRef: ElementRef?,
        actionAttempted: String?,
        errorDescription: String,
        workflowID: String? = nil,
        stepIndex: Int? = nil,
        db: ElementDatabase
    ) {
        let expectedJSON: String?
        if let expected = expectedMap {
            expectedJSON = encodeStateSnapshot(expected)
        } else {
            expectedJSON = nil
        }

        let actualJSON = encodeStateSnapshot(actualMap)

        db.logFailure(
            workflowID: workflowID,
            stepIndex: stepIndex,
            expectedStateJSON: expectedJSON,
            actualStateJSON: actualJSON,
            elementRef: elementRef?.description,
            actionAttempted: actionAttempted,
            errorDescription: errorDescription,
            appBundleID: actualMap.focusedApp.bundleID
        )
    }

    /// Get a summary of recent failures for an app.
    public static func summary(appBundleID: String?, db: ElementDatabase) -> String? {
        let failures = db.recentFailures(appBundleID: appBundleID, limit: 10)
        guard !failures.isEmpty else { return nil }

        var lines: [String] = ["## Recent Failures (\(failures.count)):"]
        for f in failures.prefix(5) {
            let ref = f.elementRef ?? "?"
            let action = f.actionAttempted ?? "?"
            let error = f.errorDescription ?? "unknown"
            let time = formatDate(f.timestamp)
            lines.append("- [\(time)] \(ref) \(action): \(error)")
        }
        if failures.count > 5 {
            lines.append("... +\(failures.count - 5) more")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Compact state snapshot for storage.
    private static func encodeStateSnapshot(_ map: ScreenMap) -> String {
        let dict: [String: Any] = [
            "app": map.focusedApp.name,
            "window": map.windows.first(where: { $0.isFocused })?.title ?? "",
            "elements": map.metadata.elementCount,
            "interactive": map.metadata.interactiveCount,
            "hash": String(Snapshot.contentHash(of: map.elements), radix: 16)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
