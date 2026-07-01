import SwiftUI
import Defaults
import KeyboardShortcuts
import MetamorphiaAgentKit

/// AI Command Bar settings — model picker, API key, learning, MCP servers.
/// First pass: provider/model selection + API key entry, all surfaced inline
/// because the per-section split (Models / Agents / Voice / Learning / MCP /
/// Developer) deserves its own focused refactor pass.
struct AICommandBarSettings: View {
    @State private var selectedProvider: LLMProvider = LLMServiceManager.shared.currentProvider
    @State private var selectedModel: String = LLMServiceManager.shared.currentModel
    @State private var apiKey: String = ""
    @State private var hasKey: Bool = false
    @State private var savedFlash = false
    @ObservedObject private var apiLog = APICallLog.shared

    var body: some View {
        Section {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("AI Command Bar")
                    .font(.headline)
                Spacer()
            }
            Text("The AI agent that lives in your notch. Press Cmd+Shift+Space (configurable below) to summon it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Hotkey") {
            KeyboardShortcuts.Recorder("Summon Command Bar", name: .commandBar)

            HStack {
                Button("Reset to ⌘⇧Space") {
                    // Reset-to-default (fix #10). The KeyboardShortcuts
                    // library stores the user's override in UserDefaults —
                    // `.reset` clears it and falls back to the `default:`
                    // value declared in `MetamorphiaShortcuts.swift`.
                    KeyboardShortcuts.reset(.commandBar)
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            // ⌘⇧Space system conflict warning (fix #9). macOS ships with
            // ⌘⇧Space bound to the input-source picker by default. When
            // that binding is enabled in System Settings → Keyboard →
            // Input Sources, macOS consumes the event before the app sees
            // it, and Metamorphia's hotkey silently appears "broken". Give the
            // user a one-click path to the relevant pane.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("If ⌘⇧Space doesn't summon the bar, macOS may be intercepting it for the input-source picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Keyboard Shortcut Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        }

        Section("Provider") {
            Picker("LLM Provider", selection: $selectedProvider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.config.displayName).tag(p)
                }
            }
            .onChange(of: selectedProvider) { _, newProvider in
                LLMServiceManager.shared.currentProvider = newProvider
                selectedModel = newProvider.config.defaultModel
                LLMServiceManager.shared.currentModel = selectedModel
                refreshKeyState()
            }

            Picker("Model", selection: $selectedModel) {
                ForEach(selectedProvider.config.availableModels, id: \.self) { m in
                    Text(m).tag(m)
                }
            }
            .onChange(of: selectedModel) { _, newModel in
                LLMServiceManager.shared.currentModel = newModel
            }
        }

        Section("API Key") {
            HStack {
                Image(systemName: hasKey ? "checkmark.circle.fill" : "key")
                    .foregroundStyle(hasKey ? .green : .secondary)
                Text(hasKey ? "Key configured for \(selectedProvider.config.displayName)"
                            : "No key set for \(selectedProvider.config.displayName)")
                    .font(.subheadline)
                Spacer()
            }

            SecureField(selectedProvider.config.keyPlaceholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save Key") {
                    APIKeyManager.shared.setKey(apiKey, for: selectedProvider)
                    apiKey = ""
                    refreshKeyState()
                    withAnimation(.smooth(duration: 0.25)) { savedFlash = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.smooth(duration: 0.25)) { savedFlash = false }
                    }
                }
                .disabled(apiKey.isEmpty)

                if hasKey {
                    Button("Delete Key", role: .destructive) {
                        APIKeyManager.shared.deleteKey(for: selectedProvider)
                        refreshKeyState()
                    }
                }

                if savedFlash {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Spacer()

                if let signupURL = URL(string: "https://\(selectedProvider.config.signupURL)") {
                    Link(destination: signupURL) {
                        Label("Get a key", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
        }

        Section("Tools") {
            Text("\(MetamorphiaBootstrap.registry?.count ?? 0) tools registered")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("The agent automatically picks relevant tools per query. Metamorphia's native managers (Timer, Clipboard, Notes, Shelf, ColorPicker, Calendar, Stats) are exposed as agent tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Costs") {
            if let tracker = MetamorphiaBootstrap.costTracker {
                Text(tracker.dailyReport())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Cost tracker not initialized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.tint)
                Text("API Log")
                    .font(.headline)
                Spacer()
                if !apiLog.entries.isEmpty {
                    Button("Clear") { APICallLog.shared.clear() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            Text("Every call to your LLM provider — the agent, writing tools, and copilots — newest first.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if apiLog.entries.isEmpty {
                Text("No API calls yet. They'll appear here as you use the agent and writing tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apiLog.entries.prefix(50)) { entry in
                    APILogRow(entry: entry)
                }
            }
        }

        Section {
            Text("More AI sub-sections — Models / Agents / Voice / Learning / MCP / Developer — will land in a follow-on UI pass. The infrastructure is ready (see MetamorphiaAgentKit) and these will plug into the existing agent loop.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { refreshKeyState() }
    }

    private func refreshKeyState() {
        hasKey = APIKeyManager.shared.hasKey(for: selectedProvider)
    }
}

/// Notch activation gesture tuning — long-press duration, haptic intensity,
/// optional swap of short-click vs long-press behaviors (accessibility for users
/// with tremors).
struct NotchActivationSettings: View {
    @Default(.notchActivationCommitDuration) private var commitDuration
    @Default(.notchActivationHapticIntensity) private var hapticIntensity
    @Default(.notchActivationModesSwapped) private var modesSwapped

    var body: some View {
        Section {
            Text("Tune the dual-activation gesture. Short-click summons the AI Command Bar; long-press opens Metamorphia tabs. Hold to feel the progressive haptic.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Long-press commit duration") {
            HStack {
                Text("\(Int(commitDuration * 1000))ms")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                Slider(value: $commitDuration, in: 0.15...0.60, step: 0.01)
            }
            Text("Default 300ms. Lower for snappy switching, higher if you find yourself accidentally entering Metamorphia tabs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Haptic feedback") {
            Picker("Intensity", selection: $hapticIntensity) {
                Text("Off").tag("off")
                Text("Light (commit only)").tag("light")
                Text("Default (with ticks)").tag("full")
            }
            .pickerStyle(.segmented)
        }

        Section("Accessibility") {
            Toggle("Swap modes (long-press = Command Bar, short-click = tabs)", isOn: $modesSwapped)
            Text("Useful if hand tremors or click-drift make holding the click unreliable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Defaults Keys

extension Defaults.Keys {
    static let notchActivationCommitDuration = Key<Double>("notchActivationCommitDuration", default: 0.30)
    static let notchActivationHapticIntensity = Key<String>("notchActivationHapticIntensity", default: "full")
    static let notchActivationModesSwapped = Key<Bool>("notchActivationModesSwapped", default: false)
    static let voiceEnabled = Key<Bool>("voiceEnabled", default: false)
    static let voiceWakeWordEnabled = Key<Bool>("voiceWakeWordEnabled", default: false)
}

// MARK: - Voice Settings Section

struct VoiceSettingsSection: View {
    @Default(.voiceEnabled) private var voiceEnabled
    @Default(.voiceWakeWordEnabled) private var wakeWordEnabled

    var body: some View {
        Toggle("Enable voice input (Cmd+Shift+V)", isOn: $voiceEnabled)
            .onChange(of: voiceEnabled) { _, newValue in
                // `Defaults` has already persisted the canonical `"voiceEnabled"`
                // key by the time this fires; VoiceService now reads the same
                // key. Setting `isEnabled` here drives the service's start/stop
                // side-effects (background listening) on the toggle.
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

// MARK: - API Log Row

/// One row of the AI API log: an at-a-glance record of a single provider call —
/// model, transport, size, latency, and outcome.
private struct APILogRow: View {
    let entry: APICallLogEntry

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.success ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.model)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.provider)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if entry.streaming {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detailLine)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(entry.date, style: .time)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let prompt = entry.promptTokens, let completion = entry.completionTokens {
            parts.append("\(prompt)→\(completion) tok")
        } else {
            parts.append("\(entry.inputChars)→\(entry.outputChars) ch")
        }
        parts.append("\(entry.durationMs) ms")
        if let error = entry.error {
            parts.append(error)
        }
        return parts.joined(separator: "  ·  ")
    }
}
