/*
 * Metamorphia
 * Copyright (C) 2024-2026 Metamorphia Contributors
 *
 * Debug-only main-thread hang detector. A background watchdog notices when the
 * main run loop stops responding and runs `sample` against this process,
 * writing the frozen main-thread backtrace to /tmp so the exact blocking call
 * can be read off the captured stack. Compiled out of release builds.
 */

import Foundation
import os

enum FreezeDiagnostics {
    static let log = os.Logger(subsystem: "com.metamorphia.freeze", category: "watchdog")

    private static let lock = NSLock()
    private static var lastMainPing = Date()
    private static var lastSampleAt = Date.distantPast
    private static var started = false

    /// Marks a phase on the hot path so the log shows where execution was when
    /// the main thread stalled (read alongside the captured sample).
    static func mark(_ label: String) {
        log.log("phase: \(label, privacy: .public)")
    }

    static func start() {
        #if DEBUG
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        // Heartbeat on the main run loop — only ticks while main is responsive.
        let heartbeat = Timer(timeInterval: 0.1, repeats: true) { _ in
            lock.lock(); lastMainPing = Date(); lock.unlock()
        }
        RunLoop.main.add(heartbeat, forMode: .common)

        // Watchdog on a dedicated background thread.
        Thread.detachNewThread {
            Thread.current.name = "freeze-watchdog"
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock()
                let elapsed = Date().timeIntervalSince(lastMainPing)
                lock.unlock()
                if elapsed > 0.75 {
                    captureSample(hangSeconds: elapsed)
                }
            }
        }
        log.log("freeze watchdog armed")
        #endif
    }

    #if DEBUG
    private static func captureSample(hangSeconds: Double) {
        lock.lock()
        let sinceLast = Date().timeIntervalSince(lastSampleAt)
        guard sinceLast > 6 else { lock.unlock(); return } // cooldown between samples
        lastSampleAt = Date()
        lock.unlock()

        let pid = ProcessInfo.processInfo.processIdentifier
        let path = "/tmp/metamorphia-freeze-\(pid)-\(Int(Date().timeIntervalSince1970)).txt"
        log.error("MAIN THREAD HUNG ~\(String(format: "%.2f", hangSeconds))s — sampling to \(path, privacy: .public)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // Sample for 1s; if main is still hung the dominant frame is the blocker.
        proc.arguments = [String(pid), "1", "-file", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            log.error("freeze sample written: \(path, privacy: .public)")
        } catch {
            log.error("freeze sample failed to launch: \(String(describing: error), privacy: .public)")
        }
    }
    #endif
}
