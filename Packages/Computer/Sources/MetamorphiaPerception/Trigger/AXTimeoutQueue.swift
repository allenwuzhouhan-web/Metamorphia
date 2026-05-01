import Foundation

// MARK: - Errors

public struct AXTimeoutError: Error, Sendable {
    public let pid: pid_t
    public let timeout: TimeInterval

    public init(pid: pid_t, timeout: TimeInterval) {
        self.pid = pid
        self.timeout = timeout
    }
}

public struct AXPoisonedError: Error, Sendable {
    public let pid: pid_t
    public let poisonedUntil: Date

    public init(pid: pid_t, poisonedUntil: Date) {
        self.pid = pid
        self.poisonedUntil = poisonedUntil
    }
}

// MARK: - AXTimeoutQueue

/// Bounded-timeout wrapper for synchronous AX IPC calls.
///
/// AX attribute reads can stall indefinitely when a target process is
/// unresponsive (spinning, sleeping, or under GCD pressure). This queue
/// imposes a hard deadline per call and poisons the offending pid for a
/// short window so the rest of the pipeline can keep moving.
///
/// **Poison semantics:** when a call times out, the pid is marked as
/// poisoned for `poisonWindow` seconds. Any subsequent call for the same
/// pid within that window returns `AXPoisonedError` immediately without
/// touching the serial queue. Once the window expires the pid is silently
/// cleared and normal calls resume.
///
/// **Serial queue note:** calls for DIFFERENT pids run one-at-a-time through
/// the shared serial queue. A single slow pid does NOT block calls for other
/// pids from being submitted — the timed-out work item is abandoned (the
/// semaphore times out on the caller side) and the queue drains naturally.
/// However, the one abandoned item DOES occupy the serial queue until the
/// underlying AX call returns. For sustained cross-pid parallelism, callers
/// should use separate `AXTimeoutQueue` instances; this shared singleton is
/// designed for infrequent burst reads (focus changes, window events).
public final class AXTimeoutQueue: @unchecked Sendable {
    public static let shared = AXTimeoutQueue()

    private let queue = DispatchQueue(label: "com.metamorphia.ax.timeout", qos: .userInitiated)
    private let poisonLock = NSLock()
    private var poisonedPids: [pid_t: Date] = [:]
    private let poisonWindow: TimeInterval = 5.0
    private let defaultTimeout: TimeInterval = 0.15

    // Sweep counter — purge expired poisons every N lock acquisitions to avoid
    // unbounded growth in long-running processes that cycle through many pids.
    private var sweepCounter: Int = 0
    private let sweepInterval: Int = 16

    public init() {}

    // MARK: - Public API

    /// Synchronously run `body` on the serial queue with a bounded timeout.
    ///
    /// - Parameters:
    ///   - pid: The process identifier for the AX call. Used for poison tracking.
    ///   - timeout: Wall-clock deadline. Defaults to 150 ms when nil.
    ///   - body: The AX work to run. Must not capture mutable shared state
    ///     without its own synchronisation — it executes on a private serial
    ///     queue, potentially after the caller's thread has returned.
    /// - Returns: The value returned by `body`.
    /// - Throws: `AXPoisonedError` if the pid is currently poisoned,
    ///   or `AXTimeoutError` if `body` does not complete within `timeout`.
    public func run<T: Sendable>(
        pid: pid_t,
        timeout: TimeInterval? = nil,
        _ body: @escaping @Sendable () -> T
    ) throws -> T {
        // Fast path: check poison before touching the queue.
        if let expiry = poisonExpiry(pid: pid) {
            throw AXPoisonedError(pid: pid, poisonedUntil: expiry)
        }

        let deadline: TimeInterval = timeout ?? defaultTimeout
        let sem = DispatchSemaphore(value: 0)
        let boxLock = NSLock()
        var result: T?

        queue.async {
            let value = body()
            boxLock.withLock { result = value }
            sem.signal()
        }

        if sem.wait(timeout: .now() + deadline) == .timedOut {
            // The body is still running on the queue. We abandon the result
            // (boxLock + result box let it complete safely) and poison the pid.
            poisonLock.withLock {
                poisonedPids[pid] = Date().addingTimeInterval(poisonWindow)
                sweepExpiredPoisons()
            }
            throw AXTimeoutError(pid: pid, timeout: deadline)
        }

        return boxLock.withLock { result! }
    }

    /// Returns true if this pid is currently in the poison window.
    public func isPoisoned(pid: pid_t) -> Bool {
        poisonExpiry(pid: pid) != nil
    }

    /// Clears the poison entry for this pid immediately, allowing future calls.
    public func clearPoison(pid: pid_t) {
        poisonLock.withLock {
            poisonedPids.removeValue(forKey: pid)
        }
    }

    // MARK: - Private

    /// Returns the expiry date if the pid is currently poisoned, nil otherwise.
    /// Also sweeps expired entries on every `sweepInterval`-th call.
    private func poisonExpiry(pid: pid_t) -> Date? {
        poisonLock.withLock {
            sweepExpiredPoisons()
            guard let expiry = poisonedPids[pid] else { return nil }
            if Date() >= expiry {
                poisonedPids.removeValue(forKey: pid)
                return nil
            }
            return expiry
        }
    }

    /// Purge all expired entries. Must be called with `poisonLock` held.
    private func sweepExpiredPoisons() {
        sweepCounter += 1
        guard sweepCounter % sweepInterval == 0 else { return }
        let now = Date()
        poisonedPids = poisonedPids.filter { $0.value > now }
    }
}
