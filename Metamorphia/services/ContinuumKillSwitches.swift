import Foundation
import Combine
import Defaults

/// Observes Continuum feature flags and clears live in-flight state when a flag flips off.
/// Without this, disabled features persist until their next tick (next poll, wake, etc.).
@MainActor
public final class ContinuumKillSwitches {
    public static let shared = ContinuumKillSwitches()

    private var cancellables: Set<AnyCancellable> = []
    private var wired = false

    private init() {}

    public func start() {
        guard !wired else { return }
        wired = true

        // Master: news off → clear every news surface
        Defaults.publisher(.newsEnabled)
            .receive(on: RunLoop.main)
            .sink { _ in
                if Defaults[.newsEnabled] == false {
                    PredictiveStaging.shared.invalidate(reason: .manual)
                    MarketQuoteMonitor.shared.dismissMorningBrief()
                    CalendarLens.shared.dismiss()
                    ClipboardInsightsSurface.shared.dismiss()
                }
            }
            .store(in: &cancellables)

        // Per-feature gates
        Defaults.publisher(.newsMorningBriefEnabled)
            .receive(on: RunLoop.main)
            .sink { _ in
                if Defaults[.newsMorningBriefEnabled] == false {
                    MarketQuoteMonitor.shared.dismissMorningBrief()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.newsClipboardEnrichmentEnabled)
            .receive(on: RunLoop.main)
            .sink { _ in
                if Defaults[.newsClipboardEnrichmentEnabled] == false {
                    ClipboardInsightsSurface.shared.dismiss()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.newsMeetingPreBriefsEnabled)
            .receive(on: RunLoop.main)
            .sink { _ in
                if Defaults[.newsMeetingPreBriefsEnabled] == false {
                    CalendarLens.shared.dismiss()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.newsPredictiveStagingEnabled)
            .receive(on: RunLoop.main)
            .sink { _ in
                if Defaults[.newsPredictiveStagingEnabled] == false {
                    PredictiveStaging.shared.invalidate(reason: .manual)
                }
            }
            .store(in: &cancellables)
    }
}
