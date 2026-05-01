# Editing Existing PPTX Files

Use this path when a user provides a template or asks to update an existing `.pptx`.

## Read First

Extract text:

```bash
python3 -m markitdown input.pptx
```

Unpack structure:

```bash
mkdir -p /tmp/pptx-edit
unzip -q input.pptx -d /tmp/pptx-edit
find /tmp/pptx-edit/ppt/slides -name 'slide*.xml' | sort
```

Render for visual inspection when possible:

```bash
soffice --headless --convert-to pdf --outdir /tmp input.pptx
pdftoppm -jpeg -r 150 /tmp/input.pdf /tmp/input-slide
```

## Safe Editing Rules

- Preserve the template unless the user asks for a redesign.
- Prefer editing text in existing shapes over rebuilding entire slides.
- Keep relationship files and content type files intact.
- When replacing media, update the relationship target and include the asset in `ppt/media/`.
- Do not leave placeholder text, hidden lorem ipsum, or template notes.
- After XML edits, re-zip from inside the unpacked directory so `[Content_Types].xml` remains at package root.

## Repacking

```bash
cd /tmp/pptx-edit
zip -qr /tmp/edited.pptx .
```

Then run content and visual QA on `/tmp/edited.pptx`.

## When XML Editing Is Too Risky

If the requested edit is broad redesign, many slide additions, or complex layout changes, create a new `.pptx` with `pptxgenjs` and reuse the old deck only as reference material. Mention any fidelity tradeoffs clearly.
