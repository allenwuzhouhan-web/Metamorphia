/*
 * Metamorphia
 * Hardware-state bridge — forwards CameraMonitor and MicrophoneMonitor
 * @Published values into ActivityStream as typed ActivityEvents.
 *
 * No hardware access occurs here. The bridge is a pure Combine subscriber
 * over existing @Published properties already maintained by PrivacyIndicatorManager.
 *
 * Wire-up: call start() once after PrivacyIndicatorManager has started its
 * own monitoring. Dispose with stop() on app teardown.
 */

import Combine
import Foundation
import MetamorphiaAgentKit

// MARK: - HardwareStreamBridge

@MainActor
public final class HardwareStreamBridge {

    // MARK: - Private state

    private let stream: ActivityStream
    private var cancellables = Set<AnyCancellable>()
    private var running = false

    // MARK: - Init

    public init(stream: ActivityStream) {
        self.stream = stream
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true

        let camera = PrivacyIndicatorManager.shared.camera
        let mic = PrivacyIndicatorManager.shared.microphone

        // Camera: debounce 50 ms to suppress spurious double-fires from CoreMediaIO.
        camera.$isCameraActive
            .dropFirst()                          // skip the initial (synchronous) replay
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] isActive in
                guard let self, self.running else { return }
                Task { await self.stream.emit(.cameraToggled(isActive: isActive, at: .now)) }
            }
            .store(in: &cancellables)

        // Microphone: same 50 ms debounce.
        mic.$isMicActive
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] isActive in
                guard let self, self.running else { return }
                Task { await self.stream.emit(.microphoneToggled(isActive: isActive, at: .now)) }
            }
            .store(in: &cancellables)
    }

    public func stop() {
        guard running else { return }
        running = false
        cancellables.removeAll()
    }
}
