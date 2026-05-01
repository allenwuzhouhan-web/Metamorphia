---
name: system-control
description: Adjust macOS system settings — volume, brightness, dark mode, Wi-Fi, Bluetooth, Do Not Disturb, sleep/lock/shutdown. Use when the user wants to change a system-level setting.
---

# System Control

Most system settings are reachable through AppleScript (`run_applescript`) or shell commands (`run_shell_command`). Prefer the AppleScript path — it's more stable across macOS versions.

## Volume

```applescript
set volume output volume 50        -- 0–100
set volume with output muted        -- mute
set volume without output muted     -- unmute
get volume settings                 -- inspect
```

## Brightness

No direct AppleScript. Use the `brightness` CLI if installed, or UI scripting via System Events:

```bash
# If `brightness` is installed: brew install brightness
brightness 0.7                      # 0.0–1.0
```

Fallback (slow, UI-scripted):
```applescript
tell application "System Events"
  repeat 5 times
    key code 144   -- F1 / brightness down
  end repeat
end tell
```

## Dark mode toggle

```applescript
tell application "System Events"
  tell appearance preferences
    set dark mode to not dark mode
  end tell
end tell
```

Set explicitly: `set dark mode to true` / `false`.

## Wi-Fi

```bash
networksetup -setairportpower en0 off   # or on
networksetup -getairportnetwork en0     # current SSID
networksetup -listallhardwareports      # if en0 isn't the Wi-Fi interface
```

## Bluetooth

`blueutil` (Homebrew): `brew install blueutil`
```bash
blueutil --power 0        # off
blueutil --power 1        # on
blueutil --connect "AirPods"
```

Without `blueutil`, toggling BT from CLI is painful — prefer prompting the user.

## Do Not Disturb / Focus

macOS Sonoma+ renamed DND to Focus. Shortcut is the reliable path:
```applescript
tell application "Shortcuts Events"
  run shortcut "Toggle Do Not Disturb"
end tell
```

User must create a shortcut by that name first. Offer to walk them through it.

## Power

```applescript
-- Lock screen
tell application "System Events" to keystroke "q" using {control down, command down}

-- Sleep
tell application "System Events" to sleep

-- Log out / shut down (ask confirmation!)
tell application "System Events" to log out
tell application "System Events" to shut down
```

**Always confirm** before shutdown/restart/logout — irrecoverable for any unsaved work.

## Notifications / speak

```applescript
display notification "Build done" with title "Metamorphia"
say "Your coffee is ready"
```

## Gotchas

- System Events automation requires the host app to be allowed in Privacy & Security → Automation. First failure returns `-1743`.
- UI-scripted fallbacks (key codes, menu clicks) are fragile across macOS updates. Prefer native AppleScript verbs.
