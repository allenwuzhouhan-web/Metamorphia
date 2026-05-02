---
name: summarize-document
description: Read a local document (PDF, Pages, Word, plain text, markdown) and produce a summary. Use when the user has a file on their Mac they want condensed, e.g., "summarize this PDF", "tl;dr the report on my desktop".
emoji: doc.text.magnifyingglass
os: macOS
requirements: read_file, optionally run_shell_command for PDF/Pages
---

# Summarize Document

Local-file counterpart to `summarize-url`. Same condense pass, different read step.

## Workflow

1. **Locate the file.** If the user named it, glob it. If they said "the PDF I just downloaded", default to `~/Downloads/` sorted by modification time.
2. **Read.** Pick the right reader for the file type (see below).
3. **Summarize** at the length the user asked for (default: 3–5 bullets + one takeaway).

## Readers by file type

### `.txt`, `.md`, `.csv`, source code
```
read_file path=/path/to/file.md
```

### `.pdf`
Two options:
- macOS Spotlight metadata extractor (built in):
  ```
  run_shell_command command="mdls -name kMDItemTextContent -raw '/path/to/file.pdf'"
  ```
- `pdftotext` from poppler (if installed):
  ```
  run_shell_command command="pdftotext '/path/to/file.pdf' -"
  ```

The Spotlight path is zero-install but truncates very long PDFs. `pdftotext` is faithful but requires `brew install poppler`. Try Spotlight first; fall back if the body looks truncated.

### `.pages`
```
run_shell_command command="textutil -convert txt -stdout '/path/to/doc.pages'"
```
`textutil` ships with macOS and handles `.pages`, `.docx`, `.rtf`, `.html` natively. No install needed.

### `.docx`
```
run_shell_command command="textutil -convert txt -stdout '/path/to/doc.docx'"
```

### `.numbers` / `.xlsx`
Spreadsheets aren't great summary candidates — the structure matters more than the prose. Open in Numbers via `open_url` and ask the user what they want extracted, instead of summarizing blindly.

### `.key`
```
run_shell_command command="textutil -convert txt -stdout '/path/to/deck.key'"
```
This pulls slide text but loses speaker notes and slide order context. For deck summaries, mention this caveat.

## Summary structure

Match the user's ask:
- "tl;dr" / "one-liner" → 1 sentence
- "quick summary" → 3–5 bullets
- "detailed" → 8–12 bullets with section headers matching the document's structure
- "extract all key facts" → bulleted list with quote-marked claims, no commentary

## Long documents

If the extracted text is > ~50KB, summarize in passes:
1. Split into ~10KB chunks at paragraph boundaries.
2. Summarize each chunk in 3–5 bullets.
3. Summarize the bullets together for the final pass.

This is a manual map-reduce — slower than one shot but avoids dropping the second half of the document silently.

## Composing with other skills

- After `summarize-document`: pipe the summary into `word-docx` to write a one-pager, or `apple-notes` to save as a note.
- With `deep-research`: use the document as one source among several and cite it alongside web sources.

## Gotchas

- Encrypted PDFs return empty text from both extractors. Detect ("0 bytes" or one blank line) and tell the user instead of summarizing whitespace.
- Scanned (image-only) PDFs need OCR (`tesseract`) which Metamorphia doesn't ship. Note that the file appears to be image-only and ask the user to OCR first.
- Pages/Numbers/Keynote bundles are zip archives — `read_file` on the bundle path returns binary. Use `textutil` (above), not `read_file`, on iWork files.
