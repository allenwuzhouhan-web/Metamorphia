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

/// Capsule segmented control for choosing how a color's variants are derived.
/// The selected segment's accent capsule slides between options.
struct VariantSchemePicker: View {
    @Binding var scheme: VariantScheme
    /// Icons only — for the tight notch width.
    var compact: Bool = false
    /// When the selected color is near-neutral, harmonies are meaningless: gray them out.
    var harmoniesDisabled: Bool = false

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VariantScheme.allCases) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func segment(_ option: VariantScheme) -> some View {
        let on = option == scheme
        let isDisabled = harmoniesDisabled && option != .monochromatic

        return Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { scheme = option }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: option.symbol)
                    .font(.system(size: 11, weight: .semibold))
                if !compact {
                    Text(option.shortLabel)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize()
                }
            }
            .padding(.horizontal, compact ? 9 : 10)
            .padding(.vertical, 6)
            .background {
                if on {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.18))
                        .matchedGeometryEffect(id: "schemeSel", in: ns)
                }
            }
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.3 : 1)
    }
}
