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

import SwiftUI

/// Single highlight shown on one page of the What's New carousel.
struct WhatsNewHighlight: Identifiable, Hashable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String
}

struct WhatsNewView: View {
    @Binding var isPresented: Bool

    @State private var selection: Int = 0

    private let highlights: [WhatsNewHighlight] = [
        WhatsNewHighlight(
            symbol: "sparkles",
            title: String(localized: "Smarter notch"),
            detail: String(localized: "The notch now adapts to what you're doing and surfaces the right control at the right moment.")
        ),
        WhatsNewHighlight(
            symbol: "bolt.fill",
            title: String(localized: "Faster, lighter"),
            detail: String(localized: "Animations are smoother and the app uses less energy while staying out of your way.")
        ),
        WhatsNewHighlight(
            symbol: "checkmark.seal.fill",
            title: String(localized: "Polished details"),
            detail: String(localized: "Dozens of small refinements across live activities, settings, and onboarding.")
        )
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("What's New")
                .font(.title)
                .fontWeight(.semibold)
                .padding(.top, 24)

            TabView(selection: $selection) {
                ForEach(Array(highlights.enumerated()), id: \.element.id) { index, item in
                    WhatsNewPage(highlight: item)
                        .tag(index)
                        .padding(.horizontal, 24)
                }
            }
            .tabViewStyle(.automatic)
            .frame(height: 220)

            HStack(spacing: 8) {
                ForEach(highlights.indices, id: \.self) { index in
                    Circle()
                        .fill(index == selection ? Color.primary.opacity(0.85) : Color.primary.opacity(0.25))
                        .frame(width: 6, height: 6)
                        .animation(.smooth(duration: 0.25), value: selection)
                }
            }

            Button {
                isPresented = false
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 420, height: 380)
        .onAppear { startAutoAdvance() }
    }

    private func startAutoAdvance() {
        guard highlights.count > 1 else { return }
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.4)) {
                    selection = (selection + 1) % highlights.count
                }
            }
        }
    }
}

private struct WhatsNewPage: View {
    let highlight: WhatsNewHighlight

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: highlight.symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 60)

            Text(highlight.title)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text(highlight.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    WhatsNewView(isPresented: .constant(true))
}
