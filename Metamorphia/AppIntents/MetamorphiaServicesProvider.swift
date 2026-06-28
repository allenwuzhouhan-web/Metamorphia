import AppKit
import Foundation
import UniformTypeIdentifiers

/// Exposes "Send to Metamorphia" in the macOS Services submenu so a right-click
/// on any file in Finder (or any selected text in any app) can hand it straight
/// to the agent — no Shortcuts-setup required.
///
/// Wiring:
///   - `Info.plist` declares `NSServices` entries that route to
///     `analyzeFileService:userData:error:` and `askWithTextService:userData:error:`.
///   - `AppDelegate.applicationDidFinishLaunching` sets
///     `NSApp.servicesProvider = MetamorphiaServicesProvider.shared` and calls
///     `NSUpdateDynamicServices()` once per launch so the system re-reads our
///     registrations when the plist changes between builds.
@MainActor
final class MetamorphiaServicesProvider: NSObject {
    static let shared = MetamorphiaServicesProvider()

    private override init() { super.init() }

    // MARK: - "Send File to Metamorphia"

    @objc func analyzeFileService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = Self.extractFileURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = "No file URLs on the pasteboard."
            return
        }

        let paths = urls.map { $0.standardizedFileURL.path }
        let prompt = MetamorphiaIntentEngine.analyzeFilePrompt(paths: paths, question: nil)

        Task { @MainActor in
            _ = await MetamorphiaIntentEngine.run(prompt: prompt, showNotch: true)
        }
    }

    // MARK: - "Ask Metamorphia about selection"

    @objc func askWithTextService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text on the pasteboard."
            return
        }

        let prompt = """
        The user selected the following text and wants your take on it:

        \"\"\"
        \(text)
        \"\"\"

        Summarize, explain, or answer any implicit question. Be concise.
        """

        Task { @MainActor in
            _ = await MetamorphiaIntentEngine.run(prompt: prompt, showNotch: true)
        }
    }

    // MARK: - Writing Tools services

    @objc func proofreadService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { runWritingService(.proofread, pboard, error) }

    @objc func rewriteService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { runWritingService(.rewrite, pboard, error) }

    @objc func summarizeService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { runWritingService(.summarize, pboard, error) }

    @objc func replyService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) { runWritingService(.reply, pboard, error) }

    private func runWritingService(
        _ verb: AIActionRunner.WritingVerb,
        _ pboard: NSPasteboard,
        _ error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text on the pasteboard."
            return
        }
        Task { @MainActor in
            // The Services path receives the selection via pasteboard (the OS
            // serializes it before invoking us). No AX capture is needed; show
            // the notch so the result is visible to the user.
            _ = await AIActionRunner.runFromPasteboardText(verb: verb, text: text)
        }
    }

    // MARK: - Helpers

    private static func extractFileURLs(from pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let items = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            return items
        }
        return []
    }

    /// Call once on launch — harmless if called again. Pairs the runtime
    /// services provider with the static `NSServices` entries in Info.plist.
    static func register() {
        NSApp.servicesProvider = MetamorphiaServicesProvider.shared
        NSUpdateDynamicServices()
    }
}
