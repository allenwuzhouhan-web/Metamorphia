# T5 — Voice Input: Full Port of Executer's Voice Stack into Metamorphia

## Executive Summary

**Wake-word strategy.** Executer's wake word is **not** a third-party SDK. It's a custom VAD (voice-activity-detection) loop over `AVAudioEngine`'s input tap: RMS power is measured with `vDSP_measqv`, and when energy crosses −35 dB for 4 consecutive 1024-sample frames, a short-lived `SFSpeechRecognizer` session is fired to match against the assistant's name (`AssistantNameManager`). This is 100% on-device framework code, zero SPM deps. **We port it verbatim.**

**SPM deps.** Zero new Swift Package dependencies. Only the system frameworks `Speech.framework` and `AVFoundation.framework` need to be linked into the Metamorphia target. `AVFoundation` is already imported by five Metamorphia files; `Speech` is not yet linked — it must be added to `Metamorphia.xcodeproj/project.pbxproj` (Frameworks/Libraries).

**Entitlements.** Metamorphia is not sandboxed (confirmed from `Metamorphia.entitlements`). Executer declares `com.apple.security.device.audio-input = true` even unsandboxed — we mirror that. For Speech we rely on the TCC prompt from `SFSpeechRecognizer.requestAuthorization`. Info.plist already has `NSMicrophoneUsageDescription`; we must add `NSSpeechRecognitionUsageDescription`.

**Hotkey.** Use the existing `KeyboardShortcuts` library. Add `KeyboardShortcuts.Name.voiceInput` with default `.v + [.shift, .command]`. Wire in `MetamorphiaBootstrap.configure()` alongside the existing `.commandBar` handler.

**State integration.** `AICommandViewModel` gets a new `VoiceController` (thin owner of `VoiceService` + `VoiceGlowWindow`). On activation: set `inputBarState = .voiceListening(partial: "")`, show glow, start mic. On partial: update `.voiceListening(partial: text)`. On final: call existing `submit(prompt:systemPrompt:)`. On cancel/escape/second-press: restore `.ready` and fade glow out.

**Always-listening opt-in.** OFF by default. Exposed via `Defaults[.voiceWakeWordEnabled]` in `AICommandBarSettings.swift`. Requires `voiceEnabled` to also be true so the user has two toggles (use voice at all / listen for wake word in background). Matches Executer's `voice_enabled`/`voice_always_listening` two-flag split.

**Biggest risks.**
1. Metamorphia is a `LSUIElement` accessory app that's never frontmost; `AVAudioEngine.start()` and `SFSpeechRecognizer` authorization prompts can behave oddly when the process isn't activated — `NSApp.activate(ignoringOtherApps: true)` before first-run permission prompt is required.
2. Background VAD holds the mic *forever*; macOS shows the orange mic dot perpetually. That's a UX issue even if it works, so the feature must be opt-in.
3. `SFSpeechRecognizer` 60-second session cap forces Executer to respawn sessions every ~5 s during background listening — confirmed correct in the ported code.
4. `NSScreen.builtIn` is used by Executer's glow window but Metamorphia does NOT have that extension. We add a fallback that prefers the notched screen then falls back to `.main`.
5. Conflict with macOS Dictation (fn fn) which also competes for the mic — can't be avoided, user must stop Dictation first.

---

## 1. Wake-word investigation result (citations)

From `/Users/allenwu/claude/executer/Executer/Voice/VoiceService.swift`:

| Claim | Evidence |
|---|---|
| No third-party SDK | File imports only `Cocoa`, `Speech`, `AVFoundation`, `Combine`, `Accelerate` (lines 1–5). No `Picovoice`, `Porcupine`, or `Whisper` imports anywhere in `Executer/`. |
| VAD uses RMS via Accelerate | `VoiceService.swift:246` — `vDSP_measqv(channelData, 1, &rms, vDSP_Length(frameCount))` |
| Threshold is −35 dB, 4-frame latch | Lines 68–71: `vadThreshold: Float = -35.0`, `framesNeededToTrigger = 4` |
| Short-lived recognizer sessions | Lines 272–327: each VAD trigger spawns a `SFSpeechAudioBufferRecognitionRequest` with a 5 s timer (`vadSessionTimer`) to bound session length |
| Wake word is user's assistant name | Line 364: `containsWakeWord` checks `AssistantNameManager.shared.name` + `learnedVariants` |
| Calibration learns how the recognizer hears the user | `VoiceCalibration.swift` — 3 recorded samples feed into `AssistantNameManager.addLearnedVariant` |
| SPM deps for voice | `project.yml:14-16` declares only `ComputerLib`; voice uses system frameworks `AVFoundation.framework` + `Speech.framework` (lines 55–56) |
| Permanent audio tap + feed both consumers | `VoiceService.swift:196-200` — **one tap** on input node, splits to VAD measurement and the speech-detection request; re-installing the tap mid-stream crashes the HAL thread, so this is load-bearing |

**Decision:** Port the whole stack. No replacements, no stubs.

**Scope tweak vs Executer:** Metamorphia doesn't have an assistant name concept yet, so `AssistantNameManager` ports as-is with a default of `"Metamorphia"` and UserDefaults key `metamorphia_assistant_name`. Calibration (`VoiceCalibration.swift`) is **deferred** out of T5 — it's a settings-panel feature that doesn't block manual Cmd+Shift+V or background wake-word with the default name.

---

## 2. File list — all absolute paths

### Create (new files)

| Path | Why |
|---|---|
| `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceState.swift` | FSM enum — mirror of Executer's file. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/AssistantNameManager.swift` | Wake-word matching source of truth. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceService.swift` | The recognizer + VAD engine; singleton. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceGlowWindow.swift` | Rainbow-edge NSWindow overlay shown while listening. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceController.swift` | Bridge between `VoiceService` ↔ `AICommandViewModel` (equivalent to Executer's `VoiceIntegration`). |
| `/Users/allenwu/claude/metamorphia/Metamorphia/Shortcuts/VoiceShortcuts.swift` | Adds `KeyboardShortcuts.Name.voiceInput` default Cmd+Shift+V. |

### Edit (existing files)

| Path | Change |
|---|---|
| `/Users/allenwu/claude/metamorphia/Metamorphia/Info.plist` | Add `NSSpeechRecognitionUsageDescription`. Existing `NSMicrophoneUsageDescription` stays. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/Metamorphia.entitlements` | Add `com.apple.security.device.audio-input = true` (defensive — not strictly needed when unsandboxed but Executer sets it and docs recommend it). |
| `/Users/allenwu/claude/metamorphia/Metamorphia.xcodeproj/project.pbxproj` | Link `Speech.framework` (AVFoundation already linked via existing imports). |
| `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift` | Add `activateVoice()`, `cancelVoice()`, `onVoicePartial(_:)`, `onVoiceFinal(_:)` methods + hold a `VoiceController` reference. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/MetamorphiaBootstrap.swift` | Instantiate `VoiceController` after `AICommandViewModel` construction; register `KeyboardShortcuts.onKeyDown(for: .voiceInput)` handler. |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift` | Fill the T6-placeholder `.voiceListening` branch of `stateDrivenSection` with a purple-mic partial-transcript row (the pill's status slot already shows `partial`; this adds a visible "tap to cancel" affordance). |
| `/Users/allenwu/claude/metamorphia/Metamorphia/components/Settings/AICommandBarSettings.swift` | Add a new `VoiceSettingsSection` with `Toggle`s for `voiceEnabled` + `voiceWakeWordEnabled` and a `KeyboardShortcuts.Recorder` for `.voiceInput`. |

---

## 3. Full Swift source for all new files

### 3.1 `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceState.swift`

```swift
import Foundation

/// Finite-state machine for Metamorphia's voice subsystem. Ported verbatim
/// from Executer's `VoiceState`. Shape must not change — `VoiceService` and
/// `VoiceGlowWindow` both switch on every case.
enum VoiceState: Equatable {
    /// Mic off, waiting for hotkey or for background wake-word mode to start.
    case idle
    /// Mic on, passively monitoring audio level for a wake word.
    case backgroundListening
    /// Hotkey pressed (or wake word detected); glow appearing, about to listen.
    case activated
    /// Mic on, capturing command speech with live partial transcripts.
    case listening
    /// Command finalized and dispatched to the agent; mic off.
    case dispatched
    /// Recoverable fault — UI layer decides what to do (usually show alert).
    case error(String)
}
```

### 3.2 `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/AssistantNameManager.swift`

```swift
import Foundation

/// Manages Metamorphia's spoken-address name and flexible wake-phrase
/// generation. Also stores transcription variants learned during optional
/// calibration (calibration UI is deferred past T5 but the variants store
/// exists so the matcher can grow without migrations).
///
/// Default name is "Metamorphia" — changeable later in Settings. Users say
/// "Hey Metamorphia, …" and we strip the address prefix before submitting
/// the command to the agent.
final class AssistantNameManager {
    static let shared = AssistantNameManager()

    private let nameKey = "metamorphia_assistant_name"
    private let variantsKey = "metamorphia_assistant_name_variants"

    var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "Metamorphia" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    /// Transcription variants learned during calibration — how
    /// `SFSpeechRecognizer` actually hears the user say the name (varies per
    /// accent/voice). Empty in T5; populated if/when the calibration flow
    /// lands.
    var learnedVariants: [String] {
        get { UserDefaults.standard.stringArray(forKey: variantsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: variantsKey) }
    }

    func addLearnedVariant(_ variant: String) {
        let lower = variant
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return }
        var current = learnedVariants
        if !current.contains(lower) {
            current.append(lower)
            learnedVariants = current
        }
    }

    func clearLearnedVariants() {
        learnedVariants = []
    }

    /// Phrases that should be stripped from the head of a command. Longest
    /// first so the most specific prefix wins.
    func addressPrefixes() -> [String] {
        let n = name.lowercased()
        var prefixes = [
            n,
            "hey \(n)",
            "help \(n)",
            "ok \(n)",
            "okay \(n)",
        ]
        for variant in learnedVariants {
            prefixes.append(variant)
            prefixes.append("hey \(variant)")
            prefixes.append("help \(variant)")
        }
        return prefixes.sorted { $0.count > $1.count }
    }

    /// Strip any address prefix from `command`. Non-destructive — returns the
    /// original text if nothing matches.
    func stripNamePrefix(from command: String) -> String {
        let lower = command
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in addressPrefixes() {
            if lower.hasPrefix(prefix) {
                let stripped = command
                    .dropFirst(prefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? command : stripped
            }
        }
        return command
    }
}
```

### 3.3 `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceService.swift`

Port of Executer's `VoiceService.swift` — **UserDefaults keys renamed** with the `metamorphia_` prefix so a user running both apps doesn't share voice state.

```swift
import Cocoa
import Speech
import AVFoundation
import Combine
import Accelerate

/// Voice input service with optional always-on background listening for a
/// wake word. Two modes:
///
/// 1. **Manual** (always available): Cmd+Shift+V or `activate()` → mic on,
///    capture one command, mic off.
/// 2. **Background** (opt-in via Settings): mic stays on at very low cost
///    doing only RMS-power VAD; when the user speaks, spin up a short
///    `SFSpeechRecognizer` session to check for the wake word. If the wake
///    word is detected, fire `onWakeWordDetected` and transition into the
///    same command-capture path as manual.
///
/// The VAD-short-session split exists because `SFSpeechRecognizer` has a
/// ~60 s session cap and holding it open continuously is expensive. VAD
/// costs almost nothing (one vDSP RMS call per buffer).
///
/// Ported verbatim from Executer (`Executer/Voice/VoiceService.swift`). Key
/// differences:
///   - UserDefaults keys prefixed `metamorphia_`.
///   - Completion callbacks thread back through `VoiceController`, not
///     `VoiceIntegration`.
///   - `@MainActor` is **not** annotated on the class — background audio
///     IO runs off-main and all UI-facing state writes are `DispatchQueue.main.async`'d,
///     matching Executer's proven model.
final class VoiceService: ObservableObject {
    static let shared = VoiceService()

    @Published var state: VoiceState = .idle
    @Published var partialTranscription: String = ""

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "metamorphia_voice_enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "metamorphia_voice_enabled")
            if newValue && alwaysListening {
                startBackgroundListening()
            } else if !newValue {
                stopBackgroundListening()
            }
        }
    }

    var alwaysListening: Bool {
        get { UserDefaults.standard.bool(forKey: "metamorphia_voice_always_listening") }
        set {
            UserDefaults.standard.set(newValue, forKey: "metamorphia_voice_always_listening")
            if newValue && isEnabled {
                startBackgroundListening()
            } else if !newValue {
                stopBackgroundListening()
            }
        }
    }

    /// Called when a full command is ready for the agent. Always invoked on
    /// the main thread.
    var onCommandComplete: ((String) -> Void)?
    /// Called when the wake word is detected during background listening.
    /// Always invoked on the main thread.
    var onWakeWordDetected: (() -> Void)?

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private let speechRecognizer: SFSpeechRecognizer
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var timeoutTimer: Timer?
    private var lastSegmentCount = 0
    private var retryCount = 0
    private let maxRetries = 1
    private var wasBackgroundListening = false

    // Background (VAD) listening
    private var backgroundEngine: AVAudioEngine?
    private var isBackgroundActive = false
    private var speechDetectionTask: SFSpeechRecognitionTask?
    private var speechDetectionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var vadSessionTimer: Timer?
    private var vadCooldown = false
    private var framesAboveThreshold = 0
    private let vadThreshold: Float = -35.0
    private let framesNeededToTrigger = 4

    private init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
        speechRecognizer.defaultTaskHint = .dictation

        if speechRecognizer.supportsOnDeviceRecognition {
            print("[Voice] On-device recognition available for \(speechRecognizer.locale.identifier)")
        }
    }

    // MARK: - Public API

    func startBackgroundListening() {
        guard isEnabled, alwaysListening else { return }
        guard !isBackgroundActive else { return }
        guard state == .idle else { return }

        Task {
            let authorized = await requestPermissions()
            guard authorized else {
                print("[Voice] Permissions not granted for background listening")
                return
            }
            DispatchQueue.main.async { self.beginBackgroundVAD() }
        }
    }

    func stopBackgroundListening() {
        tearDownBackgroundVAD()
        if state == .backgroundListening {
            state = .idle
        }
    }

    /// Activate voice mode on demand (hotkey or menu).
    func activate() async {
        guard state == .idle || state == .backgroundListening else { return }

        wasBackgroundListening = isBackgroundActive
        tearDownBackgroundVAD()

        let authorized = await requestPermissions()
        guard authorized else {
            DispatchQueue.main.async {
                self.state = .error("Microphone or speech-recognition permission denied")
            }
            return
        }

        DispatchQueue.main.async {
            self.retryCount = 0
            self.state = .activated
            self.partialTranscription = ""
            print("[Voice] Activated — starting command listening")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.startCommandListening()
            }
        }
    }

    func stop() {
        cancelCurrentSession()
        DispatchQueue.main.async {
            self.state = .idle
            self.partialTranscription = ""
            self.resumeBackgroundListeningIfNeeded()
        }
    }

    func cancel() {
        cancelCurrentSession()
        DispatchQueue.main.async {
            self.state = .idle
            self.partialTranscription = ""
            self.resumeBackgroundListeningIfNeeded()
        }
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let micGranted: Bool
        if #available(macOS 14.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = true
        }
        guard micGranted else { return false }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Background VAD

    private func beginBackgroundVAD() {
        guard !isBackgroundActive else { return }
        guard backgroundEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("[Voice] Invalid audio format — cannot start background listening")
            return
        }

        // Single permanent tap — also feeds the speech-detection request when
        // one is active. Re-installing a tap while the audio IO thread is
        // mid-invocation of the previous block races and crashes the HAL
        // client thread; keeping one tap for the engine's lifetime avoids that.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.processBackgroundAudioBuffer(buffer)
            self.speechDetectionRequest?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[Voice] Failed to start background VAD: \(error)")
            inputNode.removeTap(onBus: 0)
            return
        }

        backgroundEngine = engine
        isBackgroundActive = true
        state = .backgroundListening
        framesAboveThreshold = 0
        vadCooldown = false
        print("[Voice] Background VAD started — listening for speech activity")
    }

    private func tearDownBackgroundVAD() {
        vadSessionTimer?.invalidate()
        vadSessionTimer = nil
        tearDownSpeechDetection()

        if let engine = backgroundEngine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        backgroundEngine = nil
        isBackgroundActive = false
        framesAboveThreshold = 0
        vadCooldown = false
    }

    private func processBackgroundAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var rms: Float = 0
        vDSP_measqv(channelData, 1, &rms, vDSP_Length(frameCount))
        let power = rms > 0 ? 10 * log10(rms) : -160.0

        if power > vadThreshold {
            framesAboveThreshold += 1
            if framesAboveThreshold >= framesNeededToTrigger && !vadCooldown {
                framesAboveThreshold = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechActivityDetected()
                }
            }
        } else {
            framesAboveThreshold = max(0, framesAboveThreshold - 1)
        }
    }

    private func onSpeechActivityDetected() {
        guard isBackgroundActive, state == .backgroundListening else { return }
        guard speechDetectionTask == nil else { return }
        vadCooldown = true

        print("[Voice] Speech activity detected — starting recognition check")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        speechDetectionRequest = request

        guard backgroundEngine != nil else { return }

        speechDetectionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, self.isBackgroundActive else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

                if self.containsWakeWord(lower) {
                    print("[Voice] Wake word detected: \"\(text)\"")
                    DispatchQueue.main.async {
                        let commandAfterWake = AssistantNameManager.shared
                            .stripNamePrefix(from: text)
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        self.tearDownBackgroundVAD()
                        self.wasBackgroundListening = true
                        self.state = .activated
                        self.partialTranscription = commandAfterWake
                        self.onWakeWordDetected?()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.startCommandListening()
                        }
                    }
                    return
                }

                if result.isFinal {
                    DispatchQueue.main.async { self.endSpeechDetectionSession() }
                }
            }

            if error != nil {
                DispatchQueue.main.async { self.endSpeechDetectionSession() }
            }
        }

        // Kill the detection session after 5 s max so a long monologue
        // without a wake word doesn't keep it alive.
        vadSessionTimer?.invalidate()
        vadSessionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.endSpeechDetectionSession()
        }
    }

    private func endSpeechDetectionSession() {
        tearDownSpeechDetection()

        if let engine = backgroundEngine, !engine.isRunning {
            isBackgroundActive = false
            state = .idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startBackgroundListening()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.vadCooldown = false
        }
    }

    private func tearDownSpeechDetection() {
        vadSessionTimer?.invalidate()
        vadSessionTimer = nil
        speechDetectionTask?.cancel()
        speechDetectionTask = nil
        speechDetectionRequest?.endAudio()
        speechDetectionRequest = nil
    }

    private func containsWakeWord(_ text: String) -> Bool {
        let lower = text.lowercased()
        let name = AssistantNameManager.shared.name.lowercased()
        if lower.contains(name) { return true }
        for variant in AssistantNameManager.shared.learnedVariants {
            if lower.contains(variant) { return true }
        }
        return false
    }

    private func resumeBackgroundListeningIfNeeded() {
        if wasBackgroundListening || (isEnabled && alwaysListening) {
            wasBackgroundListening = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.state == .idle else { return }
                self.startBackgroundListening()
            }
        }
    }

    // MARK: - Command Listening

    private func startCommandListening() {
        guard state == .activated || state == .listening else { return }

        state = .listening
        lastSegmentCount = 0
        print("[Voice] Mic on — listening for command")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[Voice] Failed to start audio engine: \(error)")
            state = .error("Audio engine failed")
            return
        }

        audioEngine = engine

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, self.state == .listening else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                let segmentCount = result.bestTranscription.segments.count

                DispatchQueue.main.async {
                    let stripped = AssistantNameManager.shared.stripNamePrefix(from: text)
                    self.partialTranscription = stripped

                    let lower = stripped
                        .lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if lower == "cancel" || lower == "never mind" || lower == "nevermind" {
                        print("[Voice] User cancelled via speech")
                        self.cancel()
                        return
                    }

                    if segmentCount > self.lastSegmentCount {
                        self.lastSegmentCount = segmentCount
                        self.resetSilenceTimer()
                    }
                }

                if result.isFinal {
                    DispatchQueue.main.async { self.finishCommand(text) }
                }
            }

            if let error = error as NSError? {
                print("[Voice] Recognition error: \(error.domain) code \(error.code)")
                DispatchQueue.main.async {
                    if !self.partialTranscription.isEmpty {
                        self.finishCommand(self.partialTranscription)
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        self.cancelCurrentSession()
                        self.state = .activated
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.startCommandListening()
                        }
                    } else {
                        self.cancel()
                    }
                }
            }
        }

        resetSilenceTimer()

        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            guard let self = self, self.state == .listening else { return }
            if !self.partialTranscription.isEmpty {
                self.finishCommand(self.partialTranscription)
            } else {
                self.cancel()
            }
        }
    }

    private func finishCommand(_ command: String) {
        let stripped = AssistantNameManager.shared.stripNamePrefix(from: command)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancel()
            return
        }

        cancelCurrentSession()
        state = .dispatched
        print("[Voice] Mic off — command: \"\(trimmed)\"")

        onCommandComplete?(trimmed)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.state = .idle
            self?.resumeBackgroundListeningIfNeeded()
        }
    }

    // MARK: - Timers / session teardown

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self = self, self.state == .listening else { return }
            if !self.partialTranscription.isEmpty {
                self.finishCommand(self.partialTranscription)
            }
        }
    }

    private func cancelCurrentSession() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
    }
}
```

### 3.4 `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceGlowWindow.swift`

Ported verbatim from Executer with one important fix: **Metamorphia does not have an `NSScreen.builtIn` extension**. We resolve the glow-host screen by preferring the main screen's notched display (highest safeAreaInsets.top) and falling back to `.main`.

```swift
import Cocoa
import QuartzCore

/// Full-screen transparent overlay that draws a pulsing rainbow aura around
/// the screen edges while voice mode is active. Clicks pass through to apps
/// underneath (`ignoresMouseEvents = true`).
///
/// Ported from Executer's `VoiceGlowWindow`. Only difference: resolves the
/// host screen without `NSScreen.builtIn` (Metamorphia doesn't ship that
/// extension) — picks the notched display if one is present, otherwise the
/// main screen.
final class VoiceGlowWindow {
    private var window: NSWindow?
    private var glowLayer: VoiceGlowLayer?

    func show() {
        guard window == nil else { return }
        guard let screen = Self.resolveHostScreen() else { return }

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.isReleasedWhenClosed = false

        let containerView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = CGColor.clear

        let glow = VoiceGlowLayer()
        glow.frame = containerView.bounds
        glow.contentsScale = screen.backingScaleFactor
        containerView.layer?.addSublayer(glow)

        win.contentView = containerView
        window = win
        glowLayer = glow

        win.orderFrontRegardless()

        DispatchQueue.main.async {
            glow.startAnimation()
        }
    }

    func hide() {
        glowLayer?.fadeOut { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.glowLayer = nil
        }
    }

    func updatePulseIntensity(_ state: VoiceState) {
        switch state {
        case .activated: glowLayer?.setPulseDuration(1.5)
        case .listening: glowLayer?.setPulseDuration(3.0)
        case .dispatched: glowLayer?.setPulseDuration(4.0)
        default: break
        }
    }

    /// Prefer the display with a notch (non-zero `safeAreaInsets.top`), fall
    /// back to the main screen. Metamorphia's notch UI already lives on this
    /// same screen so the glow and notch animations stay visually unified.
    private static func resolveHostScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main
    }
}

/// Rainbow aura around the screen margins — four gradient edge layers that
/// rotate through a hand-tuned rainbow palette with a breathing pulse and a
/// dreamy colored shadow. Ported unchanged from Executer.
final class VoiceGlowLayer: CALayer {

    private let edgeDepth: CGFloat = 60
    private var edgeLayers: [CAGradientLayer] = []
    private var colorTimer: Timer?
    private var colorPhase: Int = 0

    private let rainbowColors: [CGColor] = [
        NSColor(hue: 0.00, saturation: 0.65, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.08, saturation: 0.65, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.15, saturation: 0.55, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.33, saturation: 0.55, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.55, saturation: 0.55, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.62, saturation: 0.65, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.75, saturation: 0.55, brightness: 1.0, alpha: 0.55).cgColor,
        NSColor(hue: 0.85, saturation: 0.45, brightness: 1.0, alpha: 0.55).cgColor,
    ]

    private let rainbowShadows: [CGColor] = [
        NSColor(hue: 0.00, saturation: 0.8, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.08, saturation: 0.8, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.15, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.33, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.55, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.62, saturation: 0.8, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.75, saturation: 0.7, brightness: 1.0, alpha: 1.0).cgColor,
        NSColor(hue: 0.85, saturation: 0.6, brightness: 1.0, alpha: 1.0).cgColor,
    ]

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func startAnimation() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let transparent = CGColor.clear

        let edges: [(CGRect, CGPoint, CGPoint, Int)] = [
            (CGRect(x: 0, y: h - edgeDepth, width: w, height: edgeDepth),
             CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1), 0),
            (CGRect(x: w - edgeDepth, y: 0, width: edgeDepth, height: h),
             CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5), 2),
            (CGRect(x: 0, y: 0, width: w, height: edgeDepth),
             CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0), 4),
            (CGRect(x: 0, y: 0, width: edgeDepth, height: h),
             CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), 6),
        ]

        for (frame, start, end, colorOffset) in edges {
            let gradient = CAGradientLayer()
            gradient.frame = frame
            let idx = colorOffset % rainbowColors.count
            gradient.colors = [rainbowColors[idx], transparent]
            gradient.startPoint = start
            gradient.endPoint = end
            gradient.locations = [0.0, 1.0]
            gradient.shadowColor = rainbowShadows[idx]
            gradient.shadowRadius = 25
            gradient.shadowOpacity = 0.6
            gradient.shadowOffset = .zero

            addSublayer(gradient)
            edgeLayers.append(gradient)
        }

        opacity = 0

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.4
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        add(fadeIn, forKey: "fadeIn")

        for edge in edgeLayers {
            addBreathingPulse(to: edge, duration: 3.0)
        }

        colorTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self = self, !self.edgeLayers.isEmpty else {
                timer.invalidate()
                return
            }
            self.colorPhase = (self.colorPhase + 1) % self.rainbowColors.count

            for (i, edge) in self.edgeLayers.enumerated() {
                let idx = (self.colorPhase + i * 2) % self.rainbowColors.count
                let newColors = [self.rainbowColors[idx], CGColor.clear]

                let colorAnim = CABasicAnimation(keyPath: "colors")
                colorAnim.toValue = newColors
                colorAnim.duration = 0.3
                colorAnim.fillMode = .forwards
                colorAnim.isRemovedOnCompletion = false
                edge.add(colorAnim, forKey: "rainbow")

                let shadowAnim = CABasicAnimation(keyPath: "shadowColor")
                shadowAnim.toValue = self.rainbowShadows[idx]
                shadowAnim.duration = 0.3
                shadowAnim.fillMode = .forwards
                shadowAnim.isRemovedOnCompletion = false
                edge.add(shadowAnim, forKey: "rainbowShadow")
            }
        }
    }

    func fadeOut(completion: @escaping () -> Void) {
        colorTimer?.invalidate()
        colorTimer = nil

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.toValue = 0
        fadeOut.duration = 0.6
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        add(fadeOut, forKey: "fadeOut")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            completion()
        }
    }

    func setPulseDuration(_ duration: CGFloat) {
        for edge in edgeLayers {
            edge.removeAnimation(forKey: "breathing")
            addBreathingPulse(to: edge, duration: duration)
        }
    }

    private func addBreathingPulse(to layer: CAGradientLayer, duration: CGFloat) {
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.3, 0.7, 0.3]
        pulse.keyTimes = [0, 0.5, 1.0]
        pulse.duration = CFTimeInterval(duration)
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: "breathing")
    }
}
```

### 3.5 `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceController.swift`

Equivalent of Executer's `VoiceIntegration`. Owns the glow window, wires the service's callbacks to the view model.

```swift
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
                case .error:
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
}
```

### 3.6 `/Users/allenwu/claude/metamorphia/Metamorphia/Shortcuts/VoiceShortcuts.swift`

```swift
import AppKit
import KeyboardShortcuts

/// Cmd+Shift+V summons Metamorphia's voice input. Added here (not inside
/// `MetamorphiaShortcuts.swift`) so T5 can land without touching the T1
/// hotkey file. Registration happens in `MetamorphiaBootstrap.configure()`.
public extension KeyboardShortcuts.Name {
    /// Cmd+Shift+V toggles voice listening.
    static let voiceInput = Self(
        "voiceInput",
        default: .init(.v, modifiers: [.shift, .command])
    )
}
```

---

## 4. Entitlements + Info.plist diffs

### `/Users/allenwu/claude/metamorphia/Metamorphia/Info.plist`

Insert immediately after the existing `NSMicrophoneUsageDescription` key (line 27–28):

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Metamorphia uses speech recognition to transcribe your voice commands to the AI agent on-device when available.</string>
```

The existing `NSMicrophoneUsageDescription` copy ("Metamorphia needs microphone access to transcribe your voice commands to the AI agent.") is already correct — leave it untouched.

### `/Users/allenwu/claude/metamorphia/Metamorphia/Metamorphia.entitlements`

Insert inside the `<dict>` (defensive — Metamorphia is unsandboxed today but future hardening might flip it on):

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

### `/Users/allenwu/claude/metamorphia/Metamorphia.xcodeproj/project.pbxproj`

Add `Speech.framework` to the **Frameworks, Libraries, and Embedded Content** list of the `Metamorphia` target. In the `PBXFrameworksBuildPhase` section, add:

```
XXXXXXXXXXXXXXXXXXXXXXXX /* Speech.framework in Frameworks */,
```

and add a matching `PBXBuildFile` and `PBXFileReference` entry (standard xcodeproj edit; the coder agent will use Xcode UI or a known-good pbxproj editor — the mechanical details are not worth specifying here). `AVFoundation.framework` is already linked indirectly via existing `import AVFoundation` usage; ensure it's explicitly listed too.

---

## 5. ViewModel changes — exact code

Add to `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift`, placed in a new extension so the big `@MainActor public final class AICommandViewModel` body isn't disturbed. Drop this block immediately after the existing `clearConversation()` method (around line 781, before the `updatePreferredHeight(_:)` comment), **or** as a separate `extension AICommandViewModel { … }` block at the bottom of the file just before the first `#if canImport(MetamorphiaAgentKit)` block that adds sink conformances.

```swift
// MARK: - Voice input (T5)

extension AICommandViewModel {

    /// The voice controller instance. Weak because it's owned by
    /// `MetamorphiaBootstrap`; nil when voice hasn't been configured (e.g.
    /// tests, preview, or a build where the voice stack was excluded).
    public var voiceController: VoiceController? {
        get { objc_getAssociatedObject(self, &voiceControllerKey) as? VoiceController }
        set {
            objc_setAssociatedObject(
                self,
                &voiceControllerKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Hotkey handler — toggles voice listening. Keep this thin: all actual
    /// mic work happens inside `VoiceController.activate()`.
    public func activateVoice() {
        // Called in two paths:
        //   1. `VoiceController.beginVoiceUI()` flips us into `.voiceListening`
        //      as part of UI setup; this method no-ops because state already
        //      matches.
        //   2. A caller that only has a view-model reference (e.g. a menu
        //      item) calls this and expects the controller to handle
        //      everything downstream. We forward to the controller.
        if case .voiceListening = inputBarState { return }

        guard let controller = voiceController else {
            // Voice stack not configured — surface a one-shot error so the
            // user sees why nothing happened.
            inputBarState = .error(message: "Voice input is not available in this build.")
            return
        }
        inputBarState = .voiceListening(partial: "")
        controller.activate()
    }

    /// Called by `VoiceController` on each live partial transcript.
    public func onVoicePartial(_ text: String) {
        // Guard so stale partials after cancel don't resurrect .voiceListening.
        if case .voiceListening = inputBarState {
            inputBarState = .voiceListening(partial: text)
        }
    }

    /// Called by `VoiceController` when the recognizer returns a final
    /// utterance. Dispatches to the agent via the existing `submit` path.
    public func onVoiceFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inputBarState = .ready
            return
        }
        // Drop back to .ready first so `submit` can flip to .processing
        // cleanly (submit's guard only respects the ready/result/error path).
        inputBarState = .ready
        Task { [weak self] in
            guard let self else { return }
            // Reuse the same system prompt NotchCommandBarView uses for typed
            // prompts — voice commands are treated identically to typed ones.
            let systemPrompt = "You are Metamorphia, an AI assistant on macOS. Use the available tools to fulfill the user's request. Be concise — the user sees your reply in a compact bar."
            await self.submit(prompt: trimmed, systemPrompt: systemPrompt)
        }
    }

    /// Cancel voice listening and return the pill to `.ready`.
    public func cancelVoice() {
        if case .voiceListening = inputBarState {
            inputBarState = .ready
        }
    }
}

private var voiceControllerKey: UInt8 = 0
```

**Rationale for associated object.** The view model is a public final class in a package-facing module; adding a stored property bloats its public surface and means stubs must carry it too. An associated object confines the reference to T5's wiring code and keeps the existing init signatures stable.

---

## 6. Hotkey wiring — bootstrap changes

Add to `/Users/allenwu/claude/metamorphia/Metamorphia/MetamorphiaBootstrap.swift`.

**Add a stored property** near the top of the `MetamorphiaBootstrap` enum (around line 67, alongside the other published `private(set)` vars):

```swift
public static private(set) var voiceController: VoiceController?
```

**Wire the controller + hotkey** inside `configure()`, inserted right after `CommandBarCoordinator.shared.viewModel = viewModel` (currently at line 512, section 7), **before** the existing `KeyboardShortcuts.onKeyDown(for: .commandBar)` block:

```swift
// 7a. Voice input (T5). Owns VoiceService + glow window lifecycle. Weak
//     ref back on the view model so hotkey callers that only hold the VM
//     can reach the controller.
let voiceController = VoiceController(viewModel: viewModel)
voiceController.setup()
Self.voiceController = voiceController
viewModel.voiceController = voiceController
```

**Register the hotkey** immediately after the existing `.commandBar` block (after line 520 closing brace):

```swift
// 8b. Cmd+Shift+V — voice input.
KeyboardShortcuts.onKeyDown(for: .voiceInput) {
    NSLog("🎙 [Metamorphia/Voice] hotkey ⌘⇧V pressed")
    Task { @MainActor in
        MetamorphiaBootstrap.voiceController?.activate()
    }
}

// 8c. Defensive default restore — mirrors the `.commandBar` path.
if KeyboardShortcuts.getShortcut(for: .voiceInput) == nil {
    KeyboardShortcuts.reset(.voiceInput)
    print("[MetamorphiaBootstrap] voiceInput hotkey was empty — restored ⌘⇧V default.")
}
```

---

## 7. Glow window lifecycle

| Event | Actor | Action |
|---|---|---|
| Hotkey pressed / wake word fires | `VoiceController.beginVoiceUI()` | Instantiate `VoiceGlowWindow`, call `show()` with `.activated` intensity. |
| Recognizer transitions to `.listening` | `VoiceService.$state` sink | `glowWindow?.updatePulseIntensity(.listening)` — slows pulse to 3 s. |
| Final command or cancel | `handleCommandComplete` / `cancel` | `glowWindow?.hide()` fades out over 0.6 s, then `glowWindow = nil`. |
| User presses Cmd+Shift+V again mid-listen | `VoiceController.activate()` | `voiceActive` is true → falls through to `cancel()`. |
| User presses Escape in Command Bar | `NotchCommandBarView` onKeyPress | Call `viewModel.voiceController?.cancel()`. See section 8. |

**NSWindow geometry (from Executer, unchanged):**
- Frame = chosen screen's `.frame` (full-screen overlay).
- Style mask = `.borderless`.
- Level = `.screenSaver` — above everything including menu bar and full-screen apps.
- `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = false`, `ignoresMouseEvents = true`.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`.
- Host screen = first display with notch (`safeAreaInsets.top > 0`), else `NSScreen.main`. Does not track active-screen changes — matches Executer. If the user drags Metamorphia to another monitor mid-listen, glow stays on original. Document as known.

---

## 8. Edits to `NotchCommandBarView`

Replace the `case .voiceListening:` branch in `stateDrivenSection` (lines 147–149) with a visible partial-transcript row that echoes the pill's status slot but adds a cancel button and a waveform glyph. This keeps the pill itself usable (status-text path already handles `partial`) while giving the user a clear Escape-to-cancel affordance.

```swift
case .voiceListening(let partial):
    VoiceListeningRow(
        partial: partial,
        onCancel: { [weak viewModel] in
            viewModel?.voiceController?.cancel()
        }
    )
    .transition(.opacity.combined(with: .move(edge: .top)))
    .padding(.top, 6)
```

Add the row view at the bottom of the same file (or in a new file; either works):

```swift
private struct VoiceListeningRow: View {
    let partial: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.purple.opacity(0.9))
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text(partial.isEmpty ? "Listening…" : partial)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Cancel voice listening (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.purple.opacity(0.12))
        )
    }
}
```

**Escape handling.** In the `TextField`'s existing `.onKeyPress(.escape)` block (lines 220–226), extend the handler so escape cancels voice when active:

```swift
.onKeyPress(.escape) {
    if !viewModel.slashSuggestions.isEmpty {
        viewModel.currentInput += " "
        return .handled
    }
    if case .voiceListening = viewModel.inputBarState {
        viewModel.voiceController?.cancel()
        return .handled
    }
    return .ignored
}
```

However, note the TextField is `isEditable`-gated (line 192), and `.voiceListening` is NOT editable — the TextField is not in the tree during voice. To catch Escape, attach a sibling `.background(...)` key-press handler to the whole `NotchCommandBarView.body` (at the `.animation(...)` chain near line 116):

```swift
.focusable(true)
.onKeyPress(.escape) {
    if case .voiceListening = viewModel.inputBarState {
        viewModel.voiceController?.cancel()
        return .handled
    }
    return .ignored
}
```

---

## 9. Settings panel — exact edit to `AICommandBarSettings.swift`

Append a new `VoiceSettingsSection` view to `/Users/allenwu/claude/metamorphia/Metamorphia/components/Settings/AICommandBarSettings.swift`. Also add a new `Section` call to `AICommandBarSettings.body` (after line 149, right after the existing `Tools` section and before `Costs`):

```swift
Section("Voice Input") {
    VoiceSettingsSection()
}
```

And append the new view at the bottom of the file:

```swift
struct VoiceSettingsSection: View {
    @Default(.voiceEnabled) private var voiceEnabled
    @Default(.voiceWakeWordEnabled) private var wakeWordEnabled

    var body: some View {
        Toggle("Enable voice input (Cmd+Shift+V)", isOn: $voiceEnabled)
            .onChange(of: voiceEnabled) { _, newValue in
                // Toggle the bridged UserDefaults key the service actually
                // reads. `Defaults` writes `"voiceEnabled"`; `VoiceService`
                // reads `"metamorphia_voice_enabled"`. Mirror on change.
                VoiceService.shared.isEnabled = newValue
            }

        KeyboardShortcuts.Recorder("Voice input hotkey", name: .voiceInput)

        HStack {
            Button("Reset to ⌘⇧V") {
                KeyboardShortcuts.reset(.voiceInput)
            }
            .buttonStyle(.bordered)
            Spacer()
        }

        Toggle("Listen for \"\(assistantName)\" in the background", isOn: $wakeWordEnabled)
            .disabled(!voiceEnabled)
            .onChange(of: wakeWordEnabled) { _, newValue in
                VoiceService.shared.alwaysListening = newValue
            }

        if wakeWordEnabled {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("The microphone stays on while this is enabled. macOS will show the orange mic indicator continuously. Expect ~1–2% CPU overhead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }

        Text("Speech recognition runs on-device when supported for your locale (macOS 14+). No audio leaves your Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var assistantName: String {
        AssistantNameManager.shared.name
    }
}

extension Defaults.Keys {
    static let voiceEnabled = Key<Bool>("voiceEnabled", default: false)
    static let voiceWakeWordEnabled = Key<Bool>("voiceWakeWordEnabled", default: false)
}
```

Note: `Defaults[.voiceEnabled]` and `VoiceService`'s `"metamorphia_voice_enabled"` UserDefaults key live in the same domain but under different keys. The settings section mirrors on toggle. We could unify by making `VoiceService` read `"voiceEnabled"` directly — simpler but couples the service to the `Defaults` library. Keep the mirror to stay framework-free in the service.

---

## 10. Permissions UX

**First-press flow (Cmd+Shift+V):**

1. `VoiceController.activate()` → `VoiceService.activate()` → `requestPermissions()`.
2. `AVAudioApplication.requestRecordPermission()` shows the TCC mic prompt (blocking for user).
3. If denied, `requestPermissions()` returns false → `state = .error("Microphone or speech-recognition permission denied")` → `VoiceController`'s `$state` sink sees `.error` and calls `self.cancel()` which calls `viewModel.cancelVoice()` → pill back to `.ready`.
4. User sees pill flicker back and no glow. That's a silent failure — **not acceptable**. Add an NSAlert fallback:

Add to `VoiceController.cancel()` (or better, in a new `showPermissionDeniedAlert()` method called from the `.error` branch of the state sink):

```swift
private func showPermissionDeniedAlert(message: String) {
    let alert = NSAlert()
    alert.messageText = "Voice Input Needs Permission"
    alert.informativeText = "Metamorphia couldn't access the microphone or speech recognition. Open System Settings to grant access, then try again.\n\nError: \(message)"
    alert.alertStyle = .warning
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
```

Wire it: in the `voice.$state` sink, change the `.error(let msg)` branch to call this alert before cancelling.

---

## 11. Risks & open questions

| Risk | Mitigation |
|---|---|
| **(a) On-device recognition locale support.** `supportsOnDeviceRecognition` is true for en-US on modern Macs, but not for every locale the user might be set to. If false, Speech ships audio to Apple servers — user expects privacy. | `VoiceService.init` already logs support status. Add a Settings line: "On-device recognition: YES for en-US" so the user sees whether audio leaves their Mac. Future: force `recognitionRequest.requiresOnDeviceRecognition = true` when available and fall back with a prompt if the locale doesn't support it. |
| **(b) Wake-word CPU.** VAD is one `vDSP_measqv` per 1024-sample buffer (~43 Hz at 44.1 kHz). That's ~1% CPU on M1+. Short speech-detection sessions add bursts of ~5% during speech. Acceptable but the orange mic dot is always visible. | Opt-in only. Settings warning text already states the cost. |
| **(c) Mic hot-swap / device change.** Plugging in AirPods mid-listen stops the engine. Executer's code already handles this in `endSpeechDetectionSession` (engine-not-running check → restart). Works. | Ported as-is. Add a test case for the smoke plan. |
| **(d) Interaction with macOS Siri/Dictation.** Both compete for the mic. Dictation (Fn-Fn) takes priority when active. | Can't fix. Document in Settings footnote. |
| **(e) Third-party SDK adoption.** N/A — Executer's stack uses only Apple frameworks. Zero SPM changes. | — |
| **(f) Calibration flow (not ported in T5).** `VoiceCalibration.swift` learns how the recognizer hears the user say the name. Without it, wake word matches the literal string "Metamorphia" only. | Port in T5.5 (follow-up task) — non-blocking; matcher degrades gracefully. |
| **(g) Bar open vs closed during voice.** If Cmd+Shift+V is pressed with the notch closed, `VoiceController.beginVoiceUI()` calls `CommandBarCoordinator.shared.summon()`. The summon path is idempotent (it's a toggle guard — already-open is a no-op). | Confirmed from reading `CommandBarCoordinator.summon()` — guard on `vm.notchState` handles both paths. |
| **(h) LSUIElement activation.** Metamorphia is an accessory app. `SFSpeechRecognizer.requestAuthorization` surfaces a TCC prompt; the permission dialog is system-modal and appears regardless of activation state, but the Metamorphia app must at least be running (it is). No extra activation needed. | — |
| **(i) Cmd+Shift+Space + Cmd+Shift+V interaction.** If the user Cmd+Shift+Space's while voice is listening, `CommandBarCoordinator.dismiss()` runs. Currently nothing tells voice to stop. | Fix: in `CommandBarCoordinator.dismiss()` add `MetamorphiaBootstrap.voiceController?.cancel()` before closing the notch. Alternatively wire a listener on `commandBarDidDismiss` in `VoiceController`. Prefer the latter — less coupling. |

---

## 12. Out of scope

- Voice synthesis (speak-aloud responses). Already handled by `NSSpeechSynthesizer` in `ResultBubbleView` from T2.
- Non-English locales. Locale = `Locale.current` falling back to `en-US` (same as Executer).
- Custom voice commands (e.g. "Metamorphia clear chat"). Only the hard-coded "cancel"/"never mind" cancel words port from Executer.
- Continuous conversation mode. One command per Cmd+Shift+V press.
- Voice-based tool confirmation. Destructive actions still go through `MetamorphiaToolSafetyGate`'s visual prompt, voice or typed.
- `VoiceCalibration` panel. Deferred to a T5.5 follow-up.
- In-meeting transcription / `MeetingTranscriber`. Totally separate subsystem; not part of the command-bar voice stack.

---

## 13. Test plan (manual smoke)

Run in this order, in a clean Metamorphia build with zero prior mic/speech grants:

1. **Cold permission flow.** Launch Metamorphia fresh. Open Settings → AI Command Bar → toggle "Enable voice input" ON. Press Cmd+Shift+V. Expect: mic permission dialog appears, then speech-recognition dialog. Grant both. Expect: glow window fades in around screen edges, pill shows "Listening…" in purple, command bar opens if closed.
2. **Happy-path command.** With voice listening active, say "what's the weather today". Expect: partial transcripts appear in the pill and in the voice-listening row within ~300 ms per word. After ~2.5 s of silence, the glow fades, the pill flips to `.processing`, and the agent runs the command and returns a response.
3. **Self-cancel via speech.** Press Cmd+Shift+V. Say "cancel". Expect: glow fades, pill returns to `.ready`, no agent submission.
4. **Self-cancel via hotkey.** Press Cmd+Shift+V. Wait until glow shows. Press Cmd+Shift+V again before speaking. Expect: glow fades, `.ready`.
5. **Self-cancel via Escape.** Press Cmd+Shift+V. Wait until glow shows. Press Escape. Expect: glow fades, `.ready`.
6. **Timeout.** Press Cmd+Shift+V. Say nothing for 12 s. Expect: glow fades, pill returns to `.ready` (no phantom submission).
7. **Permission denied.** In System Settings, deny Microphone for Metamorphia. Press Cmd+Shift+V. Expect: NSAlert "Voice Input Needs Permission" with "Open Settings" button. Click it — expect Privacy → Microphone pane opens.
8. **Wake word (opt-in).** Enable "Listen for Metamorphia in the background" in Settings. Close the notch. Say "Hey Metamorphia, what time is it". Expect: within ~1 s of "Metamorphia" being recognized, the command-bar opens, the glow shows, and the partial transcript already contains "what time is it". On silence the agent runs the command.
9. **Wake-word false positive.** Enable wake word. Say "never gonna give you up" several times. Expect: VAD triggers short sessions but no wake word match, no command bar opens.
10. **Cmd+Shift+Space while listening.** Press Cmd+Shift+V. Wait for glow. Press Cmd+Shift+Space. Expect: command bar dismisses AND voice cancels (glow fades). Validates risk (i) fix.
11. **Device hot-swap.** Start listening. Mid-listen, plug in headphones. Expect: within ~1 s, the engine restarts (background listening) or the current command session completes/errors gracefully and drops back to `.ready`.
12. **Concurrent agent run rejection.** Submit a typed command that takes ≥10 s. While it's running, press Cmd+Shift+V. Expect: nothing happens — log line "[Voice] Agent already running — ignoring voice hotkey".

---

## Critical Files for Implementation

- `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceService.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceController.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/Voice/VoiceGlowWindow.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/MetamorphiaBootstrap.swift`