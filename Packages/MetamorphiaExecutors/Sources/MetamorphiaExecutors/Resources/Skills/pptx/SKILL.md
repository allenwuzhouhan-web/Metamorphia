---
name: pptx
description: Use this skill whenever a PowerPoint file, .pptx deck, slide deck, presentation, pitch deck, template, speaker notes, or slide comments are involved as input or output. Use for creating complete PowerPoint decks from scratch, reading or extracting deck content, editing existing presentations, combining/splitting decks, and rendering decks for QA. For Keynote-only output, use create-ppt instead.
emoji: rectangle.on.rectangle
os: macOS
requirements: python3; optional markitdown[pptx], pptxgenjs, LibreOffice/soffice, pdftoppm
---

# PowerPoint PPTX Skill

Use this for PowerPoint-first work. The older `create-ppt` skill is Keynote-only and writes `.key`; prefer this skill whenever the user says PowerPoint, ppt, pptx, deck, slides, slide deck, pitch deck, or presentation unless they explicitly ask for Keynote.

## Quick Reference

| Task | Path |
| --- | --- |
| Read or analyze deck content | `python3 -m markitdown input.pptx` when installed; otherwise unzip and inspect `ppt/slides/*.xml` |
| Create a complete deck from scratch | Use `pptxgenjs` when available; see bundled `pptxgenjs.md` |
| Edit an existing deck/template | Preserve the template; see bundled `editing.md` |
| Visual QA | Render to PDF/images, inspect, fix, and re-render affected slides |

Metamorphia loads adjacent guides with this skill. If commands refer to support files, use the support directory shown by `load_skill`, not the current user document directory.

Ask before installing missing dependencies. Do not silently fetch network packages. Never combine a dependency check with an install fallback in one command. Use a check-only command first; if it fails, either use an installed fallback such as `python-pptx`/AppleScript or ask the user before installing.

## Reading Content

```bash
python3 -m markitdown presentation.pptx
```

If MarkItDown is unavailable, `.pptx` is a ZIP package:

```bash
mkdir -p /tmp/pptx-unpacked
unzip -q presentation.pptx -d /tmp/pptx-unpacked
find /tmp/pptx-unpacked/ppt/slides -name 'slide*.xml' -print
```

For quick text extraction without extra dependencies, parse slide XML and decode XML entities. Keep slide order by sorting `slide1.xml`, `slide2.xml`, etc. naturally.

## Creating Complete Decks

For a new deck, prefer `pptxgenjs` when available because it writes real `.pptx` files directly and supports layouts, shapes, images, tables, notes, and speaker-friendly typography. Read the bundled `pptxgenjs.md` before authoring.

Do not create plain title-and-bullet slides throughout. Every slide should include a visual element: shape system, icon, diagram, chart, stat callout, timeline, image, or structured cards.

## Editing Existing Decks

For template reuse or precise updates, read the bundled `editing.md`. The safe workflow is:

1. Inspect deck text and layout.
2. Render thumbnails or PDF images if possible.
3. Unpack the `.pptx`.
4. Modify the minimal set of XML or generate replacement slides.
5. Repack and verify content.

## Design Rules

- Pick a topic-specific palette, not default blue.
- Give one color clear dominance, one or two supporting tones, and one accent.
- Vary layouts across slides: title, two-column, cards, timeline, comparison, stat callout, and conclusion.
- Use at least 0.5 inch slide margins and 0.3-0.5 inch internal gaps.
- Use strong type hierarchy: titles 36-44 pt, section headers 20-24 pt, body 14-16 pt, captions 10-12 pt.
- Left-align body text. Center only title-only moments or intentional hero text.
- Avoid title underlines. Use whitespace, background fields, side rails, cards, or contrast panels instead.
- Avoid low contrast, cramped cards, placeholder text, and text-only slides.

## Suggested Palettes

| Theme | Primary | Secondary | Accent |
| --- | --- | --- | --- |
| Midnight Executive | `1E2761` | `CADCFC` | `FFFFFF` |
| Forest & Moss | `2C5F2D` | `97BC62` | `F5F5F5` |
| Coral Energy | `F96167` | `F9E795` | `2F3C7E` |
| Warm Terracotta | `B85042` | `E7E8D1` | `A7BEAE` |
| Ocean Gradient | `065A82` | `1C7293` | `21295C` |
| Charcoal Minimal | `36454F` | `F2F2F2` | `212121` |
| Teal Trust | `028090` | `00A896` | `02C39A` |
| Berry & Cream | `6D2E46` | `A26769` | `ECE2D0` |
| Sage Calm | `84B59F` | `69A297` | `50808E` |
| Cherry Bold | `990011` | `FCF6F5` | `2F3C7E` |

## Font Pairings

| Header | Body |
| --- | --- |
| Georgia | Calibri |
| Arial Black | Arial |
| Calibri | Calibri Light |
| Cambria | Calibri |
| Trebuchet MS | Calibri |
| Impact | Arial |
| Palatino | Garamond |
| Consolas | Calibri |

## QA Required

Assume the first render has problems. Do at least one inspect-fix-verify loop before calling the deck done.

Content QA:

```bash
python3 -m markitdown output.pptx
python3 -m markitdown output.pptx | grep -iE "xxxx|lorem|ipsum|this.*(page|slide).*layout|placeholder"
```

Visual QA:

```bash
soffice --headless --convert-to pdf --outdir /tmp output.pptx
pdftoppm -jpeg -r 150 /tmp/output.pdf /tmp/slide
```

Inspect rendered slide images for:

- Overlap between text, icons, lines, shapes, and footers.
- Cut-off text or text that overflows a shape.
- Titles wrapping into decorative elements.
- Margins under 0.5 inch.
- Gaps under 0.3 inch or uneven spacing between repeated elements.
- Low-contrast text/icons.
- Excessive wrapping from narrow boxes.
- Leftover placeholder text.

Fix issues, regenerate, and re-check affected slides.
