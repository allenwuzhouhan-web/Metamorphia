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

enum SneakContentType: Equatable {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
    case timer
    case reminder
    case recording
    case doNotDisturb
    case bluetoothAudio
    case privacy
    case lockScreen
    case capsLock
    case extensionLiveActivity(bundleID: String, activityID: String)
}

extension SneakContentType {
    static func == (lhs: SneakContentType, rhs: SneakContentType) -> Bool {
        switch (lhs, rhs) {
        case (.brightness, .brightness),
             (.volume, .volume),
             (.backlight, .backlight),
             (.music, .music),
             (.mic, .mic),
             (.battery, .battery),
             (.download, .download),
             (.timer, .timer),
             (.reminder, .reminder),
             (.recording, .recording),
             (.doNotDisturb, .doNotDisturb),
             (.bluetoothAudio, .bluetoothAudio),
             (.privacy, .privacy),
             (.lockScreen, .lockScreen),
             (.capsLock, .capsLock):
            return true
        case let (.extensionLiveActivity(lb, la), .extensionLiveActivity(rb, ra)):
            return lb == rb && la == ra
        default:
            return false
        }
    }
}

extension SneakContentType {
    var isExtensionPayload: Bool {
        if case .extensionLiveActivity = self {
            return true
        }
        return false
    }
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
    var title: String = ""
    var subtitle: String = ""
    var accentColor: Color?
    var styleOverride: SneakPeekStyle? = nil
    var targetScreenName: String? = nil
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

class MetamorphiaViewCoordinator: ObservableObject {
    static let shared = MetamorphiaViewCoordinator()
    private var cancellables = Set<AnyCancellable>()
    
    private static let tabOrder: [NotchViews] = [.home, .shelf, .markets, .news, .timer, .stats, .colorPicker, .equation, .graphing, .tools, .notes, .clipboard, .terminal, .extensionExperience, .commandBar]
    
    /// Direction of the most recent tab switch (true = forward/right, false = backward/left)
    @Published var tabSwitchForward: Bool = true
    
    @Published var currentView: NotchViews = .home {
        didSet {
            // Minimalistic UI collapses all widget tabs to .home, but the AI
            // Command Bar is not a widget — it's an on-demand overlay that
            // should always be summonable. Without this whitelist, any attempt
            // to switch to .commandBar is instantly reverted, silently breaking
            // every activation path.
            if Defaults[.enableMinimalisticUI]
                && currentView != .home
                && currentView != .commandBar {
                currentView = .home
                return
            }
            // Track direction before SwiftUI re-renders
            let oldIdx = Self.tabOrder.firstIndex(of: oldValue) ?? 0
            let newIdx = Self.tabOrder.firstIndex(of: currentView) ?? 0
            tabSwitchForward = newIdx >= oldIdx
            handleStatsTabTransition(from: oldValue, to: currentView)
        }
    }
    
    @Published var statsSecondRowExpansion: CGFloat = 1
    @Published var notesLayoutState: NotesLayoutState = .list
    @Published var selectedExtensionExperienceID: String?
    
    
    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("timerLiveActivityEnabled") var timerLiveActivityEnabled: Bool = true

    @Default(.enableTimerFeature) private var enableTimerFeature
    @Default(.timerDisplayMode) private var timerDisplayMode
    
    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if TrayDrop.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }
    
    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @AppStorage("hudReplacement") var hudReplacement: Bool = true
    
    @AppStorage("preferred_screen_name") var preferredScreen = NSScreen.main?.localizedName ?? "Unknown" {
        didSet {
            selectedScreen = preferredScreen
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }
    
    @Published var selectedScreen: String = NSScreen.main?.localizedName ?? "Unknown"

    @Published var optionKeyPressed: Bool = true
    private let extensionNotchExperienceManager = ExtensionNotchExperienceManager.shared
    
    private init() {
        selectedScreen = preferredScreen
        Defaults.publisher(.timerDisplayMode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleTimerDisplayModeChange(change.newValue)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableTimerFeature)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleTimerFeatureToggle(change.newValue)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableEquationFeature)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleEquationFeatureToggle(change.newValue)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableGraphingFeature)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleGraphingFeatureToggle(change.newValue)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableScratchpads)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleScratchpadsFeatureToggle(change.newValue)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableMinimalisticUI)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.handleMinimalisticModeChange(change.newValue)
            }
            .store(in: &cancellables)

        extensionNotchExperienceManager.$activeExperiences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] experiences in
                self?.handleExtensionExperienceSnapshot(experiences)
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableThirdPartyExtensions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleExtensionFeatureToggle()
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableExtensionNotchExperiences)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleExtensionFeatureToggle()
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableExtensionNotchTabs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleExtensionFeatureToggle()
            }
            .store(in: &cancellables)

        handleExtensionExperienceSnapshot(extensionNotchExperienceManager.activeExperiences)

        // Observe all tab-affecting settings to enforce minimum notch width
        Publishers.MergeMany(
            Defaults.publisher(.showStandardMediaControls).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.showCalendar).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.showMirror).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.dynamicShelf).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableTimerFeature).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.timerDisplayMode).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableStatsFeature).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableNotes).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableClipboardManager).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.clipboardDisplayMode).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableTerminalFeature).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.enableMinimalisticUI).map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
        .sink { _ in
            enforceMinimumNotchWidth()
        }
        .store(in: &cancellables)

        // Enforce minimum width on launch for existing configurations
        enforceMinimumNotchWidth()
    }

    private func handleStatsTabTransition(from oldValue: NotchViews, to newValue: NotchViews) {
        guard oldValue != newValue else { return }
        if newValue == .stats && Defaults[.enableStatsFeature] {
            statsSecondRowExpansion = 1
        }
    }

    private func handleTimerDisplayModeChange(_ mode: TimerDisplayMode) {
        guard mode == .popover, currentView == .timer else { return }
        withAnimation(.smooth) {
            currentView = .home
        }
    }

    private func handleTimerFeatureToggle(_ isEnabled: Bool) {
        guard !isEnabled, currentView == .timer else { return }
        withAnimation(.smooth) {
            currentView = .home
        }
    }

    private func handleEquationFeatureToggle(_ isEnabled: Bool) {
        guard !isEnabled, currentView == .equation else { return }
        withAnimation(.smooth) {
            currentView = .home
        }
    }

    private func handleGraphingFeatureToggle(_ isEnabled: Bool) {
        guard !isEnabled, currentView == .graphing else { return }
        withAnimation(.smooth) {
            currentView = .home
        }
    }

    private func handleScratchpadsFeatureToggle(_ isEnabled: Bool) {
        guard !isEnabled, currentView == .tools else { return }
        withAnimation(.smooth) {
            currentView = .home
        }
    }

    private func handleMinimalisticModeChange(_ isEnabled: Bool) {
        guard isEnabled else { return }
        if currentView != .home {
            withAnimation(.smooth) {
                currentView = .home
            }
        }
    }

    private func handleExtensionExperienceSnapshot(_ experiences: [ExtensionNotchExperiencePayload]) {
        guard extensionTabsAllowed else {
            selectedExtensionExperienceID = nil
            resetExtensionViewIfNeeded()
            return
        }

        let tabCapablePayloads = experiences.filter { $0.descriptor.tab != nil }
        guard !tabCapablePayloads.isEmpty else {
            selectedExtensionExperienceID = nil
            resetExtensionViewIfNeeded()
            return
        }

        if let currentID = selectedExtensionExperienceID,
           tabCapablePayloads.contains(where: { $0.descriptor.id == currentID }) {
            return
        }

        selectedExtensionExperienceID = tabCapablePayloads.first?.descriptor.id
    }

    private func handleExtensionFeatureToggle() {
        handleExtensionExperienceSnapshot(extensionNotchExperienceManager.activeExperiences)
    }

    private func resetExtensionViewIfNeeded() {
        guard currentView == .extensionExperience else { return }
        withAnimation(.smooth) {
            currentView = .home
        }
    }

    private var extensionTabsAllowed: Bool {
        Defaults[.enableThirdPartyExtensions]
        && Defaults[.enableExtensionNotchExperiences]
        && Defaults[.enableExtensionNotchTabs]
    }
    
    func toggleSneakPeek(
        status: Bool,
        type: SneakContentType,
        duration: TimeInterval = 1.5,
        value: CGFloat = 0,
        icon: String = "",
        title: String = "",
        subtitle: String = "",
        accentColor: Color? = nil,
        styleOverride: SneakPeekStyle? = nil,
        onScreen targetScreen: NSScreen? = nil
    ) {
        let resolvedDuration: TimeInterval
        switch type {
        case .timer:
            resolvedDuration = 10
        case .reminder:
            resolvedDuration = Defaults[.reminderSneakPeekDuration]
        case .extensionLiveActivity:
            resolvedDuration = duration
        default:
            resolvedDuration = duration
        }
        sneakPeekDuration = resolvedDuration
        let bypassedTypes: [SneakContentType] = [.music, .timer, .reminder, .bluetoothAudio]
        
        // Check if it's an extension type
        let isExtensionType: Bool
        if case .extensionLiveActivity = type {
            isExtensionType = true
        } else {
            isExtensionType = false
        }
        
        if !isExtensionType && !bypassedTypes.contains(type) && !Defaults[.enableSystemHUD] {
            return
        }
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.3)) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
                self.sneakPeek.title = title
                self.sneakPeek.subtitle = subtitle
                self.sneakPeek.accentColor = accentColor
                self.sneakPeek.styleOverride = styleOverride
                self.sneakPeek.targetScreenName = targetScreen?.localizedName
            }
        }
    }
    
    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()
        
        // Don't schedule auto-hide if duration is infinite (for persistent indicators like Caps Lock)
        guard duration.isFinite else { return }

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    // Hide the sneak peek with the correct type that was showing
                    self.toggleSneakPeek(status: false, type: self.sneakPeek.type)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }
    
    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }
    
    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?
    
    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                // Auto-hide every expanding type except downloads, which
                // DownloadManager dismisses itself when the transfer finishes.
                if expandingView.type != .download {
                    let duration: TimeInterval = 3
                    let showingType = expandingView.type
                    expandingViewTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(duration))
                        guard let self = self, !Task.isCancelled else { return }
                        // Dismiss the type that's actually showing — mirrors the
                        // sneakPeek auto-hide path — instead of always resetting
                        // to .battery, which would dismiss the wrong content.
                        self.toggleExpandingView(status: false, type: showingType)
                    }
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }

    
    func showEmpty() {
        currentView = .home
    }
    
    // MARK: - Clipboard Management
    @Published var shouldToggleClipboardPopover: Bool = false
    
    func toggleClipboardPopover() {
        // Toggle the published property to trigger UI updates
        shouldToggleClipboardPopover.toggle()
    }
}
