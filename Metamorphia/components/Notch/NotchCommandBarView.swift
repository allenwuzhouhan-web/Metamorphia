import SwiftUI
import AppKit

/// Command Bar tab — renders inside the notch when
/// `coordinator.currentView == .commandBar`. There is no separate window;
/// open/close, position, and shape come from `MetamorphiaWindow` +
/// `MetamorphiaViewModel.open()/close()`.
///
/// Visual language mirrors Siri: a dark translucent panel with one
/// animated orb, the prompt field, and — when there's a response — a calm
/// body below. No gradients, no dividers, no halos. State is carried by
/// the orb alone so the panel never has to draw itself.
///
/// Structural open/close motion is owned by the notch container. This view
/// avoids a second entrance transform so command-bar summon uses the same
/// full-open mechanism as the music home surface.
struct NotchCommandBarView: View {
    @ObservedObject var viewModel: AICommandViewModel
    @EnvironmentObject var notchVM: MetamorphiaViewModel
    @FocusState private var inputFocused: Bool

    /// True while a file drag is hovering over the input row.
    @State private var isDragHovering: Bool = false

    /// Mirrors the AppKit text view's measured height so the row grows with
    /// wrapped lines instead of clipping them inside SwiftUI's multiline
    /// TextField layout.
    @State private var inputTextHeight: CGFloat = 25

    /// One spring for every structural change — enter, grow, shrink,
    /// response-arrived. Matches the notch's open/close spring so every
    /// motion lands on the same frame.
    private static let fluidSpring = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0)

    /// Quick fade for incidental state (suggestion list, trailing control
    /// swaps, status label changes). Short and axisless so it never reads
    /// as its own event.
    private static let quickFade = Animation.easeOut(duration: 0.2)

    /// Keeps the editable region clear of the notch's strong right-hand curve
    /// without shrinking the row so aggressively that prompt text wraps far
    /// earlier than the visible command bar edge.
    private static let trailingSafeInset: CGFloat = 44

    init(viewModel: AICommandViewModel) {
        self.viewModel = viewModel
    }

    private var hasResponse: Bool {
        viewModel.conversation.last != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
                .padding(.trailing, Self.trailingSafeInset)

#if canImport(MetamorphiaAgentKit)
            if !viewModel.slashSuggestions.isEmpty {
                SkillSuggestionListView(
                    suggestions: viewModel.slashSuggestions,
                    selectedIndex: viewModel.selectedSuggestionIndex,
                    onSelect: { suggestion in viewModel.insertSuggestion(suggestion) }
                )
                .padding(.top, 8)
                .transition(.opacity)
            }
#endif

            // MARK: - State-driven cards (T7/T8/… placeholders)
            stateDrivenSection

            if !viewModel.conversation.isEmpty {
                TranscriptView(viewModel: viewModel)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        // Tight bottom padding so the response bubble sits right above
        // the notch's bottom curve. The outer 12pt mainLayout padding +
        // 18pt shadow inset already give the bubble a comfortable
        // landing zone — anything more turns into dead black space.
        .padding(.bottom, hasResponse ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Measure the content height and publish it upward. The VM
        // debounces so the notch resizes in one spring pass instead of
        // per-keystroke stutter.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CommandBarContentHeightKey.self,
                    value: proxy.size.height
                )
            }
        )
        .onPreferenceChange(CommandBarContentHeightKey.self) { height in
            viewModel.updatePreferredHeight(height)
        }
        .onAppear {
            inputFocused = true
            // Phase 10: inject any staged response before the view renders
            // so the user sees it without a round-trip. The call is
            // synchronous on the MainActor and returns in < 1 ms.
            viewModel.consumeStagedResponse()
            // If a reviewed document's comments were cleared while we were away,
            // run the verification pass.
            viewModel.checkArmedRecheckOnAppear()
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
        .onExitCommand {
            if case .voiceListening = viewModel.inputBarState {
                // T5: voice-cancel path — preserve as-is.
                viewModel.voiceController?.cancel()
            } else if case .researchChoice = viewModel.inputBarState {
                // T7: dismiss research choice card; original text stays in currentInput.
                viewModel.cancelChoice()
            } else if case .browserChoice = viewModel.inputBarState {
                // T7: dismiss browser choice card; original text stays in currentInput.
                viewModel.cancelChoice()
            } else if case .purposeQuestion = viewModel.inputBarState {
                // Dismiss the purpose question; original text stays in currentInput.
                viewModel.cancelChoice()
            } else {
                CommandBarCoordinator.shared.dismiss()
            }
        }
        .animation(Self.fluidSpring, value: hasResponse)
        // Key on the coarse phase, not the full state — otherwise every streamed
        // token (which changes `streaming`'s payload) re-arms the spring across
        // the whole subtree and freezes the UI for the response's duration.
        .animation(Self.fluidSpring, value: viewModel.inputBarState.animationPhase)
        .animation(Self.fluidSpring, value: viewModel.currentAgent.id)
#if canImport(MetamorphiaAgentKit)
        .animation(Self.quickFade, value: viewModel.slashSuggestions.map(\.id))
        .animation(Self.fluidSpring, value: viewModel.pendingSkillProposal)
#endif
    }

    // MARK: - State-driven cards (T7/T8/… placeholders)

    @ViewBuilder
    private var stateDrivenSection: some View {
        switch viewModel.inputBarState {
        case .researchChoice(let query):
            ResearchChoiceCard(
                query: query,
                onPickDeep: { viewModel.submitResearch(query: query, mode: .deep) },
                onPickLight: { viewModel.submitResearch(query: query, mode: .light) },
                onCancel: { viewModel.cancelChoice() }
            )
        case .browserChoice(let query):
            BrowserChoiceCard(
                query: query,
                onPickVisible: { viewModel.submitBrowserTask(query: query, visible: true) },
                onPickBackground: { viewModel.submitBrowserTask(query: query, visible: false) },
                onCancel: { viewModel.cancelChoice() }
            )
        case .purposeQuestion(let question, let originalPrompt):
            PurposeQuestionCard(
                question: question,
                onSubmit: { purpose in
                    viewModel.submitReviewWithPurpose(originalPrompt: originalPrompt, purpose: purpose)
                },
                onCancel: { viewModel.cancelChoice() }
            )
        case .thoughtRecall:
            // TODO: T8 — ThoughtRecallCard.
            EmptyView()
        case .newsBriefing:
            // TODO: T9 — NewsBriefingCard.
            EmptyView()
        case .coworkingSuggestion:
            // TODO: T10 — CoworkingSuggestionCard.
            EmptyView()
        case .healthCard:
            // TODO: T11 — health check card.
            EmptyView()
        case .voiceListening(let partial):
            VoiceListeningRow(
                partial: partial,
                onCancel: { [weak viewModel] in
                    viewModel?.voiceController?.cancel()
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
            .padding(.top, 6)
        case .ready, .processing, .planning, .executing, .streaming,
             .result, .error:
            EmptyView()
        }
    }

    // MARK: - Stub warning

    private var stubWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange.opacity(0.85))
                .font(.system(size: 11))
            Text("AI backend not linked — rebuild with MetamorphiaAgentKit.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: CommandBarStateHelpers.icon(for: viewModel.inputBarState))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(CommandBarStateHelpers.iconColor(for: viewModel.inputBarState))
                    .animation(.spring(response: 0.3), value: viewModel.inputBarState.animationPhase)

                if viewModel.currentAgent.id != AgentProfile.general.id {
                    Circle()
                        .fill(viewModel.currentAgent.color)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5))
                        .offset(x: 2, y: -2)
                        .transition(.scale.combined(with: .opacity))
                    }
            }
            .frame(width: 18, height: 18)
            .padding(.top, 4)

            // Hide the agent pill when the user hasn't switched off the
            // default General profile — the label adds visual noise and
            // crowds the TextField on narrow notches. The state-icon dot
            // (rendered above) already signals the active agent for any
            // non-default selection.
            if viewModel.currentAgent.id != AgentProfile.general.id {
                AgentPickerView(
                    activeAgent: viewModel.currentAgent,
                    profiles: AgentRegistry.shared.allProfiles(),
                    onSelect: { viewModel.setActiveAgent($0) }
                )
                .transition(.opacity)
            }

            if !viewModel.attachedFiles.isEmpty {
                AttachmentBadgeView(
                    count: viewModel.attachedFiles.count,
                    onClear: { viewModel.clearAttachments() }
                )
                .transition(.scale.combined(with: .opacity))
                .padding(.top, 1)
            }

            if isEditable(viewModel.inputBarState) {
                ZStack(alignment: .topLeading) {
                    if viewModel.currentInput.isEmpty {
                        Text("Ask Metamorphia")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.white.opacity(0.28))
                            .padding(.top, 3)
                            .allowsHitTesting(false)
                    }

                    CommandBarPromptInput(
                        text: $viewModel.currentInput,
                        measuredHeight: $inputTextHeight,
                        isFocused: inputFocused,
                        onSubmit: submit,
                        onMoveUp: {
#if canImport(MetamorphiaAgentKit)
                            guard !viewModel.slashSuggestions.isEmpty else { return false }
                            viewModel.moveSelection(-1)
                            return true
#else
                            false
#endif
                        },
                        onMoveDown: {
#if canImport(MetamorphiaAgentKit)
                            guard !viewModel.slashSuggestions.isEmpty else { return false }
                            viewModel.moveSelection(1)
                            return true
#else
                            false
#endif
                        },
                        onTab: {
#if canImport(MetamorphiaAgentKit)
                            guard !viewModel.slashSuggestions.isEmpty else { return false }
                            return viewModel.acceptSelectedSuggestion()
#else
                            false
#endif
                        },
                        onReturn: {
#if canImport(MetamorphiaAgentKit)
                            guard !viewModel.slashSuggestions.isEmpty else { return false }
                            return viewModel.acceptSelectedSuggestion()
#else
                            false
#endif
                        },
                        onEscape: {
#if canImport(MetamorphiaAgentKit)
                            if !viewModel.slashSuggestions.isEmpty {
                                viewModel.currentInput += " "
                                return true
                            }
#endif
                            return false
                        }
                    )
                    .frame(height: inputTextHeight)
                }
                // Explicit fill so the editor always claims the
                // remaining horizontal room, even while empty.
                .frame(minHeight: inputTextHeight)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(CommandBarStateHelpers.statusText(for: viewModel.inputBarState))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            trailingControl
                .padding(.top, 4)
                .animation(Self.quickFade, value: viewModel.isProcessing)
                .animation(Self.quickFade, value: viewModel.currentInput.isEmpty)
        }
        .background(
            ShimmerOverlay(
                isActive: CommandBarStateHelpers.isShimmering(viewModel.inputBarState),
                colors: CommandBarStateHelpers.shimmerGradient(for: viewModel.inputBarState)
            )
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(0.35)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isDragHovering ? 0.6 : 0), lineWidth: 1.5)
                .animation(.easeOut(duration: 0.15), value: isDragHovering)
        )
        .onDrop(of: ["public.file-url"], isTargeted: $isDragHovering) { providers in
            handleFileDrop(providers)
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        var pendingURLs: [URL] = []
        let pendingURLsLock = NSLock()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    pendingURLsLock.lock(); pendingURLs.append(url); pendingURLsLock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            guard !pendingURLs.isEmpty else { return }
            viewModel.attachFiles(urls: pendingURLs)
        }
        return true
    }

    /// The field is editable in:
    ///   - `.ready` (user is composing)
    ///   - `.thoughtRecall` (later task — user can type over the recall prompt)
    ///   - `.result` / `.error` (T2 — the response lives in its own bubble
    ///     below, so the pill returns to the editable TextField immediately
    ///     so the user can type the next question without an extra tap or
    ///     keystroke to re-focus)
    /// Every other state shows the status label.
    private func isEditable(_ state: InputBarState) -> Bool {
        switch state {
        case .ready, .thoughtRecall, .result, .error: return true
        default: return false
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if viewModel.isProcessing {
            // Stop is the only mid-run affordance. Subtle glyph, no
            // filled-circle chrome competing with the orb.
            Button {
                Task { await viewModel.cancel() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .transition(.opacity)
        } else if !viewModel.currentInput.isEmpty {
            // Faint return glyph once there's text. Minimal disclosure
            // that Return submits — no filled send button.
            Image(systemName: "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 18, height: 18)
                .transition(.opacity)
        }
    }

    // MARK: - Helpers

    private func submit() {
        let prompt = viewModel.currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        Task {
            await viewModel.submit(prompt: prompt, systemPrompt: systemPromptForContext())
        }
    }

    private func systemPromptForContext() -> String {
        // Single source of truth — includes the user's actual macOS short
        // name and home directory so the agent can't invent fake user
        // paths and refuse to open the user's own files.
        AICommandViewModel.defaultSystemPrompt
    }
}

private struct VoiceListeningRow: View {
    let partial: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.purple.opacity(0.9))
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text(partial.isEmpty ? "Listening…" : partial)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Cancel voice listening (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.purple.opacity(0.12))
        )
    }
}
