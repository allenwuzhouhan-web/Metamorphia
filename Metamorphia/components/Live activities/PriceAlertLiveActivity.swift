/*
 * Metamorphia
 * Minimal closed-notch Live Activity for price-alert firings.
 *
 * Renders one row: ticker + delta, tinted green for rising / red for falling.
 * No side squircle, no verbose state text. Matches the Apple-ecosystem
 * register of the existing AgentRunningLiveActivity / PrivacyLiveActivity
 * indicators. Suppressed entirely during Do Not Disturb.
 */

import SwiftUI
import Defaults

struct PriceAlertLiveActivity: View {
    @ObservedObject private var monitor = MarketQuoteMonitor.shared
    @ObservedObject private var dnd = DoNotDisturbManager.shared

    var body: some View {
        HStack {
            Spacer()
            if shouldRender, let alert = monitor.activeAlerts.first {
                indicator(for: alert)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .id(alert.id)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: monitor.activeAlerts.first?.id)
        .contentShape(Rectangle())
        .onTapGesture {
            if let first = monitor.activeAlerts.first {
                monitor.dismissAlert(first.id)
            }
        }
    }

    private var shouldRender: Bool {
        guard Defaults[.marketsLiveActivityEnabled] else { return false }
        guard !dnd.isDoNotDisturbActive else { return false }
        return !monitor.activeAlerts.isEmpty
    }

    private func indicator(for alert: PriceAlertRule) -> some View {
        let color = tint(for: alert)
        return HStack(spacing: 4) {
            Text(alert.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(label(for: alert))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.15))
        )
        .padding(.trailing, 8)
    }

    private func tint(for alert: PriceAlertRule) -> Color {
        let quote = monitor.quotes[alert.symbol]
        if let pct = quote?.changePct {
            return pct >= 0 ? .green : .red
        }
        switch alert.condition {
        case .crossAbove: return .green
        case .crossBelow: return .red
        case .percentMoveAbs: return .white
        }
    }

    private func label(for alert: PriceAlertRule) -> String {
        let quote = monitor.quotes[alert.symbol]
        switch alert.condition {
        case .crossAbove(let threshold):
            if let last = quote?.last {
                return String(format: "↑ %.2f", last)
            }
            return String(format: "↑ %.2f", threshold)
        case .crossBelow(let threshold):
            if let last = quote?.last {
                return String(format: "↓ %.2f", last)
            }
            return String(format: "↓ %.2f", threshold)
        case .percentMoveAbs:
            if let pct = quote?.changePct {
                let sign = pct >= 0 ? "+" : ""
                return String(format: "%@%.2f%%", sign, pct)
            }
            return "moved"
        }
    }
}
