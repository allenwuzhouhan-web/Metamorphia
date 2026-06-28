/*
 * Metamorphia
 * Ambient rotating-ticker view for the closed-notch glance surface.
 *
 * Rotates through the user's watchlist one symbol at a time. Layout is
 * deliberately minimal: symbol, last price, percent change. No sparkline at
 * this size; no side squircle; no verbose state text. Matches the calm,
 * Apple-native aesthetic of the existing ambient indicators.
 */

import SwiftUI
import Defaults

struct MarketTickerView: View {
    @ObservedObject private var monitor = MarketQuoteMonitor.shared
    @ObservedObject private var watchlist = WatchlistStore.shared

    @State private var rotationIndex: Int = 0

    // Driven by a SwiftUI-owned publisher so the periodic tick is torn down with
    // the view automatically — no orphaned RunLoop Timer if onDisappear is skipped.
    private let rotationTick = Timer.publish(every: 4.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let symbol = currentSymbol, let quote = monitor.quotes[symbol] {
                row(for: quote)
                    .id(symbol)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: currentSymbol ?? "")
        .onReceive(rotationTick) { _ in
            rotationIndex &+= 1
        }
        .onChange(of: watchlist.entries.map(\.symbol)) { _, _ in
            rotationIndex = 0
        }
    }

    // MARK: - Row

    private func row(for quote: MarketQuote) -> some View {
        HStack(spacing: 4) {
            Text(quote.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(formattedPrice(quote.last))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            if let pct = quote.changePct {
                Text(formattedPct(pct))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(pct >= 0 ? Color.green : Color.red)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Rotation

    private var visibleSymbols: [String] {
        watchlist.entries.map(\.symbol).filter { monitor.quotes[$0] != nil }
    }

    private var currentSymbol: String? {
        let symbols = visibleSymbols
        guard !symbols.isEmpty else { return nil }
        return symbols[rotationIndex % symbols.count]
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
