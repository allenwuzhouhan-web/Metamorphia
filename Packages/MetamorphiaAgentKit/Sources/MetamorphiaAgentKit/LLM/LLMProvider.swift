import Foundation

// MARK: - Provider Enum

/// The LLM providers Metamorphia knows how to talk to.
///
/// Each case maps to a ``LLMProviderConfig`` that lists its HTTP endpoint,
/// auth style, and default/available models. The config list is cached at
/// first access so `.config` is constant-time.
public enum LLMProvider: String, CaseIterable, Codable, Sendable {
    case openRouter
    case openai
    case deepseek
    case claude
    case gemini
    case kimi
    case kimiCN
    case minimax
    case cerebras
}

// MARK: - Provider Config

public struct LLMProviderConfig: Sendable {
    public let displayName: String
    public let baseURL: String
    public let defaultModel: String
    public let availableModels: [String]
    public let authStyle: AuthStyle
    public let signupURL: String
    public let keyPlaceholder: String

    public enum AuthStyle: Sendable {
        case bearer
        case anthropic
    }

    public init(
        displayName: String,
        baseURL: String,
        defaultModel: String,
        availableModels: [String],
        authStyle: AuthStyle,
        signupURL: String,
        keyPlaceholder: String
    ) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.availableModels = availableModels
        self.authStyle = authStyle
        self.signupURL = signupURL
        self.keyPlaceholder = keyPlaceholder
    }
}

public extension LLMProvider {
    private static let configs: [LLMProvider: LLMProviderConfig] = {
        var map = [LLMProvider: LLMProviderConfig]()
        for provider in LLMProvider.allCases {
            map[provider] = provider.buildConfig()
        }
        return map
    }()

    var config: LLMProviderConfig {
        Self.configs[self] ?? buildConfig()
    }

    private func buildConfig() -> LLMProviderConfig {
        switch self {
        case .openRouter:
            return LLMProviderConfig(
                displayName: "OpenRouter",
                baseURL: "https://openrouter.ai/api/v1/chat/completions",
                // Dynamic aliases resolve to each vendor's newest flagship, so the
                // default never goes stale; concrete slugs are listed below them.
                defaultModel: "~anthropic/claude-sonnet-latest",
                availableModels: [
                    "~anthropic/claude-sonnet-latest",
                    "~anthropic/claude-opus-latest",
                    "~openai/gpt-latest",
                    "~google/gemini-pro-latest",
                    "anthropic/claude-opus-4.8",
                    "anthropic/claude-sonnet-5",
                    "openai/gpt-5.5",
                    "google/gemini-3.5-flash",
                    "deepseek/deepseek-v4-pro",
                    "x-ai/grok-4.3",
                ],
                authStyle: .bearer,
                signupURL: "openrouter.ai/keys",
                keyPlaceholder: "sk-or-v1-..."
            )
        case .openai:
            return LLMProviderConfig(
                displayName: "OpenAI",
                baseURL: "https://api.openai.com/v1/chat/completions",
                defaultModel: "gpt-4.1",
                availableModels: ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "o3", "o4-mini"],
                authStyle: .bearer,
                signupURL: "platform.openai.com",
                keyPlaceholder: "sk-..."
            )
        case .deepseek:
            return LLMProviderConfig(
                displayName: "DeepSeek",
                baseURL: "https://api.deepseek.com/chat/completions",
                defaultModel: "deepseek-chat",
                availableModels: ["deepseek-chat", "deepseek-reasoner"],
                authStyle: .bearer,
                signupURL: "platform.deepseek.com",
                keyPlaceholder: "sk-..."
            )
        case .claude:
            return LLMProviderConfig(
                displayName: "Claude",
                baseURL: "https://api.anthropic.com/v1/messages",
                defaultModel: "claude-sonnet-4-6-20260320",
                availableModels: [
                    "claude-sonnet-4-6-20260320",
                    "claude-opus-4-6-20260204",
                    "claude-sonnet-4-5-20250514",
                    "claude-haiku-4-5-20251001",
                ],
                authStyle: .anthropic,
                signupURL: "console.anthropic.com",
                keyPlaceholder: "sk-ant-..."
            )
        case .gemini:
            return LLMProviderConfig(
                displayName: "Gemini",
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                defaultModel: "gemini-2.5-flash",
                availableModels: [
                    "gemini-2.5-flash",
                    "gemini-2.5-pro",
                    "gemini-3.1-flash-preview",
                    "gemini-3.1-pro-preview",
                ],
                authStyle: .bearer,
                signupURL: "aistudio.google.com",
                keyPlaceholder: "AIza..."
            )
        case .kimi:
            return LLMProviderConfig(
                displayName: "Kimi (International)",
                baseURL: "https://api.moonshot.ai/v1/chat/completions",
                defaultModel: "kimi-k2.5",
                availableModels: ["kimi-k2.5", "kimi-k2-thinking", "kimi-k2-thinking-turbo"],
                authStyle: .bearer,
                signupURL: "platform.moonshot.ai",
                keyPlaceholder: "sk-..."
            )
        case .kimiCN:
            return LLMProviderConfig(
                displayName: "Kimi (China)",
                baseURL: "https://api.kimi.com/coding/v1/chat/completions",
                defaultModel: "kimi-k2.5",
                availableModels: ["kimi-k2.5", "kimi-k2-thinking", "kimi-k2-thinking-turbo"],
                authStyle: .bearer,
                signupURL: "platform.moonshot.cn",
                keyPlaceholder: "sk-kimi-..."
            )
        case .minimax:
            return LLMProviderConfig(
                displayName: "MiniMax",
                baseURL: "https://api.minimax.io/v1/text/chatcompletion_v2",
                defaultModel: "MiniMax-M2.5",
                availableModels: ["MiniMax-M2.5", "MiniMax-M2.7", "MiniMax-M1"],
                authStyle: .bearer,
                signupURL: "platform.minimax.io",
                keyPlaceholder: "eyJ..."
            )
        case .cerebras:
            return LLMProviderConfig(
                displayName: "Cerebras",
                baseURL: "https://api.cerebras.ai/v1/chat/completions",
                defaultModel: "llama-3.3-70b",
                availableModels: [
                    "llama-3.3-70b",
                    "llama3.1-8b",
                    "qwen-3-32b",
                    "llama-4-scout-17b-16e-instruct",
                ],
                authStyle: .bearer,
                signupURL: "cloud.cerebras.ai",
                keyPlaceholder: "csk-..."
            )
        }
    }
}
