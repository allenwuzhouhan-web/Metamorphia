---
name: things-mac
description: Add todos, projects, and checklists to Things 3 via its URL scheme. Use when the user references "Things", "my inbox", or a Things-specific area/project.
---

# Things 3

Things 3 exposes a URL scheme (`things:///`) that accepts add/update commands. No AppleScript automation access needed for writes — just `open` the URL.

## Add a todo

```bash
# Basic
open "things:///add?title=Buy%20milk"

# With notes, due date, tags, project
open "things:///add?title=Draft%20proposal&notes=Send%20to%20Alex&when=tomorrow&tags=work,urgent&list=Inbox"
```

Escape query parameters. Key flags:
- `title` (required)
- `notes` — body text, can be multiline (%0A for newline)
- `when` — `today`, `tomorrow`, `evening`, `anytime`, `someday`, or ISO date `2026-05-03`
- `deadline` — hard deadline, ISO date
- `tags` — comma-separated
- `list` — project or area name
- `heading` — heading within a project
- `checklist-items` — newline-separated (%0A)

## Add to a project

```bash
open "things:///add?title=Book%20flights&list=Travel%20Plans&when=today"
```

If the project doesn't exist, the todo lands in the Inbox.

## Add a project

```bash
open "things:///add-project?title=Launch%20Website&area=Work&notes=Q2%20goal"
```

## Auth token for updates

Reading existing todos and completing/updating them requires an auth token:
1. Things → Settings → General → Enable Things URLs
2. Copy the authorization token
3. Store once; use in `auth-token=...`

Example complete:
```bash
open "things:///update?id=XXXX&completed=true&auth-token=YYYY"
```

Getting IDs requires reading the Things SQLite database directly — use `run_shell_command`:
```bash
sqlite3 ~/Library/Group\ Containers/*.com.culturedcode.ThingsMac/ThingsData-*/Things\ Database.thingsdatabase/main.sqlite \
  "SELECT uuid, title FROM TMTask WHERE trashed=0 AND status=0 LIMIT 20"
```

The DB path uses a team-id prefix — let the glob resolve it.

## Gotchas

- `open` is fire-and-forget; URLs silently no-op if malformed.
- The URL scheme brings Things to the foreground on every add. For background additions, no workaround exists — warn the user.
- Inbox is the default if you omit `list`.
