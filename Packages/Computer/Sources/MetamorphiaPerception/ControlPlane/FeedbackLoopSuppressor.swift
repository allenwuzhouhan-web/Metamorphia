import CoreGraphics
import Foundation

// MARK: - FeedbackLoopSuppressor

/// Tags agent-initiated UI actions so the perception layer ignores its own effects.
public actor FeedbackLoopSuppressor {

    /// Mouse button for click suppression. Scoped under the actor to avoid
    /// collisions with `GestureExecutor.MouseButton` (which has an identical
    /// case set but lives in a separate module).
    public enum MouseButton: Sendable, Hashable {
        case left, right, other
    }

    public static let shared = FeedbackLoopSuppressor()

    private var outstanding: [HandleEntry] = []
    private let maxOutstanding = 32

    // Constant let — accessible from nonisolated contexts without isolation crossing.
    private let snapshotBox = SnapshotBox()

    // MARK: - Public API

    /// Call before CGEvent.post. Returns a handle that correlates back to this action.
    public func beginAction(
        kind: ActionKind,
        expectedLatency: TimeInterval = 0.6
    ) -> ActionHandle {
        sweep()
        let handle = ActionHandle(
            id: UUID(),
            kind: kind,
            expiresAt: Date().addingTimeInterval(expectedLatency + 0.2)
        )
        if outstanding.count >= maxOutstanding {
            outstanding.removeFirst()
        }
        outstanding.append(HandleEntry(handle: handle, consumed: false))
        publishSnapshot()
        return handle
    }

    /// Removes the handle before it fires, so the next real user event is not suppressed.
    public func cancel(_ handle: ActionHandle) {
        outstanding.removeAll { $0.handle.id == handle.id }
        publishSnapshot()
    }

    /// Open a span-length handle for a multi-step agent action. The returned
    /// handle lives for `expectedLatency` seconds by default — long enough to
    /// cover a reasonable batch (step dispatch + recapture + verify) without
    /// masking real user events that arrive after the batch completes. Pair
    /// with `endBatch(_:)` to close the span early.
    public func beginBatch(
        id: UUID = UUID(),
        expectedLatency: TimeInterval = 4.0
    ) -> ActionHandle {
        beginAction(kind: .batch(id), expectedLatency: expectedLatency)
    }

    /// Close a batch span issued by `beginBatch`. Alias for `cancel` — kept as
    /// a distinct name so call sites read symmetrically (`begin…` / `end…`).
    public func endBatch(_ handle: ActionHandle) {
        cancel(handle)
    }

    /// Hot-path classification. nonisolated; all mutation happens atomically
    /// inside the SnapshotBox's lock so racing classify() calls cannot both
    /// match the same handle.
    public nonisolated func classify(
        fingerprint: EventFingerprint,
        at: Date = Date()
    ) -> Origin {
        snapshotBox.classify(now: at) { [fingerprint] handle in
            Self.fingerprintMatches(fingerprint, handle: handle, at: at)
        }
    }

    private func sweep() {
        let now = Date()
        outstanding.removeAll { $0.handle.expiresAt < now }
    }

    private func publishSnapshot() {
        snapshotBox.write(outstanding)
    }

    // MARK: - Pure matching (static, operates only on value types)

    private static func fingerprintMatches(
        _ fingerprint: EventFingerprint,
        handle: ActionHandle,
        at now: Date
    ) -> Bool {
        // elapsed is measured from when the handle was registered.
        let registeredAt = handle.expiresAt.addingTimeInterval(-(0.6 + 0.2))
        let elapsed = now.timeIntervalSince(registeredAt) * 1000 // ms

        switch (fingerprint.kind, handle.kind) {
        case let (.click(fPoint, fButton), .click(hPoint, hButton)):
            guard fButton == hButton else { return false }
            let dist = hypot(fPoint.x - hPoint.x, fPoint.y - hPoint.y)
            return dist <= 24 && elapsed >= 50 && elapsed <= 800

        case let (.key(fCode), .key(hCode)):
            return fCode == hCode && elapsed >= 50 && elapsed <= 400

        case (.paste, .paste):
            return elapsed >= 50 && elapsed <= 800

        default:
            return false
        }
    }
}

// MARK: - Supporting public types

public enum ActionKind: Sendable, Hashable {
    case click(CGPoint, FeedbackLoopSuppressor.MouseButton)
    case key(CGKeyCode)
    case paste
    case scroll(CGPoint)
    /// Span marker for a multi-step agent action (computer_batch). The UUID
    /// correlates with the batch result so observers can group intermediate
    /// per-step handles (.click/.key/.paste) under one semantic operation
    /// instead of treating each as an unrelated event. The batch kind itself
    /// never matches a user-event fingerprint — it only exists as a
    /// longer-lived handle whose presence signals "an agent batch is active".
    case batch(UUID)
}

public enum Origin: Sendable, Hashable, Codable {
    case user
    case agent(UUID)
    case ambiguous
}

public struct EventFingerprint: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case click(CGPoint, FeedbackLoopSuppressor.MouseButton)
        case key(CGKeyCode)
        case paste
    }
    public let kind: Kind
    public let at: Date
    public init(kind: Kind, at: Date = Date()) { self.kind = kind; self.at = at }
}

public struct ActionHandle: Sendable, Hashable {
    public let id: UUID
    public let kind: ActionKind
    public let expiresAt: Date
}

// MARK: - Internal types (file-private so SnapshotBox can reference them)

struct HandleEntry: Sendable {
    let handle: ActionHandle
    var consumed: Bool
}

// MARK: - Snapshot box

/// Reference-type box that holds the NSLock-protected snapshot for nonisolated
/// classify(). Writers from the actor call `write(_:)` to publish a fresh list;
/// prior consumed flags are preserved by handle ID so a mid-write publish
/// can't un-consume a just-matched handle.
///
/// `classify(now:matcher:)` runs the match and marks the winner consumed
/// inside a single lock acquisition — this is what makes double-suppression
/// of racing identical events impossible.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [HandleEntry] = []

    func write(_ newEntries: [HandleEntry]) {
        lock.withLock {
            let consumedIDs = Set(entries.filter(\.consumed).map { $0.handle.id })
            entries = newEntries.map {
                consumedIDs.contains($0.handle.id) ? HandleEntry(handle: $0.handle, consumed: true) : $0
            }
        }
    }

    func classify(now: Date, matcher: (ActionHandle) -> Bool) -> Origin {
        lock.withLock {
            var matched: [Int] = []
            for (i, entry) in entries.enumerated() {
                guard !entry.consumed, entry.handle.expiresAt > now else { continue }
                if matcher(entry.handle) { matched.append(i) }
            }
            switch matched.count {
            case 0: return .user
            case 1:
                let winner = matched[0]
                entries[winner].consumed = true
                return .agent(entries[winner].handle.id)
            default: return .ambiguous
            }
        }
    }
}
