---
name: word-docx
description: Create, read, edit, and polish Microsoft Word documents (.docx, .doc, .rtf). Use for Word document, docx, report, memo, letter, proposal, handout, contract, table of contents, headers/footers, page numbers, comments, tracked-change style review, or converting structured content into a professional Word file. For Apple Pages-only output, use create-pages instead.
emoji: doc.text
os: macOS
requirements: python3, textutil; optional node package docx; optional LibreOffice or Microsoft Word for high-fidelity conversion
---

# Word DOCX Skill

Use this for Microsoft Word-first work. Metamorphia can create useful `.docx` files without Microsoft Word by using macOS `textutil`, and can create richer documents with the optional Node `docx` package.

## Choose The Path

| Task | Preferred path |
| --- | --- |
| Simple report, memo, letter, notes | Generate semantic HTML or RTF, convert with `textutil` |
| Tables, page numbers, headers, footers, images, section layout | Use Node `docx` if installed |
| Read existing `.docx` | `textutil -convert txt -stdout file.docx`, or unzip and inspect `word/document.xml` |
| Edit existing `.docx` | Prefer Word/LibreOffice automation for broad edits; use ZIP/XML edits only for narrow replacements |
| Legacy `.doc` | Convert to `.docx` with Word, LibreOffice, or `textutil` if it can read the file |

Before installing dependencies, ask the user. Do not silently run network installs. Never combine a dependency check with an install fallback in one command. Use a check-only command first; if it fails, either use `textutil`/HTML as a no-install fallback or ask the user before installing.

## Simple Creation With macOS Tools

For most prose documents, create HTML with real headings, lists, and tables, then convert it:

```bash
textutil -convert docx -output output.docx input.html
```

HTML authoring rules:

- Use `<h1>`, `<h2>`, `<p>`, `<ul>`, `<ol>`, and `<table>` instead of visual-only spacing.
- Keep CSS simple: fonts, margins, borders, table padding, and colors.
- Use inline or embedded CSS because conversion tools may ignore external stylesheets.
- Avoid layout tricks that Word may not preserve, such as complex flex/grid CSS.
- For source-heavy documents, include a final "Sources" or "Notes" section.

After conversion, reopen or inspect the document text:

```bash
textutil -convert txt -stdout output.docx
```

## Rich Creation With Node `docx`

Check availability:

```bash
node -e "require('docx'); console.log('docx ok')"
```

If available, create a single generator file and run it. Set page size, margins, styles, and table widths explicitly.

```javascript
const fs = require("fs");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel,
  Table, TableRow, TableCell, WidthType, BorderStyle,
  Header, Footer, PageNumber, AlignmentType
} = require("docx");

const doc = new Document({
  styles: {
    default: { document: { run: { font: "Arial", size: 24 } } },
    paragraphStyles: [
      {
        id: "Heading1",
        name: "Heading 1",
        basedOn: "Normal",
        next: "Normal",
        quickFormat: true,
        run: { font: "Arial", size: 32, bold: true },
        paragraph: { spacing: { before: 240, after: 160 }, outlineLevel: 0 }
      }
    ]
  },
  sections: [{
    properties: {
      page: {
        size: { width: 12240, height: 15840 },
        margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 }
      }
    },
    footers: {
      default: new Footer({
        children: [new Paragraph({
          alignment: AlignmentType.RIGHT,
          children: [new TextRun("Page "), new TextRun({ children: [PageNumber.CURRENT] })]
        })]
      })
    },
    children: [
      new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun("Document Title")] }),
      new Paragraph({ children: [new TextRun("Opening paragraph.")] })
    ]
  }]
});

Packer.toBuffer(doc).then(buf => fs.writeFileSync("output.docx", buf));
```

Important rules:

- Do not put `\n` inside text runs. Use separate `Paragraph` objects.
- Set US Letter explicitly unless the user asks for A4.
- Use real numbering/list APIs instead of manually typed bullet characters.
- For tables, use `WidthType.DXA`; set table width and matching cell widths.
- For images, include alt text when the library supports it.
- Keep generator code small and deterministic.

## Editing Existing DOCX Files

A `.docx` is a ZIP archive. For narrow text replacement:

1. Copy the original to a working file.
2. Unzip into a temporary directory.
3. Edit `word/document.xml` only where needed.
4. Zip from inside the unpacked directory so `[Content_Types].xml` remains at the archive root.
5. Open or convert to text to verify.

Use XML-aware parsing for larger edits. Avoid regex over entire XML documents when changing structure.

Tracked changes and comments are possible through XML, but they are easy to corrupt. Prefer producing a reviewed copy with visible markup in the text unless the user explicitly asks for real Word tracked changes/comments.

## QA Checklist

- Confirm the file extension and saved path.
- Extract text and check for missing sections, placeholder text, and broken ordering.
- For tables, check column counts and headers.
- For generated docs, open the file when possible or convert to PDF/text for inspection.
- If dependencies are missing and installation was not approved, report the exact limitation and the fallback used.
