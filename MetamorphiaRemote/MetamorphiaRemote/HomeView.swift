import MetamorphiaRemoteKit
import SwiftUI

struct HomeView: View {
    @State private var accountAvailable: Bool?
    @State private var lastError: String?
    @State private var lastSent: String?
    // M9: Ask field state
    @State private var askPrompt: String = ""
    @State private var liveResult: String?
    @State private var isAsking: Bool = false
    /// Stable conversation session id. Persisted in UserDefaults so consecutive
    /// questions on the same phone share one thread on the Mac. Tap "New chat"
    /// (or call `rotateSession()`) to start a fresh conversation.
    @AppStorage("metamorphia_remote_session_id") private var sessionID: String = UUID().uuidString
    @State private var pollTask: Task<Void, Never>?

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
            // M9: register CKQuerySubscription for TurnResult so push can
            // shorten polling latency. The 1s poll loop in startPolling()
            // is the guaranteed delivery path regardless of push delivery.
            await CommandSender.shared.registerTurnResultSubscription()
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
            askCard
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

    // M9: Ask field — lets the user send a free-form prompt to Metamorphia
    // on the Mac and see the response stream back in real time.
    // Text is prose (never code); no monospaced font used here.
    private var askCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                TextField("Ask Metamorphia…", text: $askPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { sendAsk() }
                Button { sendAsk() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(askPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAsking)
            }
            // New chat affordance — rotates the session ID so the next question
            // starts a fresh thread rather than continuing the current one.
            if liveResult != nil || isAsking {
                Button("New chat", action: rotateSession)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let liveResult {
                Divider()
                Text(liveResult)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    // M9: send a free-form ask to Metamorphia on the Mac via CloudKit.
    private func sendAsk() {
        let prompt = askPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isAsking else { return }
        isAsking = true
        liveResult = nil
        // Reuse the stable sessionID so consecutive questions continue the
        // same conversation thread. Call rotateSession() to start fresh.
        Task {
            do {
                try await CommandSender.shared.send(.askAgent(prompt: prompt, sessionID: sessionID))
                askPrompt = ""
                lastError = nil
                lastSent = "Ask Metamorphia"
                startPolling()
            } catch {
                lastError = error.localizedDescription
                isAsking = false
            }
        }
    }

    /// Rotate to a new conversation thread. Any pending poll is cancelled and
    /// the displayed result is cleared so the UI starts clean.
    private func rotateSession() {
        pollTask?.cancel()
        pollTask = nil
        liveResult = nil
        isAsking = false
        sessionID = UUID().uuidString
    }

    /// 1s poll loop for TurnResult. CKQuerySubscription (registerTurnResultSubscription)
    /// only shortens latency when APNs delivers the silent push — this loop is the
    /// guaranteed convergence path regardless of push availability.
    /// Stops when status == "complete" or after ~2 min ceiling.
    private func startPolling() {
        pollTask?.cancel()
        let sid = sessionID
        pollTask = Task {
            for _ in 0..<120 {
                if Task.isCancelled { return }
                if let r = try? await CommandSender.shared.latestTurnResult(for: sid),
                   sid == sessionID {
                    liveResult = r.text
                    if r.status == "complete" { isAsking = false; return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            isAsking = false
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
