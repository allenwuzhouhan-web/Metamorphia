import Foundation

/// Manages the currently-selected LLM provider + model, a cached service instance,
/// and optional overrides for document-creation and multimodal tasks.
///
/// Simplified from Executer's original: the large system-prompt construction
/// logic is NOT ported — that lives in the app target (it pulls from many
/// app-specific singletons: PersonalityEngine, SkillsManager, MemoryManager,
/// LearningContextProvider, DocumentStyleManager, etc.). The app target builds
/// the system prompt and passes it in as a `ChatMessage(role: "system", ...)`
/// to AgentLoop.
///
/// Persistence: `currentProvider` and `currentModel` are read from / written to
/// `UserDefaults.standard` using the same keys as Executer (`llm_provider`,
/// `llm_model`) so a one-shot prefix migration can port legacy settings.
public final class LLMServiceManager: @unchecked Sendable {
    public static let shared = LLMServiceManager()

    private let lock = NSLock()

    // MARK: - Current Selection

    private var _currentProvider: LLMProvider
    private var _currentModel: String
    private var _currentService: LLMServiceProtocol?

    public var currentProvider: LLMProvider {
        get { lock.lock(); defer { lock.unlock() }; return _currentProvider }
        set {
            lock.lock(); defer { lock.unlock() }
            _currentProvider = newValue
            _currentService = nil
            UserDefaults.standard.set(newValue.rawValue, forKey: "llm_provider")
        }
    }

    public var currentModel: String {
        get { lock.lock(); defer { lock.unlock() }; return _currentModel }
        set {
            lock.lock(); defer { lock.unlock() }
            _currentModel = newValue
            _currentService = nil
            UserDefaults.standard.set(newValue, forKey: "llm_model")
        }
    }

    public var currentService: LLMServiceProtocol {
        lock.lock(); defer { lock.unlock() }
        if let s = _currentService { return s }
        let s = Self.makeService(provider: _currentProvider, model: _currentModel, costTracker: costTracker)
        _currentService = s
        return s
    }

    // MARK: - Document-Creation Override

    private var _documentProvider: LLMProvider?
    private var _documentModel: String?
    private var _documentService: LLMServiceProtocol?

    public var documentProvider: LLMProvider? {
        get { lock.lock(); defer { lock.unlock() }; return _documentProvider }
        set {
            lock.lock(); defer { lock.unlock() }
            _documentProvider = newValue
            _documentService = nil
            UserDefaults.standard.set(newValue?.rawValue, forKey: "doc_llm_provider")
        }
    }

    public var documentModel: String? {
        get { lock.lock(); defer { lock.unlock() }; return _documentModel }
        set {
            lock.lock(); defer { lock.unlock() }
            _documentModel = newValue
            _documentService = nil
            UserDefaults.standard.set(newValue, forKey: "doc_llm_model")
        }
    }

    /// Service for document creation tasks. Falls back to `currentService` if no override set.
    public var documentService: LLMServiceProtocol {
        lock.lock()
        guard let prov = _documentProvider, let mod = _documentModel else {
            lock.unlock()
            return currentService
        }
        if let s = _documentService {
            lock.unlock()
            return s
        }
        let s = Self.makeService(provider: prov, model: mod, costTracker: costTracker)
        _documentService = s
        lock.unlock()
        return s
    }

    public var hasDocumentOverride: Bool {
        lock.lock(); defer { lock.unlock() }
        return _documentProvider != nil && _documentModel != nil
    }

    // MARK: - Multimodal Override (auto-route to Kimi for vision tasks)

    private var _multimodalService: LLMServiceProtocol?

    /// Service for multimodal tasks. Uses Kimi if any Kimi API key is available,
    /// else falls back to `currentService`.
    public var multimodalService: LLMServiceProtocol {
        lock.lock()
        if let s = _multimodalService {
            lock.unlock()
            return s
        }

        let kimiProvider: LLMProvider
        if APIKeyManager.shared.getKey(for: .kimi) != nil {
            kimiProvider = .kimi
        } else if APIKeyManager.shared.getKey(for: .kimiCN) != nil {
            kimiProvider = .kimiCN
        } else {
            lock.unlock()
            return currentService
        }

        let model = kimiProvider.config.defaultModel
        let s = Self.makeService(provider: kimiProvider, model: model, costTracker: costTracker)
        _multimodalService = s
        lock.unlock()
        return s
    }

    public var hasMultimodalProvider: Bool {
        APIKeyManager.shared.getKey(for: .kimi) != nil ||
        APIKeyManager.shared.getKey(for: .kimiCN) != nil
    }

    public var multimodalProviderName: String {
        if APIKeyManager.shared.getKey(for: .kimi) != nil { return "Kimi" }
        if APIKeyManager.shared.getKey(for: .kimiCN) != nil { return "Kimi CN" }
        return currentProvider.config.displayName
    }

    // MARK: - Cost Tracker

    /// Optional tracker injected by the app target. Services use this to record
    /// token usage per request. `nil` = tracking disabled.
    public weak var costTracker: LLMCostTracker? {
        didSet {
            lock.lock(); defer { lock.unlock() }
            // Invalidate cached services so they pick up the new tracker on next access.
            _currentService = nil
            _documentService = nil
            _multimodalService = nil
        }
    }

    // MARK: - Init

    private init() {
        let savedProvider = UserDefaults.standard.string(forKey: "llm_provider") ?? LLMProvider.openRouter.rawValue
        let provider = LLMProvider(rawValue: savedProvider) ?? .openRouter
        _currentProvider = provider
        _currentModel = UserDefaults.standard.string(forKey: "llm_model") ?? provider.config.defaultModel

        if let docProvRaw = UserDefaults.standard.string(forKey: "doc_llm_provider"),
           let docProv = LLMProvider(rawValue: docProvRaw) {
            _documentProvider = docProv
            _documentModel = UserDefaults.standard.string(forKey: "doc_llm_model") ?? docProv.config.defaultModel
        }

        // Migrate stale model selections.
        if !_currentProvider.config.availableModels.contains(_currentModel) {
            _currentModel = _currentProvider.config.defaultModel
        }
        if let dp = _documentProvider, let dm = _documentModel,
           !dp.config.availableModels.contains(dm) {
            _documentModel = dp.config.defaultModel
        }
    }

    // MARK: - Service Factory

    private static func makeService(
        provider: LLMProvider,
        model: String,
        costTracker: LLMCostTracker?
    ) -> LLMServiceProtocol {
        switch provider {
        case .claude:
            return AnthropicService(model: model, costTracker: costTracker)
        default:
            return OpenAICompatibleService(provider: provider, model: model, costTracker: costTracker)
        }
    }
}
