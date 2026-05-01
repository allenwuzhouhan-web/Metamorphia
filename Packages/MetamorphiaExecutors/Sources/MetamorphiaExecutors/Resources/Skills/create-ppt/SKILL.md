---
name: create-ppt
description: Generate a Keynote (.key) presentation via AppleScript. Use only when the user explicitly wants Keynote or a .key file. For PowerPoint, .pptx, deck, slides, pitch deck, or presentation work, prefer the pptx skill.
emoji: rectangle.on.rectangle
os: macOS
requirements: Keynote.app installed, run_applescript
---

# Create Keynote Presentation

Keynote is fully scriptable. Build the deck in one AppleScript run, save it, then open it for the user to review.

## Workflow

1. **Outline first.** Write a 3–10 slide outline (title slide + content slides + closing). Confirm the outline with the user before generating — you don't want to author 12 slides only to be told they wanted 4.
2. **Pick a theme.** Default to `"White"` for content-heavy decks, `"Black"` for cinematic decks. The user can re-theme inside Keynote later.
3. **Generate slides** with the AppleScript template below.
4. **Save** to `~/Documents/<short-name>.key` and open it.

## AppleScript template

```applescript
tell application "Keynote"
  activate
  set newDoc to make new document with properties {document theme:theme "White"}
  tell newDoc
    -- Title slide (slide 1 already exists)
    tell slide 1
      set object text of default title item to "Your Title"
      set object text of default body item to "Subtitle or author"
    end tell

    -- Content slides
    set newSlide to make new slide with properties {base slide:master slide "Title & Bullets" of newDoc}
    tell newSlide
      set object text of default title item to "Slide 2 Title"
      set object text of default body item to "First bullet" & return & "Second bullet" & return & "Third bullet"
    end tell

    -- repeat for additional slides

    save in POSIX file "/Users/USERNAME/Documents/deck.key"
  end tell
end tell
```

Replace `USERNAME` by reading `~` via `do shell script "echo $HOME"` and substituting, or pass the path in from outside.

## Master slide names

Built-in masters depend on the theme. For `"White"`:
- `"Title & Subtitle"` — title slide
- `"Title & Bullets"` — typical content slide
- `"Title, Bullets & Photo"` — bullets with image placeholder
- `"Photo"` — full-bleed image
- `"Blank"` — empty canvas

Get the available masters for any theme:
```applescript
tell application "Keynote" to get name of every master slide of front document
```

## Bullets

`object text of default body item` accepts a string with `return` characters separating bullets. Indented bullets aren't easily set programmatically — for nested structure, suggest the user adds them in Keynote after generation.

## Images

To insert an image:
```applescript
tell slide N of newDoc
  make new image with properties {file:POSIX file "/path/to/image.png"}
end tell
```

If the user asked for images you don't have, build the deck without them and note in the chat reply: "I left placeholders for images on slides X, Y — drop yours in via Keynote."

## Saving

`save in POSIX file "..."` writes a `.key` bundle. Use `~/Documents/` as the default directory; ask before writing elsewhere.

To export as PDF:
```applescript
tell application "Keynote"
  export front document to POSIX file "/path/to/deck.pdf" as PDF
end tell
```

## Composing with other skills

- After `deep-research`: pipe the research's section headers into slide titles, the bullets into slide bodies.
- Before `apple-mail`: attach the saved `.key` or exported `.pdf` to a draft email.

## Gotchas

- Keynote must be installed (it's free from the App Store but not pre-installed on every Mac). Check with `tell application "System Events" to exists application process "Keynote"` and gracefully error if missing.
- If Keynote was open with an unsaved document, the new document creation may steal focus. Save the user's existing work first, or warn them.
- The AppleScript template above runs as one block. Don't synthesize multiple `tell application "Keynote"` blocks — each costs a process roundtrip.
