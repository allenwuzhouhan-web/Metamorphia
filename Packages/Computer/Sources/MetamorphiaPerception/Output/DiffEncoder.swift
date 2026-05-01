import Foundation

/// Encodes screen diffs (what changed since last snapshot) for watch mode and SSE streams.
public enum DiffEncoder {

    /// Encode a ScreenDiff as compact JSON.
    public static func encode(_ diff: ChangeDetector.ScreenDiff) -> String {
        var json: [String: Any] = [
            "type": "diff",
            "ts": ISO8601DateFormatter().string(from: Date()),
            "changed": !diff.isEmpty,
        ]

        if diff.appSwitched {
            json["app_switch"] = [
                "from": diff.previousApp ?? "",
                "to": diff.currentApp ?? ""
            ]
        }

        if !diff.added.isEmpty {
            json["added"] = diff.added.map { encodeElement($0) }
        }

        if !diff.removed.isEmpty {
            json["removed"] = diff.removed.map { ["ref": $0.ref.description, "lbl": $0.label] }
        }

        if !diff.changed.isEmpty {
            json["changed_elements"] = diff.changed.map { change -> [String: Any] in
                [
                    "ref": change.ref.description,
                    "field": change.field,
                    "old": change.oldValue,
                    "new": change.newValue
                ]
            }
        }

        json["summary"] = diff.summary

        return serializeJSON(json)
    }

    /// Encode as a Server-Sent Event (SSE) formatted string.
    public static func encodeSSE(_ diff: ChangeDetector.ScreenDiff) -> String {
        let eventType: String
        if diff.appSwitched {
            eventType = "focus"
        } else if diff.isEmpty {
            eventType = "heartbeat"
        } else {
            eventType = "diff"
        }

        let data = encode(diff)
        return "event: \(eventType)\ndata: \(data)\n\n"
    }

    /// Encode a full snapshot as an SSE event (sent on initial connection or major changes).
    public static func encodeFullSnapshotSSE(_ map: ScreenMap) -> String {
        let data = SnapshotEncoder.encode(map)
        return "event: snapshot\ndata: \(data)\n\n"
    }

    /// Encode a safety alert as an SSE event.
    public static func encodeSafetyAlertSSE(ref: ElementRef, label: String, dangerLevel: String) -> String {
        let data = serializeJSON([
            "type": "alert",
            "ref": ref.description,
            "label": label,
            "danger": dangerLevel
        ])
        return "event: alert\ndata: \(data)\n\n"
    }

    // MARK: - Helpers

    private static func encodeElement(_ el: ScreenElement) -> [String: Any] {
        var e: [String: Any] = [
            "ref": el.ref.description,
            "role": el.role.rawValue,
            "lbl": el.label,
        ]

        if let click = el.clickPoint {
            e["click"] = [Int(click.x), Int(click.y)]
        }

        let stateNames = el.state.names
        if !stateNames.isEmpty {
            e["state"] = stateNames
        }

        if !el.actions.isEmpty {
            e["actions"] = el.actions.map { $0.rawValue }
        }

        return e
    }

    private static func serializeJSON(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }
}
