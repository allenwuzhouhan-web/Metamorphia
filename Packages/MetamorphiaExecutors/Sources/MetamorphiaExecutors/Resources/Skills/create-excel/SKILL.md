---
name: create-numbers
description: Generate an Apple Numbers (.numbers) spreadsheet via AppleScript. Use only when the user explicitly asks for Numbers, iWork, or a .numbers file. For Excel, .xlsx, workbook, CSV cleanup, formulas, charts, or spreadsheet deliverables, prefer the excel-xlsx skill.
emoji: tablecells
os: macOS
requirements: Numbers.app installed, run_applescript
---

# Create Numbers Spreadsheet

Numbers is the Apple iWork spreadsheet. Strong AppleScript support for cell values and formulas. For a true Excel workbook, use `excel-xlsx` instead of exporting from Numbers unless the user explicitly wants the iWork route.

## Workflow

1. **Define the schema.** What are the columns? How many rows? Are there formulas, totals, charts? Confirm with the user.
2. **Pick a template.** Default to `"Blank"` for raw data, `"Personal Budget"` / `"Invoice"` etc. for known formats. List with `tell application "Numbers" to get name of every template`.
3. **Generate.** Header row first, then data rows, then formulas.
4. **Save** to `~/Documents/<short-name>.numbers` and open.

## AppleScript template

```applescript
tell application "Numbers"
  activate
  set newDoc to make new document with properties {document template:template "Blank"}
  tell newDoc
    tell active sheet
      tell table 1
        -- Resize the table.
        set row count to 12
        set column count to 4

        -- Header row.
        set value of cell "A1" to "Date"
        set value of cell "B1" to "Item"
        set value of cell "C1" to "Amount"
        set value of cell "D1" to "Category"

        -- Data rows.
        set value of cell "A2" to "2026-04-16"
        set value of cell "B2" to "Coffee"
        set value of cell "C2" to 4.50
        set value of cell "D2" to "Food"

        -- Repeat for each row, or use a loop in your AppleScript generator.

        -- Formula in last row.
        set value of cell "A12" to "Total"
        set value of cell "C12" to "=SUM(C2:C11)"
      end tell
    end tell
    save in POSIX file "/Users/USERNAME/Documents/expenses.numbers"
  end tell
end tell
```

Replace `USERNAME` with the result of `do shell script "echo $HOME"`.

## Bulk loading rows

For >20 rows, prefer a `repeat with i from 2 to N` loop in AppleScript over individual cell assignments. Each `set value of cell ...` is a process roundtrip; loops batch them in the same `tell` block.

```applescript
repeat with i from 2 to 11
  set value of cell ("A" & i) to (item (i - 1) of dateList)
  set value of cell ("B" & i) to (item (i - 1) of itemList)
  set value of cell ("C" & i) to (item (i - 1) of amountList)
end repeat
```

For >500 rows, write a CSV first and have Numbers import it:
```applescript
tell application "Numbers"
  open POSIX file "/path/to/data.csv"
end tell
```

## Formulas

Numbers formula syntax matches Excel (`SUM`, `AVERAGE`, `IF`, `VLOOKUP`, `XLOOKUP`, etc.). Pass the formula as a string starting with `=`. Cell refs are A1-style.

## Charts

AppleScript can't create charts directly. If the user wants a chart, generate the data and tell them to select the range and pick "Insert > Chart" in Numbers — that's a 2-click step.

## Export to .xlsx (Microsoft Excel)

```applescript
tell application "Numbers"
  export front document to POSIX file "/path/to/expenses.xlsx" as Microsoft Excel
end tell
```

This is an iWork fallback, not the preferred Excel path. Use `excel-xlsx` for Office-first work.

## Composing with other skills

- After `deep-research`: structure the findings as a comparison table.
- Before `apple-mail`: export to `.xlsx` and attach.
- With CSVs from `run_shell_command` (e.g., `ls -la | awk ...`): parse the CSV into a Numbers table.

## Gotchas

- Numbers must be installed (free on the App Store).
- Setting cell values in a `tell table 1` block on a fresh document works because every blank Numbers doc has one default table. If you create more tables, address them by name (`tell table "Table 1"`) to avoid index drift.
- Date cells: passing a Cocoa `current date` works; passing an arbitrary string like `"2026-04-16"` makes Numbers store it as text. For sortable dates, use AppleScript's date constructor: `date "April 16, 2026"`.
- Real Microsoft Excel automation requires Excel.app and a different AppleScript dictionary (`tell application "Microsoft Excel"`).
