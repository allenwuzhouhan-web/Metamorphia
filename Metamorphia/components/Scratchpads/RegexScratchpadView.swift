import SwiftUI
import AppKit

/// A live regex tester sized for the floating notch panel.
///
/// Pattern field + flag toggles + a multi-line test editor. As you type,
/// every match is highlighted in the test string, the count is shown, and
/// the capture groups of the selected match are listed. Invalid patterns
/// surface a red inline error and never crash (NSRegularExpression's throw
/// is caught and rendered, not force-unwrapped).
@MainActor public struct RegexScratchpadView: View {
    @State private var pattern: String = "(\\w+)@(\\w+)"
    @State private var testString: String = "Reach me at ada@analytic or grace@navy."

    @State private var caseInsensitive = true
    @State private var multiline = false
    @State private var dotMatchesNewline = false

    /// Index into `matches` whose capture groups are detailed below.
    @State private var selectedMatch = 0

    /// The single source of truth for the current pattern/flags/test string,
    /// recomputed once per change rather than on every body render. `error` is
    /// set when the pattern fails to compile; `results` holds the full matches.
    @State private var compiledError: String?
    @State private var results: [NSTextCheckingResult] = []

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                patternField
                flagRow
                testEditor
                Divider().overlay(Color.white.opacity(0.08))
                resultSection
            }
            .padding(14)
        }
        .background(Color.black.opacity(0.001)) // make whole tile hit-testable
        .onAppear(perform: recompute)
        .onChange(of: pattern) { _, _ in recompute() }
        .onChange(of: testString) { _, _ in recompute() }
        .onChange(of: caseInsensitive) { _, _ in recompute() }
        .onChange(of: multiline) { _, _ in recompute() }
        .onChange(of: dotMatchesNewline) { _, _ in recompute() }
    }

    // MARK: Pattern

    private var patternField: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Pattern")
            HStack(spacing: 6) {
                Text("/")
                    .foregroundStyle(.white.opacity(0.35))
                    .font(.system(size: 13, design: .monospaced))
                TextField("regular expression", text: $pattern)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                Text("/")
                    .foregroundStyle(.white.opacity(0.35))
                    .font(.system(size: 13, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(fieldBackground(error: compiledError != nil))

            if let message = compiledError {
                inlineError(message)
            }
        }
    }

    private var flagRow: some View {
        HStack(spacing: 6) {
            RegexFlagToggle(symbol: "Aa", title: "Ignore case", isOn: $caseInsensitive)
            RegexFlagToggle(symbol: "¶", title: "Multiline", isOn: $multiline)
            RegexFlagToggle(symbol: ".∗", title: "Dotall", isOn: $dotMatchesNewline)
        }
    }

    // MARK: Test string

    private var testEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("Test string")
                Spacer(minLength: 0)
                countBadge
            }
            // Highlighted, read-only mirror layered behind the editable field
            // so matches render in place without a custom NSTextView.
            highlightedEditor
        }
    }

    private var highlightedEditor: some View {
        ZStack(alignment: .topLeading) {
            // Highlight backdrop.
            Text(highlightedTest)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // Editable layer with clear text so backdrop highlights show through.
            TextEditor(text: $testString)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.clear)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .tint(.white.opacity(0.7))
        }
        .background(fieldBackground(error: false))
    }

    /// The test string with all matches tinted; first/selected match brighter.
    private var highlightedTest: AttributedString {
        var attributed = AttributedString(testString)
        attributed.foregroundColor = .white.opacity(0.9)

        for (index, result) in results.enumerated() {
            let range = result.range
            guard let bounds = Range(range, in: testString),
                  let lower = AttributedString.Index(bounds.lowerBound, within: attributed),
                  let upper = AttributedString.Index(bounds.upperBound, within: attributed)
            else { continue }
            let isSelected = index == clampedSelection
            attributed[lower..<upper].backgroundColor = isSelected
                ? Color.accentColor.opacity(0.45)
                : Color.accentColor.opacity(0.20)
        }
        return attributed
    }

    // MARK: Results

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compiledError != nil {
                Text("Fix the pattern to see matches.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            } else if results.isEmpty {
                Text("No matches.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                matchPicker
                captureGroups
            }
        }
    }

    private var matchPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Match \(clampedSelection + 1) of \(results.count)")
            if results.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(results.indices, id: \.self) { index in
                            Button {
                                selectedMatch = index
                            } label: {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(index == clampedSelection
                                                     ? Color.accentColor
                                                     : .white.opacity(0.6))
                                    .frame(width: 24, height: 24)
                                    .background(
                                        Circle().fill(index == clampedSelection
                                                      ? Color.accentColor.opacity(0.18)
                                                      : Color.white.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var captureGroups: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groupsForSelectedMatch, id: \.index) { group in
                RegexCaptureGroupRow(index: group.index, name: group.name, value: group.value)
            }
        }
    }

    private var countBadge: some View {
        Text("\(results.count) match\(results.count == 1 ? "" : "es")")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(compiledError == nil && !results.isEmpty
                             ? Color.accentColor
                             : .white.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.white.opacity(0.06))
            )
    }

    // MARK: Derived state

    /// Compile the pattern and run matching once, into `@State`, whenever an
    /// input changes. Everything below derives from the stored `results` so a
    /// single body render no longer recompiles the regex or re-runs matching.
    private func recompute() {
        let trimmed = pattern
        guard !trimmed.isEmpty else {
            compiledError = nil
            results = []
            return
        }
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multiline { options.insert(.anchorsMatchLines) }
        if dotMatchesNewline { options.insert(.dotMatchesLineSeparators) }
        do {
            let regex = try NSRegularExpression(pattern: trimmed, options: options)
            let full = NSRange(testString.startIndex..., in: testString)
            compiledError = nil
            results = regex.matches(in: testString, options: [], range: full)
        } catch {
            compiledError = friendlyMessage(from: error)
            results = []
        }
    }

    /// Selection clamped to the available matches so a shrinking match set
    /// never indexes out of bounds.
    private var clampedSelection: Int {
        guard !results.isEmpty else { return 0 }
        return min(max(selectedMatch, 0), results.count - 1)
    }

    private struct RegexScratchpadMatch {
        let index: Int
        let name: String?
        let value: String?
    }

    /// Capture groups (including group 0, the whole match) for the selected
    /// match, derived from the already-computed `results`.
    private var groupsForSelectedMatch: [RegexScratchpadMatch] {
        guard !results.isEmpty, clampedSelection < results.count else { return [] }
        let result = results[clampedSelection]

        var rows: [RegexScratchpadMatch] = []
        for groupIndex in 0..<result.numberOfRanges {
            let range = result.range(at: groupIndex)
            let value: String?
            if range.location == NSNotFound {
                value = nil
            } else if let swiftRange = Range(range, in: testString) {
                value = String(testString[swiftRange])
            } else {
                value = nil
            }
            rows.append(RegexScratchpadMatch(index: groupIndex, name: nil, value: value))
        }
        return rows
    }

    // MARK: Helpers

    private func friendlyMessage(from error: Error) -> String {
        let ns = error as NSError
        if let reason = ns.userInfo[NSLocalizedDescriptionKey] as? String {
            return reason
        }
        return ns.localizedDescription
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
    }

    private func inlineError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.red.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
        )
    }

    private func fieldBackground(error: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(error ? Color.red.opacity(0.35) : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
    }
}

// MARK: - Flag toggle

private struct RegexFlagToggle: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(spacing: 2) {
                Text(symbol)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(title)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isOn ? Color.accentColor : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

// MARK: - Capture group row

private struct RegexCaptureGroupRow: View {
    let index: Int
    let name: String?
    let value: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 52, alignment: .leading)
            if let value {
                Text(value.isEmpty ? "(empty)" : value)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(value.isEmpty ? .white.opacity(0.35) : .white.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("no match")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .italic()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(index == 0 ? 0.07 : 0.04))
        )
    }

    private var label: String {
        if let name { return name }
        return index == 0 ? "whole" : "$\(index)"
    }
}
