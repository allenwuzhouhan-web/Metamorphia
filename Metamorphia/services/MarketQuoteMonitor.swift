/*
 * Metamorphia
 * Ambient market polling, alert evaluation, clipboard reflex, and morning
 * brief for the Market Lens feature.
 *
 * Structurally mirrors `StatsManager` (Timer + [weak self] + @MainActor Task)
 * with an additional set of observer sinks (watchlist changes, clipboard
 * history, workspace wake). Alert evaluation is folded in — no separate
 * alert manager.
 */

import Foundation
import Combine
import AppKit
import Defaults
import MetamorphiaExecutors

@MainActor
public final class MarketQuoteMonitor: ObservableObject {

    public static let shared = MarketQuoteMonitor()

    // MARK: - Published state

    @Published public private(set) var quotes: [String: MarketQuote] = [:]
    @Published public private(set) var activeAlerts: [PriceAlertRule] = []
    @Published public private(set) var morningBrief: MorningBrief?
    @Published public private(set) var clipboardSuggestion: ClipboardMarketHint?
    @Published public private(set) var lastRefreshError: String?
    @Published public private(set) var isRefreshing: Bool = false

    // MARK: - Private state

    private var pollTimer: Timer?
    private var notchIsOpen: Bool = false
    private var currentTab: NotchViews = .home
    private var cancellables = Set<AnyCancellable>()
    private var previousQuotes: [String: MarketQuote] = [:]
    private var lastBriefDate: Date?
    private var dismissedHintURLs: Set<String> = []

    private let service = YahooFinanceService()

    private static let alertCooldown: TimeInterval = 30 * 60
    private static let alertDisplayWindow: TimeInterval = 20

    // MARK: - Lifecycle

    private init() {
        observeWatchlist()
        observeClipboard()
        observeWake()
    }

    public func start() {
        scheduleNextTick()
        Task { @MainActor in await maybePostMorningBrief() }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Tab / notch state

    public func updateMonitoringState(notchIsOpen: Bool, currentTab: NotchViews) {
        let wasOpen = self.notchIsOpen
        let wasTab = self.currentTab
        self.notchIsOpen = notchIsOpen
        self.currentTab = currentTab
        if wasOpen != notchIsOpen || wasTab != currentTab {
            scheduleNextTick()
        }
    }

    // MARK: - Polling

    private var effectivePollInterval: TimeInterval {
        guard Defaults[.marketsEnabled] else { return 0 }
        if WatchlistStore.shared.entries.isEmpty { return 0 }
        return notchIsOpen
            ? Defaults[.marketsPollIntervalOpen]
            : Defaults[.marketsPollIntervalClosed]
    }

    private func scheduleNextTick() {
        pollTimer?.invalidate()
        pollTimer = nil

        let interval = effectivePollInterval
        guard interval > 0 else { return }

        Task { @MainActor in await self.refresh() }

        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
    }

    public func refreshNow() async {
        await refresh()
    }

    private func refresh() async {
        let symbols = WatchlistStore.shared.entries.map { $0.symbol }
        guard !symbols.isEmpty else {
            quotes = [:]
            previousQuotes = [:]
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let rows = try await service.quotes(symbols: symbols)
            var next: [String: MarketQuote] = [:]
            for row in rows {
                next[row.symbol] = quote(from: row)
            }
            previousQuotes = quotes
            quotes = next
            lastRefreshError = nil
            evaluateAlerts()
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    private func quote(from row: YahooFinanceService.QuoteRow) -> MarketQuote {
        MarketQuote(
            symbol: row.symbol,
            companyName: row.companyName,
            last: row.last,
            previousClose: row.previousClose,
            change: row.change,
            changePct: row.changePct,
            dayHigh: row.dayHigh,
            dayLow: row.dayLow,
            fiftyTwoWeekHigh: row.fiftyTwoWeekHigh,
            fiftyTwoWeekLow: row.fiftyTwoWeekLow,
            volume: row.volume,
            currency: row.currency,
            exchange: row.exchange,
            timestamp: row.timestamp
        )
    }

    // MARK: - Alerts

    private func evaluateAlerts() {
        var newlyFired: [PriceAlertRule] = []
        let now = Date()

        for entry in WatchlistStore.shared.entries {
            guard let quote = quotes[entry.symbol] else { continue }
            let prev = previousQuotes[entry.symbol]

            for rule in entry.alertRules {
                if let lastFired = rule.lastFiredAt,
                   now.timeIntervalSince(lastFired) < Self.alertCooldown {
                    continue
                }
                if rule.evaluate(against: quote, previous: prev) {
                    newlyFired.append(rule)
                    WatchlistStore.shared.markAlertFired(rule.id, for: entry.symbol, at: now)
                }
            }
        }

        guard !newlyFired.isEmpty else { return }

        activeAlerts = newlyFired + activeAlerts.filter { existing in
            !newlyFired.contains(where: { $0.id == existing.id })
        }

        // Auto-clear the Live Activity surface after the display window —
        // alert history is preserved in WatchlistStore via `lastFiredAt`.
        // Continuum Phase 6: alerts that expire without a dismissal call are
        // treated as ignored surfaces (no engagement, no explicit dismiss).
        let firedIDs = Set(newlyFired.map(\.id))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.alertDisplayWindow * 1_000_000_000))
            let expiredIDs = firedIDs.filter { id in self.activeAlerts.contains { $0.id == id } }
            self.activeAlerts.removeAll { firedIDs.contains($0.id) }
            if !expiredIDs.isEmpty {
                AttentionModel.shared.recordSurfaceIgnored()
            }
        }
    }

    public func dismissAlert(_ id: UUID) {
        activeAlerts.removeAll { $0.id == id }
        // Continuum Phase 6: user dismissed a price-alert surface.
        AttentionModel.shared.recordSurfaceDismissal()
    }

    // MARK: - Watchlist observation

    private func observeWatchlist() {
        WatchlistStore.shared.$entries
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleNextTick() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Clipboard reflex

    private func observeClipboard() {
        ClipboardManager.shared.$clipboardHistory
            .dropFirst()
            .compactMap { $0.first }
            .sink { [weak self] item in
                guard let self else { return }
                self.handleClipboardItem(item)
            }
            .store(in: &cancellables)
    }

    private func handleClipboardItem(_ item: ClipboardItem) {
        guard let text = item.stringData,
              let url = Self.firstURL(in: text),
              let host = url.host?.lowercased() else { return }
        guard Self.isFinanceHost(host) else { return }
        guard !dismissedHintURLs.contains(url.absoluteString) else { return }

        let watchlist = WatchlistStore.shared.entries.map { $0.symbol }
        let tickers = Self.extractTickers(fromURL: url, watchlist: watchlist)
        guard !tickers.isEmpty else { return }

        clipboardSuggestion = ClipboardMarketHint(
            url: url.absoluteString,
            extractedSymbols: tickers,
            clipboardItemId: item.id
        )
    }

    public func dismissClipboardHint() {
        if let url = clipboardSuggestion?.url {
            dismissedHintURLs.insert(url)
        }
        clipboardSuggestion = nil
        // Continuum Phase 6: user dismissed the clipboard-hint surface.
        AttentionModel.shared.recordSurfaceDismissal()
    }

    private static let financeHosts: [String] = [
        "finance.yahoo.com", "bloomberg.com", "reuters.com", "cnbc.com",
        "marketwatch.com", "seekingalpha.com", "tradingview.com",
        "investing.com", "wsj.com", "ft.com", "barrons.com",
    ]

    private static func isFinanceHost(_ host: String) -> Bool {
        financeHosts.contains { host == $0 || host.hasSuffix(".\($0)") || host.contains($0) }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return URL(string: text)
        }
        let range = NSRange(text.startIndex..., in: text)
        let match = detector.firstMatch(in: text, options: [], range: range)
        return match?.url
    }

    private static func extractTickers(fromURL url: URL, watchlist: [String]) -> [String] {
        let upper = url.absoluteString.uppercased()
        return watchlist.filter { symbol in
            let patterns = [
                "/\(symbol)/",
                "/\(symbol)?",
                "/\(symbol)#",
                "/QUOTE/\(symbol)",
                "SYMBOL=\(symbol)",
                "TICKER=\(symbol)",
                "=\(symbol)&",
                "=\(symbol)$",
            ]
            return patterns.contains { upper.contains($0) } || upper.hasSuffix("/\(symbol)")
        }
    }

    // MARK: - Morning brief

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.maybePostMorningBrief()
            }
        }
    }

    private func maybePostMorningBrief() async {
        // Both the master news flag and the morning-brief sub-flag must be on.
        // `marketsMorningBriefEnabled` (markets-only brief) is a separate flag
        // and is checked independently — this gate is for the Continuum brief.
        guard Defaults[.newsEnabled] && Defaults[.newsMorningBriefEnabled] else {
            morningBrief = nil
            return
        }
        guard Defaults[.marketsMorningBriefEnabled] else { return }
        let today = Calendar.current.startOfDay(for: .now)
        if let last = lastBriefDate,
           Calendar.current.isDate(last, inSameDayAs: today) {
            return
        }

        lastBriefDate = today
        let brief = await MorningBriefAssembler.shared.assembleForToday()
        morningBrief = brief

        // Auto-dismiss after 25 s (preserve existing behaviour).
        let capturedId = brief.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(25 * 1_000_000_000))
            guard let self else { return }
            if self.morningBrief?.id == capturedId {
                self.morningBrief = nil
                AttentionModel.shared.recordSurfaceIgnored()
            }
        }
    }

    public func dismissMorningBrief() {
        morningBrief = nil
        // Continuum Phase 6: user dismissed the morning-brief surface.
        AttentionModel.shared.recordSurfaceDismissal()
    }

}
