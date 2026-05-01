# T4 — File Attachments Plan

## Executive Summary

Port Executer's file-attachment system into Metamorphia's command bar. User drags files onto the notch (Option-modifier) OR onto the open command-bar pill; attachments extract text off-main-thread, a capsule badge appears in `inputRow` showing the count, and on `submit(...)` the extracted text is appended to the user prompt in Executer's exact `--- Attached file: NAME ---\n<content>\n--- End of NAME ---` format. Attachments clear post-submit.

1. Create `CommandBarAttachedFile` at `Metamorphia/models/CommandBarAttachedFile.swift` (prefixed to avoid collision with existing `ScreenAssistantFile`).
2. Create `FileContentExtractor` actor at `Metamorphia/services/FileContentExtractor.swift` — PDFKit for PDF, `NSAttributedString` + `textutil` shell-out for DOCX/RTF/PPT/XLS, `String(contentsOf:)` for text/code. Unsupported extensions or failures return `nil` (no garbage in the prompt).
3. Add `@Published attachedFiles`, `attachFiles(urls:)`, `removeAttachment(id:)`, `clearAttachments()` to `AICommandViewModel`. Append extracted content to the **user prompt** (matches Executer, keeps system prompt cacheable). Clear attachments after submission.
4. Add `.onDrop(of: [.fileURL], ...)` to `inputRow` in `NotchCommandBarView` with hover-stroke.
5. Extend `ContentView.dragDetector` — if Option held on drop + `notchState == .closed`, route to command bar; else existing Shelf flow.
6. Dismissible badge inside `inputRow` between icon and TextField.
7. 30K chars/file + 100K total cap (trim longest first, bottom at 2K).
8. Zero new entitlements — app isn't sandboxed (verified).

Out of scope: image/audio (ScreenAssistant handles those), cloud files, OCR, persistence across turns, per-file removal UI.

---

## 1. File List

### Create
- `/Users/allenwu/claude/metamorphia/Metamorphia/models/CommandBarAttachedFile.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/services/FileContentExtractor.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/AttachmentBadgeView.swift`

### Edit
- `/Users/allenwu/claude/metamorphia/Metamorphia/ViewModels/AICommandViewModel.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift`
- `/Users/allenwu/claude/metamorphia/Metamorphia/ContentView.swift`

---

## 2. `CommandBarAttachedFile`

```swift
// /Users/allenwu/claude/metamorphia/Metamorphia/models/CommandBarAttachedFile.swift
import Foundation

/// A file attached to the command bar, extracted to plain text for prompt
/// injection. Prefixed to avoid colliding with `ScreenAssistantFile`.
public struct CommandBarAttachedFile: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let ext: String
    public let extractedText: String
    public let extractedAt: Date
    public let sizeBytes: Int64

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        ext: String,
        extractedText: String,
        extractedAt: Date = Date(),
        sizeBytes: Int64
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.ext = ext
        self.extractedText = extractedText
        self.extractedAt = extractedAt
        self.sizeBytes = sizeBytes
    }

    public static let supportedExtensions: Set<String> = [
        "txt", "md", "swift", "js", "ts", "py", "cpp", "c", "h", "hpp",
        "java", "go", "rs", "rb", "php", "css", "html", "xml", "json",
        "yaml", "yml", "toml", "sh", "zsh", "bash", "csv", "log", "tex",
        "pdf", "docx", "doc", "pages",
        "pptx", "ppt", "xlsx", "xls",
        "rtf", "rtfd",
    ]

    public var formattedForPrompt: String {
        "--- Attached file: \(name) ---\n\(extractedText)\n--- End of \(name) ---"
    }
}
```

---

## 3. `FileContentExtractor`

```swift
// /Users/allenwu/claude/metamorphia/Metamorphia/services/FileContentExtractor.swift
import Foundation
import PDFKit
import AppKit

public actor FileContentExtractor {
    public static let shared = FileContentExtractor()

    public static let perFileCharCap = 30_000
    public static let totalCharCap = 100_000
    private static let shellTimeout: TimeInterval = 10

    public init() {}

    public func extract(from url: URL) async -> CommandBarAttachedFile? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        guard CommandBarAttachedFile.supportedExtensions.contains(ext) else {
            print("[FileContentExtractor] Unsupported extension: \(ext)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path) else {
            print("[FileContentExtractor] File missing or unreadable: \(url.path)")
            return nil
        }

        let size: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let rawContent: String
        switch ext {
        case "pdf":
            rawContent = extractPDF(url: url)
        case "rtf", "rtfd":
            rawContent = extractRTF(url: url)
        case "docx", "doc", "pages", "pptx", "ppt", "xlsx", "xls":
            rawContent = extractViaTextutil(url: url)
        default:
            rawContent = extractPlainText(url: url, maxChars: Self.perFileCharCap)
        }

        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("[FileContentExtractor] Empty content: \(name)")
            return nil
        }

        let capped: String = rawContent.count > Self.perFileCharCap
            ? String(rawContent.prefix(Self.perFileCharCap))
                + "\n\n[... truncated at \(Self.perFileCharCap) characters]"
            : rawContent

        return CommandBarAttachedFile(
            url: url, name: name, ext: ext,
            extractedText: capped, sizeBytes: size
        )
    }

    private func extractPDF(url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        let pageCount = min(doc.pageCount, 200)
        for i in 0..<pageCount {
            if let page = doc.page(at: i), let text = page.string {
                out.append(text)
                out.append("\n")
                if out.count > Self.perFileCharCap { break }
            }
        }
        return out
    }

    private func extractRTF(url: URL) -> String {
        if let data = try? Data(contentsOf: url),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil) {
            return attr.string
        }
        return runTextutil(url: url)
    }

    private func extractViaTextutil(url: URL) -> String {
        return runTextutil(url: url)
    }

    private func runTextutil(url: URL) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        task.arguments = ["-convert", "txt", "-stdout", url.path]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do { try task.run() } catch {
            print("[FileContentExtractor] textutil launch failed: \(error)")
            return ""
        }

        let deadline = Date().addingTimeInterval(Self.shellTimeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate()
            print("[FileContentExtractor] textutil timed out: \(url.lastPathComponent)")
            return ""
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func extractPlainText(url: URL, maxChars: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size > maxChars * 4 {
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return "" }
            defer { try? handle.close() }
            let data = handle.readData(ofLength: maxChars * 4)
            return String(data: data, encoding: .utf8) ?? ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Adjust a list so total extractedText.count ≤ totalCharCap.
    /// Repeatedly halves the longest file until under cap (bottoming at 2K/file).
    public static func enforceTotalCap(
        _ files: [CommandBarAttachedFile]
    ) -> [CommandBarAttachedFile] {
        var working = files
        var total = working.map { $0.extractedText.count }.reduce(0, +)
        guard total > totalCharCap else { return working }
        while total > totalCharCap {
            guard let (idx, _) = working.enumerated().max(by: {
                $0.element.extractedText.count < $1.element.extractedText.count
            }) else { break }
            let current = working[idx]
            let currentLen = current.extractedText.count
            guard currentLen > 2_000 else { break }
            let newLen = max(2_000, currentLen / 2)
            let newText = String(current.extractedText.prefix(newLen))
                + "\n\n[... truncated to \(newLen) characters to fit total cap]"
            working[idx] = CommandBarAttachedFile(
                id: current.id, url: current.url, name: current.name,
                ext: current.ext, extractedText: newText,
                extractedAt: current.extractedAt, sizeBytes: current.sizeBytes
            )
            total = working.map { $0.extractedText.count }.reduce(0, +)
        }
        return working
    }
}
```

---

## 4. ViewModel Changes

### 4.1 Property (near other `@Published`)

```swift
/// Files the user has dragged onto the command bar, pending injection into
/// the next submitted prompt. Cleared after each submission. Not persisted.
@Published public private(set) var attachedFiles: [CommandBarAttachedFile] = []
```

### 4.2 Public methods (below `clearConversation`)

```swift
public func attachFiles(urls: [URL]) {
    guard !urls.isEmpty else { return }
    for url in urls {
        if self.attachedFiles.contains(where: { $0.url == url }) { continue }
        Task { [weak self] in
            guard let file = await FileContentExtractor.shared.extract(from: url) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !self.attachedFiles.contains(where: { $0.url == file.url }) {
                    withAnimation(.spring(response: 0.25)) {
                        self.attachedFiles.append(file)
                    }
                }
            }
        }
    }
}

public func removeAttachment(id: UUID) {
    attachedFiles.removeAll { $0.id == id }
}

public func clearAttachments() {
    withAnimation(.spring(response: 0.25)) {
        attachedFiles.removeAll()
    }
}
```

### 4.3 Inject into prompt inside `submit(...)`

In `submit(...)`, find the existing `loop.submit(command: agentPrompt, ...)` call. Replace with:

```swift
let commandWithAttachments: String
if !attachedFiles.isEmpty {
    let cappedFiles = FileContentExtractor.enforceTotalCap(attachedFiles)
    let block = cappedFiles.map(\.formattedForPrompt).joined(separator: "\n\n")
    commandWithAttachments = """
    \(agentPrompt)

    The user has attached the following file(s) for context:

    \(block)
    """
    let idsToRetire = attachedFiles.map(\.id)
    Task { @MainActor [weak self] in
        guard let self else { return }
        self.attachedFiles.removeAll { idsToRetire.contains($0.id) }
    }
} else {
    commandWithAttachments = agentPrompt
}

let outcome = await loop.submit(
    command: commandWithAttachments,
    systemPrompt: primedPrompt,
    previousMessages: priorMessages
)
```

The displayed `turn.prompt` remains the raw user-typed string — no giant block in the transcript.

### 4.4 Clear attachments in `clearConversation`

Add one line: `attachedFiles.removeAll()`.

---

## 5. Drop handling on the command bar

File: `NotchCommandBarView.swift`

Add `@State private var isDragHovering: Bool = false`.

Modify `inputRow`:
- Insert `AttachmentBadgeView` between the icon and the TextField, shown when `!viewModel.attachedFiles.isEmpty`.
- Wrap the `.background(...)` in a ZStack that adds a `RoundedRectangle.strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)` when `isDragHovering`.
- Attach `.onDrop(of: [.fileURL], isTargeted: $isDragHovering)` to the HStack that calls `handleFileDrop`.

```swift
// Inside the HStack, after the icon Image, before TextField / Text branch:
if !viewModel.attachedFiles.isEmpty {
    AttachmentBadgeView(
        count: viewModel.attachedFiles.count,
        onClear: { viewModel.clearAttachments() }
    )
    .transition(.scale.combined(with: .opacity))
}
```

Drop handler helper:

```swift
private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
    guard !providers.isEmpty else { return false }
    var pendingURLs: [URL] = []
    let group = DispatchGroup()
    for provider in providers {
        group.enter()
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            defer { group.leave() }
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                pendingURLs.append(url)
            }
        }
    }
    group.notify(queue: .main) {
        guard !pendingURLs.isEmpty else { return }
        viewModel.attachFiles(urls: pendingURLs)
    }
    return true
}
```

---

## 6. Drop handling on the notch (Option-modifier route)

File: `ContentView.swift`, function `dragDetector`.

**Investigation**: Metamorphia has no dedicated `NotchWindow` — notch is drawn inside `MetamorphiaWindow` and `dragDetector` routes every drop to the Shelf. Don't hijack the Shelf; dispatch on Option key.

Modify `.onDrop` to accept `[.fileURL, .data]`, check Option on actual drop:

```swift
.onDrop(of: [.fileURL, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
    let optionHeld = NSEvent.modifierFlags.contains(.option)
    if optionHeld, vm.notchState == .closed {
        routeDropToCommandBar(providers: providers)
        return true
    }
    return true  // shelf handles
}
```

Add helper on ContentView:

```swift
private func routeDropToCommandBar(providers: [NSItemProvider]) {
    var urls: [URL] = []
    let group = DispatchGroup()
    for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
        group.enter()
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            defer { group.leave() }
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
    }
    group.notify(queue: .main) {
        guard !urls.isEmpty else { return }
        // Open the command bar first so the badge has a home.
        CommandBarCoordinator.shared.summon()
        CommandBarCoordinator.shared.viewModel?.attachFiles(urls: urls)
    }
}
```

**NOTE TO CODER:** Verify the exact method name on `CommandBarCoordinator` (`summon()` / `show(reason:)` / etc.) — use whatever `MetamorphiaShortcuts.swift` calls when Cmd+Shift+Space fires.

---

## 7. `AttachmentBadgeView`

```swift
// /Users/allenwu/claude/metamorphia/Metamorphia/components/AICommand/AttachmentBadgeView.swift
import SwiftUI

struct AttachmentBadgeView: View {
    let count: Int
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 4) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.75)))
        }
        .buttonStyle(.plain)
        .help("\(count) file\(count == 1 ? "" : "s") attached. Click to clear.")
    }
}
```

---

## 8. Prompt injection format

User prompt (NOT system prompt) gets:

```
<user's typed prompt>

The user has attached the following file(s) for context:

--- Attached file: <name1> ---
<content1>
--- End of <name1> ---

--- Attached file: <name2> ---
<content2>
--- End of <name2> ---
```

Rationale: matches Executer; system prompt stays stable for prefix-cache efficiency; doesn't collide with `primedSystemPrompt` / `injectSkillBodies` (both modify system prompt only).

`FunctionDetector.detect(in: agentPrompt)` runs on pre-attachment `agentPrompt` — attachment text can't masquerade as a math formula. Good.

---

## 9. Size limits

- Per-file: 30,000 chars. Marker: `[... truncated at 30000 characters]`.
- Total: 100,000 chars across all attachments per submission.
- `FileContentExtractor.enforceTotalCap` halves longest file text until under total cap; floor 2,000 chars.

---

## 10. Risks & open questions

1. **Entitlements / sandbox**: `Metamorphia.entitlements` does NOT contain `app-sandbox`. Subprocess + arbitrary-path reads work. `textutil` shell-out fine.
2. **Name collision**: `ScreenAssistantFile` is metadata-only, used by a different feature; prefix the new type `CommandBarAttachedFile` defensively.
3. **No pre-existing `attachedFiles`** on `AICommandViewModel` — confirmed.
4. **Shelf drop-target conflict**: dispatch on Option. Alternative: skip notch-drop and only support drop-on-open-bar — coder should pick if Option-dispatch proves messy.
5. **PPTX/XLSX quality via textutil**: spotty. Empty → reject silently. Don't port Executer's Python shell-outs.
6. **Middleware double-injection**: no known middleware in VM re-reads `attachedFiles`; AgentLoop is a black box.
7. **Option read timing**: `NSEvent.modifierFlags` reads at drop-close moment. Acceptable.
8. **Race: drop then Return immediately**: extraction may not be done before submit. Attachment simply not present on that turn. Acceptable unless visibly broken.
9. **`isDragHovering` bounce on child views**: drop modifier is on HStack as a whole, should be fine. Add `.animation(.easeOut(duration: 0.15))` on `isDragHovering` if bouncy.
10. **Quarantine xattrs**: PDFKit / textutil handle them.

---

## 11. Out of scope

- Images/audio (handled by ScreenAssistant separately).
- Cloud file URLs.
- OCR.
- Cross-turn persistence.
- Per-file removal UI (single bulk-clear X for T4).
- Shelf-to-CommandBar handoff.

---

## 12. Test plan

1. Drop `notes.txt` on open bar → badge "1", submit → log shows `commandWithAttachments` prefix contains file block; badge clears after submit.
2. Drop 3-page PDF → badge "1", submit → agent can reference PDF content.
3. Multi-file drop (Shift-click + drag): mixed .txt + .pdf + .png → badge shows "2" (png rejected); log confirms.
4. Click badge X → attachments clear with spring animation.
5. Drop `/bin/ls` (no extension) → no badge; log "Unsupported extension: ".
6. Option-drop on closed notch → bar opens, badge "1".
7. Regular drop on closed notch → Shelf opens as before (regression test).
8. Drop 5 large PDFs > 100K total → enforceTotalCap trims longest; log markers visible.
9. Submit clears attachments.
10. `clearConversation` clears attachments too.
11. Password-protected PDF → page.string empty → extractor rejects.
12. Non-trivial DOCX → textutil yields >500 chars; badge + submit work.

---

## 13. Implementation order

1. `CommandBarAttachedFile.swift` + `FileContentExtractor.swift` (pure models/services, no UI).
2. `AICommandViewModel.swift` — properties + methods + submit-injection + clearConversation tweak.
3. `AttachmentBadgeView.swift`.
4. `NotchCommandBarView.swift` — badge in inputRow + drop handler + hover stroke.
5. `ContentView.swift` — Option-routed notch drop path.
6. Build + run test plan.
