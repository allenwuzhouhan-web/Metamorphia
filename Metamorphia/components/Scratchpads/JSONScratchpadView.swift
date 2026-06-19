import SwiftUI
import AppKit

/// A JSON formatter / validator sized for the floating notch panel.
///
/// Edit JSON in the editor; Format pretty-prints with 2-space indents,
/// Minify collapses it, and Copy puts the current text on the pasteboard.
/// Validity is checked live: a green chip when parsable, a red parse error
/// (with the underlying message) when not. A collapsible tree of the parsed
/// value is shown when valid. All parsing goes through JSONSerialization and
/// is fully guarded — malformed input shows an error, never crashes.
@MainActor public struct JSONScratchpadView: View {
    @State private var text: String = """
    {
      "name": "Metamorphia",
      "ok": true,
      "tags": ["regex", "json"],
      "count": 2
    }
    """
    @State private var showCopied = false
    @State private var showTree = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionBar
            statusChip
            editor
            if showTree, case .success(let value) = validation {
                Divider().overlay(Color.white.opacity(0.08))
                treeView(for: value)
            }
        }
        .padding(14)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 6) {
            JSONScratchpadAction(symbol: "text.alignleft", title: "Format", action: format)
            JSONScratchpadAction(symbol: "arrow.down.right.and.arrow.up.left", title: "Minify", action: minify)
            JSONScratchpadAction(
                symbol: showCopied ? "checkmark" : "doc.on.doc",
                title: showCopied ? "Copied" : "Copy",
                tint: showCopied ? .green : nil,
                action: copy
            )
            Spacer(minLength: 0)
            treeToggle
        }
    }

    private var treeToggle: some View {
        Button {
            showTree.toggle()
        } label: {
            Image(systemName: showTree ? "list.bullet.indent" : "list.bullet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(showTree ? Color.accentColor : .white.opacity(0.5))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .help(showTree ? "Hide tree" : "Show tree")
        .disabled({ if case .success = validation { return false } else { return true } }())
    }

    // MARK: Status

    private var statusChip: some View {
        HStack(spacing: 6) {
            switch validation {
            case .empty:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.white.opacity(0.4))
                Text("Paste or type JSON")
                    .foregroundStyle(.white.opacity(0.45))
            case .success:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Valid JSON")
                    .foregroundStyle(.green.opacity(0.9))
            case .failure(let message):
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(statusFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(statusStroke, lineWidth: 1)
        )
    }

    private var statusFill: Color {
        switch validation {
        case .empty: return Color.white.opacity(0.04)
        case .success: return Color.green.opacity(0.08)
        case .failure: return Color.red.opacity(0.08)
        }
    }

    private var statusStroke: Color {
        switch validation {
        case .empty: return Color.white.opacity(0.08)
        case .success: return Color.green.opacity(0.2)
        case .failure: return Color.red.opacity(0.2)
        }
    }

    // MARK: Editor

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.white.opacity(0.92))
            .scrollContentBackground(.hidden)
            .tint(.white.opacity(0.7))
            .frame(minHeight: 150, maxHeight: 220)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: Tree

    @ViewBuilder
    private func treeView(for value: Any) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tree")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                JSONTreeNode(key: nil, value: value, depth: 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: Derived validation

    private enum JSONScratchpadResult {
        case empty
        case success(Any)
        case failure(String)
    }

    /// Live parse result. JSONSerialization with `.fragmentsAllowed` so bare
    /// scalars (e.g. `42`, `"hi"`) validate too, matching common expectations.
    private var validation: JSONScratchpadResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let data = text.data(using: .utf8) else {
            return .failure("Text is not valid UTF-8.")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .success(object)
        } catch {
            return .failure((error as NSError).localizedDescription)
        }
    }

    // MARK: Actions

    private func format() {
        guard case .success(let value) = validation else { return }
        guard JSONSerialization.isValidJSONObject(value) || isFragment(value) else { return }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options),
              var pretty = String(data: data, encoding: .utf8)
        else { return }
        // Foundation pretty-prints with 4 spaces; normalize to 2.
        pretty = reindentToTwoSpaces(pretty)
        text = pretty
    }

    private func minify() {
        guard case .success(let value) = validation else { return }
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options),
              let compact = String(data: data, encoding: .utf8)
        else { return }
        text = compact
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }

    private func isFragment(_ value: Any) -> Bool {
        !(value is [Any]) && !(value is [String: Any])
    }

    /// Converts Foundation's 4-space pretty-print indentation to 2 spaces by
    /// rewriting each line's leading-space run (which is always a multiple of 4).
    private func reindentToTwoSpaces(_ source: String) -> String {
        source
            .split(separator: Character("\n"), omittingEmptySubsequences: false)
            .map { line -> String in
                let leading = line.prefix { $0 == " " }.count
                let rest = line.dropFirst(leading)
                let levels = leading / 4
                return String(repeating: "  ", count: levels) + String(rest)
            }
            .joined(separator: "\n")
    }
}

// MARK: - Action button

private struct JSONScratchpadAction: View {
    let symbol: String
    let title: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint ?? .white.opacity(0.8))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tree node

/// One recursive row of the parsed-value tree. Containers (object/array) are
/// collapsible; scalars render inline with a type-tinted value.
private struct JSONTreeNode: View {
    let key: String?
    let value: Any
    let depth: Int

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let children = childRows {
                disclosureRow(childCount: children.count)
                if isExpanded {
                    ForEach(children.indices, id: \.self) { index in
                        JSONTreeNode(key: children[index].key,
                                     value: children[index].value,
                                     depth: depth + 1)
                    }
                }
            } else {
                scalarRow
            }
        }
    }

    private func disclosureRow(childCount: Int) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                indent
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 10)
                if let key {
                    Text(key)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(containerLabel(childCount: childCount))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
    }

    private var scalarRow: some View {
        HStack(spacing: 4) {
            indent
            Color.clear.frame(width: 10, height: 1)
            if let key {
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text(":")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(scalarText)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(scalarColor)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var indent: some View {
        Color.clear.frame(width: CGFloat(depth) * 12, height: 1)
    }

    // MARK: Value classification

    /// Child rows for a container, or nil for a scalar/leaf.
    private var childRows: [(key: String?, value: Any)]? {
        if let dict = value as? [String: Any] {
            return dict.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
        }
        if let array = value as? [Any] {
            return array.enumerated().map { (key: "[\($0.offset)]", value: $0.element) }
        }
        return nil
    }

    private func containerLabel(childCount: Int) -> String {
        if value is [String: Any] {
            return "{ \(childCount) }"
        }
        return "[ \(childCount) ]"
    }

    private var scalarText: String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            // Distinguish booleans from numbers via the boxed type encoding.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let string = value as? String {
            return "\"\(string)\""
        }
        return String(describing: value)
    }

    private var scalarColor: Color {
        if value is NSNull { return .white.opacity(0.4) }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .orange.opacity(0.9)
        }
        if value is NSNumber { return .cyan.opacity(0.85) }
        if value is String { return .green.opacity(0.8) }
        return .white.opacity(0.8)
    }
}
