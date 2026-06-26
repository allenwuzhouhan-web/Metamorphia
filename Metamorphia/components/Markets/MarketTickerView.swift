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
    @State private var rotationTimer: Timer?

    var body: some View {
        Group {
            if let symbol = currentSymbol, let quote = monitor.quotes[symbol] {
                row(for: quote)
                    .id(symbol)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: currentSymbol ?? "")
        .onAppear(perform: startRotation)
        .onDisappear(perform: stopRotation)
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

    private func startRotation() {
        stopRotation()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            Task { @MainActor in
                rotationIndex &+= 1
            }
        }
    }

    private func stopRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    // MARK: - Formatting

    private static let priceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func formattedPrice(_ value: Double) -> String {
        // Reuse a shared formatter (configured per call) instead of allocating one
        // on every row render. Safe: views render on the main thread.
        let formatter = Self.priceFormatter
        let digits = value >= 1000 ? 0 : 2
        formatter.maximumFractionDigits = digits
        formatter.minimumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    private func formattedPct(_ pct: Double) -> String {
        let sign = pct >= 0 ? "+" : ""
        return String(format: "%@%.2f%%", sign, pct)
    }
}
