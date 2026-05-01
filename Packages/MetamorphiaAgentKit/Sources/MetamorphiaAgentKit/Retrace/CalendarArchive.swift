import Foundation

/// Archives calendar events into Retrace. The host app's `CalendarLens` owns
/// the `EKEventStore` subscription and passes us a plain value to avoid
/// leaking EventKit types into Agent Kit.
public struct CalendarArchive: Sendable {

    public let ingest: RetraceIngest

    public init(ingest: RetraceIngest) {
        self.ingest = ingest
    }

    public struct EventSummary: Sendable {
        public let eventID: String
        public let title: String
        public let notes: String?
        public let start: Date
        public let end: Date
        public let attendees: [String]
        public let calendarTitle: String?
        public let location: String?

        public init(eventID: String, title: String, notes: String?, start: Date, end: Date, attendees: [String], calendarTitle: String?, location: String?) {
            self.eventID = eventID
            self.title = title
            self.notes = notes
            self.start = start
            self.end = end
            self.attendees = attendees
            self.calendarTitle = calendarTitle
            self.location = location
        }
    }

    @discardableResult
    public func record(_ event: EventSummary) async -> Int64? {
        var bodyParts: [String] = []
        if let notes = event.notes, !notes.isEmpty { bodyParts.append(notes) }
        if !event.attendees.isEmpty { bodyParts.append("Attendees: " + event.attendees.joined(separator: ", ")) }
        if let location = event.location, !location.isEmpty { bodyParts.append("Location: \(location)") }

        let body = bodyParts.joined(separator: "\n")
        let interval = ISO8601DateFormatter.string(from: event.start, timeZone: .current, formatOptions: [.withInternetDateTime])
            + "/" + ISO8601DateFormatter.string(from: event.end, timeZone: .current, formatOptions: [.withInternetDateTime])

        let draft = RetraceIngest.Draft(
            kind: .calendar,
            timestamp: event.start,
            title: event.title,
            body: body.isEmpty ? event.title : body,
            confidence: 1.0,
            sourceMeta: [
                "eventID": event.eventID,
                "interval": interval,
                "calendarTitle": event.calendarTitle ?? "",
            ],
            interestEvent: .longDwell,
            interestScale: 0.25
        )
        return await ingest.ingest(draft)
    }
}
