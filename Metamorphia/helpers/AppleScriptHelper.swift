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

class AppleScriptHelper {
    @discardableResult
    class func execute(_ scriptText: String, timeoutSeconds: TimeInterval? = nil) async throws -> NSAppleEventDescriptor? {
        if let timeoutSeconds {
            return try await executeWithTimeout(scriptText, timeoutSeconds: timeoutSeconds)
        }

        return try await executeWithoutTimeout(scriptText)
    }

    @discardableResult
    private class func executeWithTimeout(_ scriptText: String, timeoutSeconds: TimeInterval) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false

            func resumeOnce(_ result: Result<NSAppleEventDescriptor?, Error>) {
                lock.lock()
                guard !didResume else {
                    lock.unlock()
                    return
                }
                didResume = true
                lock.unlock()

                switch result {
                case .success(let descriptor):
                    continuation.resume(returning: descriptor)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            Task.detached(priority: .userInitiated) {
                do {
                    let descriptor = try await executeWithoutTimeout(scriptText)
                    resumeOnce(.success(descriptor))
                } catch {
                    resumeOnce(.failure(error))
                }
            }

            Task.detached(priority: .userInitiated) {
                let nanoseconds = UInt64(max(timeoutSeconds, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                resumeOnce(.failure(NSError(
                    domain: "AppleScriptError",
                    code: 408,
                    userInfo: [NSLocalizedDescriptionKey: "AppleScript timed out after \(timeoutSeconds) seconds"]
                )))
            }
        }
    }

    @discardableResult
    private class func executeWithoutTimeout(_ scriptText: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let script = NSAppleScript(source: scriptText)
                var error: NSDictionary?
                if let descriptor = script?.executeAndReturnError(&error) {
                    continuation.resume(returning: descriptor)
                } else if let error = error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
    }
    
    class func executeVoid(_ scriptText: String) async throws {
        _ = try await execute(scriptText)
    }
}
