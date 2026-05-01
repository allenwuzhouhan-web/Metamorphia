/*
 * Metamorphia
 * Continuum Phase 6 scaffold — attention + news feature flags.
 *
 * `attentionModelEnabled` is declared in AttentionModel.swift and co-located
 * with the type that reads it. All remaining news/continuum flags live here.
 *
 * Phase 13 additions: master news kill switch + per-surface sub-flags.
 */

import Defaults

extension Defaults.Keys {
    // MARK: - Phase 13 — Continuum news flags

    /// Master kill switch for all Continuum news surfaces. When false, the
    /// entire news experience (clipboard hints, morning brief, meeting
    /// pre-briefs, predictive staging) goes dark regardless of sub-flags.
    static let newsEnabled = Key<Bool>("continuum.newsEnabled", default: true)

    /// Allow the news morning brief to be assembled and shown on first unlock.
    /// Distinct from `marketsMorningBriefEnabled` which controls the
    /// markets-only brief; both must be true for the full brief to appear.
    static let newsMorningBriefEnabled = Key<Bool>("continuum.newsMorningBriefEnabled", default: true)

    /// Surface clipboard entity hints when a copied item matches a tracked story.
    static let newsClipboardEnrichmentEnabled = Key<Bool>("continuum.newsClipboardEnrichmentEnabled", default: true)

    /// Assemble and show pre-briefs for upcoming calendar meetings.
    static let newsMeetingPreBriefsEnabled = Key<Bool>("continuum.newsMeetingPreBriefsEnabled", default: true)

    /// Pre-compute answers to recurring morning queries on wake.
    static let newsPredictiveStagingEnabled = Key<Bool>("continuum.newsPredictiveStagingEnabled", default: true)
}
