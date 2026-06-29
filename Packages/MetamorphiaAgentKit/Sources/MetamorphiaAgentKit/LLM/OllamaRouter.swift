import Foundation

/// Local model router — talks to a locally-running Ollama instance.
///
/// Used as a cheap first-pass classifier (Qwen2.5-3B or similar) before
/// falling through to the hosted LLM. If Ollama isn't running, all methods
/// return `nil` so the existing pipeline takes over silently.
public final class OllamaRouter: @unchecked Sendable {
    public static let shared = OllamaRouter()

    public struct RoutingResult: Codable, Sendable {
        public let tools: [String]
        public let needsApi: Bool

        enum CodingKeys: String, CodingKey {
            case tools
            case needsApi = "needs_api"
        }

        public init(tools: [String], needsApi: Bool) {
            self.tools = tools
            self.needsApi = needsApi
        }
    }

    public let baseURL: String
    public let routingModel: String
    public let routingTimeout: TimeInterval

    private lazy var routingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = routingTimeout
        config.timeoutIntervalForResource = routingTimeout
        return URLSession(configuration: config)
    }()

    public init(
        baseURL: String = "http://localhost:11434",
        routingModel: String = "qwen2.5:3b",
        routingTimeout: TimeInterval = 0.5
    ) {
        self.baseURL = baseURL
        self.routingModel = routingModel
        self.routingTimeout = routingTimeout
    }

    /// Check if Ollama is reachable.
    public func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (_, response) = try await routingSession.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Generic Ollama completion. Used for per-frame local inference loops where the caller
    /// picks the model and token budget. Zero hosted-API traffic.
    public func complete(
        model: String,
        prompt: String,
        temperature: Double = 0.2,
        maxTokens: Int = 512,
        timeout: TimeInterval = 5.0
    ) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": temperature,
                "num_predict": maxTokens
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        do {
            let (data, response) = try await routingSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["response"] as? String else { return nil }
            return text
        } catch {
            return nil
        }
    }

    /// Route a user request through the local routing model.
    /// Returns nil if Ollama isn't available or parsing fails — the caller falls through.
    public func route(_ userInput: String) async -> RoutingResult? {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = buildRoutingPrompt(userInput)

        let body: [String: Any] = [
            "model": routingModel,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": 100,
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        do {
            let (data, response) = try await routingSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else { return nil }

            return parseRoutingResult(responseText)
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func buildRoutingPrompt(_ input: String) -> String {
        """
        You are a tool router. Given a user request, identify which tools are needed and whether an API call is needed.

        Available tools:
        - app_launcher: opens/quits applications
        - music_controller: play/pause/skip music
        - volume_control: adjust system volume
        - brightness_control: adjust brightness
        - file_manager: read/write/move/find files
        - search_web: search the internet
        - web_navigator: open URLs in browser
        - screenshot: capture screen
        - clipboard: manage clipboard
        - notification: show notifications
        - timer: set timers and reminders
        - calendar: manage calendar events
        - system_settings: dark mode, wifi, bluetooth
        - deepseek_chat: complex reasoning, content generation
        - presentation_creator: make presentations
        - document_creator: make documents

        Recent successful routings:
        - "open Spotify" → {"tools": ["app_launcher"], "needs_api": false}
        - "make me a ppt about history" → {"tools": ["deepseek_chat", "presentation_creator"], "needs_api": true}
        - "what time is it" → {"tools": ["timer"], "needs_api": false}
        - "search for climate change" → {"tools": ["search_web"], "needs_api": false}
        - "help me write an essay" → {"tools": ["deepseek_chat"], "needs_api": true}
        - "set volume to 50" → {"tools": ["volume_control"], "needs_api": false}
        - "take a screenshot" → {"tools": ["screenshot"], "needs_api": false}

        Respond ONLY with JSON. No explanation.
        User request: "\(input)"
        """
    }

    private func parseRoutingResult(_ text: String) -> RoutingResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
           let result = try? JSONDecoder().decode(RoutingResult.self, from: data) {
            return result
        }

        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            let jsonStr = String(trimmed[start...end])
            if let data = jsonStr.data(using: .utf8),
               let result = try? JSONDecoder().decode(RoutingResult.self, from: data) {
                return result
            }
        }

        return nil
    }
}
