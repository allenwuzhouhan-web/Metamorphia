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
import UniformTypeIdentifiers
import Defaults

/// Drop in a logo (or any image) and get its major colors back as a wheel,
/// a swatch strip, and copyable color codes. Reused by both the floating
/// panel and the notch tab.
struct ColorPaletteView: View {
    var wheelDiameter: CGFloat = 240

    @Default(.paletteColorCount) private var paletteColorCount
    @Default(.showColorFormats) private var showColorFormats

    @State private var image: NSImage?
    @State private var swatches: [LogoPaletteSwatch] = []
    @State private var selected: LogoPaletteSwatch?
    @State private var isExtracting = false
    @State private var isDropTargeted = false
    @State private var copiedID: UUID?
    @State private var savedToHistory = false

    var body: some View {
        VStack(spacing: 16) {
            if swatches.isEmpty && !isExtracting {
                dropZone
            } else {
                results
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: paletteColorCount) { _ in reextract() }
    }

    // MARK: - Empty / drop state

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Drop a logo or image here")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Its major colors are pulled into a wheel")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                pillButton(title: "Choose Image…", icon: "folder", action: chooseImage)
                pillButton(title: "Paste", icon: "doc.on.clipboard", action: pasteImage)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(isDropTargeted ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    // MARK: - Results state

    private var results: some View {
        VStack(spacing: 16) {
            sourceBar

            if isExtracting {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: wheelDiameter)
            } else {
                ColorWheelView(
                    swatches: swatches,
                    selectedID: selected?.id,
                    diameter: wheelDiameter,
                    onSelect: pick
                )
                .frame(maxWidth: .infinity)

                swatchStrip

                if let selected {
                    selectedDetails(selected)
                }

                actionBar
            }
        }
    }

    private var sourceBar: some View {
        HStack(spacing: 12) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 42, height: 42)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.12))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(swatches.count) major colors")
                    .font(.system(size: 14, weight: .semibold))
                Text("Tap a dot or swatch to copy")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            countStepper

            Button(action: reset) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Use a different image")
        }
    }

    private var countStepper: some View {
        HStack(spacing: 4) {
            stepButton(icon: "minus") {
                paletteColorCount = max(3, paletteColorCount - 1)
            }
            Text("\(paletteColorCount)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 16)
            stepButton(icon: "plus") {
                paletteColorCount = min(10, paletteColorCount + 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("Number of colors to extract")
    }

    private var swatchStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(swatches) { swatch in
                    swatchChip(swatch)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func swatchChip(_ swatch: LogoPaletteSwatch) -> some View {
        let isSelected = selected?.id == swatch.id
        return VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(swatch.color.color)
                .frame(width: 58, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                        .opacity(copiedID == swatch.id ? 1 : 0)
                )

            Text(swatch.color.hexString)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            Text(swatch.percentText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { pick(swatch) }
    }

    private func selectedDetails(_ swatch: LogoPaletteSwatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(swatch.color.color)
                    .frame(width: 64, height: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(swatch.color.hexString)
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(swatch.percentText) of the image")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 2) {
                ForEach(formats(for: swatch.color)) { format in
                    ColorFormatDetailRow(format: format, color: swatch.color)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            actionChip(
                title: "Copy All",
                icon: "doc.on.doc",
                tint: .accentColor,
                action: copyAll
            )
            actionChip(
                title: savedToHistory ? "Saved" : "Save to History",
                icon: savedToHistory ? "checkmark" : "tray.and.arrow.down",
                tint: savedToHistory ? .green : .accentColor,
                action: saveToHistory
            )
            Spacer()
        }
    }

    // MARK: - Reusable button bits

    private func pillButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func actionChip(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private func stepButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
    }

    private func formats(for color: PickedColor) -> [ColorFormat] {
        showColorFormats
            ? color.allFormats
            : [ColorFormat(name: "HEX", value: color.hexString, copyValue: color.hexString)]
    }

    // MARK: - Actions

    private func pick(_ swatch: LogoPaletteSwatch) {
        selected = swatch
        ColorPickerManager.shared.copyToClipboard(swatch.color.hexString)
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        }
        withAnimation(.easeInOut(duration: 0.15)) { copiedID = swatch.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if copiedID == swatch.id {
                withAnimation(.easeInOut(duration: 0.15)) { copiedID = nil }
            }
        }
    }

    private func copyAll() {
        let text = swatches.map { $0.color.hexString }.joined(separator: "\n")
        ColorPickerManager.shared.copyToClipboard(text)
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        }
    }

    private func saveToHistory() {
        // Insert least-prominent first so the dominant color lands at the top.
        for swatch in swatches.reversed() {
            ColorPickerManager.shared.addColor(swatch.color)
        }
        withAnimation { savedToHistory = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { savedToHistory = false }
        }
    }

    private func reset() {
        image = nil
        swatches = []
        selected = nil
        savedToHistory = false
        isExtracting = false
    }

    // MARK: - Loading images

    private func setImage(_ img: NSImage) {
        image = img
        selected = nil
        savedToHistory = false
        isExtracting = true
        img.extractPalette(maxColors: paletteColorCount) { result in
            swatches = result
            selected = result.first
            isExtracting = false
        }
    }

    private func reextract() {
        guard let image else { return }
        isExtracting = true
        savedToHistory = false
        let previousHex = selected?.color.hexString
        image.extractPalette(maxColors: paletteColorCount) { result in
            swatches = result
            selected = result.first(where: { $0.color.hexString == previousHex }) ?? result.first
            isExtracting = false
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async { setImage(img) }
            }
            return true
        }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let img = NSImage(contentsOf: url) else { return }
                DispatchQueue.main.async { setImage(img) }
            }
            return true
        }

        return false
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Extract")
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            setImage(img)
        }
    }

    private func pasteImage() {
        let pasteboard = NSPasteboard.general
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = images.first {
            setImage(img)
            return
        }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        ) as? [URL], let url = urls.first, let img = NSImage(contentsOf: url) {
            setImage(img)
        }
    }
}

#Preview {
    ColorPaletteView()
        .frame(width: 420, height: 640)
        .padding()
        .background(Color.black)
}
