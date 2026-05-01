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
