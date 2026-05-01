/*
 * Metamorphia
 * Expanded Markets tab — shown when the notch is open and the user has
 * selected the markets view. Lists watchlist entries with sparklines and
 * supports add / remove inline.
 */

import SwiftUI
import Defaults

struct NotchMarketsView: View {
    @ObservedObject private var monitor = MarketQuoteMonitor.shared
    @ObservedObject private var watchlist = WatchlistStore.shared
    @ObservedObject private var clipboardSurface = ClipboardInsightsSurface.shared

    @State private var newSymbolInput: String = ""
    @State private var addError: String?
    @State private var pendingRemoveSymbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            banners
            if watchlist.entries.isEmpty {
                emptyState
            } else {
                watchlistList
            }
            addBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Banners (alerts, clipboard hints, morning brief)

    @ViewBuilder
    private var banners: some View {
        if let brief = monitor.morningBrief {
            briefBanner(brief)
        }
        if !monitor.activeAlerts.isEmpty {
            alertsBanner
        }
        if let hint = monitor.clipboardSuggestion {
            clipboardBanner(hint)
        }
        if let threadHint = clipboardSurface.currentHint {
            ClipboardThreadHintView(hint: threadHint) {
                clipboardSurface.dismiss()
            }
        }
    }

    private var alertsBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
            Text(monitor.activeAlerts.map(\.symbol).joined(separator: ", "))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Button {
                for alert in monitor.activeAlerts { monitor.dismissAlert(alert.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.1))
        )
    }

    private func briefBanner(_ brief: MorningBrief) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.8))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(briefSummaryLines(brief).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                monitor.dismissMorningBrief()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
    }

    /// Produce at most 2 summary lines for the notch banner.
    /// Line 1: top market mover (or first thread/meeting if no movers).
    /// Line 2: priority-iterate thread → meeting → open loop → "+N more movers";
    ///         "+N more movers" only surfaces when no non-market content is available.
    private func briefSummaryLines(_ brief: MorningBrief) -> [String] {
        var lines: [String] = []

        // Line 1: top market mover, or thread update, or meeting — first non-empty.
        if let mover = brief.marketMovers.first {
            let sign = mover.changePct >= 0 ? "+" : ""
            let name = mover.displayName ?? mover.symbol
            lines.append("\(name) \(sign)\(String(format: "%.2f%%", mover.changePct))")
        } else if let thread = brief.threadUpdates.first {
            lines.append("\(thread.entity) — \(thread.reason)")
        } else if let meeting = brief.meetingsToday.first {
            lines.append("\(meeting.title) later today")
        }

        // Line 2: build a priority-ordered candidate list and pick the first available.
        // Priority: thread update → meeting → open loop → "+N more movers".
        var line2Candidates: [String] = []

        if let thread = brief.threadUpdates.first {
            let candidate = "\(thread.entity) — \(thread.reason)"
            // Only include if line 1 isn't already showing this thread.
            if lines.first != candidate {
                line2Candidates.append(candidate)
            }
        }

        if let meeting = brief.meetingsToday.first {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let timeString = formatter.string(from: meeting.timeOfDay)
            let candidate = "\(meeting.title) at \(timeString)"
            if lines.first != candidate {
                line2Candidates.append(candidate)
            }
        }

        if let loop = brief.openLoops.first {
            line2Candidates.append("\(loop.entity) — \(loop.daysSinceLastCheck)d since last check")
        }

        if brief.marketMovers.count > 1 {
            let remaining = brief.marketMovers.count - 1
            line2Candidates.append("+\(remaining) more mover\(remaining == 1 ? "" : "s")")
        }

        if let second = line2Candidates.first {
            lines.append(second)
        }

        return lines
    }

    private func clipboardBanner(_ hint: ClipboardMarketHint) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10))
                .foregroundStyle(.blue.opacity(0.9))
            Text("\(hint.extractedSymbols.joined(separator: ", ")) — analyze?")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer()
            Button {
                monitor.dismissClipboardHint()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue.opacity(0.08))
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Markets")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
            } else if let err = monitor.lastRefreshError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your watchlist is empty.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            Text("Type a ticker below — NVDA, AAPL, SPY.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var watchlistList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(watchlist.entries) { entry in
                    row(for: entry)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func row(for entry: WatchlistEntry) -> some View {
        let quote = monitor.quotes[entry.symbol]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName ?? entry.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if let quote, let name = quote.companyName, entry.displayName == nil {
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: 80, alignment: .leading)

            MarketSparkline(symbol: entry.symbol, tint: tint(for: quote))
                .frame(height: 22)
                .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 1) {
                if let quote {
                    Text(formattedPrice(quote.last))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    if let pct = quote.changePct {
                        Text(formattedPct(pct))
                            .font(.system(size: 10))
                            .foregroundStyle(pct >= 0 ? .green : .red)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 70, alignment: .trailing)

            Button {
                pendingRemoveSymbol = entry.symbol
                watchlist.remove(entry.symbol)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(0.8)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func tint(for quote: MarketQuote?) -> Color {
        guard let pct = quote?.changePct else { return .white.opacity(0.6) }
        return pct >= 0 ? .green : .red
    }

    // MARK: - Add bar

    private var addBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            TextField("", text: $newSymbolInput, prompt: Text("Add ticker (e.g. NVDA)").foregroundColor(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .onSubmit(addSymbol)
            Button("Add") { addSymbol() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .disabled(trimmedInput.isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var trimmedInput: String {
        newSymbolInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addSymbol() {
        let raw = trimmedInput
        guard !raw.isEmpty else { return }
        let symbol = raw.uppercased()
        watchlist.add(symbol)
        newSymbolInput = ""
        addError = nil
        Task { @MainActor in
            await monitor.refreshNow()
        }
    }

    // MARK: - Formatting

    private func formattedPrice(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 2
        formatter.minimumFractionDigits = value >= 1000 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    private func formattedPct(_ pct: Double) -> String {
        let sign = pct >= 0 ? "+" : ""
        return String(format: "%@%.2f%%", sign, pct)
    }
}
