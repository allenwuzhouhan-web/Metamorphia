import Foundation
import AppKit
import MetamorphiaAgentKit

/// Open a URL in the default browser.
public struct OpenURLTool: ToolDefinition {
    public let name = "open_url"
    public let description = "Open a URL in the user's default web browser."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "URL to open (must include scheme like https://)"),
        ], required: ["url"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let raw = try requiredString("url", from: args)
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        // `open_url` hands off to NSWorkspace — the user's browser performs the
        // actual request, so SSRF isn't a concern the way it is for the HTTP
        // tools. We still enforce scheme to block `file://` and `javascript:`
        // from being opened without a user gesture.
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw MetamorphiaError.invalidArguments("only http(s) URLs may be opened automatically: \(raw)")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            return "Error: NSWorkspace refused to open \(url.absoluteString) (no handler registered for this URL?)"
        }
        return "Opened \(url.absoluteString)"
    }
}

/// Fetch a URL's HTML and return the body text. Lightweight — for full browser
/// automation use `browser_task` instead (lives in the deferred set).
public struct FetchURLContentTool: ToolDefinition {
    public let name = "fetch_url_content"
    public let description = "Fetch a URL and return its HTML/text content (capped at 64KB). Use for reading articles, docs, or API responses."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "URL to fetch"),
        ], required: ["url"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let raw = try requiredString("url", from: args)
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        let url: URL
        do {
            url = try URLSafetyValidator.validate(candidate)
        } catch let error as URLSafetyValidator.ValidationError {
            return "Error: \(error.localizedDescription)"
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MetamorphiaError.apiError("invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            return "Error: HTTP \(http.statusCode) for \(url.absoluteString)"
        }

        let text = String(data: data, encoding: .utf8) ?? "<binary>"
        let body: String
        if text.count > 64_000 {
            body = String(text.prefix(64_000)) + "\n\n[...truncated, total \(text.count) chars]"
        } else {
            body = text
        }
        return ExternalContentFraming.wrap(body, source: url.absoluteString)
    }
}

/// Quick web search via DuckDuckGo HTML.
public struct SearchWebTool: ToolDefinition {
    public let name = "search_web"
    public let description = "Search the web via DuckDuckGo and return the top results as a list of titles + URLs + snippets. Use to find current information not in your training data."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "query": JSONSchema.string(description: "Search query"),
            "max_results": JSONSchema.integer(description: "Max results (default 5)", minimum: 1, maximum: 20),
        ], required: ["query"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let query = try requiredString("query", from: args)
        let max = optionalInt("max_results", from: args) ?? 5

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)")!

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        // Simple regex extraction of result anchors.
        let pattern = #"<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return "Could not parse search results."
        }
        let range = NSRange(html.startIndex..., in: html)
        var results: [(title: String, url: String)] = []
        regex.enumerateMatches(in: html, options: [], range: range) { match, _, stop in
            guard let m = match,
                  let urlRange = Range(m.range(at: 1), in: html),
                  let titleRange = Range(m.range(at: 2), in: html) else { return }
            let rawTitle = String(html[titleRange])
            let cleanTitle = stripHTML(rawTitle)
            let resolvedURL = unwrapDDG(url: String(html[urlRange]))
            results.append((cleanTitle, resolvedURL))
            if results.count >= max { stop.pointee = true }
        }

        guard !results.isEmpty else {
            return "No results for '\(query)'."
        }

        let body = results.enumerated().map { idx, r in
            "\(idx + 1). **\(r.title)**\n   \(r.url)"
        }.joined(separator: "\n\n")
        return ExternalContentFraming.wrap(body, source: "duckduckgo.com (search: \(query))")
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
         .replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#x27;", with: "'")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DuckDuckGo wraps results in a `/l/?uddg=...` redirect. Unwrap it.
    private func unwrapDDG(url: String) -> String {
        guard url.contains("uddg=") else { return url }
        let parts = url.components(separatedBy: "uddg=")
        guard parts.count > 1 else { return url }
        let encoded = parts[1].components(separatedBy: "&").first ?? parts[1]
        return encoded.removingPercentEncoding ?? url
    }
}
