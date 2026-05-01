/*
 * Metamorphia
 * Calendar pre-brief value types — shared by CalendarLens, MeetingBriefLiveActivity,
 * and the RichTurnContent command-bar renderer.
 *
 * All types are pure data (Codable / Sendable) with no behavior beyond
 * convenience accessors. Runtime logic lives in CalendarLens.
 *
 * Continuum Phase 7.
 */

import Foundation
import MetamorphiaAgentKit

// MARK: - AttendeeDigest

/// Compact representation of one meeting attendee, resolved from
/// EKParticipant fields and the EntityAliasStore.
public struct AttendeeDigest: Sendable, Codable, Hashable {
    /// EKParticipant.name — nil when CalDAV omits it.
    public let displayName: String?
    /// Lowercased address extracted from EKParticipant.url ("mailto:..." strip).
    public let email: String?
    /// Canonical entity ID resolved via EntityAliasStore (company or person name).
    public let canonicalEntity: String?
    /// Derived from the right-hand side of the email domain, e.g. "anthropic"
    /// from "sarah@anthropic.com". Nil when email is absent.
    public let company: String?

    public init(
        displayName: String?,
        email: String?,
        canonicalEntity: String?,
        company: String?
    ) {
        self.displayName = displayName
        self.email = email
        self.canonicalEntity = canonicalEntity
        self.company = company
    }
}

// MARK: - MeetingPreBrief

/// Assembled package of context surfaced five minutes before a meeting.
/// The primary attendee's entity drives story and memory lookups.
public struct MeetingPreBrief: Sendable, Codable, Hashable, Identifiable {
    /// EKEvent.eventIdentifier — stable across EKEventStore reloads.
    public let id: String
    public let title: String
    public let startDate: Date
    /// The attendee whose canonical entity scored highest in the interest graph.
    /// Nil when the event has no resolvable attendees.
    public let primaryAttendee: AttendeeDigest?
    /// All remaining attendees (self excluded, primary excluded).
    public let otherAttendees: [AttendeeDigest]
    /// Up to 3 story article refs from the primary entity's active stories,
    /// sorted by lastArticleAt descending, each within the past 7 days.
    public let recentStories: [StoryArticleRef]
    /// Up to 2 short excerpt strings from memory.recall(.thread) for the
    /// primary entity. Empty when no memories exist.
    public let lastConversationMentions: [String]
    /// Timestamp of the most-recent .thread memory record for the primary
    /// entity. Nil when no thread memories exist. Used to render a relative
    /// "last spoke N days ago" label on the brief surface.
    public let lastSpokeAt: Date?
    /// When this brief was assembled — used for display formatting.
    public let computedAt: Date

    public init(
        id: String,
        title: String,
        startDate: Date,
        primaryAttendee: AttendeeDigest?,
        otherAttendees: [AttendeeDigest],
        recentStories: [StoryArticleRef],
        lastConversationMentions: [String],
        lastSpokeAt: Date? = nil,
        computedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.primaryAttendee = primaryAttendee
        self.otherAttendees = otherAttendees
        self.recentStories = recentStories
        self.lastConversationMentions = lastConversationMentions
        self.lastSpokeAt = lastSpokeAt
        self.computedAt = computedAt
    }
}
