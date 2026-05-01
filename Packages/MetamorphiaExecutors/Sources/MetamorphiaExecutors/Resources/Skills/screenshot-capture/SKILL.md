---
name: screenshot-capture
description: Capture screenshots of the full screen, a window, or a selected region using the built-in `screencapture` CLI. Use when the user says "take a screenshot", "capture this window", "grab the top-left corner".
---

# Screenshot Capture

macOS ships `screencapture` — no install needed. Drive it via `run_shell_command`.

## Full screen

```bash
screencapture -x /tmp/shot.png              # -x = silent (no shutter sound)
screencapture -x -T 3 /tmp/shot.png         # 3-second delay
```

## Specific window (interactive)

```bash
screencapture -w /tmp/shot.png              # user clicks the window to capture
screencapture -wo /tmp/shot.png             # no window shadow (tighter crop)
```

## Selection rectangle (interactive)

```bash
screencapture -s /tmp/shot.png              # user drags a rectangle
```

## Exact region (non-interactive)

```bash
screencapture -R x,y,w,h /tmp/shot.png      # pixels, origin top-left
# e.g., top-left 800×600 quadrant:
screencapture -R 0,0,800,600 /tmp/shot.png
```

Use `system_profiler SPDisplaysDataType` or AppleScript (`tell application "Finder" to get bounds of window of desktop`) to determine screen size.

## Specific display (multi-monitor)

```bash
screencapture -D 1 /tmp/primary.png
screencapture -D 2 /tmp/external.png
```

## To clipboard instead of file

```bash
screencapture -c                            # full screen → clipboard
screencapture -cw                           # window picker → clipboard
screencapture -cs                           # selection → clipboard
```

Combine with `GetClipboardTextTool` / `run_applescript`-driven paste.

## Format

Default is PNG. Other options:
```bash
screencapture -t jpg /tmp/shot.jpg
screencapture -t pdf /tmp/shot.pdf
```

## Gotchas

- First run prompts for Screen Recording permission. If the file ends up blank, the permission was denied — direct the user to System Settings → Privacy & Security → Screen & System Audio Recording.
- The main menu bar isn't captured with `-w` unless you pass `-oM` or target the menu bar app.
- On Retina displays, pixels are logical (×2 actual) — a 800×600 `-R` capture produces a 1600×1200 image file.
