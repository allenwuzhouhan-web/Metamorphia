/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import ApplicationServices
import AVFoundation
import Combine
import EventKit
import Foundation
import SwiftUI
import MetamorphiaPerception

// MARK: - PermissionVault

/// Unifies the 5-permission universe (Accessibility, Screen Recording, Input
/// Monitoring, Automation, Full Disk) plus Camera and Calendar. Drives staged
/// onboarding and publishes per-lane status to the UI.
///
/// Composes existing stores rather than duplicating their probe logic.
@MainActor
public final class PermissionVault: ObservableObject {

    // MARK: Shared

    public static let shared = PermissionVault()

    // MARK: Permission enum

    public enum Permission: String, CaseIterable, Identifiable, Hashable, Codable {
        case accessibility
        case screenRecording
        case inputMonitoring
        case automation
        case fullDisk
        case camera
        case calendar

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .accessibility:    return "Accessibility"
            case .screenRecording:  return "Screen Recording"
            case .inputMonitoring:  return "Input Monitoring"
            case .automation:       return "Automation"
            case .fullDisk:         return "Full Disk Access"
            case .camera:           return "Camera"
            case .calendar:         return "Calendar"
            }
        }

        public var systemImageName: String {
            switch self {
            case .accessibility:    return "accessibility"
            case .screenRecording:  return "rectangle.dashed.badge.record"
            case .inputMonitoring:  return "keyboard"
            case .automation:       return "applescript"
            case .fullDisk:         return "internaldrive"
            case .camera:           return "camera"
            case .calendar:         return "calendar"
            }
        }
    }

    // MARK: Status enum

    public enum Status: String, Codable, Hashable {
        case granted
        case denied
        case notDetermined
        case restricted
    }

    // MARK: LaneStatus enum

    public enum LaneStatus: Sendable, Hashable {
        case fullyEnabled
        case degraded(missing: [Permission])
        case disabled(blocker: Permission)
    }

    // MARK: OnboardingStage enum

    public enum OnboardingStage: Int, CaseIterable {
        /// Core blocking permissions — Accessibility and Screen Recording.
        case welcome
        /// Ensures core perception is satisfied (idempotent re-check of welcome set).
        case corePerception
        /// Agent action permissions — Input Monitoring and Automation.
        case agentActions
        /// Just-in-time optional permissions — Full Disk, Camera, Calendar.
        case optional
    }

    // MARK: Published state

    @Published public private(set) var matrix: [Permission: Status] = [:]
    @Published public private(set) var lastUpdated: Date = Date()

    // MARK: Private

    private var revocationTimer: Timer?
    private let accessibilityStore: AccessibilityPermissionStore
    private let fullDiskStore: FullDiskAccessPermissionStore

    /// UserDefaults key tracking whether Automation has ever worked (best-effort probe).
    private static let automationWorkedKey = "PermissionVault.automationHasWorkedOnce"

    // MARK: Init

    public init() {
        self.accessibilityStore = AccessibilityPermissionStore.shared
        self.fullDiskStore = FullDiskAccessPermissionStore.shared
        refresh()
    }

    // MARK: Lane dependency table

    private static let laneDeps: [PerceptionLane: [Permission]] = [
        .axPoll:        [.accessibility],
        .dhashDiff:     [.screenRecording],
        .ocrFallback:   [.screenRecording],
        .browserDOM:    [.accessibility, .automation],
        .menuBarRead:   [.accessibility],
        .windowEnum:    [],
        .clipboardWatch: [],
        .screenHarvest: [.screenRecording, .fullDisk],
        .driftScan:     [.accessibility, .screenRecording],
        .selection:     [.accessibility],
        .documentWatch: [],
    ]

    // MARK: Lane status

    public func laneStatus(_ lane: PerceptionLane) -> LaneStatus {
        let deps = Self.laneDeps[lane] ?? []
        let statuses = deps.map { ($0, matrix[$0] ?? .notDetermined) }
        let denied = statuses.filter { $0.1 == .denied || $0.1 == .restricted }
        let missing = statuses.filter { $0.1 != .granted }
        if let blocker = denied.first {
            return .disabled(blocker: blocker.0)
        }
        if !missing.isEmpty {
            return .degraded(missing: missing.map { $0.0 })
        }
        return .fullyEnabled
    }

    // MARK: Staged onboarding

    /// Prompts the user through the permissions appropriate for the given stage.
    /// Each stage opens System Settings for its permissions; callers should
    /// present a UI gate before calling this (e.g. a sheet or dedicated onboarding
    /// screen). Deep-links are only followed when this function is explicitly invoked.
    public func requestStaged(_ stage: OnboardingStage) async {
        switch stage {
        case .welcome, .corePerception:
            // Blocking perception permissions — prompt AX first, then SR.
            if matrix[.accessibility] != .granted {
                accessibilityStore.requestAuthorizationPrompt()
            }
            if matrix[.screenRecording] != .granted {
                openSystemSettings(for: .screenRecording)
            }

        case .agentActions:
            if matrix[.inputMonitoring] != .granted {
                openSystemSettings(for: .inputMonitoring)
            }
            if matrix[.automation] != .granted {
                openSystemSettings(for: .automation)
            }

        case .optional:
            // JIT: only open what is still missing.
            for permission in [Permission.fullDisk, .camera, .calendar] {
                if matrix[permission] != .granted {
                    openSystemSettings(for: permission)
                    // Space requests so the user can act on each.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }

        // Re-probe after prompts settle.
        try? await Task.sleep(nanoseconds: 500_000_000)
        refresh()
    }

    // MARK: Deep links (user-initiated only)

    public func openSystemSettings(for permission: Permission) {
        let fragment: String
        switch permission {
        case .accessibility:   fragment = "Privacy_Accessibility"
        case .screenRecording: fragment = "Privacy_ScreenCapture"
        case .inputMonitoring: fragment = "Privacy_ListenEvent"
        case .automation:      fragment = "Privacy_Automation"
        case .fullDisk:        fragment = "Privacy_AllFiles"
        case .camera:          fragment = "Privacy_Camera"
        case .calendar:        fragment = "Privacy_Calendars"
        }
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(fragment)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Revocation watch lifecycle

    public func startRevocationWatch() {
        guard revocationTimer == nil else { return }
        // 30s is responsive enough to surface a mid-session revocation re-prompt
        // while keeping the periodic main-thread probe work (TCC.db file open,
        // CGPreflight, IOKit access check) well clear of contributing to hitches.
        // Tolerance lets the OS coalesce the wakeup for energy savings.
        let timer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 5.0
        RunLoop.main.add(timer, forMode: .common)
        revocationTimer = timer
    }

    public func stopRevocationWatch() {
        revocationTimer?.invalidate()
        revocationTimer = nil
    }

    // MARK: Probe

    /// Force-polls every permission and updates `matrix`.
    public func refresh() {
        var next: [Permission: Status] = [:]

        // Accessibility — delegate to existing store logic.
        next[.accessibility] = accessibilityStore.isAuthorized ? .granted : .denied

        // Screen Recording.
        next[.screenRecording] = probeScreenRecording()

        // Input Monitoring.
        next[.inputMonitoring] = probeInputMonitoring()

        // Automation — best-effort via UserDefaults flag.
        next[.automation] = probeAutomation()

        // Full Disk — delegate to existing store logic.
        fullDiskStore.refreshStatus()
        next[.fullDisk] = fullDiskStore.isAuthorized ? .granted : .denied

        // Camera.
        next[.camera] = probeCamera()

        // Calendar.
        next[.calendar] = probeCalendar()

        if next != matrix {
            matrix = next
            lastUpdated = Date()
        }
    }

    // MARK: Private probes

    private func probeScreenRecording() -> Status {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        return .denied
    }

    private typealias IOHIDCheckAccessFn = @convention(c) (UInt32) -> UInt32

    /// Resolved once: IOKit's `IOHIDCheckAccess` symbol. dlopen on a system
    /// framework returns a cached handle, but we resolve here a single time so
    /// the per-poll path never re-dlopen/dlsym-s (and never leaks a handle ref).
    private static let ioHIDCheckAccess: IOHIDCheckAccessFn? = {
        guard
            let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
            let sym = dlsym(handle, "IOHIDCheckAccess")
        else {
            return nil
        }
        return unsafeBitCast(sym, to: IOHIDCheckAccessFn.self)
    }()

    private func probeInputMonitoring() -> Status {
        // IOHIDCheckAccess / IOHIDRequestAccess are available on macOS 10.15+.
        // We check access without triggering a prompt; the kIOHIDRequestTypeListenEvent
        // constant lives in IOKit. Because this file compiles in the app target (not a
        // package), we gate on the symbol via a raw numeric value to avoid a hard IOKit
        // import dependency that may differ across SDK versions.
        //
        // IOHIDCheckAccess returns:
        //   0 = kIOHIDAccessTypeGranted
        //   1 = kIOHIDAccessTypeDenied
        //   2 = kIOHIDAccessTypeUnknown
        //
        // kIOHIDRequestTypeListenEvent = 1
        guard let fn = Self.ioHIDCheckAccess else {
            // IOKit symbol unavailable — degrade gracefully.
            return .notDetermined
        }
        let result = fn(1) // kIOHIDRequestTypeListenEvent
        switch result {
        case 0:  return .granted
        case 1:  return .denied
        default: return .notDetermined
        }
    }

    private func probeAutomation() -> Status {
        // There is no public API to check Automation permission without triggering a
        // system prompt. We track a "has worked once" flag set by call-sites that
        // successfully exercise AppleScript/JXA automation. If the flag is absent we
        // return .notDetermined (conservative — not .denied).
        let hasWorked = UserDefaults.standard.bool(forKey: Self.automationWorkedKey)
        return hasWorked ? .granted : .notDetermined
    }

    private func probeCamera() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:       return .granted
        case .denied:           return .denied
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        @unknown default:       return .notDetermined
        }
    }

    private func probeCalendar() -> Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:       return .granted
        case .denied:           return .denied
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .writeOnly:        return .degraded
        @unknown default:       return .notDetermined
        }
    }
}

// MARK: - Status convenience

extension PermissionVault.Status {
    /// Convenience alias used in the calendar probe for write-only access.
    fileprivate static let degraded: Self = .restricted
}

// MARK: - Automation flag helper

extension PermissionVault {
    /// Call this from any code path that successfully exercises AppleScript /
    /// JXA automation so the conductor can mark Automation as granted.
    public static func markAutomationWorked() {
        UserDefaults.standard.set(true, forKey: automationWorkedKey)
    }
}
