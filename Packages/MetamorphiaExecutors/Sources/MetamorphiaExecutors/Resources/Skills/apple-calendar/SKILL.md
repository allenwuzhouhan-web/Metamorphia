---
name: apple-calendar
description: Create events, list today's agenda, and find free time via AppleScript against Calendar.app. Use when the user wants to schedule a meeting or check their calendar.
---

# Apple Calendar

Calendar.app is scriptable. Use `run_applescript` for read/write; prefer reads over writes unless the user is explicit.

## Create an event

```applescript
tell application "Calendar"
  tell calendar "Home"
    set startDate to (current date) + 1 * days
    set time of startDate to 14 * hours
    set endDate to startDate + 1 * hours
    make new event with properties {summary:"Dentist", start date:startDate, end date:endDate, location:"123 Main St"}
  end tell
end tell
```

Required properties: `summary`, `start date`, `end date`. Optional: `location`, `description`, `allday event:true`.

## Today's agenda

```applescript
tell application "Calendar"
  set today to current date
  set time of today to 0
  set tomorrow to today + 1 * days
  set out to ""
  repeat with cal in calendars
    set events_today to (every event of cal whose start date ≥ today and start date < tomorrow)
    repeat with e in events_today
      set out to out & (summary of e) & " @ " & (start date of e as string) & linefeed
    end repeat
  end repeat
  return out
end tell
```

Iterating every calendar is slow on large accounts. Narrow to one calendar (`calendar "Work"`) when you can.

## Find free time

AppleScript doesn't have a native "find free slot" verb. Strategy:
1. Pull events in the window via the pattern above
2. Sort by `start date`, compute gaps ≥ the requested duration
3. Return the first gap

## Calendar names

- List calendars: `tell application "Calendar" to get name of every calendar`
- Common defaults: `"Home"`, `"Work"`, `"Calendar"`, `"iCloud"`
- Confirm with the user before creating on an unfamiliar calendar

## Gotchas

- Calendar.app must be running or AppleScript will launch it (flash of dock icon).
- Time zones default to the Mac's current zone. For cross-TZ scheduling, state the zone explicitly to the user.
- Recurring events are read-only through AppleScript — you can create single instances but not RRULEs.
