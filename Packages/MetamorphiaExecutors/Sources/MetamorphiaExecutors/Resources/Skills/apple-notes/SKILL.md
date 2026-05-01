---
name: apple-notes
description: Create, read, search, and update Apple Notes via AppleScript. Use when the user says "add a note", "find my note about X", "update the note titled Y", or references Notes.app.
---

# Apple Notes

Drive Notes.app through AppleScript via the `run_applescript` tool. No external CLI required. Works with the default account and all folders the user has synced.

## When to use

- User says "add a note", "make a note", "save this as a note"
- User wants to search notes ("find the note about the trip budget")
- User wants to append to or edit an existing note

## Create a note

```applescript
tell application "Notes"
  tell account "iCloud"
    make new note at folder "Notes" with properties {name:"Grocery list", body:"<div>milk</div><div>eggs</div>"}
  end tell
end tell
```

Notes uses HTML for the `body`. Wrap plain lines in `<div>` to preserve line breaks. Escape `&`, `<`, `>` in user-provided content.

## List / search notes

```applescript
tell application "Notes"
  set matches to every note whose name contains "trip budget"
  set out to ""
  repeat with n in matches
    set out to out & (name of n) & linefeed
  end repeat
  return out
end tell
```

For full-text matches, swap `name contains` for `body contains`.

## Append to a note

```applescript
tell application "Notes"
  set target to first note whose name is "Meeting log"
  set body of target to (body of target) & "<div>" & "New entry" & "</div>"
end tell
```

## Folders

- List folders: `tell application "Notes" to get name of every folder`
- Create in a specific folder: change `at folder "Notes"` to the folder name
- Default account on most Macs is `"iCloud"`; fall back to `"On My Mac"` if iCloud isn't set up

## Gotchas

- First call may prompt the user to grant Automation access to Notes. If AppleScript fails with `-1743`, ask the user to allow the host app (Metamorphia) under System Settings → Privacy & Security → Automation.
- Notes with attachments (images, PDFs) can be read but body edits strip non-HTML content. Warn the user before overwriting.
- Use `display dialog` sparingly — it blocks until the user responds.
