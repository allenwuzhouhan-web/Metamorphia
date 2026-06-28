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

import Foundation
import Combine
import SwiftUI

final class YouTubeMusicController: MediaControllerProtocol {
    // MARK: - Published Properties
    @Published var playbackState = PlaybackState(
        bundleIdentifier: YouTubeMusicConfiguration.default.bundleIdentifier
    )

    private var artworkFetchTask: Task<Void, Never>?
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    /// Serializes every mutation of the @Published `playbackState` onto the main
    /// actor. The published value and its Combine subscriber list are not
    /// thread-safe, and writes otherwise arrive from the WebSocket executor, the
    /// periodic timer, and async command handlers concurrently.
    @MainActor
    private func mutatePlaybackState(_ transform: (inout PlaybackState) -> Void) {
        var copy = playbackState
        transform(&copy)
        playbackState = copy
    }
    
    var isWorking: Bool {
        isActive() && (updateTimer != nil || webSocketClient != nil)
    }
    
    // MARK: - Private Properties
    private let configuration: YouTubeMusicConfiguration
    private let httpClient: YouTubeMusicHTTPClient
    private let authManager: YouTubeMusicAuthManager
    private var webSocketClient: YouTubeMusicWebSocketClient?
    
    private var updateTimer: Timer?
    private var appStateObserver: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1.0
    
    // MARK: - Initialization
    init(configuration: YouTubeMusicConfiguration = .default) {
        self.configuration = configuration
        self.httpClient = YouTubeMusicHTTPClient(baseURL: configuration.baseURL)
        self.authManager = YouTubeMusicAuthManager(httpClient: httpClient)
        
        setupAppStateObserver()

        Task {
            await initializeIfAppActive()
        }
    }

    deinit {
        updateTimer?.invalidate()
        appStateObserver?.cancel()
        artworkFetchTask?.cancel()
    }

    // MARK: - MediaControllerProtocol Implementation
    func play() async { await sendCommand(endpoint: "/play", method: "POST") }
    
    func pause() async { await sendCommand(endpoint: "/pause", method: "POST") }
    
    func togglePlay() async {
        if !isActive() { launchApp() }
        await sendCommand(endpoint: "/toggle-play", method: "POST")
    }
    
    func nextTrack() async { await sendCommand(endpoint: "/next", method: "POST") }

    func previousTrack() async { await sendCommand(endpoint: "/previous", method: "POST") }
    
    func seek(to time: Double) async {
        let payload = ["seconds": time]
        await sendCommand(endpoint: "/seek-to", method: "POST", body: payload)
    }
    func fetchShuffleState() async { await sendCommand(endpoint: "/shuffle", method: "GET", refresh: false) }
    func fetchRepeatMode() async { await sendCommand(endpoint: "/repeat-mode", method: "GET", refresh: false) }
    
    func toggleShuffle() async { await sendCommand(endpoint: "/shuffle", method: "POST") }
    func toggleRepeat() async { await sendCommand(endpoint: "/switch-repeat", method: "POST") }

    nonisolated func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == configuration.bundleIdentifier
        }
    }
    
    func updatePlaybackInfo() async {
        guard isActive() else {
            await resetPlaybackState()
            return
        }

        do {
            let token = try await authManager.authenticate()
            let response = try await httpClient.getPlaybackInfo(token: token)
            await updatePlaybackState(with: response)
        } catch YouTubeMusicError.authenticationRequired {
            await authManager.invalidateToken()
        } catch {
            print("[YouTubeMusicController] Failed to update playback info: \(error)")
        }
    }
    
    // MARK: - Private Methods
    private func setupAppStateObserver() {
        appStateObserver = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let launchNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named: NSWorkspace.didLaunchApplicationNotification
                    )
                    
                    for await notification in launchNotifications {
                        await self?.handleAppLaunched(notification)
                    }
                }
                
                group.addTask {
                    let terminateNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named: NSWorkspace.didTerminateApplicationNotification
                    )
                    
                    for await notification in terminateNotifications {
                        await self?.handleAppTerminated(notification)
                    }
                }
            }
        }
    }
    
    private func handleAppLaunched(_ notification: Notification) async {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == configuration.bundleIdentifier else {
            return
        }
        
        await initializeIfAppActive()
    }
    
    private func handleAppTerminated(_ notification: Notification) async {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == configuration.bundleIdentifier else {
            return
        }
        
        Task { @MainActor in
            stopPeriodicUpdates()
            appStateObserver?.cancel()
        }
        
        Task {
            await webSocketClient?.disconnect()
            webSocketClient = nil
        }

        await resetPlaybackState()
    }
    
    private func initializeIfAppActive() async {
        guard isActive() else { return }
        
        do {
            let token = try await authManager.authenticate()
            await setupWebSocketIfPossible(token: token)
            await startPeriodicUpdates()
            await updatePlaybackInfo()
        } catch {
            print("[YouTubeMusicController] Failed to initialize: \(error)")
            await scheduleReconnect()
        }
    }
    
    private func setupWebSocketIfPossible(token: String) async {
        guard let wsURL = WebSocketURLBuilder.buildURL(from: configuration.baseURL) else {
            print("[YouTubeMusicController] Failed to build WebSocket URL")
            return
        }
        
        let client = YouTubeMusicWebSocketClient(
            onMessage: { [weak self] data in
                await self?.handleWebSocketMessage(data)
            },
            onDisconnect: { [weak self] in
                await self?.handleWebSocketDisconnect()
            }
        )
        
        do {
            try await client.connect(to: wsURL, with: token)
            webSocketClient = client
            stopPeriodicUpdates() // WebSocket will provide real-time updates
            reconnectDelay = configuration.reconnectDelay.lowerBound
        } catch {
            print("[YouTubeMusicController] WebSocket connection failed: \(error)")
            await scheduleReconnect()
        }
    }
    
    private func handleWebSocketMessage(_ data: Data) async {
        guard let message = WebSocketMessage(from: data) else {
            if let response = try? JSONDecoder().decode(PlaybackResponse.self, from: data) {
                await updatePlaybackState(with: response)
            }
            return
        }
        switch message.type {
        case .playerInfo, .videoChanged, .playerStateChanged:
            if let data = message.extractData(),
               let response = PlaybackResponse.from(websocketData: data) {
                await updatePlaybackState(with: response)
            }

        case .positionChanged:
            guard let data = message.extractData() else { return }

            var position: Double? = nil
            if let pos = data["position"] as? Double {
                position = pos
            } else if let elapsed = data["elapsedSeconds"] as? Double {
                position = elapsed
            }
            guard let newPosition = position else { return }

            await mutatePlaybackState { copy in
                copy.currentTime = newPosition
                copy.lastUpdated = Date()
            }

        case .repeatChanged:
            guard let data = message.extractData() else { return }

            let newRepeatMode: RepeatMode?
            if let repeatStr = data["repeat"] as? String {
                switch repeatStr.uppercased() {
                case "NONE": newRepeatMode = .off
                case "ALL": newRepeatMode = .all
                case "ONE": newRepeatMode = .one
                default: newRepeatMode = nil
                }
            } else {
                newRepeatMode = nil
            }
            await mutatePlaybackState { copy in
                if let newRepeatMode { copy.repeatMode = newRepeatMode }
                copy.lastUpdated = Date()
            }

        case .shuffleChanged:
            guard let data = message.extractData() else { return }

            let newShuffle = (data["shuffle"] as? Bool) ?? (data["isShuffled"] as? Bool)
            await mutatePlaybackState { copy in
                if let newShuffle { copy.isShuffled = newShuffle }
                copy.lastUpdated = Date()
            }

        case .volumeChanged:
            break
        }
    }
    
    private func handleWebSocketDisconnect() async {
        webSocketClient = nil
        await startPeriodicUpdates() // Fallback to polling
        await scheduleReconnect()
    }
    
    private func scheduleReconnect() async {
        try? await Task.sleep(for: .seconds(reconnectDelay))
        reconnectDelay = min(reconnectDelay * 2, configuration.reconnectDelay.upperBound)
        
        if isActive() {
            await initializeIfAppActive()
        }
    }
    
    private func startPeriodicUpdates() async {
        guard isActive() && webSocketClient == nil else { return }
        
        stopPeriodicUpdates()
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: configuration.updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    private func stopPeriodicUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func pollPlaybackState() async {
        if !isActive() {
            return
        }
        
        await fetchRepeatMode()
        await fetchShuffleState()
        await updatePlaybackInfo()
    }
    
    private func sendCommand(
        endpoint: String,
        method: String = "POST",
        body: (any Codable & Sendable)? = nil,
        refresh: Bool = true
    ) async {
        do {
            let token = try await authManager.authenticate()
            
            let data = try await httpClient.sendCommand(
                endpoint: endpoint,
                method: method,
                body: body,
                token: token
            )
            // Lightweight endpoint-specific parsing
            if endpoint == "/shuffle" {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let shuffleState = json?["state"] as? Bool
                await mutatePlaybackState { copy in
                    copy.isShuffled = shuffleState ?? !copy.isShuffled
                }
            } else if endpoint == "/repeat-mode" {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let mode = json["mode"] as? String { await updateRepeatMode(mode) }
                }
            }  else if endpoint == "/switch-repeat" {
                // Find next repeat mode
                await mutatePlaybackState { copy in
                    switch copy.repeatMode {
                    case .off: copy.repeatMode = .all
                    case .all: copy.repeatMode = .one
                    case .one: copy.repeatMode = .off
                    }
                }
            } else if refresh && webSocketClient == nil {
                try? await Task.sleep(for: .milliseconds(100))
                await updatePlaybackInfo()
            }
        } catch YouTubeMusicError.authenticationRequired {
            await authManager.invalidateToken()
        } catch {
            print("[YouTubeMusicController] Command failed: \(error)")
        }
    }
    
    private func updatePlaybackState(with response: PlaybackResponse) async {
        // Extract primitive values off-actor, then apply them on the main actor
        // where `playbackState` is owned.
        let isPlaying = !response.isPaused
        let title = response.title
        let artist = response.artist
        let album = response.album
        let elapsed = response.elapsedSeconds
        let duration = response.songDuration
        let shuffled = response.isShuffled
        let repeatModeRaw = response.repeatMode

        await mutatePlaybackState { newState in
            newState.isPlaying = isPlaying

            if let title { newState.title = title }
            if let artist { newState.artist = artist }
            if let album { newState.album = album }
            if let elapsed { newState.currentTime = elapsed }
            if let duration { newState.duration = duration }

            newState.lastUpdated = Date()

            if let shuffled { newState.isShuffled = shuffled }

            if let mode = repeatModeRaw {
                switch mode {
                case 0: newState.repeatMode = .off
                case 1: newState.repeatMode = .all
                case 2: newState.repeatMode = .one
                default: break
                }
            }
        }

        artworkFetchTask?.cancel()
        artworkFetchTask = nil

        if let artworkURL = response.imageSrc,
           let url = URL(string: artworkURL) {
            artworkFetchTask = Task {
                do {
                    let data = try await ImageService.shared.fetchImageData(from: url)
                    await MainActor.run { [weak self] in
                        self?.playbackState.artwork = data
                    }
                } catch { /* ignore */ }
            }
        }
    }
    
    @MainActor
    private func resetPlaybackState() {
        playbackState = PlaybackState(
            bundleIdentifier: configuration.bundleIdentifier,
            isPlaying: false
        )
    }
    
    private func launchApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: configuration.bundleIdentifier) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

     @MainActor
     private func updateRepeatMode(_ mode: String) {
        var target: RepeatMode? = nil
        switch mode {
            case "NONE": target = .off
            case "ALL": target = .all
            case "ONE": target = .one
            default: break
        }
        if let target, target != playbackState.repeatMode { playbackState.repeatMode = target }
    }
    
}
