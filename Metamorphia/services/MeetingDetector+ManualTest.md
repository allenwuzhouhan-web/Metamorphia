# MeetingDetector — Manual Test Plan

## Prerequisites
- Zoom installed (`us.zoom.xos`)
- `Defaults[.observeMeetings]` is `true` (default)
- `Defaults[.activityStreamEnabled]` is `true` (default)
- `HardwareStreamBridge` and `MeetingDetector` started in `MetamorphiaBootstrap`
- `PrivacyIndicatorManager` has started its own monitoring (provides camera / mic state)
- ActivityJournal visible in Metamorphia's debug view, or add a print observer on `ActivityStream.shared.events`

## Test 1 — Normal meeting flow

1. Open Zoom and start or join a meeting.
2. Enable your camera and microphone in Zoom.
3. Wait **10 seconds** while Zoom remains the frontmost window.
4. **Expected:** `ActivityEvent.meetingStarted(app: "Zoom", at: <timestamp>)` appears in the journal.
5. End the call (or leave the meeting).
6. **Expected:** `ActivityEvent.meetingEnded(durationSeconds: <N>, at: <timestamp>)` appears, where N ≥ 10.

## Test 2 — Pre-meeting camera test (false positive suppression)

1. Open Zoom but only briefly toggle camera on then off within the same 10-second window (simulating a quick A/V check before joining).
2. **Expected:** Neither `meetingStarted` nor `meetingEnded` appear in the journal.

## Test 3 — Camera turns off mid-meeting

1. Join a Zoom meeting with camera and mic active; wait 10 s for `meetingStarted` to commit.
2. Turn the camera off in Zoom.
3. **Expected:** `meetingEnded` fires immediately with the correct elapsed duration.

## Test 4 — Frontmost app changes

1. Join a Zoom meeting (camera + mic on); wait 10 s for `meetingStarted`.
2. Switch to a non-VC app (e.g. Safari).
3. **Expected:** `meetingEnded` fires.
4. Switch back to Zoom.
5. **Expected:** A new `meetingStarted` is buffered and commits after another 10 s.

## Test 5 — Google Meet in browser

1. Open Google Meet in a supported browser and join a call with camera and mic.
2. **Expected:** `meetingStarted(app: "Google Meet", ...)` after 10 s.
3. Navigate the browser away from `meet.google.com`.
4. **Expected:** `meetingEnded` fires.

## Test 6 — Feature gate

1. Set `Defaults[.observeMeetings] = false`.
2. Repeat Test 1.
3. **Expected:** No `meetingStarted` or `meetingEnded` events appear.
