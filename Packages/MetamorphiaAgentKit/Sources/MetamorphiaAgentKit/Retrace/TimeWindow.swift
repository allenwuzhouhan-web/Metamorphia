import Foundation

/// A bounded time range extracted from a natural-language query. Each window
/// carries a confidence and (optionally) the anchor that produced it, so the
/// UI can render a human "why" sentence.
public struct TimeWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let confidence: Double
    public let sourcePhrase: String
    public let anchor: Anchor?

    public var center: Date {
        Date(timeIntervalSince1970: (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2)
    }

    public var span: TimeInterval { end.timeIntervalSince(start) }

    public init(start: Date, end: Date, confidence: Double, sourcePhrase: String, anchor: Anchor? = nil) {
        self.start = start
        self.end = end
        self.confidence = confidence
        self.sourcePhrase = sourcePhrase
        self.anchor = anchor
    }

    public enum Anchor: Sendable, Equatable {
        case calendarEvent(id: String, title: String)
        case meeting(id: UUID)
        case placeLabel(String)
    }

    /// A short reason string for the UI: "yesterday night", "before 'Alex 1:1'".
    public var reason: String {
        switch anchor {
        case .calendarEvent(_, let title):
            return "\(sourcePhrase) '\(title)'"
        case .meeting:
            return "\(sourcePhrase) (meeting)"
        case .placeLabel(let label):
            return "\(sourcePhrase) '\(label)'"
        case .none:
            return sourcePhrase
        }
    }
}
