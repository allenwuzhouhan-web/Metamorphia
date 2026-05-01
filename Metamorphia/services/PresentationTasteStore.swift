import Foundation
import MetamorphiaAgentKit

public actor PresentationTasteStore {
    private struct PersistedState: Codable {
        var samples: [PresentationDeckSample]
        var activeProfile: PresentationTasteProfile?
    }

    private var samples: [UUID: PresentationDeckSample] = [:]
    private var activeProfile: PresentationTasteProfile?
    private let storageURL: URL
    private let securePersistence: SecurePersistence?
    private var pendingWriteTask: Task<Void, Never>?
    private let writeDebounce: TimeInterval = 0.35

    public init(location: URL? = nil) {
        let url = location ?? URL.applicationSupportDirectory
            .appendingPathComponent("Metamorphia", isDirectory: true)
            .appendingPathComponent("presentation-taste.enc")
        storageURL = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var secure: SecurePersistence?
        do {
            secure = try SecurePersistence(serviceTag: "com.metamorphia.presentationtaste.v1")
        } catch {
            print("[PresentationTasteStore] Keychain unavailable (\(error.localizedDescription)); using plain JSON.")
        }
        securePersistence = secure

        let state = Self.readFromDisk(
            at: url,
            fallback: url.deletingPathExtension().appendingPathExtension("json"),
            secure: secure
        )
        samples = Dictionary(uniqueKeysWithValues: state.samples.map { ($0.id, $0) })
        activeProfile = state.activeProfile
    }

    public func snapshot() -> PresentationTasteSnapshot {
        PresentationTasteSnapshot(
            samples: samples.values.sorted { $0.updatedAt > $1.updatedAt },
            activeProfile: activeProfile
        )
    }

    public func activeProfileSnapshot() -> PresentationTasteProfile? {
        activeProfile
    }

    @discardableResult
    public func addOrUpdate(sample: PresentationDeckSample) -> PresentationTasteProfile {
        var stored = sample
        stored.updatedAt = .now
        samples[stored.id] = stored
        let profile = Self.buildProfile(from: Array(samples.values))
        activeProfile = profile
        scheduleWrite()
        return profile
    }

    public func pruneDeck(id: UUID) {
        samples.removeValue(forKey: id)
        activeProfile = samples.isEmpty ? nil : Self.buildProfile(from: Array(samples.values))
        scheduleWrite()
    }

    public func forgetAll() {
        samples.removeAll()
        activeProfile = nil
        scheduleWrite()
    }

    private static func buildProfile(from samples: [PresentationDeckSample]) -> PresentationTasteProfile {
        guard !samples.isEmpty else { return PresentationTasteProfile(deckCount: 0) }

        let allFonts = samples.flatMap(\.typography)
        let titleFont = mostCommon(
            allFonts.filter { $0.role == "title" }.map(\.name),
            fallback: mostCommon(allFonts.map(\.name), fallback: "Aptos Display")
        )
        let bodyFont = mostCommon(
            allFonts.filter { $0.role != "title" }.map(\.name),
            fallback: titleFont == "Aptos Display" ? "Aptos" : titleFont
        )
        let titleSize = median(allFonts.filter { $0.role == "title" }.map(\.size), fallback: 40)
        let bodySize = median(allFonts.filter { $0.role != "title" }.map(\.size), fallback: 16)

        let palette = rankedColors(from: samples).prefix(8).map(\.self)
        let archetypes = mostCommonValues(samples.flatMap(\.layoutPatterns), limit: 6)
        let averageShapes = samples
            .map { Double($0.shapeRoles.values.reduce(0, +)) / Double(max($0.slideCount, 1)) }
        let density = median(averageShapes, fallback: 7) > 9 ? "dense" : "balanced"
        let motifs = inferMotifs(samples: samples)

        return PresentationTasteProfile(
            name: "PowerPoint Design Language",
            deckCount: samples.count,
            learnedAt: .now,
            palette: palette.isEmpty ? ["1E2761", "CADCFC", "F96167", "FFFFFF", "111827"] : Array(palette),
            titleFont: titleFont,
            bodyFont: bodyFont,
            titleSize: min(max(titleSize, 30), 48),
            bodySize: min(max(bodySize, 12), 22),
            spacingRhythm: density == "dense" ? "Compact grids with disciplined alignment" : "Moderate whitespace with strong visual hierarchy",
            layoutArchetypes: archetypes.isEmpty ? ["title with supporting body", "section divider"] : archetypes,
            motifs: motifs,
            densityPreference: density,
            antiPatterns: ["low contrast text", "too many font families", "unstructured element placement"],
            modelAssistedDeckCount: samples.filter(\.allowModelAnalysis).count
        )
    }

    private static func rankedColors(from samples: [PresentationDeckSample]) -> [String] {
        let counts = Dictionary(grouping: samples.flatMap(\.colors)) { $0.uppercased() }
            .mapValues(\.count)
        return counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.map(\.key)
    }

    private static func inferMotifs(samples: [PresentationDeckSample]) -> [String] {
        let roles = samples.reduce(into: [String: Int]()) { partial, sample in
            for (key, value) in sample.shapeRoles {
                partial[key, default: 0] += value
            }
        }
        var motifs: [String] = []
        if (roles["accent"] ?? 0) > 0 { motifs.append("accent bars and small geometric markers") }
        if (roles["image"] ?? 0) > 0 { motifs.append("image-led layouts") }
        if motifs.isEmpty { motifs.append("restrained accent shape") }
        return motifs
    }

    private static func mostCommon(_ values: [String], fallback: String) -> String {
        let filtered = values.filter { value in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let grouped = Dictionary(grouping: filtered, by: { value in value })
        let counts = grouped.mapValues { groupedValues in groupedValues.count }
        let sortedCounts = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        return sortedCounts.first?.key ?? fallback
    }

    private static func mostCommonValues(_ values: [String], limit: Int) -> [String] {
        let filtered = values.filter { !$0.isEmpty }
        let grouped = Dictionary(grouping: filtered, by: { value in value })
        let counts = grouped.mapValues { groupedValues in groupedValues.count }
        let sortedCounts = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        return sortedCounts.prefix(limit).map(\.key)
    }

    private static func median(_ values: [Double], fallback: Double) -> Double {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return fallback }
        return sorted[sorted.count / 2]
    }

    private var plainFallbackURL: URL {
        storageURL.deletingPathExtension().appendingPathExtension("json")
    }

    private func scheduleWrite() {
        pendingWriteTask?.cancel()
        let state = PersistedState(
            samples: samples.values.sorted { $0.updatedAt > $1.updatedAt },
            activeProfile: activeProfile
        )
        let encURL = storageURL
        let plainURL = plainFallbackURL
        let secure = securePersistence
        let debounce = writeDebounce
        pendingWriteTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let json = try encoder.encode(state)
                    if let secure {
                        try secure.encrypt(json).write(to: encURL, options: .atomic)
                    } else {
                        try json.write(to: plainURL, options: .atomic)
                    }
                } catch {
                    print("[PresentationTasteStore] save failed: \(error)")
                }
            }.value
        }
    }

    nonisolated private static func readFromDisk(
        at encURL: URL,
        fallback: URL,
        secure: SecurePersistence?
    ) -> PersistedState {
        if let secure,
           let encData = try? Data(contentsOf: encURL),
           !encData.isEmpty,
           let json = try? secure.decrypt(encData),
           let state = try? JSONDecoder().decode(PersistedState.self, from: json) {
            return state
        }
        guard let data = try? Data(contentsOf: fallback),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return PersistedState(samples: [], activeProfile: nil)
        }
        return state
    }
}
