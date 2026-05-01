import Foundation

/// Tracks API token usage and costs per provider.
///
/// Conforms to ``LLMCostTracker`` so `AnthropicService` and `OpenAICompatibleService`
/// can record usage. Notifies an optional handler when the daily budget is exceeded,
/// but **never blocks execution** — budget enforcement is advisory.
///
/// Sever change vs. Executer: `NotificationCenter.default.post(name: .costBudgetExceeded)`
/// is replaced with an injected `budgetExceededHandler: ((String) -> Void)?`. The app
/// target wires this to its own UI / notification surface.
public final class CostTracker: LLMCostTracker, AgentLoopCostReader, @unchecked Sendable {

    // MARK: - AgentLoopCostReader

    /// Expose cumulative daily spend so ``AgentLoop`` can enforce a per-task
    /// cost ceiling by diffing against a snapshot captured at task start.
    public var currentSpendUSD: Double { currentDailyCostUSD }


    // MARK: - Constants

    public static let yuanToUSD: Double = 0.14

    // MARK: - Per-Provider Pricing (USD per 1M tokens)

    private let pricing: [String: (input: Double, output: Double)] = [
        "claude":   (input: 3.00,  output: 15.00),
        "deepseek": (input: 0.14,  output: 0.28),
        "gemini":   (input: 0.075, output: 0.30),
        "kimi":     (input: 0.70,  output: 0.70),
        "kimicn":   (input: 0.70,  output: 0.70),
        "minimax":  (input: 0.15,  output: 0.15),
    ]

    // MARK: - State

    private var dailyInputTokens: Int = 0
    private var dailyOutputTokens: Int = 0
    public private(set) var learningTokensToday: Int = 0
    private var dailyCostUSD: Double = 0.0
    private var monthlyCostUSD: Double = 0.0
    private var lastResetDate: Date
    private var lastMonthlyResetDate: Date
    private var hasNotifiedToday = false
    private var agentCosts: [String: Double] = [:]
    private var agentTokens: [String: Int] = [:]

    // MARK: - Session Budget (for overnight exploration)

    private var sessionProviderCostUSD: [String: Double] = [:]

    /// Active agent id for cost attribution. Used by LLM services when recording.
    public var activeAgentId: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _activeAgentId
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _activeAgentId = newValue
        }
    }
    private var _activeAgentId: String? = "general"

    /// Called when daily spend first exceeds the daily budget in a given day.
    /// App target wires this to its UI / notification surface.
    public var budgetExceededHandler: ((_ message: String) -> Void)?

    private let lock = NSLock()
    private let defaults: UserDefaults

    // MARK: - Budget Thresholds (user-configurable, advisory)

    public var dailyBudgetUSD: Double {
        get { defaults.double(forKey: "cost_daily_budget") }
        set { defaults.set(newValue, forKey: "cost_daily_budget") }
    }

    public var monthlyBudgetUSD: Double {
        get { defaults.double(forKey: "cost_monthly_budget") }
        set { defaults.set(newValue, forKey: "cost_monthly_budget") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: "cost_daily_budget") == nil {
            defaults.set(5.0, forKey: "cost_daily_budget")
        }
        if defaults.object(forKey: "cost_monthly_budget") == nil {
            defaults.set(50.0, forKey: "cost_monthly_budget")
        }

        dailyCostUSD = defaults.double(forKey: "cost_daily_total")
        monthlyCostUSD = defaults.double(forKey: "cost_monthly_total")
        dailyInputTokens = defaults.integer(forKey: "cost_daily_input_tokens")
        dailyOutputTokens = defaults.integer(forKey: "cost_daily_output_tokens")
        lastResetDate = defaults.object(forKey: "cost_last_reset") as? Date ?? Date()
        lastMonthlyResetDate = defaults.object(forKey: "cost_last_monthly_reset") as? Date ?? Date()

        checkAndResetIfNeededUnlocked()
    }

    // MARK: - LLMCostTracker

    public func record(provider: String, inputTokens: Int, outputTokens: Int, agentId: String?) {
        let effectiveAgent = agentId ?? "general"
        lock.lock()
        defer { lock.unlock() }

        checkAndResetIfNeededUnlocked()

        let providerKey = provider.lowercased()
        let rates = pricing[providerKey] ?? (input: 1.0, output: 1.0)

        let inputCost = Double(inputTokens) / 1_000_000 * rates.input
        let outputCost = Double(outputTokens) / 1_000_000 * rates.output
        let callCost = inputCost + outputCost

        dailyInputTokens += inputTokens
        dailyOutputTokens += outputTokens
        dailyCostUSD += callCost
        monthlyCostUSD += callCost

        agentCosts[effectiveAgent, default: 0] += callCost
        agentTokens[effectiveAgent, default: 0] += inputTokens + outputTokens

        sessionProviderCostUSD[providerKey, default: 0] += callCost

        defaults.set(dailyCostUSD, forKey: "cost_daily_total")
        defaults.set(monthlyCostUSD, forKey: "cost_monthly_total")
        defaults.set(dailyInputTokens, forKey: "cost_daily_input_tokens")
        defaults.set(dailyOutputTokens, forKey: "cost_daily_output_tokens")

        if !hasNotifiedToday && dailyCostUSD > dailyBudgetUSD {
            hasNotifiedToday = true
            let message = String(format: "Daily API spend: $%.2f (budget: $%.2f)", dailyCostUSD, dailyBudgetUSD)
            print("[CostTracker] \(message)")
            // Call the handler off-lock to avoid reentrancy.
            let handler = self.budgetExceededHandler
            DispatchQueue.main.async {
                handler?(message)
            }
        }
    }

    /// Record tokens from learning-context injection (for accounting).
    public func recordLearningOverhead(tokens: Int) {
        lock.lock()
        learningTokensToday += tokens
        lock.unlock()
    }

    // MARK: - Queries

    public var currentDailyCostUSD: Double {
        lock.lock(); defer { lock.unlock() }
        return dailyCostUSD
    }

    public func isOverDailyBudget() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return dailyCostUSD > dailyBudgetUSD
    }

    public func dailyReport() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(format: "Today: $%.2f / $%.2f budget | %d input + %d output tokens | Month: $%.2f / $%.2f",
                      dailyCostUSD, dailyBudgetUSD,
                      dailyInputTokens, dailyOutputTokens,
                      monthlyCostUSD, monthlyBudgetUSD)
    }

    public func agentBreakdown() -> [(agentId: String, cost: Double, tokens: Int)] {
        lock.lock(); defer { lock.unlock() }
        return agentCosts.map { (agentId: $0.key, cost: $0.value, tokens: agentTokens[$0.key] ?? 0) }
            .sorted { $0.cost > $1.cost }
    }

    // MARK: - Session Budget (Overnight Exploration)

    public func startExplorationSession() {
        lock.lock()
        sessionProviderCostUSD.removeAll()
        lock.unlock()
    }

    public func sessionCostYuan(provider: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        let usd = sessionProviderCostUSD[provider.lowercased()] ?? 0
        return usd / Self.yuanToUSD
    }

    public func isOverSessionBudget(provider: String, budgetYuan: Double) -> Bool {
        sessionCostYuan(provider: provider) >= budgetYuan
    }

    public func sessionCostSummary() -> [(provider: String, yuan: Double)] {
        lock.lock(); defer { lock.unlock() }
        return sessionProviderCostUSD.map { ($0.key, $0.value / Self.yuanToUSD) }
            .sorted { $0.yuan > $1.yuan }
    }

    // MARK: - Reset

    private func checkAndResetIfNeededUnlocked() {
        let calendar = Calendar.current
        let now = Date()

        if !calendar.isDate(lastResetDate, inSameDayAs: now) {
            dailyCostUSD = 0
            dailyInputTokens = 0
            dailyOutputTokens = 0
            hasNotifiedToday = false
            learningTokensToday = 0
            agentCosts.removeAll()
            agentTokens.removeAll()
            lastResetDate = now
            defaults.set(0.0, forKey: "cost_daily_total")
            defaults.set(0, forKey: "cost_daily_input_tokens")
            defaults.set(0, forKey: "cost_daily_output_tokens")
            defaults.set(now, forKey: "cost_last_reset")
        }

        if calendar.component(.month, from: lastMonthlyResetDate) != calendar.component(.month, from: now) {
            monthlyCostUSD = 0
            lastMonthlyResetDate = now
            defaults.set(0.0, forKey: "cost_monthly_total")
            defaults.set(now, forKey: "cost_last_monthly_reset")
        }
    }
}
