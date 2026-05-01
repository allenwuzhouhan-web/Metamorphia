---
name: browser-automation
description: Open URLs, read tab state, and drive Safari or Chrome via AppleScript. Use when the user says "open this in my browser", "what tab am I on", "close all YouTube tabs".
---

# Browser Automation

Safari and Chrome both have AppleScript dictionaries. Use `run_applescript`.

## Open a URL

Works for any registered URL handler — no browser-specific logic needed:
```bash
open "https://example.com"
open -a "Google Chrome" "https://example.com"     # force a specific browser
```

## Read current tab

Safari:
```applescript
tell application "Safari"
  return {URL of current tab of front window, name of current tab of front window}
end tell
```

Chrome:
```applescript
tell application "Google Chrome"
  return {URL of active tab of window 1, title of active tab of window 1}
end tell
```

## List every open tab

Safari:
```applescript
tell application "Safari"
  set out to ""
  repeat with w in windows
    repeat with t in tabs of w
      set out to out & (URL of t) & " | " & (name of t) & linefeed
    end repeat
  end repeat
  return out
end tell
```

Chrome uses `tabs of window` with `URL` and `title`.

## Close tabs matching a pattern

Safari:
```applescript
tell application "Safari"
  repeat with w in windows
    set toClose to {}
    repeat with t in tabs of w
      if (URL of t) contains "youtube.com" then
        set end of toClose to t
      end if
    end repeat
    repeat with t in toClose
      close t
    end repeat
  end repeat
end tell
```

## Run JavaScript in a tab (Chrome only)

```applescript
tell application "Google Chrome"
  execute active tab of window 1 javascript "document.title"
end tell
```

Safari requires enabling "Allow JavaScript from Apple Events" in Safari → Settings → Advanced → Develop, plus the Develop menu must be enabled. If blocked, Chrome is the easier path.

## Reload / back / forward

- Safari: `tell application "Safari" to do JavaScript "location.reload()" in current tab of front window`
- Chrome: `tell application "Google Chrome" to reload active tab of window 1`

## Gotchas

- First run prompts for Automation access to the browser (`-1743` on denial).
- Chrome's `execute ... javascript` returns a string (or AppleScript-native types for primitives). Complex objects come back as `missing value` — serialize to JSON in the JS side.
- Safari's JavaScript bridge is off by default (privacy). Walk the user through enabling it if they want scripted JS.
- For real scraping, `fetch_url_content` is faster and doesn't depend on a running browser.
