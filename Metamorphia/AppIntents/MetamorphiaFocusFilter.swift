import AppIntents
import Defaults
import Foundation

/// Focus Filter — lets the user attach Metamorphia to any macOS Focus
/// (Work, Sleep, etc.) in System Settings > Focus > Focus Filters.
/// When the Focus turns on, the system calls `perform()` with
/// `suppressProposals` reflecting the desired suppression state, and we
/// persist it to Defaults[.focusFilterActive] — the durable focus signal
/// the ProposalLoop reads. The system also calls perform() when the Focus
/// turns off (via a revert invocation), so we clear it then. This is more
/// reliable than scraping Assertions.json because it is a first-party
/// OS contract.
struct MetamorphiaFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Quiet Metamorphia proposals"
    static var description = IntentDescription(
        "While this Focus is on, suppress Metamorphia's ambient proposals.",
        categoryName: "Focus"
    )

    /// Whether ambient proposals should be suppressed while this Focus is on.
    @Parameter(title: "Suppress ambient proposals", default: true)
    var suppressProposals: Bool

    // Shown in the Focus Filter editor row.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: suppressProposals
                ? "Proposals: suppressed"
                : "Proposals: allowed"
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // The system calls this on Focus ON (apply) and OFF (revert).
        // When the filter is deactivated the system re-invokes with
        // suppressProposals = false (or removes the filter entirely), so
        // we always write the current value of suppressProposals.
        // DoNotDisturbManager.focusSuppressionActive falls back to
        // isDoNotDisturbActive when this flag is false, covering the
        // case where the off-transition doesn't re-invoke perform().
        Defaults[.focusFilterActive] = suppressProposals
        return .result()
    }
}
