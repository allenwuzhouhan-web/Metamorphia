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
import AppKit
import Defaults

/// The selected color and its 5 generated variants, as a row of copyable chips.
/// Hovering a chip lifts the matching dot on the wheel (`highlightedSlot`).
struct VariantStrip: View {
    let base: PickedColor
    let variants: [ColorVariant]
    @Binding var highlightedSlot: Int?
    /// Color-only chips (no hex caption) for the tight notch.
    var compact: Bool = false
    let onCopy: (PickedColor) -> Void

    @State private var copiedSlot: Int?   // -2 == base

    var body: some View {
        HStack(spacing: 9) {
            baseChip

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 42)

            ForEach(variants) { variant in
                variantChip(variant)
            }
        }
    }

    private var baseChip: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(base.color)
                .frame(width: 56, height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                )
                .overlay(copiedCheck(slot: -2))

            if !compact {
                Text(base.hexString)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Base")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { copy(base, slot: -2) }
    }

    private func variantChip(_ variant: ColorVariant) -> some View {
        let lifted = highlightedSlot == variant.slot
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(variant.color.color)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(lifted ? 0.9 : 0.25), lineWidth: lifted ? 2 : 1)
                )
                .overlay(copiedCheck(slot: variant.slot))
                .scaleEffect(lifted ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: lifted)

            if !compact {
                Text(variant.color.hexString)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { highlightedSlot = variant.slot }
            else if highlightedSlot == variant.slot { highlightedSlot = nil }
        }
        .onTapGesture { copy(variant.color, slot: variant.slot) }
    }

    private func copiedCheck(slot: Int) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .shadow(radius: 1)
            .opacity(copiedSlot == slot ? 1 : 0)
    }

    private func copy(_ color: PickedColor, slot: Int) {
        onCopy(color)
        withAnimation(.easeInOut(duration: 0.15)) { copiedSlot = slot }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if copiedSlot == slot {
                withAnimation(.easeInOut(duration: 0.15)) { copiedSlot = nil }
            }
        }
    }
}
