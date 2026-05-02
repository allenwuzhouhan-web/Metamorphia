import AppKit
import Foundation
import MetamorphiaAgentKit
import MetamorphiaPerception

public enum ConversationContinuationOutcome: Sendable {
    case placed(appName: String, characterCount: Int)
    case placedDirect(appName: String, recipient: String, characterCount: Int)
    case cancelled
    case needsUserInput(String)
    case failure(String)

    public var userMessage: String {
        switch self {
        case .placed(let appName, let count):
            return "Placed a \(count)-character draft in \(appName). Review it and press Send yourself."
        case .placedDirect(let appName, let recipient, let count):
            return "Placed a \(count)-character message to \(recipient) in \(appName). Review it and press Send yourself."
        case .cancelled:
            return "Draft cancelled."
        case .needsUserInput(let message):
            return message
        case .failure(let message):
            return message
        }
    }
}

public struct ConversationDraft: Sendable {
    public let appName: String
    public let appBundleID: String?
    public let windowTitle: String?
    public let composeRef: ElementRef
    public let composeFallbackPoint: CGPoint?
    public let existingDraft: String
    public let replyText: String
    public let rationale: String
    public let riskFlags: [String]
    public let confidence: Double
    public let needsUserInput: Bool
}

public struct WeChatDirectMessageRequest: Sendable, Equatable {
    public let recipient: String
    public let message: String
}

@MainActor
public final class ConversationContinuationService {
    public static let shared = ConversationContinuationService()

    private init() {}

    public static func isConversationContinuationRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let verbs = ["reply", "respond", "draft", "continue", "message", "text back"]
        let surfaces = ["chat", "conversation", "message", "wechat", "weixin", "wei xin", "微信", "slack", "whatsapp", "discord"]
        return verbs.contains { lower.contains($0) } && surfaces.contains { lower.contains($0) }
    }

    public static func parseWeChatDirectMessageRequest(_ prompt: String) -> WeChatDirectMessageRequest? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let tellPrefixes = ["tell "]
        let sendPrefixes = ["wechat ", "weixin ", "微信", "message ", "text ", "dm "]
        let prefix = (tellPrefixes + sendPrefixes).first { lower.hasPrefix($0) }
        guard let prefix else { return nil }

        let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        var remainder = String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        remainder = stripLeadingDirectMessageNoise(remainder)
        guard !remainder.isEmpty else { return nil }

        let parsed: (recipient: String, message: String)?
        if lower.hasPrefix("tell ") {
            parsed = parseTellRemainder(remainder)
        } else {
            parsed = parseMessageRemainder(remainder)
        }

        guard let parsed else { return nil }
        let recipient = cleanRecipient(parsed.recipient)
        let message = cleanDirectMessage(parsed.message)
        guard isUsableRecipient(recipient), !message.isEmpty else { return nil }
        return WeChatDirectMessageRequest(recipient: recipient, message: polishDraftTone(message))
    }

    public func runDraftReviewAndPlace(
        sourcePrompt: String? = nil,
        preferredAppName: String? = nil
    ) async -> ConversationContinuationOutcome {
        do {
            let draft = try await prepareDraft(
                sourcePrompt: sourcePrompt,
                preferredAppName: preferredAppName
            )

            if draft.needsUserInput {
                await presentNeedsInput(draft)
                return .needsUserInput(needsInputMessage(for: draft))
            }

            guard let approvedText = await presentReview(draft), !approvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .cancelled
            }

            let placed = try await placeDraft(approvedText, basedOn: draft, preferredAppName: preferredAppName)
            return .placed(appName: draft.appName, characterCount: placed)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await presentFailure(message)
            return .failure(message)
        }
    }

    public func runWeChatDirectMessageAndPlace(
        sourcePrompt: String
    ) async -> ConversationContinuationOutcome {
        guard let request = Self.parseWeChatDirectMessageRequest(sourcePrompt) else {
            let message = "I could not tell who to message and what to say."
            await presentFailure(message)
            return .failure(message)
        }

        do {
            let appName = try await activateOrOpenWeChat()
            try GestureExecutor.keyCombo(keys: [.character("f")], modifiers: .command)
            try await Task.sleep(nanoseconds: 120_000_000)
            try GestureExecutor.keyCombo(keys: [.character("a")], modifiers: .command)
            try GestureExecutor.keyPress(.delete)
            try await GestureExecutor.typeString(request.recipient)
            try await Task.sleep(nanoseconds: 220_000_000)
            try GestureExecutor.keyPress(.enter)
            try await Task.sleep(nanoseconds: 650_000_000)

            let count = try await placeTextInActiveCompose(
                request.message,
                preferredAppName: appName
            )
            return .placedDirect(appName: appName, recipient: request.recipient, characterCount: count)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await presentFailure(message)
            return .failure(message)
        }
    }

    // MARK: - Drafting

    private func prepareDraft(
        sourcePrompt: String?,
        preferredAppName: String?
    ) async throws -> ConversationDraft {
        let rawMap = await DefaultComputerPerception.shared.capture(
            forceOCR: false,
            appFilter: preferredAppName,
            ocrOverride: .auto
        )
        let map = rawMap.redactedForLLM()
        let target = try resolveMessagingTarget(in: map, preferredAppName: preferredAppName)
        let compose = try findComposeInput(in: map)
        let screenContext = TextFormatter.format(map, maxElements: 90)
        let prompt = buildDraftPrompt(
            sourcePrompt: sourcePrompt,
            target: target,
            compose: compose,
            screenContext: screenContext,
            safety: map.safety
        )

        let response = try await LLMServiceManager.shared.currentService.sendChatRequest(
            messages: [
                ChatMessage(role: "system", content: Self.systemPrompt),
                ChatMessage(role: "user", content: prompt),
            ],
            tools: nil,
            maxTokens: 700
        )

        let parsed = Self.parseDraftResponse(response.text ?? "")
        let localRiskFlags = localRiskFlags(from: map.safety)
        var riskFlags = Array(Set(parsed.riskFlags + localRiskFlags)).sorted()
        let hardStop = riskFlags.contains("sensitive_screen") || riskFlags.contains("dangerous_action")
        var replyText = Self.polishDraftTone(parsed.replyText.trimmingCharacters(in: .whitespacesAndNewlines))

        // Missing background is not a reason to refuse the workflow. For normal
        // school/work/social chats, place an editable clarification draft
        // instead of turning the whole feature into a dead end.
        if parsed.needsUserInput, !hardStop, replyText.isEmpty {
            replyText = Self.clarificationDraft(for: screenContext)
            riskFlags.append("clarifying_draft")
            riskFlags = Array(Set(riskFlags)).sorted()
        }
        let needsUserInput = hardStop

        guard !replyText.isEmpty || needsUserInput else {
            throw ConversationContinuationError.draftingFailed("Metamorphia could not produce a usable reply draft.")
        }

        return ConversationDraft(
            appName: target.appName,
            appBundleID: target.bundleID,
            windowTitle: target.windowTitle,
            composeRef: compose.ref,
            composeFallbackPoint: compose.ref.index < 0 ? compose.clickPoint : nil,
            existingDraft: compose.value.trimmingCharacters(in: .whitespacesAndNewlines),
            replyText: replyText,
            rationale: parsed.rationale,
            riskFlags: riskFlags,
            confidence: parsed.confidence,
            needsUserInput: needsUserInput
        )
    }

    private static let systemPrompt = """
    You draft replies for the user's active chat. Preserve the user's likely voice, relationship tone, language, and context.
    Write like a real person in a normal chat: concise, warm when appropriate, and natural.
    Use normal sentence casing. Do not use all-caps emphasis unless the user explicitly asks for it or it is a standard acronym like ESL/IB/AP.
    Avoid stiff assistant phrasing. Avoid slang like "wanna" or "gonna" unless the visible conversation already uses that tone.

    Return only compact JSON with these keys:
    - reply_text: string
    - rationale: one short sentence
    - risk_flags: array of short snake_case strings
    - confidence: number from 0 to 1
    - needs_user_input: boolean

    If ordinary school, class, homework, scheduling, work, or social context is missing, do not refuse. Draft a concise clarification reply that asks for the missing details in the conversation's language.
    Set needs_user_input true and leave reply_text empty only when the conversation is sensitive, hostile, legally/financially/medically consequential, romantic or family-critical, or clearly requires the user's personal judgment. Do not set needs_user_input just because background context is incomplete.
    Never include markdown fences. Never claim the message was sent.
    """

    private static func clarificationDraft(for screenContext: String) -> String {
        if screenContext.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            return "你能再发我一下具体要求或背景吗？我想确认清楚再回复你。"
        }
        return "Can you send me the specific details or context? I want to make sure I respond correctly."
    }

    private static func polishDraftTone(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let acronymAllowlist: Set<String> = [
            "AI", "AP", "ACT", "ESL", "GPA", "IB", "IELTS", "PDF", "SAT",
            "STEM", "TOEFL", "UK", "URL", "US", "USA",
        ]
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var polished: [String] = []
        var sentenceStart = true

        for word in words {
            let letters = word.filter(\.isLetter)
            let upperLetters = String(letters).uppercased()
            let isAllCapsWord = letters.count >= 3 &&
                String(letters) == upperLetters &&
                !acronymAllowlist.contains(upperLetters)

            let next: String
            if isAllCapsWord {
                let lowered = word.lowercased()
                next = sentenceStart ? lowered.prefix(1).uppercased() + lowered.dropFirst() : lowered
            } else {
                next = word
            }

            polished.append(next)
            if word.contains(".") || word.contains("?") || word.contains("!") {
                sentenceStart = true
            } else if !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentenceStart = false
            }
        }

        return polished.joined(separator: " ")
    }

    private static func stripLeadingDirectMessageNoise(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["to ", "wechat to ", "weixin to ", "微信给"] {
            if result.lowercased().hasPrefix(prefix.lowercased()) {
                let start = result.index(result.startIndex, offsetBy: prefix.count)
                result = String(result[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return result
    }

    private static func parseTellRemainder(_ remainder: String) -> (recipient: String, message: String)? {
        let delimiterPatterns = [
            " that ",
            " saying ",
            " to say ",
            ":",
            "：",
        ]
        if let parsed = splitRemainder(remainder, delimiters: delimiterPatterns) {
            return parsed
        }

        if let parsed = splitRemainder(remainder, delimiters: [" to "]) {
            return (parsed.recipient, parsed.message)
        }

        return splitFirstWordRecipient(remainder)
    }

    private static func parseMessageRemainder(_ remainder: String) -> (recipient: String, message: String)? {
        let delimiters = [
            " that ",
            " saying ",
            " to say ",
            " with ",
            ":",
            "：",
        ]
        if let parsed = splitRemainder(remainder, delimiters: delimiters) {
            return parsed
        }
        return splitFirstWordRecipient(remainder)
    }

    private static func splitRemainder(
        _ text: String,
        delimiters: [String]
    ) -> (recipient: String, message: String)? {
        for delimiter in delimiters {
            let options: String.CompareOptions = delimiter == ":" || delimiter == "：" ? [] : [.caseInsensitive]
            if let range = text.range(of: delimiter, options: options) {
                let recipient = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let message = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !recipient.isEmpty, !message.isEmpty {
                    return (recipient, message)
                }
            }
        }
        return nil
    }

    private static func splitFirstWordRecipient(_ text: String) -> (recipient: String, message: String)? {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func cleanRecipient(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingNoise = [" on wechat", " in wechat", " via wechat", " on weixin", " in weixin", " via weixin", " 微信"]
        for suffix in trailingNoise {
            if result.lowercased().hasSuffix(suffix) {
                result.removeLast(suffix.count)
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
    }

    private static func cleanDirectMessage(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
    }

    private static func isUsableRecipient(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return false }
        return !["me", "myself", "us", "metamorphia"].contains(lower)
    }

    private func needsInputMessage(for draft: ConversationDraft) -> String {
        var parts = ["This conversation needs your judgment before Metamorphia should draft into the chat."]
        if !draft.rationale.isEmpty {
            parts.append(draft.rationale)
        }
        if !draft.riskFlags.isEmpty {
            parts.append("Flags: \(draft.riskFlags.joined(separator: ", "))")
        }
        return parts.joined(separator: "\n")
    }

    private func buildDraftPrompt(
        sourcePrompt: String?,
        target: MessagingTarget,
        compose: ScreenElement,
        screenContext: String,
        safety: SafetyReport
    ) -> String {
        let userIntent = sourcePrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = compose.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        App: \(target.appName)
        Bundle: \(target.bundleID ?? "unknown")
        Window: \(target.windowTitle ?? "unknown")
        User request: \(userIntent?.isEmpty == false ? userIntent! : "Draft an appropriate reply to the visible conversation.")
        Existing compose-box text: \(existing.isEmpty ? "(empty)" : existing)
        Safety: dangers=\(safety.dangers.count), sensitive=\(safety.sensitive.count)

        Visible screen context:
        \(screenContext)
        """
    }

    // MARK: - Placement

    private func placeDraft(
        _ text: String,
        basedOn draft: ConversationDraft,
        preferredAppName: String?
    ) async throws -> Int {
        return try await placeTextInActiveCompose(
            text,
            preferredAppName: preferredAppName ?? draft.appName,
            fallbackPoint: draft.composeFallbackPoint
        )
    }

    private func placeTextInActiveCompose(
        _ text: String,
        preferredAppName: String?,
        fallbackPoint: CGPoint? = nil
    ) async throws -> Int {
        let rawMap = await DefaultComputerPerception.shared.capture(
            forceOCR: false,
            appFilter: preferredAppName,
            ocrOverride: .auto
        )
        let map = rawMap.redactedForLLM()
        _ = try resolveMessagingTarget(in: map, preferredAppName: preferredAppName)
        let compose = try findComposeInput(in: map)
        let clearFirst = !compose.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if compose.ref.index < 0, let point = compose.clickPoint ?? fallbackPoint {
            return try await placeDraftByClickingFallback(text, at: point)
        }

        let result = try await SemanticExecutor.shared.type(
            ref: compose.ref,
            text: text,
            pressEnter: false,
            clearFirst: clearFirst,
            in: map,
            stabilizer: PerceptionPipeline.shared.refStabilizer
        )
        return result.charactersTyped
    }

    private func activateOrOpenWeChat() async throws -> String {
        let bundleIDs = [
            "com.tencent.xinWeChat",
            "com.tencent.WeChat",
            "com.tencent.xin",
        ]
        let normalizedBundleIDs = Set(bundleIDs.map { $0.lowercased() })

        for normalizedBundleID in normalizedBundleIDs {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.lowercased() == normalizedBundleID }) {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                try await Task.sleep(nanoseconds: 350_000_000)
                return app.localizedName ?? "WeChat"
            }
        }

        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let app = try await openApplication(at: url)
                try await Task.sleep(nanoseconds: 700_000_000)
                return app.localizedName ?? "WeChat"
            }
        }

        for path in ["/Applications/WeChat.app", "/Applications/Weixin.app", "/Applications/微信.app"] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                let app = try await openApplication(at: url)
                try await Task.sleep(nanoseconds: 700_000_000)
                return app.localizedName ?? "WeChat"
            }
        }

        throw ConversationContinuationError.draftingFailed("I could not find WeChat installed on this Mac.")
    }

    private func openApplication(at url: URL) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: error ?? ConversationContinuationError.draftingFailed("Could not open WeChat."))
                }
            }
        }
    }

    private func placeDraftByClickingFallback(_ text: String, at point: CGPoint) async throws -> Int {
        try GestureExecutor.click(at: point, button: .left, count: 1)
        try await Task.sleep(nanoseconds: 120_000_000)
        try await GestureExecutor.typeString(text)
        return text.count
    }

    // MARK: - Target + compose resolution

    private struct MessagingTarget {
        let appName: String
        let bundleID: String?
        let windowTitle: String?
    }

    private func resolveMessagingTarget(in map: ScreenMap, preferredAppName: String? = nil) throws -> MessagingTarget {
        let appName = map.focusedApp.name
        let bundleID = map.focusedApp.bundleID
        let windowTitle = map.windows.first(where: { $0.isFocused })?.title ?? map.windows.first?.title

        if Self.isSupportedMessagingApp(appName: appName, bundleID: bundleID) {
            return MessagingTarget(appName: appName, bundleID: bundleID, windowTitle: windowTitle)
        }

        if let preferredAppName,
           Self.isSupportedMessagingApp(appName: preferredAppName, bundleID: nil) {
            let preferredWindow = map.windows.first { window in
                window.appName.localizedCaseInsensitiveContains(preferredAppName) ||
                preferredAppName.localizedCaseInsensitiveContains(window.appName)
            }
            return MessagingTarget(
                appName: preferredWindow?.appName ?? preferredAppName,
                bundleID: preferredWindow?.appBundleID,
                windowTitle: preferredWindow?.title ?? windowTitle
            )
        }

        throw ConversationContinuationError.unsupportedApp(preferredAppName ?? appName)
    }

    private static func isSupportedMessagingApp(appName: String, bundleID: String?) -> Bool {
        let normalizedName = appName.lowercased()
        let normalizedBundle = (bundleID ?? "").lowercased()
        let names = ["wechat", "weixin", "wei xin", "微信", "messages", "slack", "whatsapp", "discord", "teams", "mail", "outlook"]
        if names.contains(where: { normalizedName.contains($0) }) { return true }

        let bundleFragments = [
            "com.tencent.xinwechat",
            "com.tencent.wechat",
            "com.tencent.xin",
            "com.apple.mobilesms",
            "com.tinyspeck.slackmacgap",
            "com.whatsapp.whatsapp",
            "com.hnc.discord",
            "com.microsoft.teams",
            "com.apple.mail",
            "com.microsoft.outlook",
        ]
        return bundleFragments.contains { normalizedBundle.contains($0) }
    }

    private func findComposeInput(in map: ScreenMap) throws -> ScreenElement {
        let candidates = map.elements.filter { element in
            Self.composeInputRoles.contains(element.role) &&
            element.state.contains(.enabled) &&
            !element.state.contains(.password)
        }

        guard let best = candidates.max(by: { composeScore($0, in: map) < composeScore($1, in: map) }) else {
            if let fallback = fallbackComposeInput(in: map) {
                return fallback
            }
            throw ConversationContinuationError.noComposeInput(composeDiagnostic(for: map))
        }
        return best
    }

    private static let composeInputRoles: Set<ElementRole> = [
        .textField,
        .textArea,
        .comboBox,
        .webArea,
    ]

    private func composeScore(_ element: ScreenElement, in map: ScreenMap) -> Double {
        let label = "\(element.label) \(element.value)".lowercased()
        var score = 0.0
        if element.role == .textArea { score += 3.0 }
        if element.role == .textField { score += 2.0 }
        if element.role == .webArea { score += 1.5 }
        if element.state.contains(.focused) { score += 4.0 }
        if label.contains("message") || label.contains("reply") || label.contains("chat") || label.contains("输入") || label.contains("发送") || label.contains("编辑") || label.contains("type") {
            score += 3.0
        }
        if label.contains("search") || label.contains("find") || label.contains("filter") {
            score -= 5.0
        }
        if let bounds = element.bounds {
            let displayHeight = map.displays.first(where: { $0.index == element.displayIndex })?.height ?? map.display.height
            score += Double(bounds.midY / max(CGFloat(displayHeight), 1)) * 2.0
            score += Double(bounds.width / max(CGFloat(map.display.width), 1))
        }
        return score
    }

    private func fallbackComposeInput(in map: ScreenMap) -> ScreenElement? {
        guard Self.isSupportedMessagingApp(appName: map.focusedApp.name, bundleID: map.focusedApp.bundleID) ||
              map.windows.contains(where: { Self.isSupportedMessagingApp(appName: $0.appName, bundleID: $0.appBundleID) }) else {
            return nil
        }

        guard let point = fallbackComposePoint(in: map) else { return nil }
        return ScreenElement(
            ref: ElementRef(index: -1),
            role: .webArea,
            subrole: "",
            label: "chat compose fallback",
            value: "",
            bounds: nil,
            clickPoint: point,
            state: .enabled,
            actions: [],
            parentRef: nil,
            depth: 0,
            source: .accessibility,
            confidence: 0.35,
            appBundleID: map.focusedApp.bundleID,
            windowIndex: map.windows.first(where: { $0.isFocused })?.index ?? 0,
            displayIndex: map.windows.first(where: { $0.isFocused })?.displayIndex ?? map.display.index
        )
    }

    private func fallbackComposePoint(in map: ScreenMap) -> CGPoint? {
        let chatWindows = map.windows.filter {
            Self.isSupportedMessagingApp(appName: $0.appName, bundleID: $0.appBundleID)
        }
        let window = chatWindows.first(where: { $0.isFocused })
            ?? chatWindows.max { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }
            ?? map.windows.first(where: { $0.isFocused })
            ?? map.windows.max { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }

        guard let window, window.bounds.width >= 240, window.bounds.height >= 220 else {
            return nil
        }

        if let send = bottomSendButton(in: map.elements, window: window) {
            return CGPoint(
                x: max(window.bounds.minX + window.bounds.width * 0.45, send.bounds!.minX - 140),
                y: send.bounds!.midY
            )
        }

        return CGPoint(
            x: window.bounds.minX + window.bounds.width * 0.62,
            y: window.bounds.maxY - min(max(window.bounds.height * 0.09, 56), 92)
        )
    }

    private func bottomSendButton(in elements: [ScreenElement], window: WindowInfo) -> ScreenElement? {
        elements
            .filter { element in
                guard [.button, .ocrButton].contains(element.role),
                      let bounds = element.bounds,
                      window.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else {
                    return false
                }
                let label = element.label.lowercased()
                return bounds.midY > window.bounds.minY + window.bounds.height * 0.65 &&
                    (label.contains("send") || label.contains("发送"))
            }
            .max { lhs, rhs in
                (lhs.bounds?.midY ?? 0) < (rhs.bounds?.midY ?? 0)
            }
    }

    private func composeDiagnostic(for map: ScreenMap) -> String {
        let roleCounts = Dictionary(grouping: map.elements, by: { $0.role.rawValue })
            .mapValues(\.count)
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(8)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        let focused = map.elements.first(where: { $0.state.contains(.focused) })
        let focusedSummary = focused.map {
            "Focused element: \($0.role.rawValue) \"\($0.label.prefix(40))\"."
        }

        return [
            "I could not find an editable compose box in the active conversation.",
            focusedSummary,
            roleCounts.isEmpty ? nil : "Captured roles: \(roleCounts).",
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    // MARK: - Review UI

    private func presentReview(_ draft: ConversationDraft) async -> String? {
        let alert = NSAlert()
        alert.messageText = draft.existingDraft.isEmpty ? "Place this draft in \(draft.appName)?" : "Replace the current chat draft in \(draft.appName)?"
        alert.informativeText = reviewSubtitle(for: draft)
        alert.addButton(withTitle: "Place in Chat")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = draft.replyText
        textView.font = .systemFont(ofSize: 13)
        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return textView.string
    }

    private func presentNeedsInput(_ draft: ConversationDraft) async {
        let alert = NSAlert()
        alert.messageText = "This conversation needs your judgment"
        alert.informativeText = reviewSubtitle(for: draft)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentFailure(_ message: String) async {
        let alert = NSAlert()
        alert.messageText = "Could not draft a chat reply"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func reviewSubtitle(for draft: ConversationDraft) -> String {
        var parts: [String] = []
        if !draft.rationale.isEmpty { parts.append(draft.rationale) }
        if !draft.riskFlags.isEmpty { parts.append("Flags: \(draft.riskFlags.joined(separator: ", "))") }
        parts.append("Metamorphia will type only. It will not press Send.")
        return parts.joined(separator: "\n")
    }

    // MARK: - Parsing

    private struct ParsedDraft {
        let replyText: String
        let rationale: String
        let riskFlags: [String]
        let confidence: Double
        let needsUserInput: Bool
    }

    private static func parseDraftResponse(_ text: String) -> ParsedDraft {
        let cleaned = stripFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedDraft(
                replyText: cleaned,
                rationale: "",
                riskFlags: ["unstructured_model_output"],
                confidence: 0.4,
                needsUserInput: false
            )
        }
        return ParsedDraft(
            replyText: obj["reply_text"] as? String ?? obj["reply"] as? String ?? "",
            rationale: obj["rationale"] as? String ?? "",
            riskFlags: obj["risk_flags"] as? [String] ?? [],
            confidence: obj["confidence"] as? Double ?? 0.5,
            needsUserInput: obj["needs_user_input"] as? Bool ?? false
        )
    }

    private static func stripFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```JSON", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result
    }

    private func localRiskFlags(from safety: SafetyReport) -> [String] {
        var flags: [String] = []
        if !safety.sensitive.isEmpty { flags.append("sensitive_screen") }
        if !safety.dangers.isEmpty { flags.append("dangerous_action") }
        return flags
    }
}

private enum ConversationContinuationError: LocalizedError {
    case unsupportedApp(String)
    case noComposeInput(String)
    case draftingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedApp(let app):
            return "\(app) is not recognized as a supported messaging app yet. Focus a WeiXin/WeChat, Messages, Slack, WhatsApp, Discord, Teams, Mail, or Outlook conversation and try again."
        case .noComposeInput(let diagnostic):
            return diagnostic
        case .draftingFailed(let message):
            return message
        }
    }
}
