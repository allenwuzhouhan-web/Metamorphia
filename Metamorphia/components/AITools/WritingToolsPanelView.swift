/*
 * Metamorphia – Intelligence Glass
 *
 * Interactive Writing Tools surface.
 *
 * Shows four verb buttons (Proofread, Rewrite, Summarize, Reply). On tap,
 * captures the current selection via TextFieldAccess, runs the model headlessly
 * (no notch summon), and presents the result with Replace / Copy actions.
 *
 * Font notes: result text uses .system(size:) — proportional San Francisco,
 * never monospaced.
 */

import SwiftUI

// MARK: - WritingToolsPanelView

struct WritingToolsPanelView: View {
    @StateObject private var model = WritingToolsPanelModel()
    var onDismiss: () -> Void

    var body: some View {
        LiquidGlassBackground(variant: .defaultVariant, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 10) {

                // Verb capsule row
                HStack(spacing: 8) {
                    ForEach(AIActionRunner.WritingVerb.allCases) { verb in
                        verbButton(verb)
                    }
                }

                // Result area
                if model.isRunning {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 8)
                        Spacer()
                    }
                } else if !model.result.isEmpty {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(model.result)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                    .frame(maxHeight: 220)

                    HStack(spacing: 8) {
                        Button("Replace") {
                            model.replace()
                            onDismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Copy") {
                            model.copyResult()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        if let errorMessage = model.errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 340)
        }
    }

    @ViewBuilder
    private func verbButton(_ verb: AIActionRunner.WritingVerb) -> some View {
        Button {
            model.invoke(verb)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: verb.iconSymbol)
                    .font(.system(size: 12))
                Text(verb.displayName)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(model.activeVerb == verb
                          ? Color.accentColor.opacity(0.25)
                          : Color.secondary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
    }
}

// MARK: - WritingToolsPanelModel

@MainActor
final class WritingToolsPanelModel: ObservableObject {
    @Published var isRunning = false
    @Published var result = ""
    @Published var errorMessage: String?
    @Published var activeVerb: AIActionRunner.WritingVerb?

    private var lastCapture: TextFieldAccess.Capture?
    private var runTask: Task<Void, Never>?

    func invoke(_ verb: AIActionRunner.WritingVerb) {
        runTask?.cancel()
        result = ""
        errorMessage = nil
        activeVerb = verb
        isRunning = true

        runTask = Task {
            guard let (capture, generated) = await AIActionRunner.generate(verb: verb) else {
                if !Task.isCancelled {
                    errorMessage = "Could not read selected text."
                    isRunning = false
                }
                return
            }
            guard !Task.isCancelled else { return }
            lastCapture = capture
            result = generated
            isRunning = false
        }
    }

    func replace() {
        guard let capture = lastCapture, !result.isEmpty else { return }
        TextFieldAccess.writeBack(result, to: capture)
    }

    func copyResult() {
        guard !result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }
}
