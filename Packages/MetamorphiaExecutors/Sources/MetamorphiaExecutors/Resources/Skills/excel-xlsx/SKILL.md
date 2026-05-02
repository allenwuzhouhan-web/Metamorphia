---
name: excel-xlsx
description: Create, read, edit, clean, analyze, and format Microsoft Excel spreadsheets (.xlsx, .xlsm, .csv, .tsv). Use for Excel, xlsx, spreadsheet, workbook, worksheet, formulas, charts, data cleaning, financial models, pivot-style summaries, tabular deliverables, or converting CSV/TSV data into a professional Excel file. For Apple Numbers-only output, use create-numbers instead.
emoji: tablecells
os: macOS
requirements: python3; optional pandas, openpyxl, xlsxwriter, LibreOffice or Excel for recalculation
---

# Excel XLSX Skill

Use this for Microsoft Excel-first work. Prefer real `.xlsx` output over Apple Numbers exports whenever the user says Excel, spreadsheet, workbook, `.xlsx`, or `.xlsm`.

## Choose The Library

| Task | Preferred tool |
| --- | --- |
| Read/analyze tabular data | pandas |
| Create formatted workbook with formulas | openpyxl or xlsxwriter |
| Modify an existing workbook while preserving formulas/styles | openpyxl |
| Charts in a new workbook | xlsxwriter |
| Recalculate formulas | LibreOffice, Excel, or tell user recalculation needs an Office engine |

Check dependencies first:

```bash
python3 -c "import openpyxl; print('openpyxl ok')"
python3 -c "import pandas; print('pandas ok')"
```

Ask before installing missing packages or using network access. Never combine a dependency check with an install fallback in one command. Use a check-only command first; if it fails, either use a no-install fallback or ask the user before installing.

## Core Rules

- Use Excel formulas for calculated values. Do not compute totals, growth rates, ratios, or scenario outputs in Python and hardcode the results.
- Put assumptions in editable cells and reference them from formulas.
- Preserve an existing workbook's style unless the user asks for redesign.
- Use clear sheet names, frozen header rows, column widths, number formats, and filters.
- For financial models, use conventional colors when appropriate: blue font for hardcoded inputs, black for formulas, green for internal links, red for external links, yellow fill for key assumptions.
- Save a separate output file when editing an existing workbook unless the user explicitly asks to overwrite.

## Create A Workbook With openpyxl

Keep generated scripts compact. If the workbook is complex, create it in stages and verify after each stage rather than sending a very large one-shot script.

```python
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

wb = Workbook()
ws = wb.active
ws.title = "Summary"

headers = ["Item", "Amount", "Share"]
ws.append(headers)
for cell in ws[1]:
    cell.font = Font(bold=True, color="FFFFFF")
    cell.fill = PatternFill("solid", fgColor="1F4E78")
    cell.alignment = Alignment(horizontal="center")

rows = [["Revenue", 125000, None], ["Cost", 72000, None], ["Profit", None, None]]
for row in rows:
    ws.append(row)

ws["B4"] = "=B2-B3"
ws["C2"] = "=B2/$B$2"
ws["C3"] = "=B3/$B$2"
ws["C4"] = "=B4/$B$2"

for cell in ws["B"][1:]:
    cell.number_format = '$#,##0;($#,##0);-'
for cell in ws["C"][1:]:
    cell.number_format = '0.0%'

ws.freeze_panes = "A2"
ws.auto_filter.ref = ws.dimensions
for col in range(1, ws.max_column + 1):
    ws.column_dimensions[get_column_letter(col)].width = 16

wb.save("output.xlsx")
```

## Read Or Clean Data

```python
import pandas as pd

df = pd.read_excel("input.xlsx", sheet_name=0)
df.columns = [str(c).strip() for c in df.columns]
df = df.dropna(how="all")
df.to_excel("cleaned.xlsx", index=False)
```

When cleaning messy files:

- Preserve original data in a separate sheet named `Raw` when useful.
- Put transformed data in `Cleaned` or `Analysis`.
- Record assumptions or dropped-row logic in a `Notes` sheet.

## Recalculation And Error Checks

Openpyxl writes formulas but does not calculate cached results. If formulas matter:

1. Try to recalculate with LibreOffice or Excel if available.
2. Reopen with `data_only=False` to scan formula strings for bad references.
3. Reopen with `data_only=True` only for checking cached values after an Office engine recalculates.

Basic error scan after recalculation:

```python
from openpyxl import load_workbook

wb = load_workbook("output.xlsx", data_only=False)
errors = []
for ws in wb.worksheets:
    for row in ws.iter_rows():
        for cell in row:
            if isinstance(cell.value, str) and cell.value in {"#REF!", "#DIV/0!", "#VALUE!", "#N/A", "#NAME?"}:
                errors.append(f"{ws.title}!{cell.coordinate}: {cell.value}")
print(errors)
```

If recalculation tooling is unavailable, state that formulas were written but cached formula results could not be verified locally.

## QA Checklist

- Confirm workbook opens and path ends in `.xlsx` unless another format was requested.
- Check every formula range for off-by-one errors.
- Check number formats: currency, percentages, years, and negatives.
- Verify no placeholder sheet names or placeholder text remain.
- For user-provided templates, compare changed sheets against the original for unintended style loss.
