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

import Combine
import Defaults
import SwiftUI

@MainActor
class MetamorphiaViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = MetamorphiaViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: MetamorphiaAnimations = .init()
    let animation: Animation?
    static let commandBarCollapseAnimation = Animation.smooth(duration: 0.32)

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed
    @Published private(set) var notchTransitionStyle: NotchTransitionStyle = .standard

    @Published var dragDetectorTargeting: Bool = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = true
    @Published var isHoveringCalendar: Bool = false
    @Published var isBatteryPopoverActive: Bool = false
    @Published var isClipboardPopoverActive: Bool = false
    @Published var isColorPickerPopoverActive: Bool = false
    @Published var isStatsPopoverActive: Bool = false
    @Published var isReminderPopoverActive: Bool = false
    @Published var isMediaOutputPopoverActive: Bool = false
    @Published var isTimerPopoverActive: Bool = false
    @Published var shouldRecheckHover: Bool = false
    @Published var isScrollGestureActive: Bool = false
    private var scrollGestureSuppressionTokens: Set<UUID> = []
    @Published private(set) var isAutoCloseSuppressed: Bool = false
    private var autoCloseSuppressionTokens: Set<UUID> = []
    private let clipboardFocusWindow: TimeInterval = 10

    func setScrollGestureSuppression(_ active: Bool, token: UUID) {
        if active {
            let inserted = scrollGestureSuppressionTokens.insert(token).inserted
            if inserted {
                isScrollGestureActive = true
            }
        } else {
            if scrollGestureSuppressionTokens.remove(token) != nil {
                isScrollGestureActive = !scrollGestureSuppressionTokens.isEmpty
            }
        }
    }

    private func resetScrollGestureSuppression() {
        scrollGestureSuppressionTokens.removeAll()
        isScrollGestureActive = false
    }

    func setAutoCloseSuppression(_ active: Bool, token: UUID) {
        if active {
            let inserted = autoCloseSuppressionTokens.insert(token).inserted
            if inserted {
                isAutoCloseSuppressed = true
            }
        } else if autoCloseSuppressionTokens.remove(token) != nil {
            isAutoCloseSuppressed = !autoCloseSuppressionTokens.isEmpty
        }
    }

    private func resetAutoCloseSuppression() {
        autoCloseSuppressionTokens.removeAll()
        isAutoCloseSuppressed = false
    }

    private func focusClipboardTabIfNeeded() {
        guard !Defaults[.enableMinimalisticUI] else { return }
        guard Defaults[.enableClipboardManager] else { return }
        guard Defaults[.clipboardDisplayMode] == .separateTab else { return }
        guard let lastCopyDate = ClipboardManager.shared.lastCopiedItemDate else { return }
        guard Date().timeIntervalSince(lastCopyDate) <= clipboardFocusWindow else { return }
        guard coordinator.currentView != .notes else { return }
        withAnimation(.smooth) {
            coordinator.currentView = .notes
        }
    }
    
    let webcamManager = WebcamManager.shared
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false

    @Published var screen: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()
    
    @MainActor
    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screen: String? = nil) {
        animation = animationLibrary.animation

        super.init()
        
        self.screen = screen
        notchSize = getClosedNotchSize(screen: screen)
        closedNotchSize = notchSize

        Publishers.CombineLatest($dropZoneTargeting, $dragDetectorTargeting)
            .map { value1, value2 in
                value1 || value2
            }
            .assign(to: &$anyDropZoneTargeting)
        
        setupDetectorObserver()

        ReminderLiveActivityManager.shared.$activeWindowReminders
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchState == .open else { return }
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.smooth) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                        animated: true,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)

        // Observe settings + lyrics changes to dynamically resize the notch
        let enableLyricsPublisher = Defaults.publisher(.enableLyrics).map { $0.newValue }

        enableLyricsPublisher
            .combineLatest(MusicManager.shared.$currentLyrics)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard Defaults[.enableMinimalisticUI] else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchState == .open else { return }
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.smooth) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                        animated: true,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)

        TimerManager.shared.$activeSource
            .combineLatest(TimerManager.shared.$isTimerActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.handleMinimalisticTimerHeightChange()
            }
            .store(in: &cancellables)

        coordinator.$statsSecondRowExpansion
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.notchState == .open else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                        animated: false,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)

        coordinator.$notesLayoutState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.notchState == .open else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                        animated: true,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.openNotchWidth, options: [])
            .map { $0.newValue }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.notchState == .open else { return }
                guard !Defaults[.enableMinimalisticUI] else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.smooth) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: false),
                        animated: true,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func handleMinimalisticTimerHeightChange() {
        guard Defaults[.enableMinimalisticUI] else { return }
        guard notchState == .open else { return }
        let updatedTarget = calculateDynamicNotchSize()
        guard notchSize != updatedTarget else { return }
        withAnimation(.smooth) {
            notchSize = updatedTarget
        }
        if let delegate = AppDelegate.shared {
            delegate.ensureWindowSize(
                addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                animated: true,
                force: false
            )
        }
    }
    
    private func setupDetectorObserver() {
        // 1) Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.enableFullscreenMediaDetection)
            .map(\.newValue)

        // 2) For each non‑nil screen name, map to a Bool publisher for that screen's status
        let detector = self.detector
        let statusPublisher = $screen
            .compactMap { $0 }
            .removeDuplicates()
            .map { screenName in
                detector.$fullscreenStatus
                    .map { $0[screenName] ?? false }
                    .removeDuplicates()
            }
            .switchToLatest()

        // 3) Combine enabled & status, animate only on changes
        Publishers.CombineLatest(statusPublisher, enabledPublisher)
            .map { status, enabled in enabled && status }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }
    
    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = NSScreen.screens.first { $0.localizedName == screen }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        let screenFrame = getScreenFrame(screen)
        if let frame = screenFrame {
            
            let baseY = frame.maxY - notchSize.height
            let baseX = frame.midX - notchSize.width / 2
            
            return position.y >= baseY && position.x >= baseX && position.x <= baseX + notchSize.width
        }
        
        return false
    }

    func open() {
        notchTransitionStyle = .standard
        let targetSize = calculateDynamicNotchSize()
        let paddedSize = addShadowPadding(to: targetSize, isMinimalistic: Defaults[.enableMinimalisticUI])

        let applyExpansion: () -> Void = { [weak self] in
            guard let self else { return }
            // Drive the NSWindow frame and the SwiftUI state change from the
            // same AppKit animation transaction. Without this, the window
            // jumped to full size in one frame while SwiftUI content had no
            // animation owner — producing the "pop" on click.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.42
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                context.allowsImplicitAnimation = true

                AppDelegate.shared?.ensureWindowSize(
                    paddedSize,
                    animated: true,
                    force: true
                )

                // Matched SwiftUI spring so the content morph lands with the
                // window frame instead of before or after it. One owner, one
                // curve — no competing implicit animations.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    self.notchSize = targetSize
                    self.notchState = .open
                }
            }

            MusicManager.shared.forceUpdate()
            self.focusClipboardTabIfNeeded()
        }

        if Thread.isMainThread {
            applyExpansion()
        } else {
            DispatchQueue.main.async(execute: applyExpansion)
        }
    }
    
    private func calculateDynamicNotchSize() -> CGSize {
        let baseSize = Defaults[.enableMinimalisticUI] ? minimalisticOpenNotchSize : openNotchSize
        var adjustedSize = baseSize

        if coordinator.currentView == .notes || coordinator.currentView == .clipboard {
            let preferred = coordinator.notesLayoutState.preferredHeight
            adjustedSize.height = max(adjustedSize.height, preferred)
            return adjustedSize
        }

        if coordinator.currentView == .commandBar {
            let cmdVM = CommandBarCoordinator.shared.viewModel
            let preferred = cmdVM?.commandBarPreferredHeight ?? 82
            let compacted = cmdVM?.isResponseCompacted ?? false
            // Compacted mode — user scrolled up to get the bar out of their
            // way, so collapse to roughly the idle input height and trust
            // the ScrollView inside to let them still read by scrolling.
            if compacted {
                adjustedSize.height = 118
            } else {
                // Same screen-cap and chrome budget as
                // `AppDelegate.calculateRequiredNotchSize` (commandBar
                // branch). Both halve the visible screen — see the
                // long-form note there for the rationale.
                let screenCap: CGFloat = {
                    let visible = NSScreen.main?.visibleFrame.height ?? 900
                    return max(160, (visible - 20) / 2)
                }()
                adjustedSize.height = max(110, min(screenCap, preferred + 60))
            }
            // Width is locked to the user's configured `openNotchWidth` —
            // see the long-form note in `AppDelegate.calculateRequiredNotchSize`
            // (commandBar branch). Growing the window wider than the inner
            // SwiftUI content drifts the visible notch shape off-center.
            _ = cmdVM?.commandBarPreferredWidth
            return adjustedSize
        }

        return statsAdjustedNotchSize(
            from: adjustedSize,
            isStatsTabActive: coordinator.currentView == .stats,
            secondRowProgress: coordinator.statsSecondRowExpansion
        )
    }

    /// Recalculate the open notch size and animate to it. Used when a tab's
    /// content changes height while the notch is already open (e.g. command
    /// bar response arrives), so the same bouncy spring is reused instead of
    /// going through a full close/open cycle.
    func refreshOpenSize(animated: Bool = true) {
        guard notchState == .open else { return }
        notchTransitionStyle = .standard
        let targetSize = calculateDynamicNotchSize()
        if let delegate = AppDelegate.shared {
            delegate.ensureWindowSize(
                addShadowPadding(to: targetSize, isMinimalistic: Defaults[.enableMinimalisticUI]),
                animated: animated,
                force: true
            )
        }
        if animated {
            withAnimation(animationLibrary.animation) {
                notchSize = targetSize
            }
        } else {
            notchSize = targetSize
        }
    }

    // MARK: - Minimize / restore (AI command bar)
    //
    // `minimize()` collapses the open notch to an idle-height bar that
    // reserves just enough room for a pulsing dot + a short live-status
    // label. The agent run is **not** cancelled — it keeps going in the
    // background, and `restore()` brings the full command bar back so the
    // user can read the response.
    //
    // Both transitions go through the same window-resize path as `open()` /
    // `close()` so the notch uses its existing bouncy spring, not a hard
    // snap.

    func minimize() {
        notchTransitionStyle = .standard
        // Don't touch `coordinator.currentView` — the user is coming back
        // here, and mounting/unmounting the command bar would also cancel
        // the TextField focus and throw away the streaming response.
        let targetSize = CGSize(
            width: closedNotchSize.width + 140,
            height: effectiveClosedNotchHeight
        )
        withAnimation(animationLibrary.animation) {
            notchSize = targetSize
            notchState = .minimized
        }
        if let delegate = AppDelegate.shared {
            delegate.ensureWindowSize(
                addShadowPadding(to: targetSize, isMinimalistic: Defaults[.enableMinimalisticUI]),
                animated: true,
                force: true
            )
        }
    }

    func restore() {
        notchTransitionStyle = .standard
        let targetSize = calculateDynamicNotchSize()
        withAnimation(animationLibrary.animation) {
            notchSize = targetSize
            notchState = .open
        }
        if let delegate = AppDelegate.shared {
            delegate.ensureWindowSize(
                addShadowPadding(to: targetSize, isMinimalistic: Defaults[.enableMinimalisticUI]),
                animated: true,
                force: true
            )
        }
        CommandBarCoordinator.shared.viewModel?.hasUnseenCompletion = false
    }

    func close() {
        notchTransitionStyle = .standard
        let targetSize = getClosedNotchSize(screen: screen)
        applyClosedState(targetSize: targetSize)

        // Set the current view to shelf if it contains files and the user enables openShelfByDefault
        // Otherwise, if the user has not enabled openLastShelfByDefault, set the view to home
        if !ShelfStateViewModel.shared.isEmpty && Defaults[.openShelfByDefault] && !Defaults[.enableMinimalisticUI] {
            coordinator.currentView = .shelf
        } else if !coordinator.openLastTabByDefault {
            coordinator.currentView = .home
        }
    }

    func closeForCommandBarCollapse(completion: @escaping () -> Void) {
        let targetSize = getClosedNotchSize(screen: screen)
        notchTransitionStyle = .commandBarCollapse
        withAnimation(Self.commandBarCollapseAnimation) {
            applyClosedState(targetSize: targetSize)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self else { return }
            self.notchTransitionStyle = .standard
            completion()
        }
    }

    private func applyClosedState(targetSize: CGSize) {
        notchSize = targetSize
        closedNotchSize = targetSize
        notchState = .closed
        resetScrollGestureSuppression()
        resetAutoCloseSuppression()
    }

    func closeForLockScreen() {
        notchTransitionStyle = .standard
        let targetSize = getClosedNotchSize(screen: screen)
        withAnimation(.none) {
            applyClosedState(targetSize: targetSize)
        }
    }

    private var helloCloseScheduled = false

    func closeHello() {
        guard !helloCloseScheduled else { return }
        helloCloseScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            self.coordinator.firstLaunch = false
            withAnimation(self.animationLibrary.animation) {
                self.close()
            }
        }
    }
    
    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
                isCameraExpanded = false
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
                isCameraExpanded = true
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "OK")
                alert.runModal()

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRequestingAuthorization = false
            }

        default:
            break
        }
    }
}
