import SwiftUI
import AppKit
import MetamorphiaAgentKit

/// Scrollable transcript of all conversation turns. Every past turn stays
/// visible; only the last turn is "live" (and only while the FSM is in a
/// non-ready state). Live streaming turns show `StreamingResponseText`;
/// terminal turns show `ResultBubbleView` / `ErrorBubbleView` gated on
/// `isLive` so past turns never get haptics, glow, or auto-dismiss.
struct TranscriptView: View {
    @ObservedObject var viewModel: AICommandViewModel

    /// Measured natural height of the transcript content. Drives the outer
    /// ScrollView's frame so it hugs short content (no black gap between
    /// input row and response) and only claims `transcriptMaxHeight` when
    /// the content would actually overflow it.
    @State private var measuredContentHeight: CGFloat = 0

    /// FSM is in any non-ready state = the last turn is "live".
    private var hasActiveFSM: Bool {
        switch viewModel.inputBarState {
        case .ready: return false
        default: return true
        }
    }

    /// Ceiling for the scrollable transcript area, sized to fit inside
    /// the half-screen window cap enforced by
    /// `AppDelegate.calculateRequiredNotchSize` (commandBar branch).
    /// Half of visible − 20 (the window cap) − ~120pt of chrome (header,
    /// input row, paddings, corner clearance, shadow). Beyond this the
    /// inner ScrollView scrolls.
    private var transcriptMaxHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 900
        return max(120, (visible - 20) / 2 - 120)
    }

    /// Effective transcript height: hug content when small, cap at
    /// `transcriptMaxHeight` when content would overflow. Without this, a
    /// SwiftUI ScrollView with `.frame(maxHeight:)` greedily claims the
    /// full max in its scroll axis, leaving a tall black gap below short
    /// responses.
    private var effectiveTranscriptHeight: CGFloat {
        if viewModel.isResponseCompacted { return 44 }
        let measured = max(measuredContentHeight, 1)
        return min(measured, transcriptMaxHeight)
    }

    /// A turn is "research" if the user explicitly picked the research
    /// choice card (prompt re-entered with `[deep research]` /
    /// `[light research]`). These prompts are long-running and yield
    /// structured documents, so the Word-doc affordance is always shown.
    private func isResearchTurn(_ turn: AICommandViewModel.Turn) -> Bool {
        turn.prompt.hasPrefix("[deep research] ") ||
        turn.prompt.hasPrefix("[light research] ")
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if !viewModel.conversation.isEmpty {
                    clearHeader
                }
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(viewModel.conversation.enumerated()), id: \.element.id) { idx, turn in
                            turnRow(turn: turn, isLast: idx == viewModel.conversation.count - 1)
                                .id(turn.id)
                        }
                    }
                    .padding(.vertical, 4)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TranscriptContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                }
                .frame(height: effectiveTranscriptHeight)
                .onPreferenceChange(TranscriptContentHeightKey.self) { value in
                    if abs(measuredContentHeight - value) > 0.5 {
                        measuredContentHeight = value
                    }
                }
            }
            .onChange(of: viewModel.conversation.count) { _, _ in
                if let last = viewModel.conversation.last {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.conversation.last?.result ?? "") { _, _ in
                guard let last = viewModel.conversation.last, last.isStreaming else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.conversation.last?.isStreaming ?? false) { _, stillStreaming in
                if !stillStreaming, let last = viewModel.conversation.last {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Clear header

    private var clearHeader: some View {
        HStack {
            Spacer()
            Button {
                viewModel.clearConversation()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .medium))
                    Text("Clear")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Clear conversation")
        }
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    // MARK: - Turn row

    @ViewBuilder
    private func turnRow(turn: AICommandViewModel.Turn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            promptLabel(turn.prompt)
            bubble(turn: turn, isLast: isLast)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func promptLabel(_ prompt: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "text.bubble")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 2)
            Text(prompt)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Bubble selection

    @ViewBuilder
    private func bubble(turn: AICommandViewModel.Turn, isLast: Bool) -> some View {
        let isLive = isLast && hasActiveFSM
        let isErrorTurn = turn.isError ||
            (isLive && { if case .error = viewModel.inputBarState { return true } else { return false } }())

        if isLive && turn.isStreaming {
            liveStreamingBody(turn: turn)
        } else if isErrorTurn {
            let message: String = {
                if isLive, case .error(let m) = viewModel.inputBarState { return m }
                return turn.result
            }()
            ErrorBubbleView(
                message: message,
                agentTree: isLive ? viewModel.agentTree : nil,
                trace: turn.trace,
                isLive: isLive,
                onDismiss: { viewModel.clearConversation() }
            )
        } else {
            let message: String = {
                if isLive, case .result(let m) = viewModel.inputBarState { return m }
                return turn.result
            }()
            if message.isEmpty, !isLive {
                if let content = turn.richContent {
                    richContentView(content, turnID: turn.id)
                } else {
                    EmptyView()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ResultBubbleView(
                        message: message,
                        agentTree: isLive ? viewModel.agentTree : nil,
                        trace: turn.trace,
                        isLive: isLive,
                        isResearchResult: isResearchTurn(turn),
                        onDismiss: { viewModel.clearConversation() },
                        onOpenAsDocument: {
                            viewModel.openLastResultAsDocument(turnID: turn.id)
                        }
                    )
                    if let content = turn.richContent {
                        richContentView(content, turnID: turn.id)
                    }
                }
            }
        }
    }

    // MARK: - Live streaming body

    @ViewBuilder
    private func liveStreamingBody(turn: AICommandViewModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turn.result.isEmpty {
                StreamingResponseText(text: turn.result)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !turn.toolPills.isEmpty {
                toolPillStack(turn.toolPills)
            }
            if let content = turn.richContent {
                richContentView(content, turnID: turn.id)
                    .transition(.opacity)
            }
        }
    }

    private func richContentView(_ content: RichTurnContent, turnID: UUID) -> RichTurnContentView {
        RichTurnContentView(
            content: content,
            onDocumentReviewAction: { action in
                await viewModel.handleRichContentAction(turnID: turnID, action: action)
            },
            onDocumentRecheck: {
                await viewModel.handleRecheck(turnID: turnID)
            },
            onPowerPointRewriteAction: { action in
                await viewModel.handlePowerPointRewriteAction(turnID: turnID, action: action)
            },
            onPowerPointDesignAction: { action in
                await viewModel.handlePowerPointDesignAction(turnID: turnID, action: action)
            },
            onPowerPointDirectEditAction: { action in
                await viewModel.handlePowerPointDirectEditAction(turnID: turnID, action: action)
            },
            onPowerPointFinishAction: { action in
                await viewModel.handlePowerPointFinishAction(turnID: turnID, action: action)
            },
            onExcelAnalysisAction: { action in
                await viewModel.handleExcelAnalysisAction(turnID: turnID, action: action)
            }
        )
    }

    @ViewBuilder
    private func toolPillStack(_ pills: [AICommandViewModel.ToolCallPill]) -> some View {
        CommandBarFlowLayout(spacing: 6, lineSpacing: 5) {
            ForEach(pills) { pill in
                ToolPillView(pill: pill)
            }
        }
    }
}

private struct TranscriptContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
