import SwiftUI
import MetamorphiaAgentKit

// MARK: - AgentTraceCard

/// Full-fidelity execution-trace sheet for a completed agent turn.
/// Replaces `BubbleTracePlaceholderView` as of T12.
///
/// Design: 440×540 dark sheet with accent-tinted stroke (red = failed, blue = success).
/// Sections: outcome badge + stats, Plan (if any), Tool Calls (expandable),
/// LLM Reasoning (if any), Errors, Full Timeline.
/// Two copy actions: markdown (`trace.formattedString()`) and JSON (hand-rolled).
struct AgentTraceCard: View {
    let trace: AgentTrace
    let onDismiss: () -> Void

    @State private var expandedToolCalls: Set<UUID> = []
    @State private var showCopiedMarkdown = false
    @State private var showCopiedJSON = false

    private var isFailed: Bool {
        if case .failure = trace.finalOutcome { return true }
        return false
    }

    private var accentColor: Color {
        isFailed ? .red : Color(red: 0.3, green: 0.6, blue: 1.0)
    }

    private var outcomeLabel: String {
        switch trace.finalOutcome {
        case .success: return "SUCCESS"
        case .failure(let msg): return "FAILED — \(TraceRedactor.redact(String(msg.prefix(60))))"
        case .cancelled: return "CANCELLED"
        case .none: return "RUNNING"
        }
    }

    private var outcomeBadgeColor: Color {
        switch trace.finalOutcome {
        case .success: return .green
        case .failure: return .red
        case .cancelled: return .orange
        case .none: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().background(accentColor.opacity(0.3))
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    outcomeBadge
                    statsRow
                    if let plan = trace.planOutput, !plan.isEmpty {
                        planSection(plan)
                    }
                    toolCallsSection
                    llmReasoningSection
                    if !trace.errorEntries.isEmpty {
                        errorsSection
                    }
                    timelineSection
                }
                .padding(16)
            }
            Divider().background(accentColor.opacity(0.2))
            copyBar
        }
        .frame(width: 440, height: 540)
        .background(Color.black.opacity(0.86))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accentColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor)
            Text("Execution Trace")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Outcome badge

    private var outcomeBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(outcomeBadgeColor)
                .frame(width: 8, height: 8)
            Text(outcomeLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(outcomeBadgeColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(outcomeBadgeColor.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(outcomeBadgeColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Stats row

    private var statsRow: some View {
        HStack(spacing: 10) {
            statBadge(label: "Duration", value: trace.formattedDuration)
            statBadge(label: "LLM calls", value: "\(trace.llmCallCount)")
            statBadge(label: "Tool calls", value: "\(trace.toolCallCount)")
            statBadge(label: "Errors", value: "\(trace.errorEntries.count)", accent: trace.errorEntries.isEmpty ? nil : .red)
        }
    }

    private func statBadge(label: String, value: String, accent: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(accent ?? .white)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Plan section

    private func planSection(_ plan: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Plan", icon: "list.bullet")
            Text(TraceRedactor.redact(plan))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .textSelection(.enabled)
        }
    }

    // MARK: - Tool calls section

    private var toolCallsSection: some View {
        let toolEntries = trace.entries.filter {
            if case .toolCall = $0.kind { return true }
            return false
        }
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Tool Calls (\(toolEntries.count))", icon: "wrench.and.screwdriver")
            if toolEntries.isEmpty {
                Text("No tool calls in this run.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 4)
            } else {
                ForEach(toolEntries) { entry in
                    toolCallRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func toolCallRow(_ entry: TraceEntry) -> some View {
        if case .toolCall(let name, let args, let result, let ms, let success) = entry.kind {
            let isExpanded = expandedToolCalls.contains(entry.id)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if isExpanded {
                        expandedToolCalls.remove(entry.id)
                    } else {
                        expandedToolCalls.insert(entry.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(success ? .green : .red)
                        Text(name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.88))
                        Spacer()
                        Text("\(Int(ms))ms")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(success ? Color.white.opacity(0.04) : Color.red.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(success ? Color.white.opacity(0.08) : Color.red.opacity(0.2), lineWidth: 1)
                )

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        expandedField(label: "Args", value: TraceRedactor.redact(args))
                        expandedField(label: "Result", value: TraceRedactor.redact(result))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private func expandedField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .textCase(.uppercase)
            Text(String(value.prefix(800)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - LLM Reasoning section

    @ViewBuilder
    private var llmReasoningSection: some View {
        let reasoningEntries = trace.entries.compactMap { entry -> (id: UUID, reasoning: String)? in
            if case .llmCall(_, _, _, let reasoning) = entry.kind,
               let r = reasoning, !r.isEmpty {
                return (id: entry.id, reasoning: r)
            }
            return nil
        }
        if !reasoningEntries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("LLM Reasoning (\(reasoningEntries.count))", icon: "brain")
                ForEach(reasoningEntries, id: \.id) { item in
                    Text(TraceRedactor.redact(String(item.reasoning.prefix(600))))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.purple.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.purple.opacity(0.2), lineWidth: 1)
                        )
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Errors section

    private var errorsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Errors (\(trace.errorEntries.count))", icon: "exclamationmark.triangle.fill")
            ForEach(trace.errorEntries) { entry in
                if case .error(let source, let message) = entry.kind {
                    HStack(alignment: .top, spacing: 6) {
                        Text("[\(source)]")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.85))
                        Text(TraceRedactor.redact(message))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.red.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - Full Timeline section

    private var timelineSection: some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Full Timeline (\(trace.entries.count))", icon: "clock")
            ForEach(trace.entries) { entry in
                timelineRow(entry, fmt: fmt)
            }
        }
    }

    private func timelineRow(_ entry: TraceEntry, fmt: DateFormatter) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dotColor(entry))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fmt.string(from: entry.timestamp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(entry.summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let ms = entry.durationMs {
                    Text("\(Int(ms))ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
    }

    private func dotColor(_ entry: TraceEntry) -> Color {
        switch entry.colorName {
        case "purple": return .purple
        case "blue": return Color(red: 0.3, green: 0.6, blue: 1.0)
        case "red": return .red
        case "teal": return .teal
        case "orange": return .orange
        case "gray": return .gray
        case "yellow": return .yellow
        case "green": return .green
        default: return .white.opacity(0.5)
        }
    }

    // MARK: - Copy bar

    private var copyBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button {
                copyMarkdown()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCopiedMarkdown ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                    Text(showCopiedMarkdown ? "Copied" : "Markdown")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(showCopiedMarkdown ? .green : .white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.25), value: showCopiedMarkdown)

            Button {
                copyJSON()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCopiedJSON ? "checkmark" : "curlybraces")
                        .font(.system(size: 10, weight: .medium))
                    Text(showCopiedJSON ? "Copied" : "JSON")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(showCopiedJSON ? .green : .white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.25), value: showCopiedJSON)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Section header helper

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accentColor.opacity(0.8))
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Copy actions

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trace.formattedString(), forType: .string)
        showCopiedMarkdown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedMarkdown = false }
    }

    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(traceAsJSON(trace), forType: .string)
        showCopiedJSON = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedJSON = false }
    }
}

// MARK: - JSON encoder (hand-rolled, no Codable dependency)

private func traceAsJSON(_ trace: AgentTrace) -> String {
    let iso = ISO8601DateFormatter()

    func jsonString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    func outcomeJSON(_ o: AgentTrace.Outcome?) -> String {
        guard let o else { return "null" }
        switch o {
        case .success: return "{\"status\":\"success\"}"
        case .failure(let msg): return "{\"status\":\"failure\",\"message\":\(jsonString(TraceRedactor.redact(msg)))}"
        case .cancelled: return "{\"status\":\"cancelled\"}"
        }
    }

    func entryJSON(_ e: TraceEntry) -> String {
        var fields: [String] = [
            "\"id\":\(jsonString(e.id.uuidString))",
            "\"timestamp\":\(jsonString(iso.string(from: e.timestamp)))"
        ]
        if let ms = e.durationMs { fields.append("\"durationMs\":\(Int(ms))") }

        let kindStr: String
        switch e.kind {
        case .llmCall(let msgCount, let respLen, let hasTools, let reasoning):
            var k = "{\"type\":\"llmCall\",\"messageCount\":\(msgCount),\"responseLength\":\(respLen),\"hasToolCalls\":\(hasTools)"
            if let r = reasoning { k += ",\"reasoning\":\(jsonString(TraceRedactor.redact(String(r.prefix(800)))))" }
            k += "}"
            kindStr = k
        case .toolCall(let name, let args, let result, let ms, let success):
            kindStr = "{\"type\":\"toolCall\",\"name\":\(jsonString(name)),\"arguments\":\(jsonString(TraceRedactor.redact(String(args.prefix(1200))))),\"result\":\(jsonString(TraceRedactor.redact(String(result.prefix(1200))))),\"durationMs\":\(Int(ms)),\"success\":\(success)}"
        case .planning(let output):
            kindStr = "{\"type\":\"planning\",\"output\":\(jsonString(TraceRedactor.redact(output)))}"
        case .subAgentDecomposition(let count):
            kindStr = "{\"type\":\"subAgentDecomposition\",\"taskCount\":\(count)}"
        case .webScrape(let url, let preview):
            kindStr = "{\"type\":\"webScrape\",\"url\":\(jsonString(url)),\"contentPreview\":\(jsonString(TraceRedactor.redact(String(preview.prefix(400)))))}"
        case .error(let source, let message):
            kindStr = "{\"type\":\"error\",\"source\":\(jsonString(source)),\"message\":\(jsonString(TraceRedactor.redact(message)))}"
        case .contextPrune(let before, let after):
            kindStr = "{\"type\":\"contextPrune\",\"beforeTokens\":\(before),\"afterTokens\":\(after)}"
        case .retry(let tool, let attempt, let reason):
            kindStr = "{\"type\":\"retry\",\"toolName\":\(jsonString(tool)),\"attempt\":\(attempt),\"reason\":\(jsonString(reason))}"
        case .selfEvaluation(let passed, let feedback):
            kindStr = "{\"type\":\"selfEvaluation\",\"passed\":\(passed),\"feedback\":\(jsonString(TraceRedactor.redact(feedback)))}"
        case .subAgentComplete(let id, let app, let ms, let success):
            var k = "{\"type\":\"subAgentComplete\",\"id\":\(jsonString(id))"
            if let a = app { k += ",\"app\":\(jsonString(a))" }
            k += ",\"durationMs\":\(Int(ms)),\"success\":\(success)}"
            kindStr = k
        case .hostAgentRouting(let count, let apps):
            let appsArr = apps.map { jsonString($0) }.joined(separator: ",")
            kindStr = "{\"type\":\"hostAgentRouting\",\"subtaskCount\":\(count),\"apps\":[\(appsArr)]}"
        }
        fields.append("\"kind\":\(kindStr)")
        return "{\(fields.joined(separator: ","))}"
    }

    let entriesJSON = trace.entries.map { entryJSON($0) }.joined(separator: ",\n  ")
    var lines: [String] = [
        "{",
        "  \"id\":\(jsonString(trace.id.uuidString)),",
        "  \"goal\":\(jsonString(TraceRedactor.redact(trace.goal))),",
        "  \"startTime\":\(jsonString(iso.string(from: trace.startTime))),"
    ]
    if let end = trace.endTime {
        lines.append("  \"endTime\":\(jsonString(iso.string(from: end))),")
    }
    lines.append("  \"finalOutcome\":\(outcomeJSON(trace.finalOutcome)),")
    lines.append("  \"llmCallCount\":\(trace.llmCallCount),")
    lines.append("  \"toolCallCount\":\(trace.toolCallCount),")
    lines.append("  \"errorCount\":\(trace.errorEntries.count),")
    lines.append("  \"entries\":[\n  \(entriesJSON)\n  ]")
    lines.append("}")
    return lines.joined(separator: "\n")
}
