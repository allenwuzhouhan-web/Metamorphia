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

import SwiftUI
import MetamorphiaPerception

// MARK: - PermissionMatrixView

/// Shows per-lane permission status in a scrollable matrix. Each row names a
/// perception lane and indicates which of its required permissions are granted,
/// missing, or blocked. Tapping a missing permission deep-links to System Settings.
public struct PermissionMatrixView: View {

    @ObservedObject var conductor: PermissionVault = .shared

    public init(conductor: PermissionVault = .shared) {
        self.conductor = conductor
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                matrixHeader
                    .padding(.bottom, 8)

                ForEach(PerceptionLane.allCases, id: \.self) { lane in
                    laneRow(lane)
                }
            }
            .padding()
        }
        .onAppear {
            conductor.refresh()
        }
    }

    // MARK: Header

    private var matrixHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Perception Lanes")
                .font(.headline)
            Text("Updated \(conductor.lastUpdated.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Lane row

    private func laneRow(_ lane: PerceptionLane) -> some View {
        let status = conductor.laneStatus(lane)
        let deps = laneDeps(for: lane)

        return HStack(spacing: 12) {
            // Lane name
            Text(lane.displayName)
                .font(.subheadline)
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)

            // Per-permission icons
            HStack(spacing: 6) {
                if deps.isEmpty {
                    Text("No permissions required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(deps, id: \.self) { permission in
                        permissionIcon(permission)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status pill
            statusPill(status)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(rowBackground(for: status))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Permission icon

    private func permissionIcon(_ permission: PermissionVault.Permission) -> some View {
        let permStatus = conductor.matrix[permission] ?? .notDetermined
        let (icon, color) = iconAndColor(for: permStatus)

        return Button {
            if permStatus != .granted {
                conductor.openSystemSettings(for: permission)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption)
                Text(permission.displayName)
                    .font(.caption)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(permStatus != .granted ? "Open \(permission.displayName) in System Settings" : permission.displayName)
        .disabled(permStatus == .granted)
    }

    // MARK: Status pill

    private func statusPill(_ status: PermissionVault.LaneStatus) -> some View {
        let (label, color, icon) = pillContent(for: status)
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }

    // MARK: Helpers

    private func iconAndColor(for status: PermissionVault.Status) -> (String, Color) {
        switch status {
        case .granted:       return ("checkmark", .green)
        case .denied:        return ("xmark", .red)
        case .restricted:    return ("xmark", .red)
        case .notDetermined: return ("minus", .secondary)
        }
    }

    private func pillContent(for status: PermissionVault.LaneStatus) -> (String, Color, String) {
        switch status {
        case .fullyEnabled:
            return ("Active", .green, "checkmark.circle.fill")
        case .degraded:
            return ("Degraded", .orange, "exclamationmark.triangle.fill")
        case .disabled:
            return ("Disabled", .red, "xmark.circle.fill")
        }
    }

    private func rowBackground(for status: PermissionVault.LaneStatus) -> Color {
        switch status {
        case .fullyEnabled:  return Color.primary.opacity(0.03)
        case .degraded:      return Color.orange.opacity(0.06)
        case .disabled:      return Color.red.opacity(0.06)
        }
    }

    /// Returns the permission list for a lane from PermissionVault's dependency table.
    /// Duplicated here as a view-layer helper so PermissionMatrixView stays decoupled from
    /// the conductor's private storage.
    private func laneDeps(for lane: PerceptionLane) -> [PermissionVault.Permission] {
        switch lane {
        case .axPoll:        return [.accessibility]
        case .dhashDiff:     return [.screenRecording]
        case .ocrFallback:   return [.screenRecording]
        case .browserDOM:    return [.accessibility, .automation]
        case .menuBarRead:   return [.accessibility]
        case .windowEnum:    return []
        case .clipboardWatch: return []
        case .screenHarvest: return [.screenRecording, .fullDisk]
        case .driftScan:     return [.accessibility, .screenRecording]
        case .selection:     return [.accessibility]
        case .documentWatch: return []
        }
    }
}

// MARK: - PerceptionLane display name

extension PerceptionLane {
    var displayName: String {
        switch self {
        case .axPoll:        return "AX Poll"
        case .dhashDiff:     return "Screen Diff"
        case .ocrFallback:   return "OCR Fallback"
        case .browserDOM:    return "Browser DOM"
        case .menuBarRead:   return "Menu Bar"
        case .windowEnum:    return "Window Enum"
        case .clipboardWatch: return "Clipboard"
        case .screenHarvest: return "Screen Harvest"
        case .driftScan:     return "Drift Scan"
        case .selection:     return "Selection"
        case .documentWatch: return "Document Watch"
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    PermissionMatrixView()
        .frame(width: 640, height: 500)
}
#endif
