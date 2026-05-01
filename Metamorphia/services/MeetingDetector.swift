/*
 * Metamorphia
 * Meeting detector — infers when the user is in a video-conferencing session
 * by correlating camera state, microphone state, and frontmost-app identity
 * signals from ActivityStream.
 *
 * State machine:
 *   Idle ──► MeetingOpen  when camera + mic + VC-app are all true simultaneously.
 *   MeetingOpen ──► Idle  when any of the three conditions turns false.
 *
 * Debounce: meetingStarted is held in a pending buffer for 10 s. If the meeting
 * ends before 10 s have elapsed both events are suppressed (camera-test / setup
 * false positive). If 10 s pass, meetingStarted is committed to the stream.
 *
 * Feature gate: Defaults[.observeMeetings] (default true).
 */

import Combine
import Defaults
import Foundation
import MetamorphiaAgentKit

// MARK: - Defaults key

extension Defaults.Keys {
    /// Master switch for MeetingDetector. Default: true.
    static let observeMeetings = Key<Bool>(
        "metamorphia.sensor.meetings.enabled",
        default: true
    )
}

// MARK: - MeetingDetector

@MainActor
public final class MeetingDetector {

    // MARK: - Known VC bundle IDs

    private static let vcBundleIDs: Set<String> = [
        "us.zoom.xos",
        "us.zoom.ZoomClips",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.apple.FaceTime",
        "com.hnc.Discord",
        "com.appZapya.HopIn",
        "net.whereby.app",
        "com.bullethq.around.client",
        "com.tinyspeck.slackmacgap",   // Slack huddles
    ]

    // MARK: - State machine

    private enum State {
        case idle
        case meetingOpen(app: String, startedAt: Date)
    }

    // MARK: - Private state

    private let stream: ActivityStream
    private var cancellables = Set<AnyCancellable>()
    private var running = false

    private var state: State = .idle

    // Hardware state — seeded from current monitor values at start().
    private var cameraActive: Bool = false
    private var micActive: Bool = false

    // App state — last frontmost app + whether a Google Meet browser tab is active.
    private var frontmostBundleID: String = ""
    private var frontmostAppName: String = ""
    private var lastURLHost: String = ""        // most recent .urlVisited host
    private var lastURLHostSetAt: Date? = nil   // timestamp for 30 s TTL

    // Pending meetingStarted commit — nil until all three conditions are met.
    // We hold this for 10 s before emitting to the stream (debounce for setup tests).
    private var pendingStart: (app: String, at: Date)?
    private var commitTask: Task<Void, Never>?

    // MARK: - Init

    public init(stream: ActivityStream) {
        self.stream = stream
    }

    // MARK: - Lifecycle

    public func start() {
        guard Defaults[.observeMeetings] else { return }
        guard !running else { return }
        running = true

        // Seed hardware state from current monitor values so the detector is
        // correct immediately without waiting for the next toggle event.
        cameraActive = PrivacyIndicatorManager.shared.camera.isCameraActive
        micActive = PrivacyIndicatorManager.shared.microphone.isMicActive

        subscribeToStream()
    }

    public func stop() {
        guard running else { return }
        running = false
        cancellables.removeAll()
        commitTask?.cancel()
        commitTask = nil
        pendingStart = nil
    }

    // MARK: - Stream subscription

    private func subscribeToStream() {
        stream.events
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                guard let self, self.running else { return }
                self.handle(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - Event handler

    private func handle(_ event: ActivityEvent) {
        switch event {
        case .cameraToggled(let isActive, _):
            cameraActive = isActive
            evaluate()

        case .microphoneToggled(let isActive, _):
            micActive = isActive
            evaluate()

        case .focusChanged(let bundleID, let appName, _, _, _):
            frontmostBundleID = bundleID
            frontmostAppName = appName
            evaluate()

        case .urlVisited(_, let host, _, _, _):
            lastURLHost = host
            lastURLHostSetAt = .now
            evaluate()

        default:
            break
        }
    }

    // MARK: - Condition evaluation

    /// Returns true when all three preconditions for a VC session are met.
    private var conditionsMet: Bool {
        guard cameraActive, micActive else { return false }
        return isVCApp(bundleID: frontmostBundleID) || isMeetBrowserURL()
    }

    private func isVCApp(bundleID: String) -> Bool {
        Self.vcBundleIDs.contains(bundleID)
    }

    private func isMeetBrowserURL() -> Bool {
        guard lastURLHost.contains("meet.google.com") else { return false }
        guard let setAt = lastURLHostSetAt,
              Date.now.timeIntervalSince(setAt) <= 30 else { return false }
        return true
    }

    /// The display name to use in emitted events.
    private var currentAppLabel: String {
        if isMeetBrowserURL() && !isVCApp(bundleID: frontmostBundleID) {
            return "Google Meet"
        }
        return frontmostAppName.isEmpty ? frontmostBundleID : frontmostAppName
    }

    // MARK: - State transitions

    private func evaluate() {
        guard running, Defaults[.observeMeetings] else { return }

        switch state {
        case .idle:
            if conditionsMet {
                openMeeting()
            }

        case .meetingOpen:
            if !conditionsMet {
                closeMeeting()
            }
        }
    }

    private func openMeeting() {
        let app = currentAppLabel
        let startedAt = Date.now

        // Record the pending start but don't emit yet — wait 10 s for it to stabilise.
        pendingStart = (app: app, at: startedAt)
        state = .meetingOpen(app: app, startedAt: startedAt)

        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.running else { return }
            // Still in a meeting after 10 s — commit the start event.
            if case .meetingOpen(let committedApp, let committedAt) = self.state,
               let pending = self.pendingStart,
               pending.at == committedAt {
                self.pendingStart = nil
                await self.stream.emit(.meetingStarted(app: committedApp, at: committedAt))
            }
        }
    }

    private func closeMeeting() {
        guard case .meetingOpen(let app, let startedAt) = state else { return }

        commitTask?.cancel()
        commitTask = nil

        let hasPendingStart = pendingStart != nil
        pendingStart = nil
        state = .idle

        // If meetingStarted hasn't been committed yet (< 10 s), suppress both events.
        if hasPendingStart {
            return
        }

        // meetingStarted was already committed — emit meetingEnded.
        let durationSeconds = Int(Date.now.timeIntervalSince(startedAt))
        print("[MeetingDetector] meeting ended in \(app)")
        Task { [stream] in
            await stream.emit(.meetingEnded(durationSeconds: max(0, durationSeconds), at: .now))
        }
    }
}
