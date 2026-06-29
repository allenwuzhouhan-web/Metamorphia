import AppKit
import SwiftUI
import Combine
import os.log

/// Drives the AI Command Bar by reusing the *existing* notch infrastructure.
/// `summon()` opens the notch (uses `MetamorphiaViewModel.open()` →
/// `MetamorphiaAnimations.animation` = `.spring(.bouncy(duration: 0.4))`)
/// and switches the active tab to `.commandBar`. `dismiss()` lets the command
/// bar collapse first, then restores the previous tab after the close settles.
///
/// No separate window — the bar inherits the notch's open behavior, with a
/// calmer close profile so dismissal reads more like the music surface.
///
/// Activation paths both route here:
///   - `⌘⇧Space` global hotkey → `toggle()`
///   - Single-click on the notch → `toggle()`
///
/// Every silent-return path logs via `os_log` so a broken summon can be
/// diagnosed from Console.app without attaching a debugger.
@MainActor
public final class CommandBarCoordinator {
    public static let shared = CommandBarCoordinator()

    private static let log = OSLog(subsystem: "com.johannendersmith.metamorphia", category: "CommandBar")

    /// The AI view model. Assigned by `MetamorphiaBootstrap.configure()`. If a hotkey
    /// fires before bootstrap completes, the summon is queued and replayed
    /// once this is set — see `pendingSummon`.
    public var viewModel: AICommandViewModel? {
        didSet {
            if MetamorphiaViewCoordinator.shared.currentView == .commandBar {
                MetamorphiaViewCoordinator.shared.objectWillChange.send()
            }
            wireConversationObserver()

            // Race fix (#11): replay any summon that fired before the view model
            // was assigned — otherwise the first ⌘⇧Space press after launch is
            // silently lost when bootstrap is still in flight.
            if viewModel != nil, pendingSummon {
                pendingSummon = false
                os_log(.info, log: Self.log, "Replaying queued summon after viewModel assigned")
                summon()
            }

            // Height recompute (#22): the notch's `calculateRequiredNotchSize`
            // reads `viewModel?.conversation.isEmpty` to pick 110 vs 320. If
            // the notch was created before the VM existed, the initial frame
            // may be stale — ask the current screen's notch VM to refresh.
            if viewModel != nil,
               MetamorphiaViewCoordinator.shared.currentView == .commandBar,
               let notchVM = resolveNotchViewModel(),
               notchVM.notchState == .open {
                notchVM.refreshOpenSize(animated: true)
            }
        }
    }

    /// Tab the user was on before summoning the bar — restored on dismiss.
    private var previousView: NotchViews?

    /// Set to `true` when a summon is requested before `viewModel` is
    /// available. Cleared and replayed in the `viewModel` didSet.
    private var pendingSummon: Bool = false

    /// The app that was frontmost before Metamorphia activated the command
    /// bar. Command-bar workflows that operate on "this chat" use this to
    /// keep targeting the user's prior conversation instead of the command
    /// bar itself.
    public private(set) var lastExternalAppName: String?

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Recompute the notch size whenever the conversation grows or shrinks
    /// (empty → has-response → cleared) so the same bouncy spring drives the
    /// height change instead of a separate animation.
    private func wireConversationObserver() {
        cancellables.removeAll()
        guard let vm = viewModel else { return }
        vm.$conversation
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      MetamorphiaViewCoordinator.shared.currentView == .commandBar,
                      let notchVM = self.resolveNotchViewModel() else { return }
                notchVM.refreshOpenSize()
            }
            .store(in: &cancellables)
    }

    // MARK: - Summon / dismiss

    /// Open the notch (or keep it open) and switch to the command bar tab.
    /// Every failure path logs so Console.app shows what went wrong.
    public func summon() {
        NSLog("🔔 [Metamorphia/CommandBar] summon() called — viewModel=\(viewModel == nil ? "nil" : "set")")
        // Race fix (#11): if the bootstrap hasn't handed us a view model yet,
        // remember the intent and replay once it arrives. Without this, the
        // first ⌘⇧Space press immediately after launch hits a nil VM and the
        // command bar never shows up.
        guard viewModel != nil else {
            NSLog("🔔 [Metamorphia/CommandBar] summon queued — viewModel not yet assigned")
            pendingSummon = true
            return
        }

        guard let vm = resolveNotchViewModel() else {
            NSLog("🔔 [Metamorphia/CommandBar] summon aborted — no notch VM (AppDelegate=\(AppDelegate.shared == nil ? "nil" : "live"))")
            return
        }
        NSLog("🔔 [Metamorphia/CommandBar] summon proceeding — notch state=\(vm.notchState == .open ? "open" : "closed")")

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalAppName = frontmost.localizedName
        }

        // Activate the app (#19) so the non-activating panel can become key
        // and the TextField can receive keystrokes. LSUIElement/accessory
        // apps don't auto-activate when their windows are ordered front —
        // this is the explicit step that lets the first keystroke land.
        NSApp.activate(ignoringOtherApps: true)

        // Lock-screen recovery (#7): the notch windows are ordered-out under
        // lock. Nothing else un-hides them synchronously on summon, so if the
        // user somehow hits ⌘⇧Space while the unlock animation is still in
        // flight, they'd see nothing. Ask the app delegate to re-show.
        AppDelegate.shared?.unhideWindowsIfNeeded(reason: "commandBarSummon")

        let coord = MetamorphiaViewCoordinator.shared

        if vm.notchState == .closed {
            previousView = nil  // No prior tab — opened from closed.
            coord.currentView = .commandBar
            vm.open()
        } else {
            if coord.currentView != .commandBar {
                previousView = coord.currentView
                coord.currentView = .commandBar
            }
            // Notch was already open (hover, long-press, or another tab). Force
            // a resize so the window matches the command bar's expected height;
            // otherwise the view renders into the previous tab's frame and is
            // effectively invisible.
            vm.refreshOpenSize(animated: true)
        }

        // Force-reveal (#16): the notch may be offset off-screen under
        // minimalistic UI + non-notch display (`shouldHideUntilHover`). Post a
        // notification that ContentView listens for to suspend the offset
        // while the command bar is the active tab.
        NotificationCenter.default.post(name: .commandBarDidSummon, object: nil)

        // Replace the fragile 50ms asyncAfter (#5) with a notification-driven
        // focus: tie key-focus to the actual NSWindow.didBecomeKey event,
        // with a retry fallback so a stuck spring animation can't strand us.
        makeNotchWindowKey(for: vm)
    }

    /// Collapse the command bar, then restore the prior tab after the close
    /// finishes so the content does not swap while the notch is shrinking.
    public func dismiss() {
        guard let vm = resolveNotchViewModel() else {
            os_log(.error, log: Self.log, "dismiss() aborted: no MetamorphiaViewModel")
            return
        }
        let coord = MetamorphiaViewCoordinator.shared
        let restoredView = previousView ?? NotchViews.home
        previousView = nil

        vm.closeForCommandBarCollapse { [weak vm] in
            guard let vm, vm.notchState == .closed else { return }
            coord.currentView = restoredView

            // Let the hide-until-hover offset resume on non-notch displays.
            NotificationCenter.default.post(name: .commandBarDidDismiss, object: nil)
        }
    }

    /// Toggle with state resync (#17): if the current-view and the notch-state
    /// disagree (a stuck state after an animation glitch, or a close that
    /// left `.currentView == .commandBar` stale), we treat it as "show me",
    /// not "hide me".
    public func toggle() {
        let coord = MetamorphiaViewCoordinator.shared
        guard let vm = resolveNotchViewModel() else {
            os_log(.error, log: Self.log, "toggle() aborted: no MetamorphiaViewModel")
            // Even without a live notch, queue a summon in case one arrives
            // (multi-screen, late bootstrap).
            summon()
            return
        }

        let barIsShowing = coord.currentView == .commandBar && vm.notchState == .open
        if barIsShowing {
            dismiss()
        } else {
            summon()
        }
    }

    // MARK: - Resolution

    /// Find the right notch view model for the screen under the mouse, with
    /// fallbacks (#18) for:
    ///   - cursor between/off screens (e.g. edge-of-display)
    ///   - single-display mode (`viewModels` dict is empty)
    ///   - the preferred screen in Settings having been disconnected
    private func resolveNotchViewModel() -> MetamorphiaViewModel? {
        guard let delegate = AppDelegate.shared else {
            os_log(.error, log: Self.log, "resolveNotchViewModel: AppDelegate.shared is nil")
            return nil
        }

        // 1) Screen under the mouse.
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            if let id = delegate.displayID(for: screen), let vm = delegate.viewModels[id] {
                return vm
            }
        }

        // 2) User-preferred screen (from Settings).
        let preferredName = MetamorphiaViewCoordinator.shared.preferredScreen
        if let preferred = NSScreen.screens.first(where: { $0.localizedName == preferredName }),
           let id = delegate.displayID(for: preferred),
           let vm = delegate.viewModels[id] {
            return vm
        }

        // 3) Main screen.
        if let main = NSScreen.main, let id = delegate.displayID(for: main), let vm = delegate.viewModels[id] {
            return vm
        }

        // 4) Any registered per-screen view model.
        if let anyVM = delegate.viewModels.values.first {
            return anyVM
        }

        // 5) Single-display mode — the shared vm is the only one.
        return delegate.vm
    }

    /// Make the notch's NSWindow key so SwiftUI's `TextField` receives
    /// keyDown events. Tied to `windowDidBecomeKey` instead of a hardcoded
    /// delay (fix #5), with a retry loop as fallback in case the animation
    /// never finishes.
    private func makeNotchWindowKey(for vm: MetamorphiaViewModel) {
        guard let delegate = AppDelegate.shared else {
            os_log(.error, log: Self.log, "makeNotchWindowKey: AppDelegate.shared is nil")
            return
        }

        let target: NSWindow?
        if let screen = NSScreen.screens.first(where: { $0.localizedName == vm.screen }),
           let id = delegate.displayID(for: screen),
           let w = delegate.windows[id] {
            target = w
        } else if let main = NSScreen.main, let id = delegate.displayID(for: main), let w = delegate.windows[id] {
            target = w
        } else {
            target = delegate.window ?? delegate.windows.values.first
        }

        guard let window = target else {
            os_log(.error, log: Self.log,
                   "makeNotchWindowKey: no NSWindow resolved (screen=%{public}@, windowsKeys=%d)",
                   vm.screen ?? "nil", delegate.windows.count)
            return
        }

        // Attempt 1: immediate. If the window is already orderable, this takes.
        window.makeKeyAndOrderFront(nil)

        // Attempt 2 (fallback, covers the case where the window was still
        // animating from .closed → .open when we fired): one short retry at
        // the typical spring-settle boundary. This is cheap and idempotent —
        // `makeKeyAndOrderFront` on an already-key window is a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak window] in
            guard let window else { return }
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted by `CommandBarCoordinator.summon()` so UI layers that offset the
    /// notch off-screen (e.g. minimalistic UI on non-notch displays) can
    /// temporarily reveal it for the duration of the command-bar session.
    static let commandBarDidSummon = Notification.Name("CommandBarDidSummon")

    /// Posted by `CommandBarCoordinator.dismiss()` so the same UI layers can
    /// restore their hide-until-hover behavior.
    static let commandBarDidDismiss = Notification.Name("CommandBarDidDismiss")
}
