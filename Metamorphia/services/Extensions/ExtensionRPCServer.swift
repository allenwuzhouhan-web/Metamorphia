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

import Foundation
import Network
import Defaults
import Combine

/// WebSocket server for Metamorphia RPC.
/// Uses Apple's Network.framework (`NWListener`) — no external dependencies.
/// Listens on localhost:9020 for JSON-RPC 2.0 requests over WebSocket.
@MainActor
final class ExtensionRPCServer {
    static let shared = ExtensionRPCServer()

    private var listener: NWListener?
    private var connections: [UUID: RPCClientConnection] = [:]
    private var shelfSubscribers: Set<String> = [] // bundleIdentifiers subscribed to shelf events
    private let port: UInt16 = 9020
    private let queue = DispatchQueue(label: "com.johannendersmith.metamorphia.rpc.server", qos: .userInitiated)
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Hard upper bound on a single inbound RPC frame (16 MB). Frames larger than this are
    /// dropped without decoding to bound memory/CPU on the main actor.
    private static let maxInboundFrameBytes = 16 * 1024 * 1024

    private var featureToggleCancellable: AnyCancellable?

    private init() {
        // Start/stop the listener in lockstep with the feature toggle so the port is only open
        // while third-party extensions are enabled, even if the user toggles it after launch.
        // `options: []` skips the initial emission so this doesn't re-enter `start()` during init.
        featureToggleCancellable = Defaults.publisher(.enableThirdPartyExtensions, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                if change.newValue {
                    self.start()
                } else {
                    self.stop()
                }
            }
    }

    // MARK: - Lifecycle

    func start() {
        // Only open the port when third-party extensions are enabled. When the feature is off,
        // the RPC port must not be reachable at all (mirrors the gate the service methods enforce).
        guard Defaults[.enableThirdPartyExtensions] else {
            logDiagnostics("RPC server not started: third-party extensions disabled")
            return
        }

        guard listener == nil else {
            logDiagnostics("RPC server already running")
            return
        }

        let params = NWParameters(tls: nil)
        // Restrict the listener to loopback only so the port is unreachable from the LAN.
        // `requiredLocalEndpoint` pins binding to 127.0.0.1:<port>; prohibiting non-loopback
        // interface types fails closed if the local endpoint hint is ever relaxed.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(integerLiteral: port)
        )
        params.prohibitedInterfaceTypes = [.wifi, .cellular, .wiredEthernet]
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        } catch {
            Logger.log("Failed to create RPC listener: \(error.localizedDescription)", category: .extensions)
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, conn) in connections {
            conn.connection.cancel()
        }
        connections.removeAll()
        shelfSubscribers.removeAll()
        logDiagnostics("RPC server stopped")
    }

    // MARK: - Client Notifications

    func notifyActivityDismiss(bundleIdentifier: String, activityID: String) {
        sendNotification(
            to: bundleIdentifier,
            method: "metamorphia.activityDidDismiss",
            params: [
                "bundleIdentifier": .string(bundleIdentifier),
                "activityID": .string(activityID)
            ]
        )
    }

    func notifyWidgetDismiss(bundleIdentifier: String, widgetID: String) {
        sendNotification(
            to: bundleIdentifier,
            method: "metamorphia.widgetDidDismiss",
            params: [
                "bundleIdentifier": .string(bundleIdentifier),
                "widgetID": .string(widgetID)
            ]
        )
    }

    func notifyNotchExperienceDismiss(bundleIdentifier: String, experienceID: String) {
        sendNotification(
            to: bundleIdentifier,
            method: "metamorphia.notchExperienceDidDismiss",
            params: [
                "bundleIdentifier": .string(bundleIdentifier),
                "experienceID": .string(experienceID)
            ]
        )
    }

    func notifyAuthorizationChange(bundleIdentifier: String, isAuthorized: Bool) {
        sendNotification(
            to: bundleIdentifier,
            method: "metamorphia.authorizationDidChange",
            params: [
                "bundleIdentifier": .string(bundleIdentifier),
                "isAuthorized": .bool(isAuthorized)
            ]
        )
    }

    // MARK: - Shelf Event Subscriptions

    func registerShelfSubscription(for bundleIdentifier: String) {
        shelfSubscribers.insert(bundleIdentifier)
        logDiagnostics("Registered shelf subscription for \(bundleIdentifier)")
    }

    func notifyShelfItemsChanged(itemIDs: [String], action: String) {
        guard !shelfSubscribers.isEmpty else { return }
        let params: [String: RPCValue] = [
            "action": .string(action),
            "itemIDs": .array(itemIDs.map { .string($0) })
        ]
        for subscriber in shelfSubscribers {
            sendNotification(
                to: subscriber,
                method: "metamorphia.shelfItemsDidChange",
                params: params
            )
        }
        logDiagnostics("Notified \(shelfSubscribers.count) subscriber(s) of shelf change (\(action), \(itemIDs.count) items)")
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            Logger.log("Started Metamorphia RPC WebSocket server on port \(port)", category: .extensions)
        case .failed(let error):
            Logger.log("RPC server failed: \(error.localizedDescription)", category: .extensions)
            // Attempt restart after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.listener = nil
                self?.start()
            }
        case .cancelled:
            logDiagnostics("RPC server listener cancelled")
        default:
            break
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let connID = UUID()
        let clientConn = RPCClientConnection(
            id: connID,
            connection: nwConnection,
            bundleIdentifier: nil
        )
        connections[connID] = clientConn

        nwConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(connID: connID, state: state)
            }
        }

        nwConnection.start(queue: queue)
        receiveMessage(connID: connID)
        logDiagnostics("RPC client connected (id: \(connID.uuidString.prefix(8)))")
    }

    private func handleConnectionState(connID: UUID, state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            removeConnection(connID: connID)
            logDiagnostics("RPC client disconnected (id: \(connID.uuidString.prefix(8)))")
        default:
            break
        }
    }

    /// Removes a connection and prunes its shelf subscription if no other live
    /// connection shares the same bundle identifier.
    private func removeConnection(connID: UUID) {
        guard let removed = connections.removeValue(forKey: connID) else { return }
        guard let bundleIdentifier = removed.bundleIdentifier else { return }
        let stillConnected = connections.values.contains { $0.bundleIdentifier == bundleIdentifier }
        if !stillConnected {
            shelfSubscribers.remove(bundleIdentifier)
        }
    }

    private func receiveMessage(connID: UUID) {
        guard let clientConn = connections[connID] else { return }
        let connection = clientConn.connection

        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }

            if let error {
                Task { @MainActor in
                    self.logDiagnostics("RPC receive error for \(connID.uuidString.prefix(8)): \(error.localizedDescription)")
                    self.removeConnection(connID: connID)
                }
                return
            }

            if let data = content, !data.isEmpty {
                // Reject oversized frames before decoding to bound memory/CPU on the main actor.
                guard data.count <= Self.maxInboundFrameBytes else {
                    Task { @MainActor in
                        self.logDiagnostics("Dropped oversized RPC frame (\(data.count) bytes) for \(connID.uuidString.prefix(8))")
                        let errorResponse = RPCErrorResponse(
                            error: RPCErrorObject(code: RPCErrorCode.invalidRequest, message: "Request too large"),
                            id: nil
                        )
                        self.sendResponse(errorResponse, to: connID)
                    }
                    // Continue receiving so the connection isn't wedged.
                    Task { @MainActor in
                        self.receiveMessage(connID: connID)
                    }
                    return
                }
                Task { @MainActor in
                    await self.processMessage(data: data, connID: connID)
                }
            }

            // Continue receiving
            Task { @MainActor in
                self.receiveMessage(connID: connID)
            }
        }
    }

    private func processMessage(data: Data, connID: UUID) async {
        guard var clientConn = connections[connID] else { return }

        // Parse JSON-RPC request
        guard let request = try? decoder.decode(RPCRequest.self, from: data) else {
            let errorResponse = RPCErrorResponse(
                error: RPCErrorObject(code: RPCErrorCode.parseError, message: "Invalid JSON-RPC request"),
                id: nil
            )
            sendResponse(errorResponse, to: connID)
            return
        }

        // Resolve bundle identifier from first authorization request
        if clientConn.bundleIdentifier == nil,
           let params = request.params,
           let bi = params["bundleIdentifier"]?.stringValue {
            clientConn.bundleIdentifier = bi
            connections[connID] = clientConn
        }

        let service = ExtensionRPCService(
            bundleIdentifier: clientConn.bundleIdentifier ?? "unknown",
            server: self
        )

        let responseData = await service.handleRequest(request)
        sendRawData(responseData, to: connID)
    }

    // MARK: - Send Helpers

    private func sendResponse(_ response: Codable, to connID: UUID) {
        guard let data = try? encoder.encode(response) else { return }
        sendRawData(data, to: connID)
    }

    private func sendRawData(_ data: Data, to connID: UUID) {
        guard let clientConn = connections[connID] else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "rpc-response", metadata: [metadata])

        clientConn.connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    Task { @MainActor in
                        self.logDiagnostics("RPC send error: \(error.localizedDescription)")
                    }
                }
            }
        )
    }

    private func sendNotification(to bundleIdentifier: String, method: String, params: [String: RPCValue]) {
        let notification = RPCNotification(method: method, params: params)
        guard let data = try? encoder.encode(notification) else { return }

        for (_, clientConn) in connections where clientConn.bundleIdentifier == bundleIdentifier {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "rpc-notification", metadata: [metadata])

            clientConn.connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in }
            )
        }
    }

    private func logDiagnostics(_ message: String) {
        guard Defaults[.extensionDiagnosticsLoggingEnabled] else { return }
        Logger.log(message, category: .extensions)
    }
}

// MARK: - Client Connection

struct RPCClientConnection {
    let id: UUID
    let connection: NWConnection
    var bundleIdentifier: String?
}
