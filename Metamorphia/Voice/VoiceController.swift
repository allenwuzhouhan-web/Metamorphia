import AppKit
import Combine

/// Bridges `VoiceService` to `AICommandViewModel`. Equivalent of Executer's
/// `VoiceIntegration`, adapted for Metamorphia's view model (no delegate
/// protocol — calls into `AICommandViewModel` directly on the main actor).
///
/// Owned by `MetamorphiaBootstrap`. The view model holds a weak back-
/// reference so hotkey handlers can call `activate()` / `cancel()` without
/// threading through the bootstrap every time.
@MainActor
final class VoiceController {
    private weak var viewModel: AICommandViewModel?
    private var glowWindow: VoiceGlowWindow?
    private var cancellables = Set<AnyCancellable>()
    private var voiceActive: Bool = false

    init(viewModel: AICommandViewModel) {
        self.viewModel = viewModel
    }

    /// Wire the service's Combine publishers and callbacks. Call once after
    /// the view model is live.
    func setup() {
        let voice = VoiceService.shared

        voice.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .listening:
                    self.glowWindow?.updatePulseIntensity(.listening)
                case .error(let msg):
                    self.showPermissionDeniedAlert(message: msg)
                    self.cancel()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        voice.$partialTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, let vm = self.viewModel else { return }
                // Only update while we're the active input mode — if the
                // user dismissed the bar mid-listen, don't thrash the FSM.
                if case .voiceListening = vm.inputBarState {
                    vm.onVoicePartial(text)
                }
            }
            .store(in: &cancellables)

        voice.onCommandComplete = { [weak self] command in
            DispatchQueue.main.async {
                self?.handleCommandComplete(command)
            }
        }

        voice.onWakeWordDetected = { [weak self] in
            DispatchQueue.main.async {
                self?.handleWakeWord()
            }
        }

        // Start background listening on launch if the user has opted in.
        voice.startBackgroundListening()
    }

    // MARK: - Hotkey entry points

    /// Triggered by Cmd+Shift+V. Starts mic, shows glow, listens for one
    /// command, stops mic. Pressing again mid-listen cancels.
    func activate() {
        guard let vm = viewModel else { return }
        guard VoiceService.shared.isEnabled else {
            print("[Voice] Voice not enabled in Settings — ignoring hotkey")
            return
        }

        // Don't interrupt an in-flight agent run.
        switch vm.inputBarState {
        case .processing, .planning, .executing, .streaming:
            print("[Voice] Agent already running — ignoring voice hotkey")
            return
        default:
            break
        }

        if voiceActive {
            cancel()
            return
        }

        beginVoiceUI()
        Task { await VoiceService.shared.activate() }
    }

    /// Cancel the current listen and dismiss the glow. Idempotent.
    func cancel() {
        guard let vm = viewModel else { return }
        if voiceActive {
            VoiceService.shared.cancel()
            glowWindow?.hide()
            glowWindow = nil
            voiceActive = false
        }
        vm.cancelVoice()
    }

    // MARK: - Internals

    private func beginVoiceUI() {
        guard let vm = viewModel else { return }
        voiceActive = true

        let glow = VoiceGlowWindow()
        glow.show()
        glow.updatePulseIntensity(.activated)
        glowWindow = glow

        // Ensure the Command Bar is visible so the user can see the partial
        // transcript in the pill. Uses the existing summon path so the bar
        // rides the same spring as a manual hotkey press.
        CommandBarCoordinator.shared.summon()

        vm.activateVoice()

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    private func handleWakeWord() {
        guard let vm = viewModel else { return }
        // Ignore wake word while an agent run is active — don't preempt.
        switch vm.inputBarState {
        case .processing, .planning, .executing, .streaming:
            print("[Voice] Wake word detected but agent busy — ignoring")
            return
        default:
            break
        }
        beginVoiceUI()
    }

    private func handleCommandComplete(_ command: String) {
        guard let vm = viewModel else { return }
        glowWindow?.hide()
        glowWindow = nil
        voiceActive = false
        vm.onVoiceFinal(command)
    }

    private func showPermissionDeniedAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Voice Input Needs Permission"
        alert.informativeText = "Metamorphia couldn't access the microphone or speech recognition. Open System Settings to grant access, then try again.\n\nError: \(message)"
        alert.alertStyle = .warning
        // Pre-loaded icon avoids the _NSAsynchronousPreparation crash when an
        // off-main accessibility query lands on the alert window's lazy icon.
        alert.icon = Self.warningIcon
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Deep-link to Privacy → Microphone. The specific pane depends on
            // which permission was denied; Microphone covers the common case.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static let warningIcon: NSImage = {
        let image = NSImage(systemSymbolName: "mic.slash.fill",
                            accessibilityDescription: "Microphone unavailable")
            ?? NSImage(named: NSImage.cautionName)
            ?? NSImage()
        _ = image.size
        return image
    }()
}
