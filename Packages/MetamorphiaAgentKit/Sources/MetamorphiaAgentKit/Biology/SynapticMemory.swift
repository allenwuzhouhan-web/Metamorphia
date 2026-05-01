import Foundation

/// A `Codable` value in `[0, 1]` modeling AMPA-receptor density at a synapse.
///
/// Higher → more strongly retrieved on recall. Mutators model NMDA-gated
/// long-term potentiation (`reinforce`) and the forgetting curve (`decay`).
public struct SynapticStrength: Codable, Sendable, Hashable {
    public private(set) var value: Double

    public init(_ v: Double = SynapseDefaults.baseline) {
        self.value = max(0.0, min(1.0, v))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Double.self)
        self.value = max(0.0, min(1.0, raw))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// NMDA-gated long-term potentiation. Saturates near 1.0:
    /// `value + δ·(1 − value)` — a 0.05 delta moves 0.2 → 0.24, but only 0.9 → 0.905.
    public mutating func reinforce(delta: Double = SynapseDefaults.ltpDelta) {
        guard delta > 0 else { return }
        let headroom = 1.0 - value
        value = min(1.0, value + delta * headroom)
    }

    /// Exponential synaptic decay (forgetting curve). No-op for non-positive args.
    public mutating func decay(elapsed: TimeInterval, tau: TimeInterval) {
        guard elapsed > 0, tau > 0 else { return }
        value = max(0.0, value * exp(-elapsed / tau))
    }

    public var isEligibleForEviction: Bool {
        value < SynapseDefaults.evictionThreshold
    }
}

/// Tunable constants for the biological-memory model. Kept in one place so
/// retraining the system is a numerical edit, not a code refactor.
public enum SynapseDefaults {
    public static let baseline: Double = 0.5
    public static let ltpDelta: Double = 0.05
    public static let evictionThreshold: Double = 0.05

    public static let tauSemantic: TimeInterval = 14 * 86_400
    public static let tauProcedural: TimeInterval = 7 * 86_400
    public static let tauEpisodic: TimeInterval = 3 * 86_400
}

/// A persisted record that participates in the synaptic-strength model.
///
/// Concrete records (file-backed memories, intent-scorer patterns,
/// conversation turns) conform so they share decay/reinforcement logic.
public protocol Potentiated {
    var strength: SynapticStrength { get set }
    var lastAccessed: Date { get set }
    var accessCount: Int { get set }
    var createdAt: Date { get }
    /// Static fallback tau — kept for backward compatibility.
    /// Conforming types that need per-instance tau override `decayTau` (var).
    static var decayTau: TimeInterval { get }
    /// Per-instance tau. Defaults to `Self.decayTau` so existing conformers
    /// need no changes, but types like `InterestNode` or `PersistedMemory` can
    /// return a per-record value.
    var decayTau: TimeInterval { get }
}

public extension Potentiated {
    /// Default implementation reads the instance `decayTau` so per-record
    /// tau overrides work without any changes to call sites.
    var decayTau: TimeInterval { Self.decayTau }

    /// Bring `strength` up to date with the wall clock, then update
    /// `lastAccessed` so the next decay measures from now.
    mutating func lazilyDecay(now: Date = Date()) {
        let elapsed = now.timeIntervalSince(lastAccessed)
        strength.decay(elapsed: elapsed, tau: decayTau)
        lastAccessed = now
    }

    /// LTP step on retrieval — a recalled memory gets stronger, modeling
    /// reconsolidation.
    mutating func reinforceOnRecall(
        delta: Double = SynapseDefaults.ltpDelta,
        now: Date = Date()
    ) {
        strength.reinforce(delta: delta)
        lastAccessed = now
        accessCount += 1
    }
}

/// Generic envelope for arbitrary payloads that need synaptic metadata
/// without redefining `lastAccessed`/`accessCount`/`createdAt` themselves.
///
/// Default τ is episodic (3 days).
public struct PotentiatedRecord<Payload: Codable & Sendable>: Codable, Sendable, Potentiated {
    public var payload: Payload
    public var strength: SynapticStrength
    public var lastAccessed: Date
    public var accessCount: Int
    public let createdAt: Date

    public static var decayTau: TimeInterval { SynapseDefaults.tauEpisodic }

    public init(
        payload: Payload,
        strength: SynapticStrength = SynapticStrength(),
        now: Date = Date()
    ) {
        self.payload = payload
        self.strength = strength
        self.lastAccessed = now
        self.accessCount = 0
        self.createdAt = now
    }
}
