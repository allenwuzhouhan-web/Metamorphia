# AppFocusSensor — Manual Verification Script

No XCTest target exists in the main app project. The three required test scenarios
are covered below as manual steps. The `MetamorphiaAgentKit` package tests cover
the stream itself (`ActivityStreamTests.swift`); the sensor integration is best
verified at runtime with the steps below.

## Setup

1. Build and launch Metamorphia in Debug.
2. Open Console.app or keep Xcode's debug console visible.
3. Ensure at least Finder and one other app (e.g. Safari) are open.

---

## Test 1 — Duplicate Suppression

**Goal:** Two identical focus snapshots produce exactly one emit.

**Steps:**
1. Click on Safari to make it frontmost.
2. Without switching away, click on Safari's dock icon again (or click the same
   window). The workspace notification fires again but the snapshot (bundleID,
   appName, windowTitle, pid) is identical to the last emit.

**Expected:** Only one `focusChanged` event for Safari appears in the activity
journal (check via `ActivityJournal` or Xcode breakpoint on `stream.emit`).
A second click in the same state produces no new journal entry.

---

## Test 2 — Denylist Redacts Title

**Goal:** 1Password (or any denylist app) emits `bundleID` but `windowTitle = nil`.

**Steps:**
1. Open 1Password (`com.1password.1password` or `com.1password.1password7`).
2. With AX trusted (confirm in System Settings → Privacy → Accessibility), switch
   to 1Password so it becomes frontmost.

**Expected:** The emitted event carries:
- `bundleID`: `"com.1password.1password"` (or the variant installed)
- `windowTitle`: `nil`  ← redacted even though AX could read it

Verify in the journal or via a breakpoint in `captureAndEmit()` inspecting
the `snapshot.windowTitle` before emit.

---

## Test 3 — Disabled Gate Is No-Op

**Goal:** Setting `Defaults[.observeAppFocus] = false` prevents any emit.

**Steps (via Xcode LLDB while paused or via a debug menu action):**

```swift
// In LLDB console:
expr import Defaults
expr Defaults[Defaults.Keys.observeAppFocus] = false
```

Then Cmd-Tab through 3–5 apps.

**Expected:** No new `focusChanged` entries appear in the journal while the key
is false. The sensor's `captureAndEmit()` returns early at the
`guard Defaults[.observeAppFocus]` check on every poll/notification cycle.

Reset when done:
```swift
expr Defaults[Defaults.Keys.observeAppFocus] = true
```

---

## Test 4 — Debounce Coalesces Rapid Switches (bonus)

**Steps:**
1. Perform a fast Cmd-Tab through 5 apps in under 1 second (a "storm").

**Expected:** The journal should show the final destination app, not all 5
intermediate apps. The 150 ms `DispatchWorkItem` debounce cancels earlier items
before they fire.

---

## AX Not Trusted Path

If you want to test the graceful AX-untrusted path:
1. Remove Metamorphia from System Settings → Privacy → Accessibility.
2. Relaunch.
3. Confirm the console prints exactly once:
   `[AppFocusSensor] AX not trusted — window titles unavailable`
4. Confirm focus events continue to be emitted with `windowTitle = nil`.
