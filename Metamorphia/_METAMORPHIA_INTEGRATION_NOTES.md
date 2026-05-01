# Metamorphia — Integration Notes

This file tracks manual integration steps that the automated merge pass can't
perform directly (pbxproj surgery, deletions of Executer chrome that don't
exist in this repo yet, SPM wire-up).

---

## 1. Link `MetamorphiaAgentKit` into the Xcode project (one-time)

The package lives at `Packages/MetamorphiaAgentKit/`. It's a Swift Package with
no external dependencies.

In Xcode:
1. File → Add Package Dependencies → Add Local → choose `Packages/MetamorphiaAgentKit`.
2. In the Project settings → Metamorphia target → Frameworks → add `MetamorphiaAgentKit`.

Or via pbxproj: add an `XCLocalSwiftPackageReference` pointing to
`Packages/MetamorphiaAgentKit` with `relativePath = Packages/MetamorphiaAgentKit`, and add
a `XCSwiftPackageProductDependency` for `MetamorphiaAgentKit` to the Metamorphia target's
`packageProductDependencies` and `frameworksBuildPhase.files`.

Once linked, files under `Metamorphia/` that have `import MetamorphiaAgentKit`
will resolve — currently:
- `ViewModels/AICommandViewModel.swift`

---

## 2. Wire Command Bar hotkey into AppDelegate

In `Metamorphia/MetamorphiaApp.swift`, inside
`applicationDidFinishLaunching(_:)`, alongside the existing
`KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { ... }` block, add:

```swift
KeyboardShortcuts.onKeyDown(for: .commandBar) {
    Task { @MainActor in
        CommandBarCoordinator.shared.toggle()
    }
}
```

This uses the `.commandBar` shortcut defined in `Shortcuts/MetamorphiaShortcuts.swift`
(Cmd+Shift+Space by default).

---

## 3. Construct + wire the view model at app launch

Also in `AppDelegate.applicationDidFinishLaunching(_:)`, build the agent
loop and hand the view model to the coordinator:

```swift
import MetamorphiaAgentKit

// Build shared infrastructure.
let registry = ToolRegistry()
// App target code registers tools into `registry` here — see Phase 3 docs
// for the MetamorphiaExecutors wire-up. For a bootstrap with zero tools, the
// registry still compiles and runs, it just has nothing to call.

let chain = AgentLoop.makeDefaultMiddlewareChain(
    progressSink: /* set once viewModel exists */ NullProgressSink(),
    memoryStore: NullMemoryStore(),       // replace with your MemoryManager adapter
    systemContext: NullSystemContextProvider(),
    clipboard: NullClipboardProvider(),   // replace with NSPasteboard-backed impl
    session: NullSessionProvider(),
    toolCatalog: ToolRegistryCatalogAdapter(registry: registry),
    adaptiveResponseStorageURL: URL.applicationSupportDirectory
        .appendingPathComponent("Metamorphia/response_engagement.json")
)

let loop = AgentLoop(
    service: LLMServiceManager.shared.currentService,
    registry: registry,
    middlewareChain: chain
)

let viewModel = AICommandViewModel(loop: loop)
CommandBarCoordinator.shared.viewModel = viewModel

// Register the viewModel as the progress + display sink.
// (The middleware chain was built with a NullProgressSink above; rebuild it
//  here once viewModel is available, OR swap in a concrete sink via a
//  mutable reference in your StreamingProgressMiddleware fork.)

// Register tool display names from Executer's defaults.
ToolDisplayName.register(AgentLoop.defaultFriendlyNames)
```

(The `NullProgressSink` is a stand-in — the middleware chain currently
doesn't expose a "swap the sink after construction" hook. When the app
target wires this up properly, either build the chain manually after the
view model exists, or add such a hook to `AgentLoop.makeDefaultMiddlewareChain`.)

---

## 4. Wire the dual-activation gesture

In `NotchDetector.swift` (or wherever `MetamorphiaViewModel.open()` is
currently called from the notch hit-test):

```swift
let gesture = NotchActivationGesture()
gesture.onSummonCommandBar = {
    CommandBarCoordinator.shared.toggle()
}
gesture.onCommitToMetamorphia = {
    MetamorphiaViewCoordinator.shared.currentView = .home
    vm.open()
}

// Route mouse events:
//   hoverBegan()  — on .onHover(true)
//   hoverEnded()  — on .onHover(false)
//   pressDown()   — on .onLongPressGesture(minimumDuration: 0).onPressingChanged(true)
//   pressUp()     — .onPressingChanged(false)
```

Observe `gesture.progress` to animate the notch's width/corner-radius during
the press (the "compress back" feedback). Attach this to the rendered notch
shape via a `.scaleEffect` or width transition bound to `1 - gesture.progress`.

---

## 5. Mount `AgentRunningLiveActivity` in `ContentView`

`ContentView.swift` has a branch (somewhere near the closed-notch overlay
block) that switches on active live activities to render `PrivacyLiveActivity`,
`RecordingLiveActivity`, etc. Add a new branch:

```swift
if agentViewModel.isProcessing {
    AgentRunningLiveActivity(agentViewModel: agentViewModel)
}
```

The dot shows in the right region of the closed notch alongside whatever
else is rendering (music art, privacy pulse). It does NOT steal the notch.

---

## 6. Executer chrome deletion plan (reference)

When Phase 3 imports Executer sources, DO NOT import these files — they are
replaced by the work in this branch:

| Delete | Replaced by |
|---|---|
| `Executer/App/ExecuterApp.swift` | `MetamorphiaApp` (already in Metamorphia/) |
| `Executer/App/AppDelegate.swift` | Existing AppDelegate + `AICommandBootstrap.configure(into:)` helper (to write) |
| `Executer/App/HotkeyManager.swift` | `KeyboardShortcuts` library + `MetamorphiaShortcuts.swift` |
| `Executer/App/AppState.swift` | `AICommandViewModel` + `CommandBarCoordinator` |
| `Executer/App/AppModel.swift` | Drop — most was duplicate |
| `Executer/Notch/NotchWindow.swift` | Metamorphia's `MetamorphiaWindow` (already in Metamorphia/). Contains `NotchGlowView` at lines 438-506 — gone with the file. |
| `Executer/Notch/NotchDetector.swift` | Metamorphia's equivalent |
| `Executer/Notch/ScreenGeometry.swift` | Metamorphia's per-screen notch geometry |
| `Executer/UI/InputBar/InputBarPanel.swift` | `CommandBarWindow.swift` |
| `Executer/UI/Onboarding/*` | Merge into Metamorphia's first-run flow |
| `Executer/UI/Settings/NotchSettingsTab.swift` | Metamorphia's notch settings |
| `Executer/UI/Settings/AboutSettingsTab.swift` | Metamorphia's About |
| `Executer/UI/Settings/UpdateSettingsTab.swift` | Metamorphia's Sparkle wire-up |
| `Executer/UI/Settings/LanguageSettingsTab.swift` | Metamorphia's Language settings |
| `Executer/UI/Settings/SecuritySettingsTab.swift` | Metamorphia's Security settings |

**Keep (port into this branch)**:
- `Executer/UI/InputBar/InputBarView.swift` — logic ported into `NotchAICommandBarView`
- `Executer/UI/InputBar/ResultBubbleView.swift` — styling restyled in `NotchAICommandBarView`
- `Executer/UI/InputBar/AgentPickerView.swift` — popover (wire into `agentPickerChevron`)
- `Executer/UI/InputBar/InputBarHelpers.swift` — pure logic
- `Executer/LearningDotView` → replaced by the learning pill in the header (already in `NotchAICommandBarView`)

---

## 7. iPhone → Mac remote dispatch (MetamorphiaRemote)

The remote-control feature introduces a new Swift package (`MetamorphiaRemoteKit`),
two new files in the Mac app (`RemoteCommandListener`, `KeepAwake`), and a new
iPhone Xcode project (`MetamorphiaRemote`). All Swift source is already written
on disk — the steps below are the manual Xcode-UI wire-up.

### 7a. Mac project — link MetamorphiaRemoteKit and enable iCloud

In Xcode, open `Metamorphia.xcodeproj`:

1. **Add the local package.** File → Add Package Dependencies → Add Local →
   choose `Packages/MetamorphiaRemoteKit`. When prompted, add the
   `MetamorphiaRemoteKit` product to the **Metamorphia** target.
2. **Enable iCloud capability.** Select the Metamorphia target → Signing &
   Capabilities → `+ Capability` → iCloud. Check **CloudKit**. Under
   Containers, add `iCloud.com.johannendersmith.metamorphia.remote`. The
   entitlement keys are already present in `Metamorphia.entitlements`; Xcode
   just needs the capability toggled so provisioning picks them up.
3. **Build.** The new `RemoteCommandListener.shared` referenced from
   `AppDelegate` now resolves. The listener starts alongside the other
   `.shared` managers in `applicationDidFinishLaunching`.

### 7b. iPhone project — one-time creation

The Swift sources live at `MetamorphiaRemote/MetamorphiaRemote/` but the
`.xcodeproj` is created by the Xcode wizard (cleaner than hand-rolling pbxproj).

1. File → New → Project → **iOS → App**. Product Name `MetamorphiaRemote`,
   Team `9Y64TRM77N`, Organization Identifier `com.johannendersmith`,
   Interface SwiftUI, Language Swift, Storage None. Save into
   `MetamorphiaRemote/` **alongside** the existing `MetamorphiaRemote/` folder
   containing the Swift files (i.e. the xcodeproj and the sources live
   side-by-side under `MetamorphiaRemote/`).
2. **Delete the auto-generated files** the wizard creates
   (`ContentView.swift`, the default `App` file), then drag the six existing
   Swift files from Finder into the Xcode project navigator:
   - `MetamorphiaRemoteApp.swift`
   - `HomeView.swift`
   - `CommandSender.swift`
   - `Intents.swift`
   - `MetamorphiaRemoteShortcuts.swift`
   - `MetamorphiaRemote.entitlements`
   Choose "Add to target: MetamorphiaRemote" on import.
3. **Link `MetamorphiaRemoteKit`.** File → Add Package Dependencies → Add
   Local → choose `Packages/MetamorphiaRemoteKit` (the same package the Mac
   target uses). Add the product to the MetamorphiaRemote target.
4. **Enable iCloud capability.** Target → Signing & Capabilities →
   `+ Capability` → iCloud → check **CloudKit** → add container
   `iCloud.com.johannendersmith.metamorphia.remote`. The entitlement file is
   already in the target; Xcode needs the capability enabled so the container
   provisions.
5. **Set the entitlements file.** Target → Build Settings → Code Signing
   Entitlements → `MetamorphiaRemote/MetamorphiaRemote.entitlements`.
6. **Build + run on a physical iPhone** signed into the same iCloud account as
   the Mac. The seven tiles appear; Siri exposes the eight phrases
   automatically once the app is launched once.

### 7c. CloudKit container — one-time provisioning

First time you open the Metamorphia Mac app after 7a with a signed-in iCloud
account, the `RemoteCommandListener` will call `CKContainer.accountStatus` and
then try to query the `PendingCommand` record type. The container
`iCloud.com.johannendersmith.metamorphia.remote` is auto-created on first use;
record types and indexes are auto-created when the first record is written
(Development environment). Before shipping to TestFlight / production, go to
[CloudKit Dashboard](https://icloud.developer.apple.com/), open the container,
and **Deploy Schema to Production**.

### 7d. Verification (matches the approved plan)

1. Physical iPhone + awake Mac running Metamorphia, same iCloud account.
2. Say **"Hey Siri, sleep my Mac"** — Mac screen dark within ~35 s.
3. Console.app, filter subsystem `com.johannendersmith.metamorphia`, category
   `remote-commands` — expect one `Ran sleep_mac [UUID]` log line.
4. Repeat for **"Play music on my Mac"** / **"Pause music on my Mac"**.
5. Tap **Keep Awake** on the iPhone grid; let the Mac sit idle past its sleep
   timeout — display stays on. Force-quit Metamorphia with Keep Awake on —
   display sleep resumes (proves the in-process `IOPMAssertion` replaces
   `caffeinate` correctly).

### 7e. What NOT to do

- **Don't** add iOS platforms to `MetamorphiaAgentKit` or `MetamorphiaExecutors`
  — they depend on Mac-only code. Only `MetamorphiaRemoteKit` is
  cross-platform.
- **Don't** pull any of Metamorphia's existing macOS deps (Sparkle,
  SkyLightWindow, KeyboardShortcuts, SwiftTerm, MediaRemoteAdapter) into the
  iOS target. The iPhone app's only dependency is `MetamorphiaRemoteKit`.
- **Don't** enable App Sandbox on the Mac target to add iCloud — the existing
  target runs unsandboxed by design. iCloud capabilities work fine on
  unsandboxed notarized apps.
