---
name: finder-files
description: Query Finder state — selected files, frontmost window's folder, Desktop contents — and reveal files in Finder. Use when the user references "the selected files", "this folder", "what I have open in Finder".
---

# Finder Files

Finder is scriptable and often the fastest way to answer "what's the user looking at right now". Use `run_applescript`.

## Currently selected items

```applescript
tell application "Finder"
  set sel to selection
  set out to ""
  repeat with item in sel
    set out to out & (POSIX path of (item as alias)) & linefeed
  end repeat
  return out
end tell
```

Returns empty string if nothing is selected. POSIX paths are the usable form (feed them to `run_shell_command`, `FileOperationTool`, etc.).

## Frontmost Finder window's folder

```applescript
tell application "Finder"
  if (count of Finder windows) > 0 then
    return POSIX path of (target of front window as alias)
  else
    return POSIX path of (desktop as alias)
  end if
end tell
```

## Reveal a file

```applescript
tell application "Finder"
  reveal POSIX file "/Users/you/Documents/report.pdf"
  activate
end tell
```

Or from shell: `open -R /path/to/file`

## Open a folder in a new Finder window

```bash
open ~/Downloads
```

## List Desktop / Downloads

Prefer shell — it's faster than iterating Finder:
```bash
ls -lt ~/Desktop | head -20
ls -lt ~/Downloads | head -20
```

## Move to Trash

```applescript
tell application "Finder"
  delete POSIX file "/Users/you/Desktop/old.txt"
end tell
```

This moves to Trash (recoverable). For permanent deletion, use `run_shell_command rm`.

## Finder tags

```applescript
tell application "Finder"
  set label index of (POSIX file "/path/to/file" as alias) to 2   -- 0–7: None,Orange,Red,Yellow,Blue,Purple,Green,Gray
end tell
```

For named tags (the modern macOS "Tags" feature): `run_shell_command`:
```bash
xattr -w com.apple.metadata:_kMDItemUserTags '("Work","Urgent")' /path/to/file
```

## Gotchas

- "selection" is empty when Finder isn't the frontmost app. If the user asks about "the selected files" and the script returns empty, they may have focused another app — clarify.
- `POSIX path of (item as alias)` is the reliable pattern; just `path of item` returns colon-delimited HFS paths.
