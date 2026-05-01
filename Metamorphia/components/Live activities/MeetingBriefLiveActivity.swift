/*
 * Metamorphia
 * Closed-notch flash surface for meeting pre-briefs.
 *
 * Renders one row when CalendarLens.shared.upcomingBrief is non-nil,
 * the notch is closed, and Do Not Disturb is not active.
 * Tap dismisses via CalendarLens.shared.dismiss().
 *
 * Transition and layout mirror PriceAlertLiveActivity — no side squircles,
 * no verbose state text, no monospaced typefaces.
 *
 * Continuum Phase 7.
 */

import SwiftUI

struct MeetingBriefLiveActivity: View {
    @ObservedObject private var lens = CalendarLens.shared
    @ObservedObject private var dnd = DoNotDisturbManager.shared

    var body: some View {
        HStack {
            Spacer()
            if shouldRender, let brief = lens.upcomingBrief {
                indicator(for: brief)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .id(brief.id)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: lens.upcomingBrief?.id)
        .contentShape(Rectangle())
        .onTapGesture {
            CalendarLens.shared.dismiss()
        }
    }

    // DND is the authoritative gate in ContentView. This guard is kept
    // as a defensive second check so the view never renders stale data
    // if the brief arrives between frames.
    private var shouldRender: Bool {
        guard !dnd.isDoNotDisturbActive else { return false }
        return lens.upcomingBrief != nil
    }

    private func indicator(for brief: MeetingPreBrief) -> some View {
        HStack(spacing: 4) {
            Text(label(for: brief))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.12))
        )
        .padding(.trailing, 8)
    }

    /// Single-line summary: name · company · N stories · last spoke <date>
    private func label(for brief: MeetingPreBrief) -> String {
        var parts: [String] = []

        if let attendee = brief.primaryAttendee {
            if let name = attendee.displayName ?? attendee.email {
                parts.append(name)
            }
            if let company = attendee.company {
                parts.append(company)
            }
        }

        let storyCount = brief.recentStories.count
        if storyCount > 0 {
            parts.append("\(storyCount) \(storyCount == 1 ? "story" : "stories")")
        }

        if let spokeAt = brief.lastSpokeAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(for: spokeAt, relativeTo: Date())
            parts.append("last spoke \(relative)")
        }

        return parts.isEmpty ? brief.title : parts.joined(separator: " · ")
    }
}
