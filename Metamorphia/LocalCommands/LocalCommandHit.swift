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

/// Returned by a local matcher when it successfully handles a prompt without the LLM.
public struct LocalCommandHit: Equatable {
    /// Short identifier for the matcher that handled this hit (e.g. "timer", "smart_calculator").
    public let matcherName: String
    /// Human-readable result shown in the command bar.
    public let message: String
    /// Serialized key=value pair(s) describing what was dispatched (for trace display).
    public let arguments: String
    /// Wall-clock time the matcher took (seconds). Zero for tier-2/3 hits measured internally.
    public let elapsed: TimeInterval

    public init(matcherName: String, message: String, arguments: String, elapsed: TimeInterval) {
        self.matcherName = matcherName
        self.message = message
        self.arguments = arguments
        self.elapsed = elapsed
    }
}
