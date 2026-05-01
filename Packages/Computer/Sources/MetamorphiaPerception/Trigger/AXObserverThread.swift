import Foundation
import CoreFoundation

// MARK: - AXObserverThread

/// Dedicated CFRunLoop thread for AX observer registration.
///
/// AX observers (`AXObserverRef`) must be added to a CFRunLoop via
/// `AXObserverGetRunLoopSource` + `CFRunLoopAddSource`. The main run loop is
/// already saturated with AppKit events; using it for AX observation causes
/// missed notifications under heavy UI load. This class owns a private
/// thread whose sole job is running a CFRunLoop that AX sources can attach to.
///
/// **Ownership:** this thread is transport only. It does not retain or manage
/// `AXObserverRef` lifetimes. Callers obtain the run loop via `runLoopRef()`
/// and register sources directly. See `AXObserverPool` (Wave 4) for the
/// higher-level lifecycle manager.
///
/// **Thread safety:** `start()` and `stop()` are safe to call from any thread.
/// `perform(_:)` is safe to call from any thread after `start()` returns.
/// Calling `perform(_:)` before `start()` or after `stop()` is a no-op.
public final class AXObserverThread {
    public static let shared = AXObserverThread()

    private let lock = NSLock()
    private var thread: Thread?
    private var _runLoop: CFRunLoop?

    public init() {}

    // MARK: - Lifecycle

    /// Start the observer thread. Blocks the caller until the CFRunLoop is
    /// running and ready to accept sources. Calling `start()` when already
    /// started is a no-op.
    public func start() {
        // Check under lock first — if already started, return immediately.
        var shouldWait = false
        let readySem = DispatchSemaphore(value: 0)

        lock.withLock {
            guard thread == nil else { return }
            let t = Thread(target: self, selector: #selector(threadMain(_:)), object: readySem)
            t.name = "com.metamorphia.ax.observer"
            t.qualityOfService = .userInitiated
            thread = t
            t.start()
            shouldWait = true
        }

        // Only wait if we actually spawned a new thread.
        if shouldWait {
            readySem.wait()
        }
    }

    /// Stop the observer thread. The CFRunLoop is stopped and the thread exits
    /// naturally. Calling `stop()` before `start()` is a no-op.
    public func stop() {
        let rl: CFRunLoop? = lock.withLock {
            let rl = _runLoop
            thread = nil
            _runLoop = nil
            return rl
        }
        if let rl = rl {
            CFRunLoopStop(rl)
        }
    }

    // MARK: - Scheduling

    /// Schedule `block` to run on the observer thread's CFRunLoop.
    ///
    /// The block is enqueued via `CFRunLoopPerformBlock` (mode: `.commonModes`)
    /// and the run loop is woken immediately. If the thread has not been started
    /// or has been stopped, the call is a silent no-op — callers should not rely
    /// on `block` executing in those cases.
    public func perform(_ block: @escaping @Sendable () -> Void) {
        let rl: CFRunLoop? = lock.withLock { _runLoop }
        guard let rl = rl else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    // MARK: - Run-loop accessor

    /// The underlying `CFRunLoop` for this thread. Callers use this to register
    /// `AXObserverGetRunLoopSource` sources directly. Returns nil before
    /// `start()` is called or after `stop()`.
    public func runLoopRef() -> CFRunLoop? {
        lock.withLock { _runLoop }
    }

    // MARK: - Thread entry point

    @objc private func threadMain(_ readySemObj: AnyObject) {
        let readySem = readySemObj as! DispatchSemaphore

        // Capture the run loop before signalling ready.
        let rl = CFRunLoopGetCurrent()!

        lock.withLock {
            _runLoop = rl
        }

        // Add a no-op keep-alive source so CFRunLoopRun doesn't return
        // immediately when no other sources are attached yet.
        var ctx = CFRunLoopSourceContext()
        ctx.version = 0
        ctx.perform = { _ in } // no-op
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &ctx)!
        CFRunLoopAddSource(rl, keepAlive, .commonModes)

        // Signal the calling thread that the run loop is ready.
        readySem.signal()

        // Run until CFRunLoopStop is called from stop().
        CFRunLoopRun()

        // Clean up on exit.
        CFRunLoopRemoveSource(rl, keepAlive, .commonModes)
    }
}
