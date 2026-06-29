/*
 * Metamorphia
 * Wi-Fi place sensor — emits ActivityEvent.placeChanged into the activity spine.
 *
 * Network place is inferred from the current Wi-Fi SSID, hashed with a
 * persistent per-install HMAC-SHA256 salt so the raw SSID never leaves this
 * function. The resulting 16-char hex prefix is stable across sessions for
 * the same SSID + device, and opaque to anyone who cannot reproduce the salt.
 *
 * Signal sources:
 *  1. A 30 s background poll — Wi-Fi changes are infrequent, so fine-grained
 *     polling is unnecessary.
 *  2. NSWorkspace wake notification — sample immediately after wake so the
 *     first observation after a lid-open isn't delayed up to 30 s.
 *
 * SSID acquisition: the `airport` CLI at the path below. This approach
 * requires no additional entitlements. NOTE: Apple has deprecated `airport`
 * and may remove it in a future macOS. This is borrowed time — when it breaks,
 * replace with CoreWLAN + com.apple.developer.networking.wifi entitlement.
 *
 * Privacy invariants (load-bearing — do not relax):
 *  - The SSID string is never logged, persisted, or emitted.
 *  - The salt is generated once from SecRandomCopyBytes and stored in the
 *    Keychain. If generation fails, the sensor refuses to start.
 *  - placeHash is an 8-byte HMAC-SHA256 prefix encoded as 16 hex chars.
 *  - "offline" is emitted (placeHash = "offline") when Wi-Fi is not connected.
 *
 * Feature gate: Defaults[.observePlace] (default true). start() is a no-op
 * when false.
 */

import AppKit
import CryptoKit
import Defaults
import Foundation
import MetamorphiaAgentKit
import Security

// MARK: - Defaults key

extension Defaults.Keys {
    /// Master switch for Wi-Fi place observation.
    /// Default: true. Toggle live without restarting — the sensor re-checks on
    /// every poll and wake notification.
    static let observePlace = Key<Bool>(
        "metamorphia.sensor.place.enabled",
        default: true
    )
}

// MARK: - PlaceLabelStore stub protocol

/// Coder B owns the concrete PlaceLabelStore. We code against this protocol so
/// PlaceSensor compiles independently and tests can inject mocks.
@MainActor
public protocol PlaceLabelStoreProtocol: AnyObject {
    func label(for placeHash: String) -> String?
    func assign(label: String, to placeHash: String)
    func seen(placeHash: String)
}

// MARK: - PlaceSensor

@MainActor
public final class PlaceSensor {

    // MARK: - Constants

    /// `airport` CLI path. Apple has deprecated this binary — see file-level note.
    private static let airportPath =
        "/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport"

    /// Keychain service tag for the per-install HMAC salt.
    private static let saltServiceTag = "com.metamorphia.place-salt.v1"

    /// Sentinel emitted when Wi-Fi is disconnected.
    private static let offlineSentinel = "offline"

    // MARK: - Dependencies

    private let stream: ActivityStream
    private let labelStore: any PlaceLabelStoreProtocol

    // MARK: - Private state

    /// Last-emitted place hash. Nil until first emit. Used for deduplication.
    private var lastEmittedHash: String?

    /// True after start(), false after stop().
    private var running = false

    /// Background 30 s poll task.
    private var pollTask: Task<Void, Never>?

    /// Workspace wake observer token.
    private var wakeObserver: Any?

    /// HMAC salt loaded from the Keychain on start(). Nil if unavailable.
    private var salt: Data?

    /// True once the missing-binary warning has been logged (log once policy).
    private var missingBinaryLogged = false

    /// Set to true the first time `airport` is confirmed absent. Short-circuits
    /// both `start()` and `sampleAndEmit()` until the next explicit `start()` call,
    /// which resets this flag and re-checks the binary.
    private var binaryUnavailable = false

    // MARK: - Init

    public init(stream: ActivityStream, labelStore: any PlaceLabelStoreProtocol) {
        self.stream = stream
        self.labelStore = labelStore
    }

    // MARK: - Lifecycle

    public func start() {
        guard Defaults[.observePlace] else { return }
        guard !running else { return }
        // Reset so a fresh start() re-checks after a macOS update may restore the binary.
        binaryUnavailable = false

        // Load or generate salt. Refuse to start if unavailable — the sensor
        // must not operate without a stable salt (privacy invariant).
        guard let resolvedSalt = Self.resolveSalt() else {
            print("[PlaceSensor] Salt unavailable — refusing to start")
            return
        }
        salt = resolvedSalt
        running = true

        // Subscribe to system wake so we detect place changes promptly.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.sampleAndEmit()
            }
        }

        // 30 s background poll.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.sampleAndEmit()
            }
        }

        // Emit immediately so the first place is recorded on startup.
        Task { @MainActor in
            await sampleAndEmit()
        }
    }

    public func stop() {
        guard running else { return }
        running = false

        pollTask?.cancel()
        pollTask = nil

        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    // MARK: - Sample + emit

    private func sampleAndEmit() async {
        // Re-check gate on every sample so live toggling takes effect.
        guard Defaults[.observePlace], running, !binaryUnavailable else { return }
        guard let salt else { return }

        // Spawn the `airport` subprocess off the main thread — run()/waitUntilExit()/
        // readDataToEndOfFile() each block, and must not stall the main actor.
        let alreadyLogged = missingBinaryLogged
        let sample = await Task.detached(priority: .utility) {
            Self.currentPlaceHash(salt: salt, missingBinaryLogged: alreadyLogged)
        }.value
        let hash = sample.hash

        // Fold the once-only missing-binary log state back on the main actor.
        if sample.binaryMissing {
            missingBinaryLogged = true
        }

        // If the binary went missing this tick, shut the poll down permanently
        // (until the next explicit start() call, which resets binaryUnavailable).
        if missingBinaryLogged && !FileManager.default.fileExists(atPath: Self.airportPath) {
            binaryUnavailable = true
            pollTask?.cancel()
            pollTask = nil
            running = false
            return
        }

        // Deduplicate.
        if hash == lastEmittedHash { return }
        lastEmittedHash = hash

        let label: String?
        if hash != Self.offlineSentinel {
            labelStore.seen(placeHash: hash)
            label = labelStore.label(for: hash)
        } else {
            label = nil
        }

        await stream.emit(.placeChanged(placeHash: hash, label: label, at: .now))
    }

    // MARK: - SSID + hash

    /// Result of one place sample: the hash (or offline sentinel) plus whether
    /// the `airport` binary was confirmed absent this tick. `binaryMissing` is
    /// folded back into the actor-isolated `missingBinaryLogged`/`binaryUnavailable`
    /// state by the caller, keeping that mutation off the detached worker.
    struct PlaceSample {
        let hash: String
        let binaryMissing: Bool
    }

    /// Read the current SSID, hash it with `salt`, and return the 16-char hex
    /// prefix. Returns `"offline"` when Wi-Fi is not associated.
    ///
    /// `alreadyLogged` suppresses the once-only missing-binary log; pass the
    /// current `missingBinaryLogged` value. `nonisolated` so it can run on a
    /// background task — the `airport` subprocess must never block the main actor.
    ///
    /// Privacy: the SSID string never leaves this function. Only the hash
    /// (or the offline sentinel) is returned.
    nonisolated static func currentPlaceHash(salt: Data, missingBinaryLogged alreadyLogged: Bool) -> PlaceSample {
        let read = readSSID(alreadyLogged: alreadyLogged)
        guard let ssid = read.ssid else {
            return PlaceSample(hash: offlineSentinel, binaryMissing: read.binaryMissing)
        }
        return PlaceSample(hash: hashSSID(ssid, salt: salt), binaryMissing: read.binaryMissing)
    }

    /// Invoke `airport -I` and parse the SSID line.
    /// `ssid` is nil when the binary is absent, Wi-Fi is off, or the SSID field
    /// is missing (e.g. Ethernet-only or monitor mode); `binaryMissing` reports
    /// whether the absence was specifically a missing binary.
    ///
    /// The returned SSID is raw. Callers MUST NOT log it.
    nonisolated private static func readSSID(alreadyLogged: Bool) -> (ssid: String?, binaryMissing: Bool) {
        let binaryURL = URL(fileURLWithPath: airportPath)
        guard FileManager.default.fileExists(atPath: airportPath) else {
            if !alreadyLogged {
                print("[PlaceSensor] airport binary missing at \(airportPath) — " +
                      "place detection unavailable. This is expected on a future macOS " +
                      "that has removed the deprecated binary. Migrate to CoreWLAN.")
            }
            return (nil, true)
        }

        let task = Process()
        task.executableURL = binaryURL
        task.arguments = ["-I"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // suppress stderr

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // Treat any launch error as no-SSID (conservative fail-safe).
            return (nil, false)
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        // airport -I output lines look like "     SSID: MyNetwork"
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SSID: ") else { continue }
            let ssid = String(trimmed.dropFirst("SSID: ".count))
            // Guard against empty string (can appear when not associated).
            return (ssid.isEmpty ? nil : ssid, false)
        }
        return (nil, false)
    }

    /// Compute HMAC-SHA256(ssid, key: salt)[0..<8] as a 16-char lowercase hex string.
    ///
    /// Privacy: `ssid` is consumed in-memory only and must not be stored
    /// or logged by the caller.
    nonisolated static func hashSSID(_ ssid: String, salt: Data) -> String {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(ssid.utf8),
            using: SymmetricKey(data: salt)
        )
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Salt management (Keychain)

    /// Load existing salt from the Keychain, or generate and store a fresh one.
    /// Returns nil only if both load and store fail (Keychain locked / unavailable).
    static func resolveSalt() -> Data? {
        if let existing = loadSalt() { return existing }
        return generateAndStoreSalt()
    }

    private static func loadSalt() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: saltServiceTag,
            kSecAttrAccount as String: "place-salt",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            return nil
        }
        return data
    }

    private static func generateAndStoreSalt() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            print("[PlaceSensor] SecRandomCopyBytes failed (\(status)) — cannot generate salt")
            return nil
        }
        let saltData = Data(bytes)

        // Delete any stale item first to avoid errSecDuplicateItem.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: saltServiceTag,
            kSecAttrAccount as String: "place-salt",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: saltServiceTag,
            kSecAttrAccount as String: "place-salt",
            kSecValueData as String: saltData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            print("[PlaceSensor] Keychain storage failed (\(addStatus)) — cannot persist salt")
            return nil
        }
        return saltData
    }
}
