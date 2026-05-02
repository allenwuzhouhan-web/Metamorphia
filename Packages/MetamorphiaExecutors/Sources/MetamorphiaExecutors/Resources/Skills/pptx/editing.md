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
- Remove unused placeholder shapes; do not leave blank boxes or hidden lorem ipsum.
- Re-zip from inside the unpacked directory so `[Content_Types].xml` remains at package root.

## Slide Operations

Slide order lives in `ppt/presentation.xml` under `<p:sldIdLst>`.

- Reorder slides by rearranging `<p:sldId>` elements.
- Delete slides by removing the corresponding `<p:sldId>` and then cleaning unreferenced slide files and relationships.
- Duplicate slides only when you also duplicate relationships, notes references, and content type entries.

If structural XML edits become broad or risky, create a new `.pptx` with `pptxgenjs` and use the old deck only as a visual/content reference.

## Editing Text

For each slide:

1. Read the slide XML.
2. Identify all placeholder content: text, images, charts, icons, captions, and notes.
3. Replace the smallest reliable XML block.
4. Preserve run properties (`<a:rPr>`) where possible so typography survives.
5. Re-render the slide to catch overflow.

Formatting rules:

- Use separate `<a:p>` paragraphs for separate bullets or list items.
- Avoid manually typed bullet characters when the layout already supplies bullets.
- Copy existing paragraph properties when adding new paragraphs.
- Add XML entities for smart quotes if needed: `&#x201C;`, `&#x201D;`, `&#x2018;`, `&#x2019;`.
- Add `xml:space="preserve"` on text nodes with leading or trailing spaces.

## Repacking

```bash
cd /tmp/pptx-edit
zip -qr /tmp/edited.pptx .
```

Then run content and visual QA on `/tmp/edited.pptx`.
