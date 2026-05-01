---
name: apple-mail
description: Read, search, and send mail via Mail.app AppleScript. Use when the user asks "what's in my inbox", "draft an email to X", "find the email from Y".
---

# Apple Mail

Mail.app is scriptable. Use `run_applescript`.

## Unread inbox count

```applescript
tell application "Mail"
  return unread count of inbox
end tell
```

## List recent messages

```applescript
tell application "Mail"
  set recent to messages 1 thru 20 of inbox
  set out to ""
  repeat with m in recent
    set out to out & (subject of m) & " — " & (sender of m) & linefeed
  end repeat
  return out
end tell
```

Accessing `content` downloads the body; it's slow over large inboxes. Fetch subjects/senders first, load body only for the chosen message.

## Search

```applescript
tell application "Mail"
  set matches to (messages of inbox whose subject contains "invoice")
  -- or: whose sender contains "@acme.com"
  -- or: whose date received > (current date) - 7 * days
end tell
```

Compound filters with `and` / `or`. For full-text search, Mail's AppleScript doesn't expose the Spotlight index — iterate and filter in the script.

## Compose a draft

```applescript
tell application "Mail"
  set newMsg to make new outgoing message with properties ¬
    {subject:"Re: contract", content:"Hi Alex,\n\nThoughts inline.\n\n— A", visible:true}
  tell newMsg
    make new to recipient with properties {address:"alex@example.com"}
  end tell
  -- optional: send newMsg
end tell
```

**Default to leaving `visible:true` and skipping `send`** so the user can review. Only send if the user explicitly said "send".

## Reply to a specific message

```applescript
tell application "Mail"
  set target to first message of inbox whose subject contains "invoice"
  set replyMsg to reply target opening window yes
end tell
```

## Gotchas

- First run prompts for Mail access (`-1743` if denied).
- Reading large mailboxes from AppleScript is slow. For > a few dozen messages, consider the `mdfind` Spotlight index via `run_shell_command`: `mdfind -onlyin ~/Library/Mail 'kMDItemTextContent == "*search*"'`.
- Signatures: if the account has a default signature set in Mail preferences, it's appended automatically to new compositions.
