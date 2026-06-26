import SwiftUI
import AppKit
import MetamorphiaAgentKit

// MARK: - Translate Scratchpad
//
// A small translation surface backed by the app's configured LLM. Type (or seed
// from the clipboard), pick a target language, and stream the translation in.
// Copy the result with one tap. A missing API key (or any service error) shows
// inline — it never crashes.

/// A target language the user can translate into.
struct TranslateLanguageOption: Identifiable, Hashable {
    let id: String   // English name, used in the prompt.
    let flag: String

    static let all: [TranslateLanguageOption] = [
        .init(id: "English", flag: "🇬🇧"),
        .init(id: "Spanish", flag: "🇪🇸"),
        .init(id: "French", flag: "🇫🇷"),
        .init(id: "German", flag: "🇩🇪"),
        .init(id: "Italian", flag: "🇮🇹"),
        .init(id: "Portuguese", flag: "🇵🇹"),
        .init(id: "Chinese", flag: "🇨🇳"),
        .init(id: "Japanese", flag: "🇯🇵"),
        .init(id: "Korean", flag: "🇰🇷")
    ]
}

@MainActor public struct TranslateScratchpadView: View {
    @State private var source: String = ""
    @State private var translated: String = ""
    @State private var language: TranslateLanguageOption = TranslateLanguageOption.all[1] // Spanish
    @State private var isTranslating = false
    @State private var errorText: String?
    @State private var didCopy = false
    @State private var task: Task<Void, Never>?

    @FocusState private var sourceFocused: Bool

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            sourceEditor
            controls

            if let errorText {
                inlineError(errorText)
            }

            outputArea
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: seedFromClipboardIfEmpty)
        .onDisappear { task?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Translate")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
        }
    }

    // MARK: Source

    private var sourceEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(sourceFocused ? 0.22 : 0.1), lineWidth: 1)
                )

            if source.isEmpty {
                Text("Text to translate…")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $source)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .focused($sourceFocused)
        }
        .frame(height: 92)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TranslateLanguageOption.all) { option in
                    Button {
                        language = option
                    } label: {
                        Text("\(option.flag)  \(option.id)")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(language.flag)
                    Text(language.id)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            if isTranslating {
                Button(action: cancel) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button(action: translate) {
                    Label("Translate", systemImage: "arrow.right.circle.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(canTranslate ? .white : .white.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            (canTranslate ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canTranslate)
            }
        }
    }

    private var canTranslate: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Output

    private var outputArea: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            if translated.isEmpty && !isTranslating {
                Text("Translation appears here.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(12)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(translated.isEmpty ? " " : translated)
                        // Translation output is treated as data, so mono is allowed.
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
            }

            if !translated.isEmpty {
                copyButton
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var copyButton: some View {
        Button(action: copyResult) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(didCopy ? .green : .white.opacity(0.55))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08), in: Circle())
                .animation(.spring(response: 0.25), value: didCopy)
        }
        .buttonStyle(.plain)
        .help("Copy translation")
    }

    private func inlineError(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: Actions

    private func seedFromClipboardIfEmpty() {
        guard source.isEmpty else { return }
        if let clip = NSPasteboard.general.string(forType: .string),
           !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = clip
        }
    }

    private func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translated, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { didCopy = false }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        isTranslating = false
    }

    private func translate() {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        task?.cancel()
        errorText = nil
        translated = ""
        isTranslating = true
        sourceFocused = false

        let messages = [
            ChatMessage(
                role: "system",
                content: "Translate the user text to \(language.id). Output only the translation, with no preamble, quotes, or explanation."
            ),
            ChatMessage(role: "user", content: trimmed)
        ]

        task = Task {
            do {
                let events = LLMServiceManager.shared.currentService.streamChatRequest(
                    messages: messages,
                    tools: nil,
                    maxTokens: 1024
                )
                for try await event in events {
                    if Task.isCancelled { break }
                    switch event {
                    case .textDelta(let delta):
                        translated += delta
                    case .done:
                        break
                    case .toolCallStart, .toolCallDelta, .toolCallComplete:
                        continue
                    }
                }
                if !Task.isCancelled {
                    isTranslating = false
                    if translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errorText = "The model returned no translation. Please try again."
                    }
                }
            } catch {
                if !Task.isCancelled {
                    isTranslating = false
                    errorText = readableError(error)
                }
            }
        }
    }

    /// Turns a service error into a calm, actionable sentence. A missing API key
    /// is the most common case, so it gets a friendly nudge.
    private func readableError(_ error: Error) -> String {
        let described = error.localizedDescription
        let lowered = described.lowercased()
        if lowered.contains("api key") || lowered.contains("apikey") || lowered.contains("unauthorized") || lowered.contains("401") {
            return "No API key is configured for the current model. Add one in Settings, then try again."
        }
        if described.isEmpty {
            return "Translation failed. Please try again."
        }
        return described
    }
}
