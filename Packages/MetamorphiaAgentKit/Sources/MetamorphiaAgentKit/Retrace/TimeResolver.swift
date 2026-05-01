import Foundation

/// Resolves temporal language in a user query into one or more
/// ``TimeWindow`` values. Three tiers, tried in order:
///
///   1. `NSDataDetector`    — absolute dates, durations ("2 hours ago").
///   2. Regex + calendrical — "yesterday night", "last friday",
///                            "this morning", "over the weekend", etc.
///   3. Named-anchor        — "before the Alex meeting", "when I was
///                            at the library" — cross-references
///                            calendar / place / meeting context via
///                            the injected `AnchorLookup`.
///
/// Any remainder that none of the tiers matched is returned in `remainder`
/// so the caller can feed it into the text/semantic search.
public struct TimeResolver: Sendable {

    /// External lookups provided by the host app (CalendarLens, PlaceLabelStore,
    /// MeetingDetector). The resolver does not own these — they're injected.
    public struct AnchorLookup: Sendable {
        public var calendarEventTitled: @Sendable (_ query: String, _ within: ClosedRange<Date>) async -> [CalendarMatch]
        public var placeLabelStretches: @Sendable (_ labelQuery: String, _ within: ClosedRange<Date>) async -> [PlaceStretch]
        public var meetingByTitle: @Sendable (_ titleQuery: String, _ within: ClosedRange<Date>) async -> [MeetingMatch]

        public init(
            calendarEventTitled: @escaping @Sendable (String, ClosedRange<Date>) async -> [CalendarMatch],
            placeLabelStretches: @escaping @Sendable (String, ClosedRange<Date>) async -> [PlaceStretch],
            meetingByTitle: @escaping @Sendable (String, ClosedRange<Date>) async -> [MeetingMatch]
        ) {
            self.calendarEventTitled = calendarEventTitled
            self.placeLabelStretches = placeLabelStretches
            self.meetingByTitle = meetingByTitle
        }

        public static let empty = AnchorLookup(
            calendarEventTitled: { _, _ in [] },
            placeLabelStretches: { _, _ in [] },
            meetingByTitle: { _, _ in [] }
        )
    }

    public struct CalendarMatch: Sendable {
        public let id: String
        public let title: String
        public let start: Date
        public let end: Date
        public let similarity: Double
        public init(id: String, title: String, start: Date, end: Date, similarity: Double) {
            self.id = id; self.title = title; self.start = start; self.end = end; self.similarity = similarity
        }
    }

    public struct PlaceStretch: Sendable {
        public let label: String
        public let start: Date
        public let end: Date
        public init(label: String, start: Date, end: Date) {
            self.label = label; self.start = start; self.end = end
        }
    }

    public struct MeetingMatch: Sendable {
        public let id: UUID
        public let title: String
        public let start: Date
        public let end: Date
        public init(id: UUID, title: String, start: Date, end: Date) {
            self.id = id; self.title = title; self.start = start; self.end = end
        }
    }

    public struct Resolution: Sendable {
        public let windows: [TimeWindow]
        public let remainder: String
        public init(windows: [TimeWindow], remainder: String) {
            self.windows = windows; self.remainder = remainder
        }
    }

    public let anchorLookup: AnchorLookup
    public let calendar: Calendar

    public init(anchorLookup: AnchorLookup = .empty, calendar: Calendar = .current) {
        self.anchorLookup = anchorLookup
        var c = calendar
        c.timeZone = .current
        self.calendar = c
    }

    // MARK: - Main entry

    public func resolve(_ query: String, now: Date = Date()) async -> Resolution {
        var remainder = query
        var windows: [TimeWindow] = []

        // Tier 1 — NSDataDetector
        let (t1, afterT1) = tier1NSDataDetector(remainder, now: now)
        windows.append(contentsOf: t1)
        remainder = afterT1

        // Tier 2 — regex + calendrical
        let (t2, afterT2) = tier2Calendrical(remainder, now: now)
        windows.append(contentsOf: t2)
        remainder = afterT2

        // Tier 3 — named anchors (async, uses injected lookups)
        let (t3, afterT3) = await tier3NamedAnchors(remainder, now: now)
        windows.append(contentsOf: t3)
        remainder = afterT3

        return Resolution(windows: windows, remainder: remainder.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Tier 1: NSDataDetector

    private func tier1NSDataDetector(_ input: String, now: Date) -> ([TimeWindow], String) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return ([], input)
        }
        let range = NSRange(location: 0, length: input.utf16.count)
        var windows: [TimeWindow] = []
        var cutouts: [NSRange] = []
        detector.enumerateMatches(in: input, options: [], range: range) { result, _, _ in
            guard let result = result else { return }
            if let date = result.date {
                let duration = result.duration
                let start: Date
                let end: Date
                if duration > 0 {
                    start = date
                    end = date.addingTimeInterval(duration)
                } else {
                    // Point-in-time: bucket to the day if no time-of-day
                    // appears in the matched substring, else ±1 hour.
                    let substr = (input as NSString).substring(with: result.range)
                    let hasTime = substr.range(of: #":|am|pm|noon|midnight"#, options: .regularExpression) != nil
                    if hasTime {
                        start = date.addingTimeInterval(-1800)
                        end = date.addingTimeInterval(1800)
                    } else {
                        let day = calendar.startOfDay(for: date)
                        start = day
                        end = calendar.date(byAdding: .day, value: 1, to: day).map { $0.addingTimeInterval(-1) } ?? day
                    }
                }
                let phrase = (input as NSString).substring(with: result.range)
                windows.append(TimeWindow(start: start, end: end, confidence: 0.9, sourcePhrase: phrase))
                cutouts.append(result.range)
            }
        }
        let remainder = removeRanges(from: input, ranges: cutouts)
        return (windows, remainder)
    }

    // MARK: - Tier 2: regex + calendrical

    /// Ordered list of `(regex, builder)` pairs. Earlier patterns win.
    private static let calendricalPatterns: [(NSRegularExpression, @Sendable (NSTextCheckingResult, String, Date, Calendar) -> TimeWindow?)] = {
        func re(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }

        return [
            // yesterday night / yesterday evening / yesterday afternoon / yesterday morning
            (re(#"\byesterday\s+(morning|afternoon|evening|night)\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let partRange = m.range(at: 1)
                let part = (src as NSString).substring(with: partRange).lowercased()
                let prev = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
                return window(for: part, on: prev, now: now, cal: cal, phrase: phrase, confidence: 0.95)
            }),
            // tonight
            (re(#"\btonight\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let today = cal.startOfDay(for: now)
                let start = cal.date(bySettingHour: 21, minute: 0, second: 0, of: today) ?? today
                let end = cal.date(byAdding: .hour, value: 5, to: start) ?? start
                return TimeWindow(start: start, end: end, confidence: 0.95, sourcePhrase: phrase)
            }),
            // this morning / this afternoon / this evening
            (re(#"\bthis\s+(morning|afternoon|evening)\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let partRange = m.range(at: 1)
                let part = (src as NSString).substring(with: partRange).lowercased()
                let today = cal.startOfDay(for: now)
                return window(for: part, on: today, now: now, cal: cal, phrase: phrase, confidence: 0.95)
            }),
            // last night
            (re(#"\blast\s+night\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let prev = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
                return window(for: "night", on: prev, now: now, cal: cal, phrase: phrase, confidence: 0.95)
            }),
            // yesterday (plain)
            (re(#"\byesterday\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let prev = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
                let end = cal.date(byAdding: .day, value: 1, to: prev).map { $0.addingTimeInterval(-1) } ?? prev
                return TimeWindow(start: prev, end: end, confidence: 0.95, sourcePhrase: phrase)
            }),
            // today (plain)
            (re(#"\btoday\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let today = cal.startOfDay(for: now)
                return TimeWindow(start: today, end: now, confidence: 0.9, sourcePhrase: phrase)
            }),
            // earlier today
            (re(#"\bearlier\s+today\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let today = cal.startOfDay(for: now)
                return TimeWindow(start: today, end: now.addingTimeInterval(-1800), confidence: 0.8, sourcePhrase: phrase)
            }),
            // just now / right now
            (re(#"\b(?:just\s+now|right\s+now)\b"#), { m, src, now, _ in
                let phrase = (src as NSString).substring(with: m.range)
                return TimeWindow(start: now.addingTimeInterval(-300), end: now, confidence: 0.7, sourcePhrase: phrase)
            }),
            // a few minutes ago
            (re(#"\ba\s+few\s+minutes?\s+ago\b"#), { m, src, now, _ in
                let phrase = (src as NSString).substring(with: m.range)
                return TimeWindow(start: now.addingTimeInterval(-900), end: now, confidence: 0.6, sourcePhrase: phrase)
            }),
            // over the weekend / last weekend
            (re(#"\b(?:over\s+the\s+weekend|last\s+weekend|this\s+weekend)\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let weekday = cal.component(.weekday, from: now)
                let daysBackToSat = (weekday + 1) % 7  // Sat=7 in Cocoa; normalize
                let satStart: Date
                if phrase.lowercased().contains("this") {
                    // this weekend: most recent Sat OR upcoming Sat if today < Sat
                    let diffToSat = 7 - weekday
                    satStart = cal.date(byAdding: .day, value: diffToSat, to: cal.startOfDay(for: now)) ?? now
                } else {
                    satStart = cal.date(byAdding: .day, value: -daysBackToSat, to: cal.startOfDay(for: now)) ?? now
                }
                let sunEnd = cal.date(byAdding: .day, value: 2, to: satStart).map { $0.addingTimeInterval(-1) } ?? satStart
                return TimeWindow(start: satStart, end: sunEnd, confidence: 0.85, sourcePhrase: phrase)
            }),
            // last (Mon..Sun)
            (re(#"\blast\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let dayRange = m.range(at: 1)
                let dayName = (src as NSString).substring(with: dayRange).lowercased()
                let target = weekdayNumber(from: dayName)
                let weekday = cal.component(.weekday, from: now)
                var delta = weekday - target
                if delta <= 0 { delta += 7 }
                let dayStart = cal.date(byAdding: .day, value: -delta, to: cal.startOfDay(for: now)) ?? now
                let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart).map { $0.addingTimeInterval(-1) } ?? dayStart
                return TimeWindow(start: dayStart, end: dayEnd, confidence: 0.9, sourcePhrase: phrase)
            }),
            // last week
            (re(#"\blast\s+week\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                var monday = cal.startOfDay(for: now)
                while cal.component(.weekday, from: monday) != 2 { // Mon == 2
                    guard let prior = cal.date(byAdding: .day, value: -1, to: monday) else { break }
                    monday = prior
                }
                let lastMonday = cal.date(byAdding: .day, value: -7, to: monday) ?? monday
                let lastSunEnd = cal.date(byAdding: .day, value: 7, to: lastMonday).map { $0.addingTimeInterval(-1) } ?? lastMonday
                return TimeWindow(start: lastMonday, end: lastSunEnd, confidence: 0.9, sourcePhrase: phrase)
            }),
            // last month
            (re(#"\blast\s+month\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let comps = cal.dateComponents([.year, .month], from: now)
                guard let firstOfThis = cal.date(from: comps),
                      let firstOfLast = cal.date(byAdding: .month, value: -1, to: firstOfThis),
                      let endOfLast = cal.date(byAdding: .day, value: -1, to: firstOfThis) else {
                    return nil
                }
                return TimeWindow(start: firstOfLast, end: endOfLast.addingTimeInterval(86400 - 1), confidence: 0.9, sourcePhrase: phrase)
            }),
            // N (hour|day|week|month)s ago
            (re(#"\b(\d+)\s+(hour|day|week|month)s?\s+ago\b"#), { m, src, now, cal in
                let phrase = (src as NSString).substring(with: m.range)
                let n = Int((src as NSString).substring(with: m.range(at: 1))) ?? 0
                let unit = (src as NSString).substring(with: m.range(at: 2)).lowercased()
                let component: Calendar.Component = {
                    switch unit {
                    case "hour": return .hour
                    case "day": return .day
                    case "week": return .weekOfYear
                    case "month": return .month
                    default: return .day
                    }
                }()
                guard let start = cal.date(byAdding: component, value: -n, to: now) else { return nil }
                // Width scales with granularity.
                let width: TimeInterval = {
                    switch component {
                    case .hour: return 1800
                    case .day: return 43200
                    case .weekOfYear: return 86400 * 2
                    case .month: return 86400 * 5
                    default: return 3600
                    }
                }()
                return TimeWindow(start: start.addingTimeInterval(-width), end: start.addingTimeInterval(width), confidence: 0.85, sourcePhrase: phrase)
            }),
        ]
    }()

    private func tier2Calendrical(_ input: String, now: Date) -> ([TimeWindow], String) {
        var windows: [TimeWindow] = []
        var cutouts: [NSRange] = []
        for (regex, builder) in Self.calendricalPatterns {
            let matches = regex.matches(in: input, range: NSRange(location: 0, length: input.utf16.count))
            for m in matches {
                // Skip if the range was already consumed by an earlier pattern.
                if cutouts.contains(where: { $0.intersection(m.range) != nil }) { continue }
                if let w = builder(m, input, now, calendar) {
                    windows.append(w)
                    cutouts.append(m.range)
                }
            }
        }
        let remainder = removeRanges(from: input, ranges: cutouts)
        return (windows, remainder)
    }

    // MARK: - Tier 3: named anchors

    private static let anchorRelationRegex = try! NSRegularExpression(
        pattern: #"\b(before|after|during|around)\s+(the\s+)?([A-Za-z][A-Za-z0-9._ ]{1,40}?)\s+(meeting|call|standup|chat|sync|1:1|interview|appointment)\b"#,
        options: [.caseInsensitive]
    )

    private static let placeRegex = try! NSRegularExpression(
        pattern: #"\b(?:when|while)\s+(?:i\s+was|i'?m|im)\s+(?:at|in)\s+(?:the\s+)?([A-Za-z][A-Za-z0-9 ]{1,30})\b"#,
        options: [.caseInsensitive]
    )

    private func tier3NamedAnchors(_ input: String, now: Date) async -> ([TimeWindow], String) {
        var windows: [TimeWindow] = []
        var cutouts: [NSRange] = []

        // Calendar / meeting anchor
        let relMatches = Self.anchorRelationRegex.matches(in: input, range: NSRange(location: 0, length: input.utf16.count))
        for m in relMatches {
            let phrase = (input as NSString).substring(with: m.range)
            let relation = (input as NSString).substring(with: m.range(at: 1)).lowercased()
            let entity = (input as NSString).substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            let scope = (now.addingTimeInterval(-60 * 86400))...(now.addingTimeInterval(7 * 86400))
            let matches = await anchorLookup.calendarEventTitled(entity, scope)
            guard let best = matches.max(by: { $0.similarity < $1.similarity }), best.similarity >= 0.4 else {
                continue
            }
            let (s, e): (Date, Date) = {
                switch relation {
                case "before": return (best.start.addingTimeInterval(-4 * 3600), best.start)
                case "after":  return (best.end, best.end.addingTimeInterval(4 * 3600))
                case "during": return (best.start, best.end)
                default:       return (best.start.addingTimeInterval(-3600), best.end.addingTimeInterval(3600))
                }
            }()
            let conf = min(0.85, 0.5 + best.similarity * 0.4)
            windows.append(TimeWindow(
                start: s, end: e, confidence: conf,
                sourcePhrase: phrase,
                anchor: .calendarEvent(id: best.id, title: best.title)
            ))
            cutouts.append(m.range)
        }

        // Place anchor
        let placeMatches = Self.placeRegex.matches(in: input, range: NSRange(location: 0, length: input.utf16.count))
        for m in placeMatches {
            let phrase = (input as NSString).substring(with: m.range)
            let label = (input as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let scope = (now.addingTimeInterval(-90 * 86400))...now
            let stretches = await anchorLookup.placeLabelStretches(label, scope)
            guard let best = stretches.max(by: { $0.end < $1.end }) else { continue }
            windows.append(TimeWindow(
                start: best.start, end: best.end,
                confidence: 0.7, sourcePhrase: phrase,
                anchor: .placeLabel(best.label)
            ))
            cutouts.append(m.range)
        }

        let remainder = removeRanges(from: input, ranges: cutouts)
        return (windows, remainder)
    }

    // MARK: - Utilities

    private func removeRanges(from input: String, ranges: [NSRange]) -> String {
        guard !ranges.isEmpty else { return input }
        let sorted = ranges.sorted { $0.location < $1.location }
        let ns = input as NSString
        var cursor = 0
        var out = ""
        for r in sorted {
            if r.location >= cursor {
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                cursor = r.location + r.length
            }
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func window(for part: String, on day: Date, now: Date, cal: Calendar, phrase: String, confidence: Double) -> TimeWindow {
        let (startHour, hours): (Int, Int) = {
            switch part {
            case "morning":   return (6, 6)     // 06:00 → 12:00
            case "afternoon": return (12, 6)    // 12:00 → 18:00
            case "evening":   return (18, 4)    // 18:00 → 22:00
            case "night":     return (21, 5)    // 21:00 → 02:00 (next day)
            default:          return (0, 24)
            }
        }()
        let start = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: day) ?? day
        let end = cal.date(byAdding: .hour, value: hours, to: start) ?? start
        return TimeWindow(start: start, end: end, confidence: confidence, sourcePhrase: phrase)
    }

    private static func weekdayNumber(from name: String) -> Int {
        switch name {
        case "sunday":    return 1
        case "monday":    return 2
        case "tuesday":   return 3
        case "wednesday": return 4
        case "thursday":  return 5
        case "friday":    return 6
        case "saturday":  return 7
        default:          return 0
        }
    }
}
