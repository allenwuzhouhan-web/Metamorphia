import SwiftUI
import AppKit

/// Pure list-marker logic, kept free of AppKit so it reads (and reasons) like
/// plain data. A "list line" is `<indent><marker><space><body>`, where the
/// marker is either a bullet (`- ` / `* `) or an ordered token whose *style* is
/// decided by nesting depth — decimal → lower-alpha → lower-roman, then it
/// cycles. That depth-drives-style rule is what makes `1.` → `a.` → `i.` feel
/// automatic and sidesteps the "is `i.` alpha or roman?" ambiguity.
enum SmartList {
    /// Spaces per nesting level. Markers are always generated as multiples of it,
    /// so `leadingSpaces / width` is a reliable depth.
    static let indentUnit = "    "
    static let indentWidth = 4
    /// Don't let Tab runaway indentation past a sane outline depth.
    static let maxDepth = 8

    enum OrderedStyle { case decimal, lowerAlpha, lowerRoman }

    enum Kind: Equatable {
        case bullet(glyph: String)
        case ordered(style: OrderedStyle, ordinal: Int)
    }

    struct Line {
        var depth: Int
        var kind: Kind
        /// Everything after the marker and its trailing space.
        var body: String
        /// UTF-16 length of `<indent><marker><space>` — used to build NSRanges.
        var prefixLength: Int
    }

    static func style(forDepth depth: Int) -> OrderedStyle {
        switch ((depth % 3) + 3) % 3 {
        case 0: return .decimal
        case 1: return .lowerAlpha
        default: return .lowerRoman
        }
    }

    /// Parse one raw line into a list `Line`, or `nil` when it isn't a list item.
    static func parse(_ line: String) -> Line? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        let depth = leadingSpaces / indentWidth
        let afterIndent = String(line.dropFirst(leadingSpaces))

        // Bullet: "- " or "* "
        if afterIndent.hasPrefix("- ") || afterIndent.hasPrefix("* ") {
            let glyph = String(afterIndent.prefix(1))
            let body = String(afterIndent.dropFirst(2))
            let prefixLength = (line as NSString).length - (body as NSString).length
            return Line(depth: depth, kind: .bullet(glyph: glyph), body: body, prefixLength: prefixLength)
        }

        // Ordered: "<token>. " where token is digits / a letter / a roman numeral.
        guard let dotIndex = afterIndent.firstIndex(of: ".") else { return nil }
        let token = String(afterIndent[afterIndent.startIndex..<dotIndex])
        let afterDot = afterIndent[afterIndent.index(after: dotIndex)...]
        guard !token.isEmpty, afterDot.hasPrefix(" ") else { return nil }
        guard let (style, ordinal) = classify(token: token, depth: depth) else { return nil }

        let body = String(afterDot.dropFirst())
        let prefixLength = (line as NSString).length - (body as NSString).length
        return Line(depth: depth, kind: .ordered(style: style, ordinal: ordinal), body: body, prefixLength: prefixLength)
    }

    /// Classify an ordered token into (style, ordinal). Depth is a tiebreaker for
    /// the alpha-vs-roman overlap (a lone `i` is alpha at depth 1, roman at depth 2).
    private static func classify(token: String, depth: Int) -> (OrderedStyle, Int)? {
        if let n = Int(token), n > 0 { return (.decimal, n) }
        let lower = token.lowercased()
        let isRomanSet = !lower.isEmpty && lower.allSatisfy { "ivxlcdm".contains($0) }
        let isAlpha = lower.allSatisfy { $0.isLetter } && lower.count == 1

        if isRomanSet, style(forDepth: depth) == .lowerRoman, let r = romanToInt(lower) {
            return (.lowerRoman, r)
        }
        if isAlpha, let scalar = lower.unicodeScalars.first {
            return (.lowerAlpha, Int(scalar.value) - 96) // 'a' -> 1
        }
        if isRomanSet, let r = romanToInt(lower) { return (.lowerRoman, r) }
        return nil
    }

    /// Render an ordered marker (without indent) as `"<token>. "`.
    static func orderedMarker(style: OrderedStyle, ordinal: Int) -> String {
        let token: String
        switch style {
        case .decimal: token = "\(max(1, ordinal))"
        case .lowerAlpha: token = alpha(ordinal)
        case .lowerRoman: token = intToRoman(ordinal).lowercased()
        }
        return token + ". "
    }

    /// The full marker (with indent) that should *begin the next line* after `line`.
    static func continuationMarker(after line: Line) -> String {
        let indent = String(repeating: indentUnit, count: line.depth)
        switch line.kind {
        case .bullet(let glyph):
            return indent + glyph + " "
        case .ordered(let style, let ordinal):
            return indent + orderedMarker(style: style, ordinal: ordinal + 1)
        }
    }

    // MARK: Ordinal lookup for re-leveling

    /// The next ordinal for an ordered item newly placed at `depth`, by scanning
    /// previous lines for the nearest sibling at the same depth.
    static func nextOrdinal(forDepth depth: Int, aboveLineIndex index: Int, in lines: [String]) -> Int {
        var i = index - 1
        while i >= 0 {
            guard let parsed = parse(lines[i]) else {
                // A blank or non-list line only breaks the run when at/left of us.
                if lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i -= 1; continue }
                break
            }
            if parsed.depth < depth { break }
            if parsed.depth == depth, case .ordered(_, let ordinal) = parsed.kind {
                return ordinal + 1
            }
            i -= 1
        }
        return 1
    }

    // MARK: Numeral helpers

    static func alpha(_ n: Int) -> String {
        var value = max(1, n)
        var result = ""
        while value > 0 {
            value -= 1
            let scalar = UnicodeScalar(97 + (value % 26))!
            result = String(Character(scalar)) + result
            value /= 26
        }
        return result
    }

    static func intToRoman(_ n: Int) -> String {
        guard n > 0 else { return "I" }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
        ]
        var value = n
        var result = ""
        for (amount, symbol) in table {
            while value >= amount { result += symbol; value -= amount }
        }
        return result
    }

    static func romanToInt(_ s: String) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        let chars = Array(s.lowercased())
        var total = 0
        for (idx, ch) in chars.enumerated() {
            guard let v = values[ch] else { return nil }
            if idx + 1 < chars.count, let next = values[chars[idx + 1]], v < next {
                total -= v
            } else {
                total += v
            }
        }
        return total > 0 ? total : nil
    }
}

/// A light handle the SwiftUI parent holds to observe the current selection and
/// drop transformed text back in — the seam the inline Writing Tools ride on.
final class SmartListController: ObservableObject {
    @Published var selectedText: String = ""
    fileprivate weak var textView: NSTextView?

    /// Replace the current selection (used by Writing Tools "Replace"), keeping
    /// the result selected so a follow-up action can chain.
    func replaceSelection(with newText: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: newText) else { return }
        tv.replaceCharacters(in: range, with: newText)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location, length: (newText as NSString).length))
    }
}

/// An NSTextView that renders regular (non-monospaced) text and whispers the next
/// list marker just below the caret line, so the outline structure previews
/// before you commit to it.
final class SmartListNSTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGhostMarker()
    }

    private func drawGhostMarker() {
        guard selectedRange().length == 0,
              let lm = layoutManager,
              let tc = textContainer,
              let font = self.font else { return }

        let ns = string as NSString
        let caret = selectedRange().location
        guard caret <= ns.length else { return }
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let lineText = ns.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
        guard let parsed = SmartList.parse(lineText), !parsed.body.isEmpty else { return }

        let ghost = SmartList.continuationMarker(after: parsed)
        let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        let lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let origin = CGPoint(
            x: textContainerOrigin.x + lineRect.minX,
            y: textContainerOrigin.y + lineRect.maxY
        )
        let color = (textColor ?? .white).withAlphaComponent(0.30)
        (ghost as NSString).draw(at: origin, withAttributes: [
            .font: font,
            .foregroundColor: color
        ])
    }
}

/// A SwiftUI wrapper over `SmartListNSTextView` that turns the plain notes field
/// into a leveled-list editor: Enter continues and increments the marker, an
/// empty item exits the list, and Tab / Shift-Tab change nesting depth (which
/// re-styles the marker `1.` → `a.` → `i.`).
struct SmartListTextView: NSViewRepresentable {
    @Binding var text: String
    var controller: SmartListController? = nil
    var fontSize: CGFloat = 13
    var textColor: NSColor = .white
    var isEditable: Bool = true
    var autofocus: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        // Swap in our ghost-drawing subclass, wired to the same text storage.
        let base = scroll.documentView as! NSTextView
        let textView = SmartListNSTextView(frame: base.frame, textContainer: base.textContainer)
        scroll.documentView = textView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = textColor
        textView.insertionPointColor = textColor.withAlphaComponent(0.8)
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        controller?.textView = textView

        if autofocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let clamped = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }
        if controller?.textView !== textView { controller?.textView = textView }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: SmartListTextView

        init(_ parent: SmartListTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true // refresh the ghost marker
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if let controller = parent.controller {
                let range = textView.selectedRange()
                controller.selectedText = (textView.string as NSString).substring(with: range)
            }
            textView.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return handleNewline(textView)
            case #selector(NSResponder.insertTab(_:)):
                return handleIndent(textView, delta: +1)
            case #selector(NSResponder.insertBacktab(_:)):
                return handleIndent(textView, delta: -1)
            default:
                return false
            }
        }

        // MARK: List behavior

        private func handleNewline(_ textView: NSTextView) -> Bool {
            let selected = textView.selectedRange()
            guard selected.length == 0 else { return false }

            let ns = textView.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: selected.location, length: 0))
            let lineText = ns.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
            guard let parsed = SmartList.parse(lineText) else { return false }

            if parsed.body.isEmpty {
                // Empty item + Enter exits the list: drop the marker, leave a blank line.
                let markerRange = NSRange(location: lineRange.location, length: parsed.prefixLength)
                guard textView.shouldChangeText(in: markerRange, replacementString: "") else { return true }
                textView.replaceCharacters(in: markerRange, with: "")
                textView.didChangeText()
                return true
            }

            // Continue the list on the next line with the incremented marker.
            let insertion = "\n" + SmartList.continuationMarker(after: parsed)
            textView.insertText(insertion, replacementRange: selected)
            Haptics.tick()
            return true
        }

        private func handleIndent(_ textView: NSTextView, delta: Int) -> Bool {
            let selected = textView.selectedRange()
            let ns = textView.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: selected.location, length: 0))
            let lineText = ns.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
            guard let parsed = SmartList.parse(lineText) else { return false }

            let newDepth = max(0, min(SmartList.maxDepth, parsed.depth + delta))
            if newDepth == parsed.depth { return true }

            let indent = String(repeating: SmartList.indentUnit, count: newDepth)
            let newMarker: String
            switch parsed.kind {
            case .bullet(let glyph):
                newMarker = indent + glyph + " "
            case .ordered:
                let lines = textView.string.components(separatedBy: "\n")
                let lineIndex = lineIndexOfCaret(in: ns, lineStart: lineRange.location)
                let style = SmartList.style(forDepth: newDepth)
                let ordinal = SmartList.nextOrdinal(forDepth: newDepth, aboveLineIndex: lineIndex, in: lines)
                newMarker = indent + SmartList.orderedMarker(style: style, ordinal: ordinal)
            }

            let oldPrefixRange = NSRange(location: lineRange.location, length: parsed.prefixLength)
            guard textView.shouldChangeText(in: oldPrefixRange, replacementString: newMarker) else { return true }
            textView.replaceCharacters(in: oldPrefixRange, with: newMarker)
            textView.didChangeText()

            // Keep the caret in the body where it was, shifted by the marker delta.
            let deltaLen = (newMarker as NSString).length - parsed.prefixLength
            let newCaret = max(lineRange.location, selected.location + deltaLen)
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            Haptics.select()
            return true
        }

        /// Which element of the "\n"-split lines the caret sits on.
        private func lineIndexOfCaret(in ns: NSString, lineStart: Int) -> Int {
            guard lineStart > 0 else { return 0 }
            return ns.substring(to: lineStart).components(separatedBy: "\n").count - 1
        }
    }
}
