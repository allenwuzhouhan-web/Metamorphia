---
name: create-word
description: Generate a Pages (.pages) document via AppleScript — write title, headings, body paragraphs, save to disk. Use when the user says "write a document about X", "draft a memo", "create a Pages doc".
emoji: doc.text
os: macOS
requirements: Pages.app installed, run_applescript
---

# Create Pages Document

Pages is the Apple iWork word processor. Less scriptable than Keynote, but enough to create a styled document with title, headings, and body paragraphs. (For a true `.docx`, see the Microsoft Word section below.)

## Workflow

1. **Outline first.** Confirm the document's structure (title, sections, length) with the user before generating.
2. **Pick a template.** Default to `"Blank"` for prose, `"Letter"` for letters, `"Report"` for structured reports. Get the full list with `tell application "Pages" to get name of every template`.
3. **Generate.**
4. **Save** to `~/Documents/<short-name>.pages` and open.

## AppleScript template

```applescript
tell application "Pages"
  activate
  set newDoc to make new document with properties {document template:template "Blank"}
  tell newDoc
    -- Pages exposes the body as a single text block. Build the whole body
    -- as one string with paragraph breaks, then assign.
    set body text to "Document Title" & return & return & ¬
      "## Section 1" & return & ¬
      "Opening paragraph goes here. Pages will style this as body text by default. " & ¬
      "Add another sentence here." & return & return & ¬
      "## Section 2" & return & ¬
      "Second section content."

    save in POSIX file "/Users/USERNAME/Documents/memo.pages"
  end tell
end tell
```

Replace `USERNAME` with the result of `do shell script "echo $HOME"`.

## Headings and styles

Pages styles aren't directly settable via AppleScript on every property — `body text` accepts plain text. To apply heading styles, the cleanest path is to write the document, then have the user select-and-style. To programmatically style:

```applescript
tell application "System Events" to tell process "Pages"
  -- Use UI scripting against the Format > Paragraph Style menu.
  -- Brittle across Pages versions; only do this when the user explicitly
  -- needs structured headings before opening the file.
end tell
```

Prefer plain markdown-flavored body text and let the user run a "Format > Paragraph Style > Heading 1" pass after opening if styling matters.

## Export to .docx (Microsoft Word)

If the user actually needs `.docx`:

```applescript
tell application "Pages"
  export front document to POSIX file "/path/to/memo.docx" as Microsoft Word
end tell
```

This is the only way to produce a `.docx` from Metamorphia today — there's no native tool for direct `.docx` writing. The export preserves text, basic styles, and lists.

## Composing with other skills

- After `deep-research`: pipe the report into the body, sections become Pages sections.
- Before `apple-mail`: export to PDF or `.docx` and attach to a draft.
- With `summarize-document`: read a long doc, write a one-page summary as a new Pages file.

## Gotchas

- Pages must be installed (free on the App Store, not always pre-installed). Check before scripting.
- AppleScript's `body text` assignment can be slow for very long documents (> 50 pages). For long-form, write to a `.txt` file first and have Pages open it.
- Pages templates beyond `"Blank"` come pre-populated with placeholder text. Setting `body text` will overwrite the placeholders, so the styling baked into the template may not propagate cleanly. For non-blank templates, generate using UI scripting instead, or accept that the result will look like a plain blank doc.
- Real Microsoft Word automation requires Word.app and a different AppleScript dictionary entirely (`tell application "Microsoft Word"`). Only attempt that if the user has Word installed.
