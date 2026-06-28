import AppKit
import Defaults
import SwiftUI

/// "Draw a tool out of the notch."
///
/// A mouse drag that starts on the notch pulls a droplet of the notch's own ink out
/// from under the lip (see ``GooeyTetherView``). The droplet follows the cursor; the
/// farther it goes the weaker the gooey neck until, past ``PullSession/breakDistance``,
/// it snaps free and morphs into a function-square that drops a floating scratchpad
/// where you let go. Release before the break and the droplet dissolves back in —
/// nothing spawns. A plain click never starts a pull, so it still opens the notch.
///
/// The visuals live in a full-screen, click-*through* panel (`ignoresMouseEvents`) that
/// only exists while a pull is in flight, so it can never intercept a desktop click.
/// All input comes from an `NSEvent` monitor pair, mirroring `CapsLockManager`.

enum PullPhase: Equatable {
    case idle       // no pull in flight
    case pulling    // droplet attached, following the cursor
    case snapping   // neck broke; droplet crystallising into a square
    case recoiling  // released early; droplet dissolving back into the notch
}

@MainActor
final class PullSession: ObservableObject {
    static let shared = PullSession()

    @Published private(set) var phase: PullPhase = .idle
    @Published private(set) var selectedTool: ScratchTool = .regex
    /// Live cursor location, AppKit global coordinates (bottom-left origin).
    @Published private(set) var currentScreen: CGPoint = .zero

    /// Notch-lip anchor, global coordinates — the fixed end of the tether.
    private(set) var anchorScreen: CGPoint = .zero
    /// The screen the pull lives on; the surface window covers exactly this rect.
    private(set) var hostFrame: CGRect = .zero

    /// Downward pull (points below the notch lip) at which the tool auto-maximizes.
    let commitDepth: CGFloat = 95
    /// Horizontal band over which the drag scrubs through the six tools.
    private let toolSpan: CGFloat = 260

    /// Latched true from the moment a pull commits until the mouse is released, so a
    /// single press spawns at most ONE window even though the start gesture keeps firing.
    private var committedAwaitingRelease = false

    /// True from the moment a pull begins until the mouse is released — INCLUDING the
    /// brief post-commit window where `phase` is back to `.idle` but the button is still
    /// held. Notch-open paths consult this so a pull never flashes the notch open.
    var isEngaged: Bool { phase != .idle || committedAwaitingRelease }

    /// Notch-band height for this pull — the top strip the tether stays hidden behind.
    private(set) var notchBandHeight: CGFloat = 0

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var surface: NSPanel?

    private init() {}

    // MARK: Derived geometry

    /// How far the cursor has been pulled straight DOWN from the notch lip. Selection
    /// and commit key off this vertical depth, not radial distance, so moving sideways
    /// to choose a tool never trips the commit and the choice doesn't drift as you pull.
    var depth: CGFloat { max(0, anchorScreen.y - currentScreen.y) }

    /// 1 = firmly connected · 0 = at the commit point.
    var strength: CGFloat { max(0, 1 - depth / commitDepth) }

    /// Anchor mapped into the surface view's top-left coordinate space.
    func anchorInView() -> CGPoint {
        CGPoint(x: anchorScreen.x - hostFrame.minX, y: hostFrame.maxY - anchorScreen.y)
    }

    /// Cursor mapped into the surface view's top-left coordinate space.
    func tipInView() -> CGPoint {
        CGPoint(x: currentScreen.x - hostFrame.minX, y: hostFrame.maxY - currentScreen.y)
    }

    // MARK: Lifecycle

    /// Begin a pull if one isn't already running. Idempotent, so the start gesture can
    /// call it on every `onChanged` without spawning duplicates.
    func beginIfNeeded() {
        guard phase == .idle, !committedAwaitingRelease, Defaults[.enableScratchpads] else { return }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        hostFrame = screen.frame
        // On a notched display the safe-area inset is the notch height; otherwise use a
        // small band under the top edge. Anchor the tether root UP inside that band
        // (not at its bottom edge) so the notch — which now renders ABOVE this surface —
        // hides the root, and the neck appears to emerge from *behind* the notch.
        let notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 8
        notchBandHeight = notchHeight
        anchorScreen = CGPoint(x: hostFrame.midX, y: hostFrame.maxY - notchHeight * 0.45)
        currentScreen = mouse
        selectedTool = tool(forX: mouse.x)
        phase = .pulling

        presentSurface()
        installMonitors()
        haptic(.levelChange) // a soft "grabbed it" tick
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            guard phase == .pulling else { return }
            currentScreen = NSEvent.mouseLocation
            // Tool follows horizontal position the whole time (continuous switching).
            let next = tool(forX: currentScreen.x)
            if next != selectedTool {
                selectedTool = next
                haptic(.alignment) // detent as the selection changes
            }
            // Pulled far enough straight down → auto-maximize the current tool, once.
            if depth >= commitDepth { commit() }
        case .leftMouseUp:
            if committedAwaitingRelease {
                // The window already spawned on commit; this release just clears the latch.
                committedAwaitingRelease = false
                removeMonitors()
            } else {
                finish()
            }
        default:
            break
        }
    }

    /// The pull crossed the commit depth: crystallise the current tool and drop exactly
    /// one scratchpad at the cursor — no release required. The latch (set here, cleared
    /// on mouse-up) is what stops the still-firing start gesture spawning a second window.
    private func commit() {
        guard phase == .pulling, !committedAwaitingRelease else { return }
        committedAwaitingRelease = true
        let tool = selectedTool
        let drop = currentScreen
        haptic(.generic)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { phase = .snapping }
        // Keep the monitors alive so we still catch the release that clears the latch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            ScratchpadWindow.shared.present(tool: tool, at: drop)
            self?.tearDownSurface()
            self?.phase = .idle // visuals reset; the latch stays until the mouse releases
        }
    }

    /// Mouse released before the commit depth → dissolve the droplet back into the notch.
    private func finish() {
        guard phase == .pulling else { return }
        removeMonitors()
        withAnimation(.easeOut(duration: 0.18)) { phase = .recoiling }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.dismiss()
        }
    }

    private func tearDownSurface() {
        surface?.orderOut(nil)
        surface = nil
    }

    private func dismiss() {
        tearDownSurface()
        phase = .idle
    }

    // MARK: Tool scrubbing

    private func tool(forX x: CGFloat) -> ScratchTool {
        let all = ScratchTool.allCases
        let frac = min(max((x - anchorScreen.x + toolSpan / 2) / toolSpan, 0), 1)
        let index = Int((frac * CGFloat(all.count - 1)).rounded())
        return all[min(max(index, 0), all.count - 1)]
    }

    // MARK: Surface window

    private func presentSurface() {
        let panel = ToolPullPanel(
            contentRect: hostFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // purely visual — never steals a click
        // BELOW the notch window (which is .mainMenu + 3): the opaque black notch then
        // occludes the tether root, so the connection reads as coming from behind it.
        // Still above every normal window + the menu bar, so the droplet floats on top.
        panel.level = .mainMenu + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ToolPullSurfaceView(session: self))
        panel.setFrame(hostFrame, display: true)
        panel.orderFrontRegardless()
        surface = panel
    }

    // MARK: Event monitors (mirrors CapsLockManager's local + global pair)

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Defaults[.enableHaptics] else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// Borderless, non-key visual panel for the pull. It never becomes key/main and ignores
/// mouse events, so it only ever paints the tether.
private final class ToolPullPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The surface view

/// Renders the gooey tether, the developing tool badge, and the snap-morph square,
/// all driven by ``PullSession``. Fully non-interactive.
struct ToolPullSurfaceView: View {
    @ObservedObject var session: PullSession

    private let tileSize: CGFloat = 66

    var body: some View {
        let anchor = session.anchorInView()
        let tip = session.tipInView()

        ZStack(alignment: .topLeading) {
            Color.clear

            if session.phase == .pulling || session.phase == .recoiling {
                GooeyTetherView(anchor: anchor, tip: tip, strength: session.strength)
                    .mask(emergenceMask)
                    .opacity(session.phase == .recoiling ? 0 : 1)

                // The tool's mark surfaces in the droplet as the bond weakens —
                // a hint of what it's about to become.
                Image(systemName: session.selectedTool.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .position(tip)
                    .opacity(session.phase == .recoiling ? 0 : Double(1 - session.strength))
            }

            if session.phase == .snapping {
                morphedSquare
                    .position(tip)
                    .transition(.scale(scale: 0.25).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: session.phase)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Keeps the tether's top — the strip behind the notch — invisible, so the
    /// connection only appears once it clears the notch's bottom edge, fading in over a
    /// short band. The droplet itself (below the notch) is unmasked.
    private var emergenceMask: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: session.notchBandHeight)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Color.black
        }
    }

    /// The crystallised "function-square" the droplet becomes at the snap.
    private var morphedSquare: some View {
        VStack(spacing: 5) {
            Image(systemName: session.selectedTool.systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
            Text(session.selectedTool.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: tileSize, height: tileSize)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

// MARK: - Start trigger

extension View {
    /// Lets a mouse drag that starts on this view (the notch) begin a tool pull, while
    /// leaving plain clicks — and the notch's own tap/scroll gestures — untouched. The
    /// 8pt minimum means a click opens the notch as before; only a drag tears a tool out.
    func notchToolPull(enabled: Bool) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in
                    guard enabled else { return }
                    PullSession.shared.beginIfNeeded()
                }
        )
    }
}
