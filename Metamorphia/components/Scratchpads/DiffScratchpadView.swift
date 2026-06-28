/*
 * Metamorphia
 * Two-pane text diff — the scratchpad UI.
 *
 * Paste an Original and a Changed version; the view computes a line-level diff
 * (LCS over lines) and renders it side-by-side with added lines tinted green
 * and removed lines red. Diffing runs off the main actor with a short debounce
 * so large pastes don't stall typing, and oversized inputs are capped so the
 * UI stays responsive rather than locking up.
 *
 * All state is local (@State). No app singletons, no network, no force-unwraps.
 * Empty or identical inputs degrade to a calm "no differences" state. Built to
 * sit in a ~360x440 floating panel; the result list scrolls.
 */

import SwiftUI

/// A side-by-side, line-level text diff scratchpad. Hostable in the notch or a
/// floating panel.
@MainActor
public struct DiffScratchpadView: View {
    /// Left-hand source text.
    @State private var original: String
    /// Right-hand source text.
    @State private var changed: String

    /// The computed, render-ready rows. Recomputed (debounced) on edits.
    @State private var rows: [DiffRow] = []
    /// Tallies for the status strip.
    @State private var addedCount = 0
    @State private var removedCount = 0
    /// Set when an input was too large and got capped before diffing.
    @State private var truncated = false

    /// Coalesces rapid edits into a single diff pass, run off-actor.
    @StateObject private var scheduler = DiffScratchpadDebounce()

    /// Monotonically increasing id stamped on each scheduled pass. Results from a
    /// pass older than the latest scheduled id are dropped so a slow in-flight
    /// diff can't publish stale rows over newer input.
    @State private var diffGeneration = 0

    /// Guards against runaway work: inputs longer than this many lines are
    /// truncated before diffing. Kept modest so the O(n·m) LCS table stays
    /// small (~18MB at the cap) rather than ballooning to hundreds of MB.
    private static let lineCap = 1_500

    public init(original: String = "", changed: String = "") {
        _original = State(initialValue: original)
        _changed = State(initialValue: changed)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            editors
            divider
            statusStrip
            resultList
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(minWidth: 300)
        .onChange(of: original) { _, _ in scheduleDiff() }
        .onChange(of: changed) { _, _ in scheduleDiff() }
        .onAppear { scheduleDiff() }
    }

    // MARK: - Editors

    private var editors: some View {
        HStack(alignment: .top, spacing: 8) {
            SidePaneEditor(title: "Original", text: $original, accent: .red)
            SidePaneEditor(title: "Changed", text: $changed, accent: .green)
        }
    }

    // MARK: - Status

    private var statusStrip: some View {
        HStack(spacing: 10) {
            DiffStatusBadge(symbol: "plus", count: addedCount, tint: .green, label: "added")
            DiffStatusBadge(symbol: "minus", count: removedCount, tint: .red, label: "removed")
            Spacer(minLength: 0)
            if truncated {
                Text("input capped")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.9))
                    .help("Input was longer than \(Self.lineCap) lines and was truncated before diffing.")
            }
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultList: some View {
        if rows.isEmpty {
            emptyState
        } else if addedCount == 0 && removedCount == 0 {
            identicalState
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        DiffRowView(row: row)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120, maxHeight: 240)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var emptyState: some View {
        placeholderBox(icon: "text.alignleft", text: "Paste text into both panes to see the diff.")
    }

    private var identicalState: some View {
        placeholderBox(icon: "equal.circle", text: "No differences — the two versions match.")
    }

    private func placeholderBox(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.30))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 120, maxHeight: 240)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - Diffing

    /// Snapshot the editors and recompute the diff off the main actor, then
    /// publish the result back. The debounce ensures only the latest snapshot
    /// is honored, so stale passes can't overwrite newer ones.
    private func scheduleDiff() {
        let left = original
        let right = changed
        let cap = Self.lineCap
        diffGeneration += 1
        let generation = diffGeneration

        scheduler.schedule {
            let result = DiffEngine.diff(original: left, changed: right, lineCap: cap)
            // Hop back to the main actor to mutate @State.
            Task { @MainActor in
                // Ignore results from a pass superseded by a newer scheduled one.
                guard generation == diffGeneration else { return }
                rows = result.rows
                addedCount = result.added
                removedCount = result.removed
                truncated = result.truncated
            }
        }
    }
}

// MARK: - Side pane editor

/// One labelled editor pane. The accent colours the header dot to hint which
/// side adds (green) vs. removes (red).
private struct SidePaneEditor: View {
    let title: String
    @Binding var text: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(accent.opacity(0.85))
                    .frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.40))
                    .tracking(0.5)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white.opacity(0.92))
                .frame(minHeight: 64, maxHeight: 110)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Status badge

private struct DiffStatusBadge: View {
    let symbol: String
    let count: Int
    let tint: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(count > 0 ? tint : Color.white.opacity(0.35))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((count > 0 ? tint : Color.white).opacity(count > 0 ? 0.14 : 0.05))
        )
        .help("\(count) lines \(label)")
    }
}

// MARK: - Row view

private struct DiffRowView: View {
    let row: DiffRow

    var body: some View {
        HStack(spacing: 0) {
            cell(text: row.leftText, lineNumber: row.leftNumber, side: .left)
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
            cell(text: row.rightText, lineNumber: row.rightNumber, side: .right)
        }
        .background(row.kind.rowTint)
    }

    private enum Side { case left, right }

    @ViewBuilder
    private func cell(text: String?, lineNumber: Int?, side: Side) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(lineNumber.map(String.init) ?? "")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
                .frame(width: 22, alignment: .trailing)
            Text(displayText(text))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(textTint(for: side))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cellTint(for: side))
    }

    /// Render an empty placeholder line as a faint dot rather than nothing, so
    /// the eye can track the gutter on a side with no corresponding line.
    private func displayText(_ text: String?) -> String {
        guard let text else { return " " }
        return text.isEmpty ? " " : text
    }

    private func textTint(for side: Side) -> Color {
        switch row.kind {
        case .same:
            return .white.opacity(0.80)
        case .added:
            return side == .right ? Color.green.opacity(0.95) : .white.opacity(0.15)
        case .removed:
            return side == .left ? Color.red.opacity(0.95) : .white.opacity(0.15)
        case .changed:
            return side == .left ? Color.red.opacity(0.95) : Color.green.opacity(0.95)
        }
    }

    private func cellTint(for side: Side) -> Color {
        switch row.kind {
        case .same:
            return .clear
        case .added:
            return side == .right ? Color.green.opacity(0.12) : Color.white.opacity(0.02)
        case .removed:
            return side == .left ? Color.red.opacity(0.12) : Color.white.opacity(0.02)
        case .changed:
            return side == .left ? Color.red.opacity(0.12) : Color.green.opacity(0.12)
        }
    }
}

// MARK: - Diff model

/// A single aligned row in the side-by-side view. Either side may be empty when
/// a line exists on only one version.
private struct DiffRow: Identifiable {
    let id = UUID()
    let kind: DiffKind
    let leftText: String?
    let rightText: String?
    let leftNumber: Int?
    let rightNumber: Int?
}

/// How a row differs between the two versions.
private enum DiffKind: Equatable {
    case same
    case added
    case removed
    case changed

    var rowTint: Color {
        switch self {
        case .same: return .clear
        case .added, .removed, .changed: return Color.white.opacity(0.015)
        }
    }
}

/// The output of a diff pass: the aligned rows plus tallies and a truncation
/// flag for the status strip.
private struct DiffComputed {
    let rows: [DiffRow]
    let added: Int
    let removed: Int
    let truncated: Bool
}

// MARK: - Diff engine

/// A small, self-contained line-level differ built on a longest-common-
/// subsequence table. Pure and side-effect free so it can run off the main
/// actor. Inputs are capped to keep the O(n·m) table bounded.
private enum DiffEngine {

    static func diff(original: String, changed: String, lineCap: Int) -> DiffComputed {
        let leftAll = splitLines(original)
        let rightAll = splitLines(changed)

        let left = Array(leftAll.prefix(lineCap))
        let right = Array(rightAll.prefix(lineCap))
        let wasTruncated = leftAll.count > lineCap || rightAll.count > lineCap

        // Fast paths for the common trivial cases.
        if left.isEmpty && right.isEmpty {
            return DiffComputed(rows: [], added: 0, removed: 0, truncated: wasTruncated)
        }

        let ops = lcsOps(left, right)
        let rows = assemble(ops, left: left, right: right)

        let added = rows.reduce(0) { $0 + ($1.kind == .added || $1.kind == .changed ? 1 : 0) }
        let removed = rows.reduce(0) { $0 + ($1.kind == .removed || $1.kind == .changed ? 1 : 0) }

        return DiffComputed(rows: rows, added: added, removed: removed, truncated: wasTruncated)
    }

    /// Split into lines, dropping a single trailing empty line so a text that
    /// ends in "\n" doesn't show a phantom final blank row.
    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// A diff operation in source order.
    private enum Op {
        case keep(left: Int, right: Int)
        case remove(left: Int)
        case insert(right: Int)
    }

    /// Build the classic LCS DP table, then backtrack into an ordered op list.
    private static func lcsOps(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count
        let m = b.count
        if n == 0 { return (0..<m).map { .insert(right: $0) } }
        if m == 0 { return (0..<n).map { .remove(left: $0) } }

        // (n+1) x (m+1) table flattened into one buffer.
        let width = m + 1
        var table = [Int](repeating: 0, count: (n + 1) * width)

        for i in stride(from: n - 1, through: 0, by: -1) {
            let rowBase = i * width
            let nextBase = (i + 1) * width
            let ai = a[i]
            for j in stride(from: m - 1, through: 0, by: -1) {
                if ai == b[j] {
                    table[rowBase + j] = table[nextBase + (j + 1)] + 1
                } else {
                    table[rowBase + j] = max(table[nextBase + j], table[rowBase + (j + 1)])
                }
            }
        }

        var ops: [Op] = []
        ops.reserveCapacity(n + m)
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.keep(left: i, right: j))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + (j + 1)] {
                ops.append(.remove(left: i))
                i += 1
            } else {
                ops.append(.insert(right: j))
                j += 1
            }
        }
        while i < n { ops.append(.remove(left: i)); i += 1 }
        while j < m { ops.append(.insert(right: j)); j += 1 }
        return ops
    }

    /// Collapse the op stream into aligned rows, resolving line text from the
    /// source arrays. Adjacent remove+insert runs are zipped together into
    /// "changed" rows so a one-for-one edit shows old on the left, new on the
    /// right instead of two stacked single-sided rows.
    private static func assemble(_ ops: [Op], left: [String], right: [String]) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(ops.count)

        // Pending single-sided runs we may still pair up.
        var pendingRemovals: [Int] = []
        var pendingInsertions: [Int] = []

        func flushPending() {
            // Zip the two runs into aligned "changed" rows, padding the shorter
            // side with empty cells.
            let paired = min(pendingRemovals.count, pendingInsertions.count)
            for k in 0..<paired {
                let li = pendingRemovals[k]
                let ri = pendingInsertions[k]
                rows.append(DiffRow(
                    kind: .changed,
                    leftText: left[li],
                    rightText: right[ri],
                    leftNumber: li + 1,
                    rightNumber: ri + 1
                ))
            }
            for k in paired..<pendingRemovals.count {
                let li = pendingRemovals[k]
                rows.append(DiffRow(
                    kind: .removed,
                    leftText: left[li],
                    rightText: nil,
                    leftNumber: li + 1,
                    rightNumber: nil
                ))
            }
            for k in paired..<pendingInsertions.count {
                let ri = pendingInsertions[k]
                rows.append(DiffRow(
                    kind: .added,
                    leftText: nil,
                    rightText: right[ri],
                    leftNumber: nil,
                    rightNumber: ri + 1
                ))
            }
            pendingRemovals.removeAll(keepingCapacity: true)
            pendingInsertions.removeAll(keepingCapacity: true)
        }

        for op in ops {
            switch op {
            case let .keep(li, ri):
                flushPending()
                rows.append(DiffRow(
                    kind: .same,
                    leftText: left[li],
                    rightText: right[ri],
                    leftNumber: li + 1,
                    rightNumber: ri + 1
                ))
            case let .remove(li):
                pendingRemovals.append(li)
            case let .insert(ri):
                pendingInsertions.append(ri)
            }
        }
        flushPending()
        return rows
    }
}

// MARK: - Debounce

/// Coalesces rapid edits and runs the (potentially heavy) diff pass on a
/// background queue, so typing into a large paste never blocks the main actor.
/// Only the latest scheduled pass survives the debounce window. Held as a
/// `@StateObject` so its work item is cancelled when the view goes away.
private final class DiffScratchpadDebounce: ObservableObject {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    private let queue = DispatchQueue(label: "metamorphia.diff-scratchpad", qos: .userInitiated)

    init(delay: TimeInterval = 0.18) {
        self.delay = delay
    }

    /// Run `body` off-actor after the debounce interval, cancelling any pending
    /// pass. `body` is responsible for hopping back to the main actor to
    /// publish results.
    func schedule(_ body: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: body)
        work = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    deinit {
        work?.cancel()
    }
}

// MARK: - Preview

#Preview("Diff Scratchpad") {
    DiffScratchpadView(
        original: "alpha\nbeta\ngamma\ndelta\nepsilon",
        changed: "alpha\nbeta two\ngamma\nzeta\ndelta\nepsilon"
    )
    .frame(width: 360, height: 440)
    .padding(20)
    .background(Color.black)
}
