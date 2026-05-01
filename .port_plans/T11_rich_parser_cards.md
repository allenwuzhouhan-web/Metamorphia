# T11 — Port Rich Result Parser + Date / Event / List Cards

## Executive summary

Port Executer's text-pattern detection + three cards (`DateResultCard`, `EventResultCard`, `ListResultCard`). Skip NewsResultCard (no NewsAPI) and BrowserTrailCard (no BrowserAgent trail). When the agent's final text matches a known shape — formatted date, `[EVENT:...]` marker, or markdown list — render a compact native card under the result bubble.

**New files:**
1. `/Users/allenwu/claude/metamorphia/Metamorphia/services/RichResultParser.swift` — parser + result structs (`DateResult`, `EventResult`, `ListResult`, `ListItem`).
2. `/Users/allenwu/claude/metamorphia/Metamorphia/components/CommandBar/DateResultCard.swift`
3. `/Users/allenwu/claude/metamorphia/Metamorphia/components/CommandBar/EventResultCard.swift`
4. `/Users/allenwu/claude/metamorphia/Metamorphia/components/CommandBar/ListResultCard.swift`

**Edit:**
1. `/Users/allenwu/claude/metamorphia/Metamorphia/models/MarketModels.swift` — add three cases to `RichTurnContent` (`.dateResult`, `.eventResult`, `.listResult`).
2. `/Users/allenwu/claude/metamorphia/Metamorphia/components/CommandBar/RichTurnContentView.swift` — add three `switch` arms.
3. `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift` — call parser in `.result(text)` handler (display sink).

**Parse order:** event marker → list (≥3 items, ≥50% ratio) → date (<300 chars only).

**Styling:** native Metamorphia idiom (RoundedRectangle, `.white.opacity(0.05)`). No liquidGlass. Cards ~100 lines each. No haptics, no auto-dismiss, no calendar write.

**Guardrails:** never override existing `richContent` (protects the `.functionGraph` pre-seed in `submit`).

---

## 1. File list

See Executive Summary §1-4 above for all absolute paths.

## 2. New data types

In `RichResultParser.swift`:

```swift
public struct DateResult: Hashable, Sendable {
    public let date: Date
    public let formattedDate: String
    public let relativeDescription: String
    public let context: String?
}

public struct EventResult: Hashable, Sendable {
    public let title: String
    public let date: Date
    public let endDate: Date?
    public let location: String?
    public let attendeeCount: Int?
    public let notes: String?
}

public struct ListResult: Hashable, Sendable {
    public let title: String?
    public let items: [ListItem]
}

public struct ListItem: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let detail: String?

    public init(id: UUID = UUID(), text: String, detail: String? = nil) {
        self.id = id
        self.text = text
        self.detail = detail
    }
}
```

## 3. `RichTurnContent` extension

In `models/MarketModels.swift`, add three cases:

```swift
// --- T11: rich text-pattern cards ---
case dateResult(DateResult)
case eventResult(EventResult)
case listResult(ListResult)
```

## 4. Full `RichResultParser.swift`

```swift
import Foundation

public enum RichResultParser {

    public static func parse(_ text: String) -> RichTurnContent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let event = parseEvent(in: trimmed) { return .eventResult(event) }
        if let list  = parseList(in: trimmed)  { return .listResult(list)   }
        if let date  = parseDate(in: trimmed)  { return .dateResult(date)   }
        return nil
    }

    // MARK: - Event marker: [EVENT: title | ISO-date | location?]

    private static let eventPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\[EVENT:\s*(.+?)\s*\|\s*(.+?)\s*(?:\|\s*(.+?))?\s*\]"#,
            options: [.caseInsensitive]
        )
    }()

    public static func parseEvent(in text: String) -> EventResult? {
        guard let regex = eventPattern else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        let title = ns.substring(with: m.range(at: 1))
        let dateStr = ns.substring(with: m.range(at: 2))
        let location: String? = m.range(at: 3).location != NSNotFound
            ? ns.substring(with: m.range(at: 3))
            : nil
        guard let date = parseAnyDate(dateStr) else { return nil }

        let notes = ns.replacingCharacters(in: m.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return EventResult(
            title: title,
            date: date,
            endDate: nil,
            location: location,
            attendeeCount: nil,
            notes: notes.isEmpty ? nil : notes
        )
    }

    // MARK: - Lists

    private static let listMarkerPattern = #"^(?:\d+[\.\)]\s*|-\s*|\*\s*|•\s*)"#

    public static func parseList(in text: String) -> ListResult? {
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard rawLines.count >= 3 else { return nil }
        guard let regex = try? NSRegularExpression(pattern: listMarkerPattern) else { return nil }

        var items: [ListItem] = []
        var title: String?
        var listLineCount = 0

        for (i, line) in rawLines.enumerated() {
            let ns = line as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            if let m = regex.firstMatch(in: line, range: fullRange) {
                let body = ns.substring(from: m.range.upperBound)
                    .trimmingCharacters(in: .whitespaces)
                let parts = body.components(separatedBy: " - ")
                if parts.count >= 2 {
                    items.append(ListItem(
                        text: parts[0],
                        detail: parts.dropFirst().joined(separator: " - ")
                    ))
                } else {
                    items.append(ListItem(text: body, detail: nil))
                }
                listLineCount += 1
            } else if i == 0 && items.isEmpty {
                title = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*: "))
            }
        }

        let ratio = Double(listLineCount) / Double(rawLines.count)
        guard items.count >= 3, ratio >= 0.5 else { return nil }
        return ListResult(title: title, items: items)
    }

    // MARK: - Dates

    public static func parseDate(in text: String) -> DateResult? {
        guard text.count < 300 else { return nil }

        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        )
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = detector?.matches(in: text, range: range).first,
              let date = match.date else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = match.duration > 0 ? .short : .none

        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full

        let contextText = ns.replacingCharacters(in: match.range, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:- "))

        return DateResult(
            date: date,
            formattedDate: formatter.string(from: date),
            relativeDescription: relative.localizedString(for: date, relativeTo: Date()),
            context: contextText.isEmpty ? nil : contextText
        )
    }

    // MARK: - Shared

    private static func parseAnyDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }

        let formats = ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "MMM d, yyyy", "MMMM d, yyyy", "MM/dd/yyyy"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: string) { return d }
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let r = NSRange(location: 0, length: (string as NSString).length)
        return detector?.firstMatch(in: string, range: r)?.date
    }
}

public struct DateResult: Hashable, Sendable {
    public let date: Date
    public let formattedDate: String
    public let relativeDescription: String
    public let context: String?
}

public struct EventResult: Hashable, Sendable {
    public let title: String
    public let date: Date
    public let endDate: Date?
    public let location: String?
    public let attendeeCount: Int?
    public let notes: String?
}

public struct ListResult: Hashable, Sendable {
    public let title: String?
    public let items: [ListItem]
}

public struct ListItem: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let detail: String?

    public init(id: UUID = UUID(), text: String, detail: String? = nil) {
        self.id = id
        self.text = text
        self.detail = detail
    }
}
```

## 5. Card views (full source)

### `DateResultCard.swift`

```swift
import SwiftUI

struct DateResultCard: View {
    let result: DateResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Date")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }

            Text(result.formattedDate)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text(result.relativeDescription)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))

            if let context = result.context, !context.isEmpty {
                Text(context)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
}
```

### `EventResultCard.swift`

```swift
import SwiftUI

struct EventResultCard: View {
    let result: EventResult

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: result.date)
    }

    private var formattedEndTime: String? {
        guard let end = result.endDate else { return nil }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Event")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }

            Text(result.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Text(formattedDate + (formattedEndTime.map { " – \($0)" } ?? ""))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }

            if let location = result.location {
                HStack(spacing: 6) {
                    Image(systemName: "location")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(location)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            if let count = result.attendeeCount, count > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("\(count) attendees")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            if let notes = result.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }
}
```

### `ListResultCard.swift`

```swift
import SwiftUI

struct ListResultCard: View {
    let result: ListResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                if let title = result.title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                } else {
                    Text("List")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(result.items.enumerated()), id: \.element.id) { idx, item in
                        row(index: idx, item: item)
                    }
                }
            }
            .frame(maxHeight: 180)

            Text("\(result.items.count) items")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private func row(index: Int, item: ListItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
```

## 6. `RichTurnContentView.swift` edits

Add three arms to the existing `switch content` block:

```swift
case .dateResult(let date):
    DateResultCard(result: date)
case .eventResult(let event):
    EventResultCard(result: event)
case .listResult(let list):
    ListResultCard(result: list)
```

Existing arms unchanged.

## 7. `AICommandViewModel.swift` edits

In the display sink's `.result(text)` arm, add parser call with guard:

```swift
case .result(let text):
    if let idx = self.conversation.indices.last {
        self.conversation[idx].result = text
        self.conversation[idx].isStreaming = false
        self.conversation[idx].isError = false

        // T11 — opportunistic rich-content detection. Never overrides
        // an existing richContent (e.g. functionGraph pre-seed).
        if self.conversation[idx].richContent == nil,
           let parsed = RichResultParser.parse(text) {
            self.conversation[idx].richContent = parsed
        }
    }
    self.inputBarState = .result(message: text)
    self.streamingBuffer = ""
```

**NOTE TO CODER:** T12 is being developed in parallel and also modifies this handler (adds `trace:` to Turn + assigns `outcome.trace`). Merge carefully — both edits coexist in the same handler but touch different fields. If T12 ships first, your edit sits alongside the `trace` assignment.

## 8. Risks

1. **False positives**: offhand date mentions, step-style lists. Mitigated by `<300` char gate on dates and `≥50%` ratio gate on lists. Card is additive (above result bubble), so false-positive card doesn't replace the answer.
2. **Regex edge cases**: `1.Foo` (no space) — confirmed to match. Event pattern greedy-minimal on fields (extra pipes truncate).
3. **Function-graph overlap**: function seed happens at `submit` line 362; T11 only assigns if `richContent == nil`. Safe.
4. **Hashable churn**: `ListItem` has per-instance UUID. Second parse produces fresh UUIDs. Guard prevents second assignment. Safe.
5. **`.error` path**: parser not called — correct, errors never card.

## 9. Out of scope

- NewsResultCard (no NewsAPI)
- BrowserTrailCard (no BrowserAgent trail)
- Calendar integration (`EKEventStore` write)
- Map view for event location
- Auto-dismiss, haptic feedback
- Rich-text links in list items
- Staged response parsing (`consumeStagedResponse`)

## 10. Test plan

**Positive (should card):**
- "What's today's date?" → DateResultCard
- "When is the summer solstice?" → DateResultCard
- "Top 3 python web frameworks?" → ListResultCard (3 items)
- "List the planets." → ListResultCard (8 items, title)
- Agent reply containing `[EVENT: Meeting with Alice | 2026-04-24T15:00:00Z | HQ] I've noted this.` → EventResultCard

**Negative (no card):**
- Error responses (`.error` branch skips parser)
- Long prose (>300 chars) with a date mention
- Two-bullet reply (items < 3)
- Code block with numbered comments (ratio < 0.5)
- `y = sin(x)` prompt (function graph pre-seeded, parser no-ops)

## 11. Implementation order

1. Create `RichResultParser.swift` (compiles standalone).
2. Add three cases to `RichTurnContent` in `MarketModels.swift`. Build will fail until step 3.
3. Add three arms to `RichTurnContentView.swift` (placeholder Text views are fine at this step).
4. Fill in the three card files.
5. Wire parser into `AICommandViewModel.emit(.result(text))`.
6. Build + smoke-test per §10.
