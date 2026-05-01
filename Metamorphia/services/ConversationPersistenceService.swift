import Foundation
import MetamorphiaAgentKit

/// Owns `conversation.json` for the AI command bar — persists turns across
/// app launches so the agent retains genuine continuity. Turns are
/// salience-weighted: turns the user actually re-references stay strong;
/// stale ones decay and eventually fall off.
///
/// Read paths (`decayedAndCapped`, `previousChatMessages`) are pure: they
/// snapshot, apply decay locally, and return — they never mutate stored
/// state. The single write path is `record(turns:)`, called from the
/// viewModel's debounced Combine sink whenever `conversation` changes.
@MainActor
public final class ConversationPersistenceService {

    // MARK: - DTOs

    /// On-disk representation of `AICommandViewModel.Turn`. Carries synaptic
    /// metadata so each turn participates in the biological memory model.
    public struct PersistedTurn: Codable, Sendable, Potentiated {
        public let id: UUID
        public let prompt: String
        public var result: String
        public var toolPills: [PersistedPill]
        public var isError: Bool
        public var strength: SynapticStrength
        public var lastAccessed: Date
        public var accessCount: Int
        public let createdAt: Date

        public static var decayTau: TimeInterval { SynapseDefaults.tauEpisodic }

        private enum CodingKeys: String, CodingKey {
            case id, prompt, result, toolPills, isError,
                 strength, lastAccessed, accessCount, createdAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            self.prompt = try c.decode(String.self, forKey: .prompt)
            self.result = try c.decode(String.self, forKey: .result)
            self.toolPills = try c.decode([PersistedPill].self, forKey: .toolPills)
            // Default `false` so files written before T3 decode cleanly.
            self.isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            self.strength = try c.decode(SynapticStrength.self, forKey: .strength)
            self.lastAccessed = try c.decode(Date.self, forKey: .lastAccessed)
            self.accessCount = try c.decode(Int.self, forKey: .accessCount)
            self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        }

        public init(
            id: UUID, prompt: String, result: String,
            toolPills: [PersistedPill], isError: Bool = false,
            strength: SynapticStrength, lastAccessed: Date,
            accessCount: Int, createdAt: Date
        ) {
            self.id = id; self.prompt = prompt; self.result = result
            self.toolPills = toolPills; self.isError = isError
            self.strength = strength; self.lastAccessed = lastAccessed
            self.accessCount = accessCount; self.createdAt = createdAt
        }
    }

    /// Display-only mirror of `AICommandViewModel.ToolCallPill`. Tool-call
    /// arguments aren't carried — restoring them would feed the LLM
    /// fabricated context.
    public struct PersistedPill: Codable, Sendable {
        public let id: UUID
        public let toolName: String
        public let stepIndex: Int
        public let totalSteps: Int
        public let isComplete: Bool
        public let isSuccess: Bool
    }

    // MARK: - State

    private let storageURL: URL
    private let writeDebounce: TimeInterval
    private let writeQueue = DispatchQueue(label: "ConversationPersistence.write", qos: .utility)
    private var pendingWrite: DispatchWorkItem?

    public private(set) var turns: [PersistedTurn] = []

    public init(storageURL: URL, writeDebounce: TimeInterval = 0.5) {
        self.storageURL = storageURL
        self.writeDebounce = writeDebounce
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        load()
    }

    // MARK: - Read (pure — no mutation, no I/O)

    /// Apply lazy decay to a snapshot, drop eligibles, take strongest
    /// `maxTurns`. Does NOT mutate `self.turns` or schedule a write — safe to
    /// call from inspection/hydration paths.
    public func decayedAndCapped(maxTurns: Int) -> [PersistedTurn] {
        let now = Date()
        var snapshot = turns
        for i in snapshot.indices { snapshot[i].lazilyDecay(now: now) }
        snapshot.removeAll { $0.strength.isEligibleForEviction }
        if snapshot.count > maxTurns {
            snapshot.sort { $0.strength.value > $1.strength.value }
            snapshot.removeLast(snapshot.count - maxTurns)
        }
        return snapshot
    }

    /// Build the `previousMessages` list for `AgentLoop.submit(...)`. Pure
    /// read. LTP for prior turns happens in `record(turns:)`, gated on actual
    /// textual recall — *not* on context-window inclusion. Without that
    /// gating, every prior turn would saturate just by being in scope.
    public func previousChatMessages(maxTurns: Int = 20) -> [ChatMessage] {
        let kept = decayedAndCapped(maxTurns: maxTurns)
            .sorted { $0.createdAt < $1.createdAt }
        var out: [ChatMessage] = []
        for t in kept {
            out.append(ChatMessage(role: "user", content: t.prompt))
            if !t.result.isEmpty {
                out.append(ChatMessage(role: "assistant", content: t.result))
            }
        }
        return out
    }

    // MARK: - Write (sole authority over `self.turns`)

    /// Merge the live conversation into the persisted store. The single write
    /// path. For each live turn:
    ///   - if already persisted (matched by UUID): apply decay, copy streaming
    ///     UI fields, and reinforce ONLY when the new prompt's tokens overlap
    ///     with the turn's content (real user recall, not mere co-presence).
    ///   - if new: insert at baseline strength.
    public func record(turns liveTurns: [AICommandViewModel.Turn]) {
        let now = Date()

        // Defensive uniquing on the existing set — a corrupted conversation.json
        // or a viewModel duplicate id must NOT trap (`uniqueKeysWithValues:` does).
        let byId = Dictionary(
            self.turns.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        // Tokens from any turns that are new in this record. These drive the
        // recall-based LTP on previously-persisted turns: a turn gets
        // potentiated when the user's *new* prompt actually mentions its
        // content, not just because both happen to fit in the context window.
        let newTurnTokens: Set<String> = {
            let newPrompts = liveTurns
                .filter { byId[$0.id] == nil }
                .map(\.prompt)
                .joined(separator: " ")
            return Self.tokenize(newPrompts)
        }()

        var seen: Set<UUID> = []
        self.turns = liveTurns.compactMap { live in
            guard seen.insert(live.id).inserted else { return nil }

            let pills = live.toolPills.map { p in
                PersistedPill(
                    id: p.id, toolName: p.toolName,
                    stepIndex: p.stepIndex, totalSteps: p.totalSteps,
                    isComplete: p.isComplete, isSuccess: p.isSuccess
                )
            }

            if var existing = byId[live.id] {
                existing.lazilyDecay(now: now)
                existing.result = live.result
                existing.toolPills = pills
                existing.isError = live.isError
                let rel = Self.relevance(turn: existing, queryTokens: newTurnTokens)
                if rel > 0 {
                    existing.reinforceOnRecall(
                        delta: SynapseDefaults.ltpDelta * rel,
                        now: now
                    )
                }
                return existing
            }

            return PersistedTurn(
                id: live.id,
                prompt: live.prompt,
                result: live.result,
                toolPills: pills,
                isError: live.isError,
                strength: SynapticStrength(SynapseDefaults.baseline),
                lastAccessed: now,
                accessCount: 0,
                createdAt: now
            )
        }
        scheduleWrite()
    }

    /// Synchronously empty the store and cancel any pending debounced write.
    /// Used by `AICommandViewModel.clearConversation()` so the immediately
    /// following `submit` does not leak prior history through
    /// `previousChatMessages`.
    public func clearAndFlush() {
        turns = []
        writeQueue.sync {
            self.pendingWrite?.cancel()
            self.pendingWrite = nil
        }
        writeSync()
    }

    /// Test helper: synchronously cancel any pending debounced write and flush
    /// the current snapshot to disk.
    public func flushForTesting() {
        writeQueue.sync {
            self.pendingWrite?.cancel()
            self.pendingWrite = nil
        }
        writeSync()
    }

    // MARK: - I/O

    private func scheduleWrite() {
        let snapshot = turns
        let url = storageURL
        let debounce = writeDebounce
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingWrite?.cancel()
            let item = DispatchWorkItem {
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    try data.write(to: url, options: .atomic)
                } catch {
                    print("[ConversationPersistence] save failed: \(error)")
                }
            }
            self.pendingWrite = item
            self.writeQueue.asyncAfter(deadline: .now() + debounce, execute: item)
        }
    }

    private func writeSync() {
        let snapshot = turns
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[ConversationPersistence] save failed: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            var loaded = try JSONDecoder().decode([PersistedTurn].self, from: data)
            // Defend against duplicate ids on disk (corruption / hand-edit).
            var seen: Set<UUID> = []
            loaded = loaded.filter { seen.insert($0.id).inserted }
            let now = Date()
            for i in loaded.indices { loaded[i].lazilyDecay(now: now) }
            turns = loaded
        } catch {
            print("[ConversationPersistence] load failed: \(error)")
        }
    }

    // MARK: - Tokenization & relevance

    private static func tokenize(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 2 })
    }

    /// Fraction of `queryTokens` that appear in the turn's prompt or result.
    /// Returns 0 for empty query (no recall signal).
    private static func relevance(turn: PersistedTurn, queryTokens: Set<String>) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let combined = (turn.prompt + " " + turn.result).lowercased()
        let hits = queryTokens.filter { combined.contains($0) }.count
        return min(1.0, Double(hits) / Double(queryTokens.count))
    }
}
