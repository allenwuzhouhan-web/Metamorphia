import SwiftUI
import AppKit

// MARK: - Streaming phase

/// Where a run currently sits. The footer and progress indicator key off this
/// so we never offer Replace before a stream has actually finished.
enum WritingToolsResultPhase: Equatable {
    case idle          // no action chosen yet
    case streaming     // tokens arriving
    case finished      // stream completed cleanly
    case failed(String) // readable error message
}

// MARK: - Model

/// Owns the live state for one Writing Tools session: which action is selected,
/// the text accumulated from the stream, the current phase, and the in-flight
/// streaming task. Kept on the main actor since it drives SwiftUI directly and
/// touches `TextFieldAccess` (also main-actor).
@MainActor
final class WritingToolsModel: ObservableObject {
    @Published private(set) var selectedAction: AIAction?
    @Published private(set) var resultText: String = ""
    @Published private(set) var phase: WritingToolsResultPhase = .idle

    /// The text the panel was opened on (selection, or window text for summarize).
    let input: String
    /// Extra reference material handed to the model (used by Smart Reply).
    let context: String?

    /// The active stream consumer. Cancelled when a new action starts or the
    /// panel goes away so we never write into a dead view.
    private var streamTask: Task<Void, Never>?

    init(input: String, context: String?) {
        self.input = input
        self.context = context
    }

    /// True once a finished, non-empty result for a replacing action is ready.
    var canReplace: Bool {
        guard case .finished = phase,
              let action = selectedAction, action.replacesSelection else { return false }
        return !trimmedResult.isEmpty
    }

    /// True when there is finished text worth copying.
    var canCopy: Bool {
        guard case .finished = phase else { return false }
        return !trimmedResult.isEmpty
    }

    var isStreaming: Bool {
        if case .streaming = phase { return true }
        return false
    }

    var trimmedResult: String {
        resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Start (or restart) a run for `action`. Safe to call repeatedly; any
    /// in-flight stream is cancelled first.
    func run(_ action: AIAction) {
        streamTask?.cancel()

        selectedAction = action
        resultText = ""
        phase = .streaming

        let input = self.input
        let context = self.context

        streamTask = Task { [weak self] in
            do {
                for try await chunk in AIActionRunner.stream(action: action, input: input, context: context) {
                    if Task.isCancelled { return }
                    self?.resultText += chunk
                }
                if Task.isCancelled { return }
                guard let self else { return }
                // Treat an empty completion the same way the runner's one-shot
                // path does, so the user gets a real message instead of a blank box.
                if self.trimmedResult.isEmpty {
                    self.phase = .failed(AIActionError.emptyResult.errorDescription ?? "No text was returned.")
                } else {
                    self.phase = .finished
                }
            } catch is CancellationError {
                // Superseded by a newer run or torn down; leave state alone.
            } catch {
                if Task.isCancelled { return }
                self?.phase = .failed(Self.readableMessage(for: error))
            }
        }
    }

    /// Re-run the currently selected action.
    func regenerate() {
        guard let action = selectedAction else { return }
        run(action)
    }

    /// Stop any in-flight work. Call from the view's `onDisappear`.
    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Turn an arbitrary error into something safe to show. Falls back to the
    /// localized description, then a generic line, so an LLM/network failure
    /// (e.g. a missing API key) surfaces as readable text rather than a crash.
    private static func readableMessage(for error: Error) -> String {
        let localized = error.localizedDescription
        if !localized.isEmpty { return localized }
        return "Something went wrong. Please try again."
    }
}

// MARK: - Panel

/// Floating Writing Tools panel: pick an action, watch the result stream in,
/// then Replace / Copy / Regenerate / Done. Matches the app's dark, rounded,
/// glassy notch language. The host (an NSPanel) handles presentation; this view
/// only reports the chosen result back through `onReplace`.
@MainActor
public struct WritingToolsPanelView: View {
    @StateObject private var model: WritingToolsModel

    /// Called with the finished result when the user taps Replace.
    private let onReplace: (String) -> Void
    /// Called when the user dismisses the panel (Done / close button).
    private let onClose: () -> Void

    @State private var didCopy = false

    /// - Parameters:
    ///   - initialText: The selected text, or the window text for summarize-style
    ///     actions — the primary subject of every transform.
    ///   - sourceContext: Extra reference material (used by Smart Reply).
    ///   - onReplace: Invoked with the chosen result; the host writes it back via
    ///     `TextFieldAccess.replaceSelection`.
    ///   - onClose: Invoked to dismiss the panel.
    public init(
        initialText: String,
        sourceContext: String? = nil,
        onReplace: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: WritingToolsModel(input: initialText, context: sourceContext))
        self.onReplace = onReplace
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actionBar
            Divider().overlay(Color.white.opacity(0.08))
            resultArea
            footer
        }
        .padding(16)
        .frame(width: 380)
        .background(panelBackground)
        .onDisappear { model.cancel() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Writing Tools")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            Text(sourcePreview)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !TextFieldAccess.isTrusted {
                Label(
                    "Enable Accessibility in System Settings to replace text in place.",
                    systemImage: "lock.shield"
                )
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.orange.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A short, single-line-ish preview of the text being worked on.
    private var sourcePreview: String {
        let collapsed = model.input
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "No text selected." }
        let limit = 140
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    // MARK: Action bar

    private var actionBar: some View {
        AITaskGridLayout(spacing: 8, lineSpacing: 8) {
            ForEach(AIAction.allCases) { action in
                AIActionChipButton(
                    action: action,
                    isSelected: model.selectedAction == action,
                    isBusy: model.selectedAction == action && model.isStreaming
                ) {
                    model.run(action)
                }
            }
        }
    }

    // MARK: Result area

    @ViewBuilder
    private var resultArea: some View {
        switch model.phase {
        case .idle:
            placeholder

        case .streaming, .finished:
            ScrollView {
                // While tokens are arriving, render plain text: parsing markdown
                // on every streamed chunk is quadratic main-thread work. We build
                // the markdown AttributedString once, when the stream finishes.
                Group {
                    if model.isStreaming {
                        AIToolsStreamingText(text: model.resultText.isEmpty ? " " : model.resultText)
                    } else {
                        AIToolsMarkdownText(text: model.resultText.isEmpty ? " " : model.resultText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 60, maxHeight: 220)
            .overlay(alignment: .topLeading) {
                if model.isStreaming {
                    streamingIndicator
                }
            }

        case .failed(let message):
            errorView(message)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
            Text("Choose an action to transform your text.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    /// Subtle "working" pill shown while tokens arrive. Sits above the streamed
    /// text rather than blocking it, so the user sees progress immediately.
    private var streamingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
            Text("Writing…")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.white.opacity(0.08))
        )
        .padding(6)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // Replace — only for replacing actions, only once finished.
            if let action = model.selectedAction, action.replacesSelection {
                Button {
                    onReplace(model.trimmedResult)
                } label: {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(WritingToolsPrimaryButtonStyle())
                .disabled(!model.canReplace)
                .help("Replace your selection with this text")
            }

            Button {
                copyResult()
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(WritingToolsSecondaryButtonStyle())
            .disabled(!model.canCopy)
            .help("Copy the result")

            Button {
                model.regenerate()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .buttonStyle(WritingToolsSecondaryButtonStyle())
            .disabled(model.selectedAction == nil || model.isStreaming)
            .help("Run the action again")

            Spacer(minLength: 0)

            Button("Done") { onClose() }
                .buttonStyle(WritingToolsSecondaryButtonStyle())
        }
    }

    private func copyResult() {
        let text = model.trimmedResult
        guard !text.isEmpty else { return }
        TextFieldAccess.copyToPasteboard(text)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }

    // MARK: Chrome

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

// MARK: - Action chip

/// One tappable action (icon + title). Highlights when selected and shows a
/// small spinner while its own run is streaming.
private struct AIActionChipButton: View {
    let action: AIAction
    let isSelected: Bool
    let isBusy: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: action.systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(action.title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(isSelected ? 0.16 : 0.07))
            )
            .overlay(
                Capsule().strokeBorder(
                    Color.white.opacity(isSelected ? 0.28 : 0.10),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(action.title)
    }
}

// MARK: - Streaming result text

/// Plain-text rendering used *while tokens are still arriving*. Re-parsing
/// markdown on every chunk is quadratic main-thread work, so we skip it during
/// the stream and only build the markdown AttributedString once the run
/// finishes (see `AIToolsMarkdownText`). Styling matches the finished view so
/// the swap is visually seamless.
private struct AIToolsStreamingText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Markdown result text

/// Best-effort markdown rendering for the finished result. Full-block markdown
/// (tables, lists) is parsed when possible so List/Table actions read well;
/// if parsing fails we fall back to plain text. Only used once the stream has
/// completed, so the parse runs a single time rather than per token.
private struct AIToolsMarkdownText: View {
    let text: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: .init(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.system(size: 12, weight: .regular, design: .rounded))
        .foregroundStyle(.white.opacity(0.92))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Button styles

/// Filled accent button for the primary Replace action.
private struct WritingToolsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.4))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.65 : 0.85) : 0.18)
                )
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// Quiet glass button for secondary footer actions.
private struct WritingToolsSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(isEnabled ? Color.white.opacity(0.85) : Color.white.opacity(0.3))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(isEnabled ? 0.12 : 0.06), lineWidth: 1)
            )
            .contentShape(Capsule())
    }
}

// MARK: - Wrapping layout for action chips

/// Flows the action chips across as many rows as needed, left-aligned. A local
/// copy so the panel doesn't depend on layouts defined elsewhere in the target.
private struct AITaskGridLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + lineSpacing
                maxRowWidth = max(maxRowWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth - spacing)
        return CGSize(width: max(maxRowWidth, 0), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
