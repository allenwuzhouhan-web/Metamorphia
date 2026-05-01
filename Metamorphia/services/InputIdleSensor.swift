/*
 * Metamorphia
 * Continuum — Input-idle sensor.
 *
 * Polls CGEventSource every 5 seconds to detect when the user's input has
 * been absent for `idleThresholdSeconds` and emits typed ActivityEvents into
 * the activity spine.
 *
 * Design notes:
 * - Uses `.combinedSessionState` — counts HID events across all sessions
 *   (keyboard + mouse + stylus) without per-key surveillance.
 * - The CGEventSource query can be called from any thread; no main-thread
 *   requirement. The state machine itself is @MainActor-isolated.
 * - The `idleReader` closure is replaceable for testing (inject a mock clock
 *   instead of the real Quartz value).
 * - Sleep/wake: forced idle on willSleep so the journal is accurate; state
 *   is reset on didWake so the next poll re-evaluates fresh.
 */

import AppKit
import Defaults
import Foundation
import MetamorphiaAgentKit

// MARK: - Defaults key

extension Defaults.Keys {
    /// Master switch for the input-idle sensor. When `false`, `start()` is a
    /// no-op and no `inputIdle` / `inputResumed` events are emitted.
    static let observeInputIdle = Key<Bool>(
        "metamorphia.inputIdleSensor.enabled",
        default: true
    )
}

// MARK: - InputIdleSensor

/// Detects user-input idle intervals and emits ``ActivityEvent/inputIdle`` /
/// ``ActivityEvent/inputResumed`` into the activity spine.
///
/// ## Lifecycle
/// ```swift
/// let sensor = InputIdleSensor(stream: MetamorphiaBootstrap.activityStream!)
/// sensor.start()
/// ```
@MainActor
public final class InputIdleSensor {

    // MARK: - Types

    /// Closure that returns seconds since the last user-input event.
    /// The default implementation queries `CGEventSource`; tests inject a mock.
    public typealias IdleReader = @Sendable () -> TimeInterval

    // MARK: - State machine

    private enum SensorState {
        case active
        case idle(beganAt: Date)
    }

    // MARK: - Public configuration

    /// Seconds without input that trigger `.inputIdle`. Default: 120 s.
    public var idleThresholdSeconds: Int = 120

    // MARK: - Private state

    private let stream: ActivityStream
    private let idleReader: IdleReader

    private var state: SensorState = .active
    private var timerTask: Task<Void, Never>?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - Init

    public init(
        stream: ActivityStream,
        idleReader: @escaping IdleReader = InputIdleSensor.defaultIdleReader
    ) {
        self.stream = stream
        self.idleReader = idleReader
    }

    // MARK: - Lifecycle

    /// Begin polling. Idempotent — calling while already running is a no-op.
    public func start() {
        guard Defaults[.observeInputIdle] else { return }
        guard timerTask == nil else { return }

        subscribeToSleepWake()

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await self?.poll()
            }
        }
    }

    /// Stop polling and remove sleep/wake observers.
    public func stop() {
        timerTask?.cancel()
        timerTask = nil

        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            sleepObserver = nil
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
    }

    // MARK: - Default idle reader

    /// Real implementation — queries Quartz for seconds since the last HID event
    /// across combined sessions. Thread-safe; no main-thread requirement.
    public static let defaultIdleReader: IdleReader = {
        // UInt32.max is the "any event type" sentinel: CGEventSource treats any
        // unrecognised CGEventType value as a wildcard matching all event types.
        // The force-unwrap is safe because CGEventType(rawValue:) only fails for
        // values the system reserves; UInt32.max is deliberately outside that set.
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )
    }

    // MARK: - Poll

    @MainActor
    private func poll() {
        guard Defaults[.observeInputIdle] else { return }

        let secondsSinceLast = idleReader()
        let threshold = TimeInterval(idleThresholdSeconds)

        switch state {
        case .active:
            if secondsSinceLast >= threshold {
                // Transition: active → idle
                let idleSeconds = Int(secondsSinceLast)
                state = .idle(beganAt: Date.now.addingTimeInterval(-secondsSinceLast))
                Task {
                    await stream.emit(.inputIdle(idleSeconds: idleSeconds, at: .now))
                }
            }

        case .idle:
            if secondsSinceLast < threshold {
                // Transition: idle → active
                if case .idle(let beganAt) = state {
                    let spentIdle = Int(Date.now.timeIntervalSince(beganAt))
                    state = .active
                    Task {
                        await stream.emit(.inputResumed(afterIdleSeconds: spentIdle, at: .now))
                    }
                }
            }
        }
    }

    // MARK: - Sleep / wake

    private func subscribeToSleepWake() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    @MainActor
    private func handleSleep() {
        guard Defaults[.observeInputIdle] else { return }

        // Only force-transition to idle when we are currently active.
        // If already idle, there is nothing to emit — the idle was already recorded.
        if case .active = state {
            let secondsSinceLast = idleReader()
            let idleSeconds = Int(max(secondsSinceLast, 0))
            let now = Date.now
            let beganAt = now.addingTimeInterval(-secondsSinceLast)
            state = .idle(beganAt: beganAt)
            Task {
                await stream.emit(.inputIdle(idleSeconds: idleSeconds, at: .now))
            }
        }
    }

    @MainActor
    private func handleWake() {
        // Reset: the next poll will re-evaluate fresh idle seconds from Quartz.
        state = .active
    }
}
