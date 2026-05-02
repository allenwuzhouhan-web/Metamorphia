# Creating PPTX From Scratch With PptxGenJS

Use this path when the user wants a complete new PowerPoint deck and there is no template deck to preserve.

## Setup Check

```bash
node -e "require('pptxgenjs'); console.log('pptxgenjs ok')"
```

If the dependency is missing, ask before installing. Do not silently fetch network dependencies. Do not write check-or-install commands such as `node -e ... || npm install ...`.

## Authoring Pattern

Create one JavaScript generator file in the working directory, run it, then QA the resulting `.pptx`. Keep the generator compact; for complex decks, generate a first pass, inspect, then patch or regenerate rather than sending an oversized one-shot script.

```javascript
const pptxgen = require("pptxgenjs");

const pptx = new pptxgen();
pptx.layout = "LAYOUT_WIDE";
pptx.author = "Metamorphia";
pptx.subject = "Generated presentation";
pptx.title = "Deck title";
pptx.company = "Metamorphia";
pptx.lang = "en-US";
pptx.theme = {
  headFontFace: "Aptos Display",
  bodyFontFace: "Aptos",
  lang: "en-US"
};

const C = {
  primary: "1E2761",
  secondary: "CADCFC",
  accent: "F96167",
  bg: "FFFFFF",
  text: "111827",
  muted: "4B5563"
};

function title(slide, text, opts = {}) {
  slide.addText(text, {
    x: opts.x ?? 0.55,
    y: opts.y ?? 0.42,
    w: opts.w ?? 12.2,
    h: opts.h ?? 0.6,
    fontFace: "Aptos Display",
    fontSize: opts.size ?? 40,
    bold: true,
    color: opts.color ?? C.text,
    margin: 0,
    breakLine: false,
    fit: "shrink"
  });
}

function body(slide, text, x, y, w, h, opts = {}) {
  slide.addText(text, {
    x, y, w, h,
    fontFace: "Aptos",
    fontSize: opts.size ?? 15,
    color: opts.color ?? C.text,
    margin: 0.08,
    breakLine: false,
    fit: "shrink",
    valign: "top"
  });
}

function card(slide, x, y, w, h, heading, copy) {
  slide.addShape(pptx.ShapeType.roundRect, {
    x, y, w, h,
    rectRadius: 0.08,
    fill: { color: "F8FAFC" },
    line: { color: "D8DEE9", width: 1 }
  });
  slide.addText(heading, {
    x: x + 0.18,
    y: y + 0.18,
    w: w - 0.36,
    h: 0.28,
    fontSize: 16,
    bold: true,
    color: C.primary,
    margin: 0,
    fit: "shrink"
  });
  body(slide, copy, x + 0.18, y + 0.58, w - 0.36, h - 0.76, { color: C.muted, size: 12 });
}

{
  const slide = pptx.addSlide();
  slide.background = { color: C.primary };
  title(slide, "Deck title", { y: 2.2, color: "FFFFFF", size: 44 });
  slide.addText("Specific, audience-aware subtitle", {
    x: 0.6, y: 3.05, w: 8.5, h: 0.4,
    fontSize: 18, color: C.secondary, margin: 0
  });
  slide.addShape(pptx.ShapeType.rect, {
    x: 10.6, y: 0, w: 2.75, h: 7.5,
    fill: { color: C.accent }, line: { color: C.accent }
  });
}

pptx.writeFile({ fileName: "output.pptx" });
```

## Layout Guidance

Use varied slide structures:

- Title: dark or high-contrast hero, one visual motif.
- Agenda: 3-5 cards or numbered rows.
- Content: two-column, card grid, process flow, or comparison.
- Data: large number callouts or chart-like shapes.
- Conclusion: strong final statement plus action list.

Keep slide elements inside a 0.5 inch margin. Use `fit: "shrink"` on text boxes that may wrap, but still size boxes conservatively.

## Common Pitfalls

- Set `margin: 0` for titles and precise alignment.
- Prefer shapes and simple diagrams over long bullets.
- Use image paths only when files exist locally.
- Use `charSpacing`, not `letterSpacing`.
- Do not use negative shadow offsets.
- Do not use typed bullet characters when using PptxGenJS bullet options.
- Add speaker notes only if requested.
