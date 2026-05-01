import MetamorphiaRemoteKit
import SwiftUI

struct HomeView: View {
    @State private var accountAvailable: Bool?
    @State private var lastError: String?
    @State private var lastSent: String?

    private let tiles: [Tile] = [
        Tile(title: "Sleep",        symbol: "moon.fill",            command: .sleepMac),
        Tile(title: "Lock",         symbol: "lock.fill",            command: .lockMac),
        Tile(title: "Play",         symbol: "play.fill",            command: .playMusic),
        Tile(title: "Pause",        symbol: "pause.fill",           command: .pauseMusic),
        Tile(title: "Previous",     symbol: "backward.fill",        command: .previousTrack),
        Tile(title: "Next",         symbol: "forward.fill",         command: .nextTrack),
        Tile(title: "Keep Awake",   symbol: "cup.and.saucer.fill",  command: .setKeepAwake(true)),
        Tile(title: "Allow Sleep",  symbol: "zzz",                  command: .setKeepAwake(false)),
    ]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Metamorphia")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            accountAvailable = await CommandSender.shared.iCloudIsAvailable()
        }
    }

    @ViewBuilder
    private var content: some View {
        if accountAvailable == false {
            signInCard
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(tiles) { tile in
                    Button { send(tile) } label: { TileView(tile: tile) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            footer
        }
    }

    private var signInCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Sign in to iCloud to continue")
                .font(.title3.weight(.semibold))
            Text("Metamorphia uses your private iCloud to send commands to your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.top, 80)
    }

    @ViewBuilder
    private var footer: some View {
        if let lastError {
            Text(lastError)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.top, 16)
        } else if let lastSent {
            Text("Sent \(lastSent)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
        }
    }

    private func send(_ tile: Tile) {
        Task {
            do {
                try await CommandSender.shared.send(tile.command)
                lastError = nil
                lastSent = tile.title
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}

private struct Tile: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let command: Command
}

private struct TileView: View {
    let tile: Tile

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: tile.symbol)
                .font(.system(size: 32, weight: .medium))
            Text(tile.title)
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }
}
