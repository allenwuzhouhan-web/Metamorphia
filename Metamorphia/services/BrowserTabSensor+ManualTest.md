# BrowserTabSensor — Manual Test Scenarios

No Xcode unit-test target exists for the `Metamorphia` app target, so the five required scenarios are described here for QA / future test-target wiring.

---

## 1. testUnsupportedBrowserSkipsPolling

**Setup:** Set `Defaults[.observeBrowserTabs] = true`. Call `sensor.start()`.
**Action:** Switch focus to TextEdit (or any non-browser app).
**Expected:** `pollTimer` is nil (no poll loop running). Zero `urlVisited` events emitted to `ActivityStream` within 2 seconds.
**How to verify:** Attach a test sink to `ActivityStream` before calling `start()` and assert the sink receives no `.urlVisited` events after focusing TextEdit.

---

## 2. testUrlHashIsStable

**Setup:** Create a `URL` with a known absolute string, e.g. `https://example.com/path?q=1`.
**Action:** Call `sensor.hash(url:)` twice with the same URL.
**Expected:** Both calls return the same 16-character lowercase hex string.
**How to verify:** `XCTAssertEqual(sensor.hash(url: url), sensor.hash(url: url))`.

---

## 3. testAllowlistFiltersEmit

**Setup:** Implement a mock `BrowserDomainAllowlistProtocol` that returns `false` from `allows(host:)`. Inject into `BrowserTabSensor.init(stream:allowlist:)`. Set `Defaults[.observeBrowserTabs] = true`. Simulate a Safari frontmost-app change.
**Action:** Let one poll fire (mock the AppleScript result to return a valid HTTP URL).
**Expected:** Zero `urlVisited` events emitted even though the URL is valid.

---

## 4. testDuplicateSuppression

**Setup:** Allow-all allowlist, feature flag on. Mock AppleScript to always return the same URL (`https://example.com`).
**Action:** Trigger two consecutive polls (call `poll()` directly or advance a mock timer twice).
**Expected:** Exactly one `urlVisited` event emitted, not two.

---

## 5. testPrivateWindowSkipped

**Setup:** Allow-all allowlist, feature flag on. Mock `AppleScriptHelper.execute` to return a descriptor whose `isPrivate` field is `true` (e.g. return a record with `isPrivate:true`).
**Action:** Trigger one poll.
**Expected:** Zero `urlVisited` events emitted.
**Note:** The sensor defaults to skip on any parse ambiguity (`isPrivate` descriptor nil → `true`), so a nil response also passes this test.
