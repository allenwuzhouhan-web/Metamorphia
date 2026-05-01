import Foundation

/// Archives agent conversation turns (user queries + assistant replies) into
/// Retrace. The host app calls us after every turn completes.
public struct AgentTurnArchive: Sendable {

    public let ingest: RetraceIngest

    public init(ingest: RetraceIngest) {
        self.ingest = ingest
    }

    public enum TurnKind: String, Sendable {
        case user
        case assistant
    }

    @discardableResult
    public func record(
        sessionID: UUID,
        turnKind: TurnKind,
        text: String,
        at: Date = Date()
    ) async -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // User turns are mostly "what I wanted" — high-signal for recall.
        // Assistant turns are lower-signal (often paraphrase of the source),
        // so we de-emphasize them via lower interest potentiation.
        let (event, scale): (InterestEvent, Double) = turnKind == .user
            ? (.queryMention, 0.5)
            : (.toolCallSubject, 0.15)

        let title: String = {
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            return String(firstLine.prefix(80))
        }()

        let draft = RetraceIngest.Draft(
            kind: .agentTurn,
            timestamp: at,
            sessionID: sessionID,
            title: title,
            body: trimmed,
            confidence: 1.0,
            sourceMeta: ["turnKind": turnKind.rawValue],
            interestEvent: event,
            interestScale: scale
        )
        return await ingest.ingest(draft)
    }
}
