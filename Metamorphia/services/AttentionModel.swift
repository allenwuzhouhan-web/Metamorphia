/*
 * Metamorphia
 * Continuum Phase 6 — Attention model.
 *
 * Learns the user's engagement windows from behavioural signals (command bar
 * submissions, surface engagements/dismissals, idle detection, wake events)
 * and exposes a `currentScore` in [0, 1] for gating proactive surfaces in
 * later phases. Zero explicit configuration; entirely observational.
 *
 * Design notes:
 * - 7 × 24 = 168 buckets indexed by (dayOfWeek, hour).
 * - Additive gradient per sample (score += delta * α, clamped [0,1]); decay toward 0.7 for stale buckets.
 * - @MainActor singleton: SwiftUI can observe `currentScore` directly.
 * - Idle detection via CGEventSource (Quartz). Requires no special entitlement
 *   beyond the Accessibility permission the app already requests; the
 *   `combinedSessionState` source type counts HID events without per-key
 *   surveillance.
 */

import AppKit
import Combine
import Defaults
import Foundation

#if canImport(MetamorphiaAgentKit)
import MetamorphiaAgentKit
#endif

// MARK: - Public types

public struct AttentionSample: Sendable, Codable, Hashable {
    public let at: Date
    public let kind: AttentionSampleKind
    /// Relative weight of this signal. Typical = 1.0; pass 0.5 for weak signals.
    public let weight: Double

    public init(at: Date = .now, kind: AttentionSampleKind, weight: Double = 1.0) {
        self.at = at
        self.kind = kind
        self.weight = weight
    }
}

public enum AttentionSampleKind: String, Sendable, Codable, CaseIterable {
    case commandBarSubmission
    case surfaceEngagement    // user clicked/read a proactive surface
    case surfaceDismissal     // user dismissed without reading
    case surfaceIgnored       // surface timed out without interaction
    case idleDetected         // user idle > idleThreshold during this bucket
    case wake                 // mac resumed from sleep
}

public struct AttentionBucket: Sendable, Codable, Hashable {
    public let dayOfWeek: Int      // 1 = Sunday … 7 = Saturday (Calendar convention)
    public let hour: Int           // 0…23
    public var engagementScore: Double   // [0, 1]
    public var sampleCount: Int
    public var lastUpdated: Date

    /// Stable dictionary key without Hashable weirdness across codecs.
    var key: BucketKey { BucketKey(dayOfWeek: dayOfWeek, hour: hour) }
}

// MARK: - AttentionModel

extension Defaults.Keys {
    static let attentionModelEnabled = Key<Bool>("continuum.attentionModelEnabled", default: true)
}

@MainActor
public final class AttentionModel: ObservableObject {

    public static let shared = AttentionModel()

    // MARK: - Published state

    /// Score for the current (dayOfWeek, hour) bucket, averaged over ±1 hour.
    /// Always 1.0 when `attentionModelEnabled == false` (surface everything).
    @Published public private(set) var currentScore: Double = 0.7

    // MARK: - Private state

    private var buckets: [BucketKey: AttentionBucket] = [:]
    private var securePersistence: SecurePersistence?

    /// Write-queue + debounce work item — same idiom as WatchlistStore.
    private let writeQueue = DispatchQueue(label: "AttentionModel.write", qos: .utility)
    private var pendingWrite: DispatchWorkItem?
    private static let writeDebounce: TimeInterval = 5.0

    /// Timers
    private var scoreRefreshTimer: Timer?
    private var idleCheckTimer: Timer?

    /// Guard against double-recording idle within the same minute.
    private var lastIdleRecordMinute: Int = -1

    /// NSWorkspace wake observer token.
    private var wakeObserver: NSObjectProtocol?

    /// Combine subscriptions held for the lifetime of the model.
    private var cancellables: Set<AnyCancellable> = []

    private static let defaultScore: Double = 0.7
    private static let learningRate: Double = 0.15
    private static let decayDays: Double = 14.0
    private static let decayRate: Double = 0.05   // per day toward default
    private static let idleThreshold: TimeInterval = 300  // 5 minutes
    private static let idleCheckInterval: TimeInterval = 30

    // MARK: - Storage URL

    private static var storageURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Metamorphia", isDirectory: true)
            .appendingPathComponent("attention-model.enc")
    }

    // MARK: - Init (private — use .shared)

    private init() {}

    // MARK: - Lifecycle

    /// Start the model. Pass a `SecurePersistence` keyed to
    /// `"com.metamorphia.attention.v1"`. If nil, buckets are kept in memory
    /// only (data lost on quit).
    public func start(securePersistence: SecurePersistence?) {
        self.securePersistence = securePersistence
        loadFromDisk()
        startTimers()
        subscribeToWake()
        refreshCurrentScore()

        // Keep currentScore honest when the kill switch is toggled at runtime.
        // Flag off → score(at:) returns 1.0; flag on → reads the loaded bucket.
        Defaults.publisher(.attentionModelEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshCurrentScore() }
            .store(in: &cancellables)

        // WS-8: parallel subscription to InputIdleSensor events via ActivityStream.
        // Routes .inputIdle and .inputResumed through the same checkIdle() hook
        // used by the 30 s poll timer. The existing `lastIdleRecordMinute` guard
        // in checkIdle() handles double-recording if both paths fire within the
        // same clock minute — no additional dedup is needed here.
        // Guard: activityStream is nil in unit-test targets, so never force-unwrap.
        if let stream = MetamorphiaBootstrap.activityStream {
            stream.events
                .sink { [weak self] event in
                    switch event {
                    case .inputIdle:
                        // Treat an authoritative idle signal from InputIdleSensor
                        // the same way the 30 s timer does: record one idle sample,
                        // relying on lastIdleRecordMinute to suppress duplicates.
                        Task { @MainActor [weak self] in self?.checkIdle() }
                    case .inputResumed(let afterIdleSeconds, _):
                        // Input resumed: reset the per-minute idle guard so the
                        // next genuine idle is not suppressed, then record a
                        // weak negative-idle (positive engagement) signal.
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.lastIdleRecordMinute = -1
                            if afterIdleSeconds > 0 {
                                self.recordSample(AttentionSample(kind: .surfaceEngagement, weight: 0.5))
                            }
                        }
                    default:
                        break
                    }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Observation API

    public func recordSample(_ sample: AttentionSample) {
        guard Defaults[.attentionModelEnabled] else { return }
        applyDelta(for: sample)
        refreshCurrentScore()
        scheduleWrite()
    }

    public func recordCommandBarSubmission() {
        recordSample(AttentionSample(kind: .commandBarSubmission))
    }

    public func recordSurfaceEngagement() {
        recordSample(AttentionSample(kind: .surfaceEngagement))
    }

    public func recordSurfaceDismissal() {
        recordSample(AttentionSample(kind: .surfaceDismissal))
    }

    public func recordSurfaceIgnored() {
        recordSample(AttentionSample(kind: .surfaceIgnored))
    }

    // MARK: - Query API

    /// Score for the bucket containing `date`, averaged over ±1 hour.
    public func score(at date: Date) -> Double {
        guard Defaults[.attentionModelEnabled] else { return 1.0 }
        let cal = Calendar.current
        let components = cal.dateComponents([.weekday, .hour], from: date)
        guard let dow = components.weekday, let hr = components.hour else {
            return Self.defaultScore
        }
        var total = 0.0
        var count = 0
        for offset in [-1, 0, 1] {
            let h = (hr + offset + 24) % 24
            let key = BucketKey(dayOfWeek: dow, hour: h)
            let raw = decayedScore(for: key, asOf: date)
            total += raw
            count += 1
        }
        return count > 0 ? (total / Double(count)) : Self.defaultScore
    }

    /// Returns all known buckets, sorted by (dayOfWeek, hour). Used for
    /// settings / debug display.
    public func windowSummary() -> [AttentionBucket] {
        buckets.values.sorted {
            $0.dayOfWeek != $1.dayOfWeek
                ? $0.dayOfWeek < $1.dayOfWeek
                : $0.hour < $1.hour
        }
    }

    // MARK: - Kill switch

    public func forgetAll() {
        buckets.removeAll()
        currentScore = Self.defaultScore
        try? FileManager.default.removeItem(at: Self.storageURL)
    }

    // MARK: - Algorithm

    /// Compute the signed delta for a sample kind (multiplied by weight).
    private static func baseDelta(for kind: AttentionSampleKind) -> Double {
        switch kind {
        case .commandBarSubmission: return  0.10
        case .surfaceEngagement:    return  0.12
        case .surfaceDismissal:     return -0.04
        case .surfaceIgnored:       return -0.06
        case .idleDetected:         return -0.02
        case .wake:                 return  0.04
        }
    }

    private func applyDelta(for sample: AttentionSample) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.weekday, .hour], from: sample.at)
        guard let dow = comps.weekday, let hr = comps.hour else { return }
        let key = BucketKey(dayOfWeek: dow, hour: hr)

        var bucket = buckets[key] ?? AttentionBucket(
            dayOfWeek: dow,
            hour: hr,
            engagementScore: Self.defaultScore,
            sampleCount: 0,
            lastUpdated: sample.at
        )

        let delta = Self.baseDelta(for: sample.kind) * sample.weight
        // Additive gradient with learning rate α. Each sample nudges the bucket
        // score by `delta * α`, clamped to [0, 1]. This converges toward high
        // scores in active hours and low scores in ignored hours over a 14-day
        // horizon.
        let raw = bucket.engagementScore + delta * Self.learningRate
        bucket.engagementScore = max(0, min(1, raw))
        bucket.sampleCount += 1
        bucket.lastUpdated = sample.at
        buckets[key] = bucket
    }

    /// Return the score for `key`, applying time-based decay toward default
    /// when the bucket hasn't been updated in > 14 days. Lazy on read.
    private func decayedScore(for key: BucketKey, asOf date: Date) -> Double {
        guard var bucket = buckets[key] else { return Self.defaultScore }
        let ageDays = date.timeIntervalSince(bucket.lastUpdated) / 86_400
        guard ageDays > Self.decayDays else { return bucket.engagementScore }

        let extraDays = ageDays - Self.decayDays
        let decay = Self.decayRate * extraDays
        let pulled = bucket.engagementScore + (Self.defaultScore - bucket.engagementScore) * decay
        let clamped = max(0, min(1, pulled))
        // Write back lazily so the next read is cheaper.
        bucket.engagementScore = clamped
        bucket.lastUpdated = date
        buckets[key] = bucket
        return clamped
    }

    // MARK: - currentScore refresh

    private func refreshCurrentScore() {
        let s = score(at: Date())
        if abs(s - currentScore) > 0.001 {
            currentScore = s
        }
    }

    // MARK: - Timers

    private func startTimers() {
        // 60s timer to keep currentScore fresh even without new samples.
        scoreRefreshTimer?.invalidate()
        scoreRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCurrentScore() }
        }

        // 30s idle-check timer.
        idleCheckTimer?.invalidate()
        idleCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }

    private func checkIdle() {
        guard Defaults[.attentionModelEnabled] else { return }
        // CGEventSourceSecondsSinceLastEventType returns the number of seconds
        // since the last event from the combined session source (keyboard +
        // mouse + stylus). UInt32.max is the "any event" mask.
        let secondsSinceLast = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )
        guard secondsSinceLast > Self.idleThreshold else { return }

        // Guard: record at most once per calendar minute.
        let currentMinute = Calendar.current.component(.minute, from: Date())
        guard currentMinute != lastIdleRecordMinute else { return }
        lastIdleRecordMinute = currentMinute

        recordSample(AttentionSample(kind: .idleDetected))
    }

    // MARK: - Wake observation

    private func subscribeToWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recordSample(AttentionSample(kind: .wake))
            }
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        // Ensure the containing directory exists.
        let dir = Self.storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: Self.storageURL.path) else { return }
        do {
            let raw = try Data(contentsOf: Self.storageURL)
            let plaintext: Data
            if let sp = securePersistence {
                plaintext = try sp.decrypt(raw)
            } else {
                plaintext = raw
            }
            let loaded = try JSONDecoder().decode([AttentionBucket].self, from: plaintext)
            for bucket in loaded {
                buckets[bucket.key] = bucket
            }
        } catch {
            // Corrupt or key-changed — start clean. Buckets default to 0.7.
            print("[AttentionModel] load failed (\(error)); starting with defaults.")
            buckets = [:]
        }
    }

    private func scheduleWrite() {
        let snapshot = Array(buckets.values)
        let url = Self.storageURL
        let sp = securePersistence
        // Capture the constant locally to avoid the main-actor-isolation warning
        // in the DispatchQueue closure (same idiom WatchlistStore uses).
        let debounce = Self.writeDebounce

        pendingWrite?.cancel()
        let item = DispatchWorkItem {
            do {
                let data = try JSONEncoder().encode(snapshot)
                let toWrite: Data
                if let sp {
                    toWrite = try sp.encrypt(data)
                } else {
                    toWrite = data
                }
                try toWrite.write(to: url, options: .atomic)
            } catch {
                print("[AttentionModel] save failed: \(error)")
            }
        }
        pendingWrite = item
        writeQueue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}

// MARK: - BucketKey

/// Lightweight Hashable key for the bucket dictionary.
struct BucketKey: Hashable, Sendable {
    let dayOfWeek: Int   // 1…7
    let hour: Int        // 0…23
}
