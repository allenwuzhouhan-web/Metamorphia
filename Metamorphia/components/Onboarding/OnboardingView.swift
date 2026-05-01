/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Metamorphia
 * See NOTICE for details.
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

import SwiftUI
import AVFoundation
import Defaults

enum OnboardingStep {
    case welcome
    case cameraPermission
    case calendarPermission
    case musicPermission
    case profileSelection
    case finished
}

private let calendarService = CalendarService()

struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @State private var showFocusMonitoringChoice = false
    @State private var didPresentFocusMonitoringChoice = false
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    private static let stepTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )

    private static let stepAnimation: Animation = .smooth(duration: 0.35)

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(Self.stepAnimation) {
                        step = .cameraPermission
                    }
                }
                .transition(Self.stepTransition)

            case .cameraPermission:
                PermissionRequestView(
                    icon: Image(systemName: "camera.fill"),
                    title: String(localized: "Enable Camera Access"),
                    description: String(localized: "Metamorphia includes a mirror feature that lets you quickly check your appearance using your camera, right from the notch. Camera access is required only to show this live preview. You can turn the mirror feature on or off at any time in the app."),
                    privacyNote: String(localized: "Your camera is never used without your consent, and nothing is recorded or stored."),
                    onAllow: {
                        Task {
                            await requestCameraPermission()
                            withAnimation(Self.stepAnimation) {
                                step = .calendarPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(Self.stepAnimation) {
                            step = .calendarPermission
                        }
                    }
                )
                .transition(Self.stepTransition)

            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: String(localized: "Enable Calendar Access"),
                    description: String(localized: "Metamorphia can show all your upcoming events in one place. Access to your calendar is needed to display your schedule."),
                    privacyNote: String(localized: "Your calendar data is only used to show your events and is never shared."),
                    onAllow: {
                        Task {
                            await requestCalendarPermission()
                            withAnimation(Self.stepAnimation) {
                                step = .musicPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(Self.stepAnimation) {
                            step = .musicPermission
                        }
                    }
                )
                .transition(Self.stepTransition)

            case .musicPermission:
                MusicControllerSelectionView(
                    onContinue: {
                        withAnimation(Self.stepAnimation) {
                            step = .profileSelection
                        }
                    }
                )
                .transition(Self.stepTransition)

            case .profileSelection:
                ProfileSelectionView(
                    onContinue: { profiles in
                        applyProfileSettings(profiles)
                        withAnimation(Self.stepAnimation) {
                            step = .finished
                        }
                    }
                )
                .transition(Self.stepTransition)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
                    .transition(Self.stepTransition)
            }
        }
        .frame(width: 400, height: 600)
        .clipped()
        .onAppear {
            guard !didPresentFocusMonitoringChoice else { return }
            didPresentFocusMonitoringChoice = true
            showFocusMonitoringChoice = true
        }
        .confirmationDialog(
            "Focus detection mode",
            isPresented: $showFocusMonitoringChoice,
            titleVisibility: .visible
        ) {
            Button("Use DevTools") {
                Defaults[.focusMonitoringMode] = .useDevTools
            }

            Button("Use without DevTools") {
                Defaults[.focusMonitoringMode] = .withoutDevTools
            }

            Button("Later", role: .cancel) {}
        } message: {
            Text("This is optional. You can change it any time from the menu bar.")
        }
    }

    // MARK: - Permission Request Logic

    func requestCameraPermission() async {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func requestCalendarPermission() async {
        await calendarService.requestAccess()
    }
}

