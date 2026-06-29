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

import Cocoa

class AirDrop: NSObject, NSSharingServiceDelegate {
    let files: [URL]

    /// Keeps the delegate alive for the duration of the share operation.
    /// `NSSharingService` holds its delegate weakly, so without this strong
    /// self-reference the instance would deallocate as soon as the caller's
    /// local reference goes out of scope, silently dropping any delegate callbacks.
    private var keepAlive: AirDrop?

    init(files: [URL]) {
        self.files = files
        super.init()
    }

    func begin() {
        do {
            try sendEx(files)
        } catch {
            NSAlert.popError(error)
        }
    }

    private func sendEx(_ files: [URL]) throws {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            throw NSError(domain: "AirDrop", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("AirDrop service not available", comment: ""),
            ])
        }
        guard service.canPerform(withItems: files) else {
            throw NSError(domain: "AirDrop", code: 2, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("AirDrop service not available", comment: ""),
            ])
        }
        keepAlive = self
        service.delegate = self
        service.perform(withItems: files)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        keepAlive = nil
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        keepAlive = nil
    }
}
