/*
 * Metamorphia
 * Renders the optional rich payload attached to an AICommand turn — a quote
 * card, sparkline, news digest, or morning brief. Falls through to plain
 * text rendering when nil, so existing command-bar flows are unaffected.
 */

import SwiftUI
import MetamorphiaAgentKit

struct RichTurnContentView: View {
    let content: RichTurnContent
    let onDocumentReviewAction: ((DocumentReviewAction) async -> Void)?
    let onDocumentRecheck: (() async -> Void)?
    let onPowerPointRewriteAction: ((PowerPointRewriteAction) async -> Void)?
    let onPowerPointDesignAction: ((PowerPointDesignAction) async -> Void)?
    let onPowerPointDirectEditAction: ((PowerPointDirectEditControlAction) async -> Void)?
    let onPowerPointFinishAction: ((PowerPointFinishAction) async -> Void)?
    let onExcelAnalysisAction: ((ExcelAnalysisAction) async -> Void)?

    init(
        content: RichTurnContent,
        onDocumentReviewAction: ((DocumentReviewAction) async -> Void)?,
        onDocumentRecheck: (() async -> Void)? = nil,
        onPowerPointRewriteAction: ((PowerPointRewriteAction) async -> Void)? = nil,
        onPowerPointDesignAction: ((PowerPointDesignAction) async -> Void)? = nil,
        onPowerPointDirectEditAction: ((PowerPointDirectEditControlAction) async -> Void)? = nil,
        onPowerPointFinishAction: ((PowerPointFinishAction) async -> Void)? = nil,
        onExcelAnalysisAction: ((ExcelAnalysisAction) async -> Void)? = nil
    ) {
        self.content = content
        self.onDocumentReviewAction = onDocumentReviewAction
        self.onDocumentRecheck = onDocumentRecheck
        self.onPowerPointRewriteAction = onPowerPointRewriteAction
        self.onPowerPointDesignAction = onPowerPointDesignAction
        self.onPowerPointDirectEditAction = onPowerPointDirectEditAction
        self.onPowerPointFinishAction = onPowerPointFinishAction
        self.onExcelAnalysisAction = onExcelAnalysisAction
    }

    var body: some View {
        Group {
            switch content {
            case .quoteCard(let quote):
                quoteCard(quote)
            case .sparkline(let symbol, let points):
                sparkline(symbol: symbol, points: points)
            case .newsDigest(let items):
                newsDigest(items)
            case .morningBrief(let brief):
                morningBrief(brief)
            case .functionGraph(let spec):
                FunctionGraphView(spec: spec)
            case .meetingBrief(let brief):
                meetingBrief(brief)
            case .retraceScenes(let query, let scenes):
                retraceScenes(query: query, scenes: scenes)
            case .dateResult(let date):
                DateResultCard(result: date)
            case .eventResult(let event):
                EventResultCard(result: event)
            case .listResult(let list):
                ListResultCard(result: list)
            case .documentReview(let review):
                DocumentReviewResultCard(
                    result: review,
                    onAction: onDocumentReviewAction,
                    onRecheck: onDocumentRecheck
                )
            case .documentRecheck(let recheck):
                DocumentRecheckResultCard(result: recheck)
            case .powerPointRewrite(let rewrite):
                PowerPointRewriteResultCard(
                    result: rewrite,
                    onAction: onPowerPointRewriteAction
                )
            case .powerPointDesign(let design):
                PowerPointDesignResultCard(
                    result: design,
                    onAction: onPowerPointDesignAction
                )
            case .powerPointDirectEdit(let edit):
                PowerPointDirectEditResultCard(
                    result: edit,
                    onAction: onPowerPointDirectEditAction
                )
            case .powerPointFinish(let finish):
                PowerPointFinishResultCard(
                    result: finish,
                    onAction: onPowerPointFinishAction
                )
            case .excelAnalysis(let analysis):
                ExcelAnalysisResultCard(
                    result: analysis,
                    onAction: onExcelAnalysisAction
                )
            }
        }
        // Soft insertion — rich payloads fade up and settle rather than
        // popping in. The opacity leg runs shorter so the card reads as
        // present before it finishes seating, matching the notch spring.
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6))
                    .animation(.smooth(duration: 0.32)),
                removal: .opacity.animation(.easeOut(duration: 0.18))
            )
        )
    }

    // MARK: - Quote card

    private func quoteCard(_ quote: MarketQuote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(quote.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if let name = quote.companyName {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
                Text(formatTime(quote.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatPrice(quote.last))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                if let pct = quote.changePct, let change = quote.change {
                    let sign = change >= 0 ? "+" : ""
                    Text("\(sign)\(formatPrice(change)) (\(sign)\(String(format: "%.2f%%", pct)))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(change >= 0 ? .green : .red)
                }
            }
            HStack(spacing: 12) {
                if let dl = quote.dayLow, let dh = quote.dayHigh {
                    infoChip("Day", value: "\(formatPrice(dl)) – \(formatPrice(dh))")
                }
                if let wl = quote.fiftyTwoWeekLow, let wh = quote.fiftyTwoWeekHigh {
                    infoChip("52wk", value: "\(formatPrice(wl)) – \(formatPrice(wh))")
                }
                if let exchange = quote.exchange {
                    infoChip("Ex.", value: exchange)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func infoChip(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
    }

    // MARK: - Sparkline

    private func sparkline(symbol: String, points: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            SparklinePath(points: points, tint: points.endsAbove ? .green : .white)
                .frame(height: 40)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: - News digest

    private func newsDigest(_ items: [MarketNewsItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items.prefix(5)) { item in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2)
                        if let publisher = item.publisher {
                            Text(publisher)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: - Morning brief

    private func morningBrief(_ brief: MorningBrief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Morning brief")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            let lines = briefLines(brief)
            ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }

            if lines.count > 3 {
                Text("…and \(lines.count - 3) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    /// Flatten all brief sections into display strings, respecting the
    /// ordering: market movers → thread updates → meetings → open loops.
    private func briefLines(_ brief: MorningBrief) -> [String] {
        var lines: [String] = []

        for mover in brief.marketMovers {
            let sign = mover.changePct >= 0 ? "+" : ""
            let name = mover.displayName ?? mover.symbol
            lines.append("\(name)  \(sign)\(String(format: "%.2f%%", mover.changePct))")
        }

        for thread in brief.threadUpdates {
            lines.append("\(thread.entity) — \(thread.reason)")
        }

        for meeting in brief.meetingsToday {
            let time = formatTime(meeting.timeOfDay)
            lines.append("\(meeting.title) at \(time)")
        }

        for loop in brief.openLoops {
            lines.append("\(loop.entity): \(loop.daysSinceLastCheck)d since last check")
        }

        return lines
    }

    // MARK: - Meeting brief

    private func meetingBrief(_ brief: MeetingPreBrief) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(brief.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(formatTime(brief.startDate))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if let attendee = brief.primaryAttendee {
                let who = attendee.displayName ?? attendee.email ?? attendee.company ?? "Unknown"
                let company = attendee.company.map { " · \($0)" } ?? ""
                Text("\(who)\(company)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            if !brief.recentStories.isEmpty {
                Text(brief.recentStories.prefix(3).map(\.title).joined(separator: "; "))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(3)
            }
            if !brief.lastConversationMentions.isEmpty {
                Text(brief.lastConversationMentions.joined(separator: " — "))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: - Formatting

    private func formatPrice(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 2
        formatter.minimumFractionDigits = value >= 1000 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Retrace scenes

    @ViewBuilder
    private func retraceScenes(query: String, scenes: [RecallScene]) -> some View {
        if scenes.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Nothing matched “\(query)” yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(10)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(scenes.prefix(3)) { scene in
                    retraceSceneCard(scene)
                }
            }
        }
    }

    private func retraceSceneCard(_ scene: RecallScene) -> some View {
        let hero = scene.hero
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: hero.item.kind.displaySymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hero.item.title ?? "(untitled)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let reason = scene.anchorReason {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(relativeTime(hero.item.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }

            // Snippet from body (first ~140 chars).
            let snippet = String(hero.item.body.prefix(140))
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }

            // Timeline ribbon of siblings.
            if scene.members.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(scene.members.dropFirst().prefix(4).enumerated()), id: \.offset) { _, sibling in
                        HStack(spacing: 4) {
                            Image(systemName: sibling.item.kind.displaySymbol)
                                .font(.system(size: 9))
                            Text(sibling.item.title?.prefix(28).description ?? sibling.item.appBundleID ?? "item")
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white.opacity(0.06), in: Capsule())
                        .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }

            // Entity chips.
            if !scene.chipEntities.isEmpty {
                HStack(spacing: 5) {
                    ForEach(scene.chipEntities.prefix(3), id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.white.opacity(0.04), in: Capsule())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private extension Array where Element == Double {
    /// True when the series closes higher than it opened — used to tint a
    /// sparkline green. Not a true monotonic check; name kept honest.
    var endsAbove: Bool {
        guard let first = first, let last = last, count >= 2 else { return false }
        return last > first
    }
}
