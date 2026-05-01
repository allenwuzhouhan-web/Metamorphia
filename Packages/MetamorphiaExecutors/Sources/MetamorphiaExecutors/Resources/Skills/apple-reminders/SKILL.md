---
name: apple-reminders
description: Create, list, and complete Apple Reminders via AppleScript. Use when the user wants a reminder that syncs to their iPhone/iPad (not a local Metamorphia alert).
---

# Apple Reminders

Reminders.app has a rich AppleScript dictionary. Drive it via `run_applescript`. Reminders created here sync through iCloud to the user's iOS devices.

## Use vs. don't use

- **Use** when the user says "remind me to X tomorrow at 9", "add to my grocery list", "what's on my reminders list"
- **Don't use** for short-term Metamorphia alerts ("ping me in 10 minutes") — use Metamorphia's scheduler for those. If ambiguous, ask.

## Add a reminder

```applescript
tell application "Reminders"
  tell list "Reminders"
    make new reminder with properties {name:"Call the dentist", due date:(current date) + 1 * days}
  end tell
end tell
```

Date math uses AppleScript `date` objects. For an explicit date/time:

```applescript
set theDate to current date
set year of theDate to 2026
set month of theDate to 5
set day of theDate to 3
set time of theDate to 9 * hours + 30 * minutes
```

## List today's reminders

```applescript
tell application "Reminders"
  set today to current date
  set time of today to 0
  set tomorrow to today + 1 * days
  set items to (every reminder of list "Reminders" whose (due date ≥ today) and (due date < tomorrow) and (completed is false))
  set out to ""
  repeat with r in items
    set out to out & (name of r) & linefeed
  end repeat
  return out
end tell
```

## Complete a reminder

```applescript
tell application "Reminders"
  set match to first reminder of list "Reminders" whose name is "Call the dentist"
  set completed of match to true
end tell
```

## Pick a list

- Default list name is usually `"Reminders"` but users often rename it
- Get all lists: `tell application "Reminders" to get name of every list`
- Confirm with the user before writing to a non-default list

## Gotchas

- First call prompts for Reminders access. If `-1743` returns, direct the user to System Settings → Privacy & Security → Reminders.
- `due date` means "when the reminder fires"; `remind me date` is an alias. Stick with `due date` for compatibility.
- Natural-language date parsing ("next Thursday", "in 2 hours") is NOT supported by AppleScript. Resolve relative dates yourself and pass a concrete `date` object.
