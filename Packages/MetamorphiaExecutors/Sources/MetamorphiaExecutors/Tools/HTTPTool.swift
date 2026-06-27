import Foundation
import MetamorphiaAgentKit

/// Structured HTTP client. Spares the agent from building curl one-liners
/// (which get fragile with JSON bodies, quoting, and auth headers).
///
/// Returns a text block with:
///   - status line
///   - response headers (one per line)
///   - body (truncated at `max_response_bytes`)
public struct HTTPRequestTool: ToolDefinition {
    public let name = "http_request"
    public let description = "Make an HTTP request. Supports method, headers, query params, JSON or raw body, and follow-redirects. Returns status + headers + body. Prefer this over curl for non-trivial requests."

    public var parameters: [String: Any] {
        JSONSchema.object(properties: [
            "url": JSONSchema.string(description: "Full URL including scheme (https://...)."),
            "method": JSONSchema.enumString(description: "HTTP method (default GET).", values: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]),
            "headers": JSONSchema.object(properties: [:]),
            "json_body": JSONSchema.object(properties: [:]),
            "body": JSONSchema.string(description: "Raw body string. Mutually exclusive with json_body."),
            "timeout_seconds": JSONSchema.integer(description: "Request timeout (default 30).", minimum: 1, maximum: 600),
            "max_response_bytes": JSONSchema.integer(description: "Truncate body after N bytes (default 256 KiB).", minimum: 512),
            "follow_redirects": JSONSchema.boolean(description: "Default true."),
        ], required: ["url"])
    }

    public init() {}

    public func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let urlString = try requiredString("url", from: args)
        let url: URL
        do {
            url = try URLSafetyValidator.validate(urlString)
        } catch let error as URLSafetyValidator.ValidationError {
            return "Error: \(error.localizedDescription)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        let method = (args["method"] as? String ?? "GET").uppercased()
        let timeout = TimeInterval(optionalInt("timeout_seconds", from: args) ?? 30)
        let maxBytes = optionalInt("max_response_bytes", from: args) ?? (256 * 1024)
        let followRedirects = optionalBool("follow_redirects", from: args) ?? true

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method

        if let headers = args["headers"] as? [String: Any] {
            for (k, v) in headers {
                request.setValue(String(describing: v), forHTTPHeaderField: k)
            }
        }

        if let json = args["json_body"] {
            let data = try JSONSerialization.data(withJSONObject: json, options: [])
            request.httpBody = data
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        } else if let body = args["body"] as? String {
            request.httpBody = body.data(using: .utf8)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(
            configuration: config,
            delegate: followRedirects ? nil : NoRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return "Error: non-HTTP response."
        }

        var out = "HTTP \(http.statusCode)\n"
        let headerPairs = http.allHeaderFields
            .compactMap { (k, v) -> String? in
                guard let key = k as? String else { return nil }
                return "\(key): \(v)"
            }
            .sorted()
        for line in headerPairs { out += line + "\n" }
        out += "\n"

        if data.count > maxBytes {
            let truncated = data.prefix(maxBytes)
            let str = String(data: truncated, encoding: .utf8) ?? "<non-UTF-8, \(data.count) bytes>"
            out += str + "\n\n… truncated (\(data.count - maxBytes) more bytes)"
        } else if let str = String(data: data, encoding: .utf8) {
            out += str
        } else {
            out += "<non-UTF-8 body, \(data.count) bytes>"
        }
        return out
    }
}

/// URLSession delegate that refuses to follow redirects.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
