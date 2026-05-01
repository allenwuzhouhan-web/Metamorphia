/*
 * Metamorphia
 * T11 — EventResultCard
 *
 * Renders a compact event card when the agent's reply contains an
 * [EVENT: title | date | location?] marker. Read-only; no EventKit write.
 */

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
