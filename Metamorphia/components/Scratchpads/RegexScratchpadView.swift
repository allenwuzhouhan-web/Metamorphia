import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A two-mode text-pattern tool for the notch.
///
/// **Find** is dead-simple literal lookup — a word or phrase, optionally whole-word.
/// **Patterns** is a searchable library of pre-built linguistic / entity patterns grouped
/// by topic → subtopic. Stack several (e.g. `/preposition + /verb`) and every match of any
/// of them lights up, each in its own colour. Regexes are compiled once and cached, and
/// matches recompute only when the text or the selection changes — so it stays fast.
@MainActor public struct RegexScratchpadView: View {
    private enum Mode: String, Sendable { case find, patterns }

    @AppStorage("regexScratchMode") private var modeRaw = Mode.patterns.rawValue
    @AppStorage("regexScratchText") private var text = RegexScratchpadView.sampleText
    @AppStorage("regexScratchStack") private var stackRaw = "preposition"
    @AppStorage("regexFindQuery") private var findQuery = ""
    @AppStorage("regexFindWholeWord") private var wholeWord = false
    @AppStorage("regexFindCaseInsensitive") private var findCaseInsensitive = true

    @State private var search = ""
    @State private var expanded: Set<String> = ["Parts of Speech"]
    @State private var highlights: [Highlight] = []

    /// Per-row match counts for the current search results, keyed by pattern slug.
    /// Filled by the background pass (never in `body`) so typing doesn't run a
    /// full-text regex per visible row on every render.
    @State private var counts: [String: Int] = [:]

    /// The highlighted editor text, rebuilt off the render path whenever the text
    /// or highlights change rather than reallocated in `body` every keystroke.
    @State private var highlightedText = AttributedString("")

    /// Debounces and runs matching off the main actor; results hop back to publish.
    @StateObject private var scheduler = RegexScratchpadDebounce()

    /// Monotonically increasing id stamped on each scheduled pass. A pass older
    /// than the latest id is dropped so a slow run can't overwrite newer input.
    @State private var generation = 0

    /// An uploaded document: its name, and — only when it's too big to preview inline —
    /// its full text (kept out of the editor). Small docs load straight into `text`.
    @State private var docName: String?
    @State private var largeDocText: String?
    @State private var docNotice: String?

    /// Above this length an uploaded doc is searched out-of-line into an exported copy.
    private let inlineLimit = 12_000

    /// Hard ceiling on how many characters a single matching pass scans. A
    /// multi-MB upload can't blow up even one background pass; the large-doc card
    /// already tells the user big docs aren't fully previewed.
    private let scanCap = 400_000

    public init() {}

    private struct Highlight: Sendable { let range: NSRange; let colorIndex: Int }

    private static let palette: [Color] = [.cyan, .purple, .orange, .green, .pink, .yellow, .mint, .teal]

    private static let sampleText = "The quick brown fox jumped over the lazy dog near the river. She is running quickly and will arrive at 9:30am. Email me at hello@example.com or visit https://example.com — it costs $19.99 (about 20%). Honestly, it was was a really great great day!"

    /// Per-pattern match colors for the exported .docx. AppKit's OOXML writer drops
    /// background highlights, but bold + colored text + underline all survive — so these
    /// are saturated foreground colors, readable on a white page.
    private static let nsPalette: [NSColor] = [
        NSColor(srgbRed: 0.00, green: 0.48, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.20, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.45, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.60, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.80, green: 0.10, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.52, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.00, green: 0.55, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.30, blue: 0.85, alpha: 1),
    ]

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .patterns }
    private var stack: [String] { stackRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty } }

    /// What matching runs against: a large doc's text, otherwise the editor text.
    private var sourceText: String { largeDocText ?? text }
    private var isLargeDoc: Bool { largeDocText != nil }

    private var charCountText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: sourceText.count)) ?? "\(sourceText.count)"
    }

    public var body: some View {
        VStack(spacing: 10) {
            topBar
            if mode == .find { findBar } else { patternBar }
            if docName != nil { docStatus }
            if isLargeDoc { largeDocCard } else { editor }
        }
        .padding(12)
        .onAppear {
            highlightedText = Self.buildHighlightedText(text, highlights: highlights)
            recompute()
        }
        .onChange(of: text) { _, newValue in
            // Reflect the typed text instantly (the visible layer is this overlay,
            // not the clear TextEditor), then debounce the expensive highlighting.
            if !isLargeDoc { highlightedText = AttributedString(newValue) }
            recompute()
        }
        .onChange(of: modeRaw) { _, _ in recompute() }
        .onChange(of: stackRaw) { _, _ in recompute() }
        .onChange(of: search) { _, _ in recompute() }
        .onChange(of: findQuery) { _, _ in recompute() }
        .onChange(of: wholeWord) { _, _ in recompute() }
        .onChange(of: findCaseInsensitive) { _, _ in recompute() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            modePicker
            uploadButton
        }
    }

    private var uploadButton: some View {
        Button(action: uploadDoc) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help("Upload a Word document (.docx)")
    }

    private var docStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(docName ?? "").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            Text("· \(charCountText) chars").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 4)
            Button(action: clearDoc) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 0) {
            modeButton("Find", .find, "magnifyingglass")
            modeButton("Patterns", .patterns, "wand.and.stars")
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func modeButton(_ title: String, _ value: Mode, _ icon: String) -> some View {
        let on = mode == value
        return Button { modeRaw = value.rawValue } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(on ? .black : .white.opacity(0.7))
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(on ? Color.white.opacity(0.9) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Find mode

    private var findBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                TextField("Find a word or phrase…", text: $findQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))

            toggleChip("Whole word", isOn: $wholeWord)
            toggleChip("Match case", isOn: matchCaseBinding)
            countBadge
        }
    }

    private var matchCaseBinding: Binding<Bool> {
        Binding(get: { !findCaseInsensitive }, set: { findCaseInsensitive = !$0 })
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .white.opacity(0.55))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: Patterns mode

    private var patternBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                TextField("Search patterns — preposition, email, passive…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.3))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))

            if !stack.isEmpty { stackChips }

            ScrollView(.vertical, showsIndicators: true) {
                if search.isEmpty { browseList } else { searchResults }
            }
            .frame(maxHeight: docName != nil ? 132 : 168)

            HStack { countBadge; Spacer(minLength: 0) }
        }
    }

    private var stackChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(stack.enumerated()), id: \.element) { index, slug in
                    if index > 0 {
                        Text("+").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.3))
                    }
                    chip(slug: slug, color: Self.palette[index % Self.palette.count])
                }
                Button { stackRaw = "" } label: {
                    Text("Clear").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
            .padding(.vertical, 1)
        }
    }

    private func chip(slug: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("/\(slug)").font(.system(size: 11, weight: .semibold, design: .rounded))
            Button { toggle(slug) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }.buttonStyle(.plain)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.16)))
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }

    private var browseList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(RegexPatternLibrary.topics, id: \.self) { topic in
                Button { toggleExpand(topic) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded.contains(topic) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 10)
                        Text(topic).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)

                if expanded.contains(topic) {
                    ForEach(RegexPatternLibrary.subtopics(in: topic), id: \.self) { sub in
                        Text(sub.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.leading, 16).padding(.top, 3)
                        ForEach(RegexPatternLibrary.patterns(topic: topic, subtopic: sub)) { pattern in
                            patternRow(pattern, showCount: false).padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }

    private var searchResults: some View {
        let results = RegexPatternLibrary.search(search)
        return VStack(alignment: .leading, spacing: 2) {
            if results.isEmpty {
                Text("No patterns match “\(search)”.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).padding(.vertical, 10)
            } else {
                ForEach(results) { pattern in patternRow(pattern, showCount: !isLargeDoc) }
            }
        }
    }

    private func patternRow(_ pattern: RegexPattern, showCount: Bool) -> some View {
        let selected = stack.contains(pattern.slug)
        return Button { toggle(pattern.slug) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 13)).foregroundStyle(selected ? Color.accentColor : .white.opacity(0.3))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(pattern.name).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                        Text("/\(pattern.slug)").font(.system(size: 10, weight: .regular, design: .rounded)).foregroundStyle(.white.opacity(0.32))
                    }
                    Text(pattern.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if showCount {
                    let n = counts[pattern.slug] ?? 0
                    Text("\(n)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(n > 0 ? Color.accentColor : .white.opacity(0.35))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.10) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var countBadge: some View {
        Text("\(highlights.count) match\(highlights.count == 1 ? "" : "es")")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(highlights.isEmpty ? .white.opacity(0.35) : Color.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            Text(highlightedText)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(.clear)
                .scrollContentBackground(.hidden)
                .tint(.white.opacity(0.6))
                .padding(.horizontal, 3).padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// Build the highlighted editor text from a source string and its matches.
    /// Called off the render path (after a matching pass), not in `body`, so a
    /// 12k-char inline doc isn't reallocated and re-styled on every keystroke.
    private static func buildHighlightedText(_ source: String, highlights: [Highlight]) -> AttributedString {
        var attributed = AttributedString(source)
        for highlight in highlights {
            guard let range = Range(highlight.range, in: source),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].backgroundColor = palette[highlight.colorIndex % palette.count].opacity(0.4)
        }
        return attributed
    }

    // MARK: Large document

    private var largeDocCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.45))
            VStack(spacing: 3) {
                Text("Large document")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(charCountText) characters — too long to preview inline.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                Text("\(highlights.count) match\(highlights.count == 1 ? "" : "es") for the current \(mode == .find ? "search" : "patterns")")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(highlights.isEmpty ? .white.opacity(0.4) : Color.accentColor)
                    .padding(.top, 1)
            }
            Button(action: exportHighlightedDoc) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Export highlighted .docx")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(highlights.isEmpty ? Color.white.opacity(0.25) : Color.white.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .disabled(highlights.isEmpty)
            if let docNotice {
                Text(docNotice)
                    .font(.system(size: 10))
                    .foregroundStyle(.green.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: Compute

    /// Schedule a debounced, off-actor matching pass. Every keystroke or toggle
    /// lands here; the actual regex work — over a span capped at `scanCap` — runs
    /// on a background queue, then hops back to the main actor to publish results,
    /// dropping any pass superseded by a newer one.
    private func recompute() {
        let source = sourceText
        let currentMode = mode
        let query = findQuery
        let whole = wholeWord
        let caseInsensitive = findCaseInsensitive
        let slugs = stack
        let searchQuery = search
        let large = isLargeDoc
        let cap = scanCap

        generation += 1
        let token = generation

        scheduler.schedule {
            let ns = source as NSString
            let full = NSRange(location: 0, length: min(ns.length, cap))
            var result: [Highlight] = []

            if currentMode == .find {
                if !query.isEmpty,
                   let regex = RegexPatternLibrary.literalRegex(query, wholeWord: whole, caseInsensitive: caseInsensitive) {
                    regex.enumerateMatches(in: source, range: full) { match, _, _ in
                        if let match, match.range.length > 0 { result.append(Highlight(range: match.range, colorIndex: 0)) }
                    }
                }
            } else {
                for (index, slug) in slugs.enumerated() {
                    guard let pattern = RegexPatternLibrary.pattern(slug: slug),
                          let regex = RegexPatternLibrary.regex(for: pattern) else { continue }
                    regex.enumerateMatches(in: source, range: full) { match, _, _ in
                        if let match, match.range.length > 0 { result.append(Highlight(range: match.range, colorIndex: index)) }
                    }
                }
            }

            // Per-row counts only for the patterns the current search shows, and
            // only for inline docs (the count badge is hidden for large docs).
            var newCounts: [String: Int] = [:]
            if !large && !searchQuery.isEmpty {
                let scannedText = ns.length > cap ? ns.substring(to: cap) : source
                for pattern in RegexPatternLibrary.search(searchQuery) {
                    newCounts[pattern.slug] = RegexPatternLibrary.count(of: pattern, in: scannedText)
                }
            }

            Task { @MainActor in
                guard token == generation else { return }
                highlights = result
                counts = newCounts
                // Rebuilt here (in a Task, off the render path) rather than in
                // `body`, so an inline doc isn't re-styled on every keystroke.
                if !large { highlightedText = Self.buildHighlightedText(source, highlights: result) }
            }
        }
    }

    // MARK: Mutations

    private func toggle(_ slug: String) {
        var current = stack
        if let index = current.firstIndex(of: slug) { current.remove(at: index) } else { current.append(slug) }
        stackRaw = current.joined(separator: ",")
    }

    private func toggleExpand(_ topic: String) {
        if expanded.contains(topic) { expanded.remove(topic) } else { expanded.insert(topic) }
    }

    // MARK: Documents

    private func uploadDoc() {
        let panel = NSOpenPanel()
        panel.title = "Choose a document"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.rtf, .plainText]
        if let docx = UTType(filenameExtension: "docx") { types.insert(docx, at: 0) }
        if let doc = UTType(filenameExtension: "doc") { types.append(doc) }
        panel.allowedContentTypes = types

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
            docName = url.lastPathComponent
            largeDocText = nil
            docNotice = "Couldn't read that document."
            return
        }
        let content = attributed.string
        docName = url.lastPathComponent
        docNotice = nil
        if content.count > inlineLimit {
            largeDocText = content        // keep it out of the editor; search exports a copy
        } else {
            largeDocText = nil
            text = content                // small enough to read and highlight inline
        }
        recompute()
    }

    private func clearDoc() {
        docName = nil
        largeDocText = nil
        docNotice = nil
        recompute()
    }

    /// Build a new .docx from the large document with every current match highlighted,
    /// then save it where the user chooses and open it.
    private func exportHighlightedDoc() {
        guard let docText = largeDocText, !highlights.isEmpty else { return }
        let attributed = NSMutableAttributedString(string: docText)
        let full = NSRange(location: 0, length: (docText as NSString).length)
        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: full)
        attributed.addAttribute(.foregroundColor, value: NSColor.black, range: full)
        // AppKit won't export a Word background highlight, so mark matches with bold +
        // a per-pattern color + underline — all of which survive the .docx round-trip.
        let boldFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .boldFontMask)
        for highlight in highlights {
            let color = Self.nsPalette[highlight.colorIndex % Self.nsPalette.count]
            attributed.addAttribute(.font, value: boldFont, range: highlight.range)
            attributed.addAttribute(.foregroundColor, value: color, range: highlight.range)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: highlight.range)
        }

        let save = NSSavePanel()
        save.title = "Save highlighted document"
        if let docx = UTType(filenameExtension: "docx") { save.allowedContentTypes = [docx] }
        let base = docName.map { ($0 as NSString).deletingPathExtension } ?? "document"
        save.nameFieldStringValue = "\(base)-highlighted.docx"

        NSApp.activate(ignoringOtherApps: true)
        guard save.runModal() == .OK, let url = save.url else { return }
        guard let data = try? attributed.data(
            from: full,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        ) else {
            docNotice = "Export failed."
            return
        }
        do {
            try data.write(to: url)
            docNotice = "Exported \(url.lastPathComponent)"
            NSWorkspace.shared.open(url)
        } catch {
            docNotice = "Couldn't save the file."
        }
    }
}

/// Debounces matching and runs it off the main actor, cancelling any pending
/// pass. The body hops back to the main actor itself to publish results.
private final class RegexScratchpadDebounce: ObservableObject {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    private let queue = DispatchQueue(label: "metamorphia.regex-scratchpad", qos: .userInitiated)

    init(delay: TimeInterval = 0.18) {
        self.delay = delay
    }

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
