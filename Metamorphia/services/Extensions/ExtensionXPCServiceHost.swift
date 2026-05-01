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

import AppKit
import Foundation
import AtollExtensionKit

/// Shared constants for the Metamorphia extension XPC service.
enum ExtensionXPCServiceConstants {
    static let machServiceName = "com.johannendersmith.metamorphia.xpc"
}

@MainActor
final class ExtensionXPCServiceHost: NSObject, NSXPCListenerDelegate {
    static let shared = ExtensionXPCServiceHost()

    /// Code-signing requirement every incoming XPC peer must satisfy. Matches
    /// Apple-notarized or ad-hoc signed builds with our team identifier.
    ///
    /// Without this, any local process could connect, report any bundle ID
    /// via `NSRunningApplication`, and invoke `presentLiveActivity` /
    /// `presentLockScreenWidget` / `presentNotchExperience` — a UI-hijack
    /// surface. `setCodeSigningRequirement` makes the kernel verify the peer's
    /// signature before delivering messages, which can't be spoofed.
    ///
    /// For developer builds signed with a different team, override via the
    /// `METAMORPHIA_XPC_PEER_REQUIREMENT` environment variable. Production builds
    /// should ship with the team ID baked in.
    private static let expectedCodeSigningRequirement: String = {
        if let override = ProcessInfo.processInfo.environment["METAMORPHIA_XPC_PEER_REQUIREMENT"],
           !override.isEmpty {
            return override
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"9Y64TRM77N\""
    }()

    private final class ClientContext {
        weak var connection: NSXPCConnection?
        let bundleIdentifier: String

        init(connection: NSXPCConnection, bundleIdentifier: String) {
            self.connection = connection
            self.bundleIdentifier = bundleIdentifier
        }
    }

    private var listener: NSXPCListener?
    private var clientContexts: [ObjectIdentifier: ClientContext] = [:]

    func start() {
        guard listener == nil else { return }

        let listener = NSXPCListener(machServiceName: ExtensionXPCServiceConstants.machServiceName)
        listener.delegate = self
        self.listener = listener
        listener.resume()

        Logger.log("Started Metamorphia XPC listener", category: .extensions)
    }

    func stop() {
        listener?.invalidate()
        listener = nil
        clientContexts.removeAll()
        Logger.log("Stopped Metamorphia XPC listener", category: .extensions)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Bind an inbound code-signing requirement BEFORE any messages flow.
        // The kernel enforces this on every message — peers that don't satisfy
        // it have their messages dropped.
        if #available(macOS 13.0, *) {
            do {
                try connection.setCodeSigningRequirement(Self.expectedCodeSigningRequirement)
            } catch {
                Logger.log("Rejected XPC connection: setCodeSigningRequirement failed (\(error))", category: .extensions)
                return false
            }
        }

        guard let bundleIdentifier = resolveBundleIdentifier(for: connection) else {
            Logger.log("Rejected XPC connection without bundle identifier", category: .extensions)
            return false
        }

        let service = ExtensionXPCService(bundleIdentifier: bundleIdentifier, host: self, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: AtollXPCServiceProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: AtollXPCClientProtocol.self)

        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.removeConnection(connection)
            }
        }

        connection.interruptionHandler = { [weak self, weak connection] in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.removeConnection(connection)
            }
        }

        connection.resume()
        clientContexts[ObjectIdentifier(connection)] = ClientContext(connection: connection, bundleIdentifier: bundleIdentifier)
        Logger.log("Accepted XPC connection from \(bundleIdentifier)", category: .extensions)
        return true
    }

    func notifyAuthorizationChange(bundleIdentifier: String, isAuthorized: Bool) {
        deliver(to: bundleIdentifier) { client in
            client.authorizationDidChange(isAuthorized: isAuthorized)
        }
    }

    func notifyActivityDismiss(bundleIdentifier: String, activityID: String) {
        deliver(to: bundleIdentifier) { client in
            client.activityDidDismiss(activityID: activityID)
        }
    }

    func notifyWidgetDismiss(bundleIdentifier: String, widgetID: String) {
        deliver(to: bundleIdentifier) { client in
            client.widgetDidDismiss(widgetID: widgetID)
        }
    }

    func notifyNotchExperienceDismiss(bundleIdentifier: String, experienceID: String) {
        deliver(to: bundleIdentifier) { client in
            client.notchExperienceDidDismiss(experienceID: experienceID)
        }
    }

    private func resolveBundleIdentifier(for connection: NSXPCConnection) -> String? {
        let processIdentifier = connection.processIdentifier
        guard processIdentifier != 0 else { return nil }

        if let app = NSRunningApplication(processIdentifier: pid_t(processIdentifier)),
           let bundleIdentifier = app.bundleIdentifier {
            return bundleIdentifier
        }

        return nil
    }

    private func deliver(to bundleIdentifier: String, send block: (AtollXPCClientProtocol) -> Void) {
        var staleIdentifiers: [ObjectIdentifier] = []

        for (identifier, context) in clientContexts where context.bundleIdentifier == bundleIdentifier {
            guard let connection = context.connection else {
                staleIdentifiers.append(identifier)
                continue
            }

            guard let client = connection.remoteObjectProxyWithErrorHandler({ error in
                Logger.log("Failed to deliver XPC callback to \(bundleIdentifier): \(error)", category: .extensions)
            }) as? AtollXPCClientProtocol else {
                continue
            }

            block(client)
        }

        staleIdentifiers.forEach { clientContexts.removeValue(forKey: $0) }
    }

    private func removeConnection(_ connection: NSXPCConnection) {
        clientContexts.removeValue(forKey: ObjectIdentifier(connection))
        Logger.log("Removed XPC connection", category: .extensions)
    }
}
