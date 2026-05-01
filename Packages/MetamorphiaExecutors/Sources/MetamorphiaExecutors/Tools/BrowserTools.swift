import Foundation
import AppKit
import MetamorphiaAgentKit
import MetamorphiaPerception

// MARK: - BrowserDOMCaptureTool

/// Grab the full DOM of the frontmost browser tab (Safari, Chrome, Edge, Arc,
/// Brave, Vivaldi, Chromium).
///
/// For Safari this uses AppleScript (`do JavaScript "document.documentElement.outerHTML"`)
/// and will trigger a one-time Automation permission prompt on first invocation.
/// For Chrome-family browsers it uses the Chrome DevTools Protocol on
/// `localhost:9222`; the browser must have been launched with
/// `--remote-debugging-port=9222`.
///
/// The capture never leaves the machine — Metamorphia consumes it locally.
/// Callers that pass `include_html: true` receive the full outer HTML; by
/// default only the url/title/byte-count triple is returned so a curious
/// LLM doesn't accidentally spill an entire page into its context.
public struct BrowserDOMCaptureTool: ToolDefinition {
    public let name = "browser_dom_capture"
    public let description = "Capture the DOM of the frontmost web browser (Safari, Chrome, Edge, Arc, Brave, Vivaldi, Chromium). Requires the browser to be frontmost. For Chrome-family browsers the Chrome DevTools Protocol must be reachable on localhost:9222 (launch with --remote-debugging-port=9222). Default output is `{url, title, byteCount, source}` as JSON. Pass include_html=true to also include the full outer HTML — intended for local reasoning, not for forwarding to remote APIs."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "include_html": JSONSchema.boolean(
                description: "When true, include the full outer HTML in the output. Default false — the LLM gets url/title/byteCount only."
            ),
        ])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args: [String: Any]
        if arguments.isEmpty || arguments == "{}" {
            args = [:]
        } else {
            args = (try? parseArguments(arguments)) ?? [:]
        }
        let includeHTML = (args["include_html"] as? Bool) ?? false

        // Need an AppInfo to identify which browser is frontmost. The quickest
        // path is a perception capture — the pipeline already tracks this.
        let map = await DefaultComputerPerception.shared.capture(
            forceOCR: false,
            appFilter: nil,
            ocrOverride: .skip
        )

        guard let dom = await BrowserDOMFetcher.shared.fetchIfBrowserFrontmost(map.focusedApp) else {
            let name = map.focusedApp.name
            return "Error: frontmost app '\(name)' is not a supported browser or the DOM could not be read. Supported browsers: Safari, Chrome, Edge, Arc, Brave, Vivaldi, Chromium."
        }

        var payload: [String: Any] = [
            "url": dom.url,
            "title": dom.title,
            "byteCount": dom.html.utf8.count,
            "source": dom.source.rawValue,
            "fetchedAt": ISO8601DateFormatter().string(from: dom.fetchedAt),
        ]
        if includeHTML {
            payload["html"] = dom.html
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "Error: failed to serialize browser DOM capture."
        }
        return json
    }
}
