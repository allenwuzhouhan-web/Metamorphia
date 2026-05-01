import Foundation
import Combine

/// Middleware that feeds agent-loop signals into `InterestGraphStore`.
///
/// Receives entity-extraction notifications (via `NotificationCenter`) and
/// fires after each tool execution to detect entity-bearing tool arguments.
/// Both paths dispatch into the actor-isolated `InterestGraphStore`.
///
/// Notification mapping:
///   - `.userTurn`   → `.queryMention`           (scale 1.0)
///   - `.clipboard`  → `.clipboardCopy`           (scale 1.0)
///   - `.backfill`   → `.queryMention`            (scale 0.5 — half-strength)
///   - `.calendar`   → `.toolCallSubject`         (scale 1.0)
///   - `.news`       → not potentiated (would create feedback loops)
///
/// Tool-call entity extraction currently handles `symbols` and `query` keys
/// in tool arguments (covers `market_data` and `news_feed`).
///
/// When an optional `ActivityStream` is provided, the potentiator also consumes
/// passive browser and focus signals:
///   - `.urlVisited`    → host as `.org` entity   `.queryMention` scale 0.3
///   - `.focusChanged`  → appName as `.org` entity `.queryMention` scale 0.2
public final class InterestGraphPotentiator: AgentMiddleware, @unchecked Sendable {

    public let name = "InterestGraphPotentiator"

    private let store: InterestGraphStore
    private var observer: NSObjectProtocol?
    private var activityCancellable: AnyCancellable?

    public init(store: InterestGraphStore, activityStream: ActivityStream? = nil) {
        self.store = store
        subscribeToNotifications()
        if let activityStream {
            subscribeToActivityStream(activityStream)
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        activityCancellable?.cancel()
    }

    // MARK: - Notification subscription

    private func subscribeToNotifications() {
        observer = NotificationCenter.default.addObserver(
            forName: .continuumEntitiesExtracted,
            object: nil,
            queue: nil    // delivered on the posting queue; we dispatch into actor async
        ) { [weak self] notification in
            guard let self else { return }
            self.handleEntitiesNotification(notification)
        }
    }

    // MARK: - ActivityStream subscription

    private func subscribeToActivityStream(_ activityStream: ActivityStream) {
        activityCancellable = activityStream.events
            .sink { [weak self] event in
                guard let self else { return }
                self.handleActivityEvent(event)
            }
    }

    private func handleActivityEvent(_ event: ActivityEvent) {
        let store = self.store
        switch event {
        // Scale 0.3 is passive-signal weight; bursty same-host visits rely on
        // InterestGraphStore's synaptic decay to absorb the pile-up. If telemetry
        // later shows pathological pile-up, add a per-host debounce here.
        case .urlVisited(_, let host, _, _, _):
            let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty else { return }
            let entity = ExtractedEntity(
                canonicalName: trimmed,
                type: .org,
                surfaceForm: trimmed,
                confidence: 0.7
            )
            Task.detached(priority: .utility) {
                await store.potentiate(entities: [entity], event: .queryMention, scale: 0.3)
            }

        // Skip focus events with redacted titles (denylisted apps like password
        // managers). The presence of a nil title is a strong signal that the app
        // itself is sensitive — don't potentiate the bundleID either.
        case .focusChanged(_, let appName, let windowTitle, _, _):
            guard windowTitle != nil else { return }
            let trimmed = appName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let entity = ExtractedEntity(
                canonicalName: trimmed.lowercased(),
                type: .org,
                surfaceForm: trimmed,
                confidence: 0.6
            )
            Task.detached(priority: .utility) {
                await store.potentiate(entities: [entity], event: .queryMention, scale: 0.2)
            }

        default:
            break
        }
    }

    private func handleEntitiesNotification(_ notification: Notification) {
        guard let entities = notification.continuumEntities,
              !entities.isEmpty,
              let source = notification.continuumSource else { return }

        // .news is explicitly excluded to avoid recommendation-feedback loops.
        guard source != .news else { return }

        let (event, scale): (InterestEvent, Double) = {
            switch source {
            case .userTurn:  return (.queryMention,    1.0)
            case .clipboard: return (.clipboardCopy,   1.0)
            case .backfill:  return (.queryMention,    0.5)
            case .calendar:  return (.toolCallSubject, 1.0)
            case .news:      return (.queryMention,    0.0)  // unreachable — guarded above
            }
        }()

        let store = self.store
        Task.detached(priority: .utility) {
            await store.potentiate(entities: entities, event: event, scale: scale)
        }
    }

    // MARK: - AgentMiddleware hooks

    /// After each tool execution, extract entity-bearing arguments and
    /// potentiate them with `.toolCallSubject`.
    public func afterToolExecution(
        _ ctx: MiddlewareContext,
        toolCalls: [ToolCall],
        results: [ToolResult]
    ) -> MiddlewareSignal {
        let store = self.store
        for call in toolCalls {
            let extracted = Self.extractEntities(from: call)
            guard !extracted.isEmpty else { continue }
            Task.detached(priority: .utility) {
                await store.potentiate(entities: extracted, event: .toolCallSubject)
            }
        }
        return .continue
    }

    // MARK: - Tool argument entity extraction

    /// Best-effort extraction of entity-bearing arguments from common tool shapes.
    /// Handles:
    ///   - `symbols: ["AAPL", "MSFT"]`  → EntityType.ticker
    ///   - `query: "Anthropic"`         → EntityType.topic (then NER from the string)
    ///   - `entity: "OpenAI"`           → EntityType.org
    private static func extractEntities(from call: ToolCall) -> [ExtractedEntity] {
        guard let data = call.function.arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [ExtractedEntity] = []

        // symbols: ["AAPL"]
        if let symbols = json["symbols"] as? [String] {
            for symbol in symbols {
                let clean = symbol.trimmingCharacters(in: .whitespaces).uppercased()
                guard !clean.isEmpty else { continue }
                results.append(ExtractedEntity(
                    canonicalName: clean,
                    type: .ticker,
                    surfaceForm: "$\(clean)",
                    confidence: 0.95
                ))
            }
        }

        // symbol: "AAPL"
        if let symbol = json["symbol"] as? String {
            let clean = symbol.trimmingCharacters(in: .whitespaces).uppercased()
            if !clean.isEmpty {
                results.append(ExtractedEntity(
                    canonicalName: clean,
                    type: .ticker,
                    surfaceForm: "$\(clean)",
                    confidence: 0.95
                ))
            }
        }

        // entity: "Anthropic"
        if let entityName = json["entity"] as? String {
            let clean = entityName.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                results.append(ExtractedEntity(
                    canonicalName: clean.lowercased(),
                    type: .org,
                    surfaceForm: clean,
                    confidence: 0.8
                ))
            }
        }

        // query: "Anthropic research" — use the first word / phrase as a topic
        if let query = json["query"] as? String {
            let clean = query.trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty {
                results.append(ExtractedEntity(
                    canonicalName: clean.lowercased(),
                    type: .topic,
                    surfaceForm: clean,
                    confidence: 0.6
                ))
            }
        }

        return results
    }
}
