import AppKit
import Foundation

/// A captured Excel data table: numeric columns are pre-parsed for analysis;
/// text columns are kept as group-by keys.
struct ExcelColumn: Sendable, Hashable {
    let name: String
    let stringValues: [String]
    let numericValues: [Double]?   // non-nil when the column is numeric
    var isNumeric: Bool { numericValues != nil }
}

struct ExcelDataTable: Sendable, Hashable {
    let workbookName: String
    let sheetName: String
    let sourceAddress: String
    let filePath: String?
    let columns: [ExcelColumn]
    let rowCount: Int

    var headers: [String] { columns.map(\.name) }
    var numericColumns: [ExcelColumn] { columns.filter { $0.isNumeric } }

    func numericColumn(named name: String) -> ExcelColumn? {
        columns.first { $0.isNumeric && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func column(named name: String) -> ExcelColumn? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

struct ExcelAnalysisRoute {
    let filePath: String?
    let commandContextBlock: String
    let systemPromptSuffix: String
    let table: ExcelDataTable
}

enum ExcelAnalysisPreparation {
    case notExcelAnalysisIntent
    case route(ExcelAnalysisRoute)
    case failure(String)
}

enum ExcelCopilot {
    private static let excelBundleID = "com.microsoft.Excel"
    private static let automationTimeoutSeconds: TimeInterval = 10
    private static let maxCaptureRows = 2_000

    private static var isExcelFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == excelBundleID
    }

    private static var isExcelOpen: Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: excelBundleID)
            .contains { !$0.isTerminated }
    }

    // MARK: - Intent

    static func detectAnalysisIntent(prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let verbs = [
            "regress", "regression", "ols", "least squares",
            "correlate", "correlation", "relationship between",
            "describe", "summary stat", "summary statistic", "summarize this data", "descriptive",
            "trend", "forecast", "project forward", "extrapolate",
            "pivot", "group by", "break down by", "aggregate by",
            "analyze this data", "analyse this data", "run an analysis",
        ]
        return verbs.contains { normalized.contains($0) }
    }

    // MARK: - Route

    static func prepareAnalysisRoute(prompt: String) async -> ExcelAnalysisPreparation {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, detectAnalysisIntent(prompt: trimmed) else { return .notExcelAnalysisIntent }
        guard isExcelFrontmost || isExcelOpen else { return .notExcelAnalysisIntent }

        guard let table = await captureTable() else {
            return .failure("Open a workbook in Microsoft Excel and select a data range (or click any cell in your table), then ask again.")
        }
        guard !table.numericColumns.isEmpty else {
            return .failure("I read the selection in \(table.workbookName), but found no numeric columns to analyze.")
        }

        let headerLine = table.columns.map { col in
            "\(col.name) [\(col.isNumeric ? "numeric" : "text")]"
        }.joined(separator: ", ")
        let sampleRows = (0..<min(10, table.rowCount)).map { rowIndex in
            table.columns.map { col -> String in
                col.stringValues.indices.contains(rowIndex) ? col.stringValues[rowIndex] : ""
            }.joined(separator: "\t")
        }.joined(separator: "\n")

        let contextBlock = """
        Excel data table to analyze:
        - Workbook: \(table.workbookName)
        - Sheet: \(table.sheetName)
        - Range: \(table.sourceAddress)
        - Rows: \(table.rowCount)
        - Columns: \(headerLine)
        - User request: \(trimmed)

        First 10 rows (tab-separated, in column order):
        \(sampleRows)
        """

        let systemPromptSuffix = """

        ## Excel Analysis Mode
        Choose the single most appropriate analysis for the user's request and the columns above.
        DO NOT compute or state any numeric statistics (no coefficients, R², p-values, means) —
        Metamorphia computes every number deterministically. Your job is only to pick the analysis
        and the columns, and to write a one-paragraph plain-language interpretation framed for the user.
        Use exact column header names from the list above.
        Emit exactly one machine-readable block with no code fence:
        [XL_ANALYSIS]
        {"kind":"simpleRegression|multipleRegression|correlation|describe|groupBy|forecast","yColumn":"<dependent/value column or null>","xColumns":["<predictor columns>"],"groupColumn":"<text column for groupBy or null>","interpretation":"One paragraph explaining what this analysis will show the user and how to read it. No numbers."}
        [/XL_ANALYSIS]
        """

        return .route(ExcelAnalysisRoute(
            filePath: table.filePath,
            commandContextBlock: contextBlock,
            systemPromptSuffix: systemPromptSuffix,
            table: table
        ))
    }

    // MARK: - Capture (read-only)

    /// Reads the selected range (if multi-row) or the used range of the active
    /// sheet via AppleScript and parses it into an `ExcelDataTable`.
    private static func captureTable() async -> ExcelDataTable? {
        let script = """
        set _maxRows to \(maxCaptureRows)
        tell application "Microsoft Excel"
            if not (exists active workbook) then return "ERR:noworkbook"
            set ws to active sheet of active workbook
            set rng to used range of ws
            try
                set sel to selection
                if (count of rows of sel) > 1 then set rng to sel
            end try
            set bookPath to ""
            try
                set bookPath to (full name of active workbook) as text
            end try
            set addr to ""
            try
                set addr to (get address of rng) as text
            end try
            set vals to value of rng
            set rowTexts to {}
            set _r to 0
            repeat with rowList in vals
                set _r to _r + 1
                if _r > _maxRows then exit repeat
                set cellTexts to {}
                repeat with c in rowList
                    set theCell to ""
                    try
                        if (contents of c) is not missing value then set theCell to (contents of c) as text
                    end try
                    set end of cellTexts to theCell
                end repeat
                set AppleScript's text item delimiters to tab
                set end of rowTexts to (cellTexts as text)
                set AppleScript's text item delimiters to ""
            end repeat
            set AppleScript's text item delimiters to linefeed
            set bodyText to (rowTexts as text)
            set AppleScript's text item delimiters to ""
            return bookPath & "|||" & (name of ws as text) & "|||" & addr & "@@@" & bodyText
        end tell
        """

        let raw: String?
        do {
            let descriptor = try await AppleScriptHelper.execute(script, timeoutSeconds: automationTimeoutSeconds)
            raw = descriptor?.stringValue
        } catch {
            return nil
        }
        guard let raw, !raw.hasPrefix("ERR:") else { return nil }
        return parseTable(raw)
    }

    private static func parseTable(_ raw: String) -> ExcelDataTable? {
        let parts = raw.components(separatedBy: "@@@")
        guard parts.count == 2 else { return nil }
        let meta = parts[0].components(separatedBy: "|||")
        let workbookPath = meta.indices.contains(0) ? meta[0] : ""
        let sheetName = meta.indices.contains(1) ? meta[1] : "Sheet1"
        let address = meta.indices.contains(2) ? meta[2] : ""
        let workbookName = workbookPath.isEmpty ? "Workbook" : (workbookPath as NSString).lastPathComponent

        let rows = parts[1]
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "\t") }
            .filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
        guard !rows.isEmpty else { return nil }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return nil }

        // Header detection: treat row 0 as headers if most of its cells are non-numeric.
        let firstRow = rows[0]
        let nonNumericInFirst = firstRow.filter { parseNumber($0) == nil && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let hasHeader = nonNumericInFirst >= max(1, firstRow.count / 2)
        let headerRow = hasHeader ? firstRow : []
        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows
        guard !dataRows.isEmpty else { return nil }

        var columns: [ExcelColumn] = []
        for col in 0..<columnCount {
            let name = headerRow.indices.contains(col) && !headerRow[col].trimmingCharacters(in: .whitespaces).isEmpty
                ? headerRow[col]
                : "Column \(col + 1)"
            let cells = dataRows.map { $0.indices.contains(col) ? $0[col] : "" }
            let parsed = cells.map { parseNumber($0) }
            let nonEmpty = cells.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            let numericCount = parsed.compactMap { $0 }.count
            let isNumeric = nonEmpty > 0 && Double(numericCount) / Double(nonEmpty) >= 0.8
            columns.append(ExcelColumn(
                name: name,
                stringValues: cells,
                numericValues: isNumeric ? parsed.map { $0 ?? 0 } : nil
            ))
        }

        return ExcelDataTable(
            workbookName: workbookName,
            sheetName: sheetName,
            sourceAddress: address,
            filePath: workbookPath.isEmpty ? nil : workbookPath,
            columns: columns,
            rowCount: dataRows.count
        )
    }

    /// Forgiving numeric parse: strips currency symbols, thousands separators,
    /// trailing percent (÷100), and parses parenthesized values as negative.
    static func parseNumber(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        var percent = false
        if text.hasSuffix("%") {
            percent = true
            text = String(text.dropLast())
        }
        for symbol in ["$", "€", "£", "¥", ",", " "] {
            text = text.replacingOccurrences(of: symbol, with: "")
        }
        guard let value = Double(text) else { return nil }
        var result = value
        if percent { result /= 100 }
        if negative { result = -result }
        return result
    }

    // MARK: - Deterministic compute

    /// Run the chosen analysis on the captured table. `plan` carries the model's
    /// kind/column selection + interpretation; every number here is computed in Swift.
    static func computeResult(plan: ExcelAnalysisResult, route: ExcelAnalysisRoute) -> ExcelAnalysisResult {
        let table = route.table
        let base = baseResult(plan: plan, route: route)

        switch plan.kind {
        case .simpleRegression, .multipleRegression:
            return regressionResult(plan: plan, table: table, base: base)
        case .correlation:
            return correlationResult(plan: plan, table: table, base: base)
        case .describe:
            return describeResult(plan: plan, table: table, base: base)
        case .groupBy:
            return groupByResult(plan: plan, table: table, base: base)
        case .forecast:
            return forecastResult(plan: plan, table: table, base: base)
        }
    }

    private static func baseResult(plan: ExcelAnalysisResult, route: ExcelAnalysisRoute) -> ExcelAnalysisResult {
        ExcelAnalysisResult(
            kind: plan.kind,
            workbookName: route.table.workbookName,
            sheetName: route.table.sheetName,
            sourceAddress: route.table.sourceAddress,
            sourceFilePath: route.filePath,
            yColumn: plan.yColumn,
            xColumns: plan.xColumns,
            groupColumn: plan.groupColumn,
            interpretation: plan.interpretation
        )
    }

    private static func regressionResult(plan: ExcelAnalysisResult, table: ExcelDataTable, base: ExcelAnalysisResult) -> ExcelAnalysisResult {
        guard let yName = plan.yColumn, let yCol = table.numericColumn(named: yName) else {
            return failureResult(base, "Pick a numeric dependent column for the regression.")
        }
        let xNames = plan.xColumns.isEmpty
            ? table.numericColumns.map(\.name).filter { $0 != yName }.prefix(1).map { $0 }
            : plan.xColumns
        let xCols = xNames.compactMap { table.numericColumn(named: $0) }
        guard !xCols.isEmpty else {
            return failureResult(base, "Pick at least one numeric predictor column.")
        }

        let y = yCol.numericValues ?? []
        let xMatrix = (0..<y.count).map { row in xCols.map { ($0.numericValues ?? [])[row] } }
        guard let fit = RegressionFit.ordinaryLeastSquares(y: y, x: xMatrix, predictorNames: xCols.map(\.name)) else {
            return failureResult(base, "The predictors are collinear or there aren't enough rows. Drop a predictor or add data.")
        }

        let equation = regressionEquation(yName: yName, coefficients: fit.coefficients)
        // Chart: for a single predictor, scatter of (x, y); else fitted vs actual.
        let chart: [ExcelChartPoint]
        let xLabel: String
        if xCols.count == 1 {
            let x = xCols[0].numericValues ?? []
            chart = zip(x, y).map { ExcelChartPoint(x: $0, y: $1) }
            xLabel = xCols[0].name
        } else {
            chart = zip(fit.fitted, y).map { ExcelChartPoint(x: $0, y: $1) }
            xLabel = "Fitted"
        }

        return result(from: base,
            equation: equation,
            coefficients: fit.coefficients,
            rSquared: fit.rSquared,
            adjustedRSquared: fit.adjustedRSquared,
            fStatistic: fit.fStatistic,
            fPValue: fit.fPValue,
            observationCount: fit.observationCount,
            xColumns: xCols.map(\.name),
            chartPoints: chart,
            chartXLabel: xLabel,
            chartYLabel: yName,
            writeBack: regressionWriteOps(yName: yName, xNames: xCols.map(\.name))
        )
    }

    private static func correlationResult(plan: ExcelAnalysisResult, table: ExcelDataTable, base: ExcelAnalysisResult) -> ExcelAnalysisResult {
        let selected = plan.xColumns.isEmpty && plan.yColumn == nil
            ? table.numericColumns
            : ([plan.yColumn].compactMap { $0 } + plan.xColumns).compactMap { table.numericColumn(named: $0) }
        let cols = selected.count >= 2 ? selected : table.numericColumns
        guard cols.count >= 2,
              let matrix = DataTableStats.pearsonMatrix(columns: cols.map { $0.numericValues ?? [] }, names: cols.map(\.name)) else {
            return failureResult(base, "Need at least two numeric columns to correlate.")
        }
        return result(from: base, correlation: matrix, writeBack: correlationWriteOps(names: cols.map(\.name)))
    }

    private static func describeResult(plan: ExcelAnalysisResult, table: ExcelDataTable, base: ExcelAnalysisResult) -> ExcelAnalysisResult {
        let summaries = table.numericColumns.compactMap { DataTableStats.describe($0.numericValues ?? [], name: $0.name) }
        guard !summaries.isEmpty else { return failureResult(base, "No numeric columns to summarize.") }
        return result(from: base, columnSummaries: summaries, writeBack: describeWriteOps(names: summaries.map(\.name)))
    }

    private static func groupByResult(plan: ExcelAnalysisResult, table: ExcelDataTable, base: ExcelAnalysisResult) -> ExcelAnalysisResult {
        guard let groupName = plan.groupColumn ?? table.columns.first(where: { !$0.isNumeric })?.name,
              let groupCol = table.column(named: groupName) else {
            return failureResult(base, "Pick a text column to group by.")
        }
        guard let valueName = plan.yColumn ?? table.numericColumns.first?.name,
              let valueCol = table.numericColumn(named: valueName) else {
            return failureResult(base, "Pick a numeric value column to aggregate.")
        }
        guard let summary = DataTableStats.groupBy(
            keys: groupCol.stringValues,
            values: valueCol.numericValues ?? [],
            groupColumn: groupName,
            valueColumn: valueName
        ) else {
            return failureResult(base, "Couldn't group \(valueName) by \(groupName).")
        }
        return result(from: base, groupSummary: summary)
    }

    private static func forecastResult(plan: ExcelAnalysisResult, table: ExcelDataTable, base: ExcelAnalysisResult) -> ExcelAnalysisResult {
        guard let yName = plan.yColumn ?? table.numericColumns.first?.name,
              let yCol = table.numericColumn(named: yName) else {
            return failureResult(base, "Pick a numeric column to forecast.")
        }
        let xCol = plan.xColumns.first.flatMap { table.numericColumn(named: $0) }
        let x = xCol?.numericValues ?? []
        let y = yCol.numericValues ?? []
        let points = DataTableStats.linearForecast(x: x, y: y, horizon: 5)
        guard !points.isEmpty else { return failureResult(base, "Need at least two rows to project a trend.") }
        let history = x.isEmpty
            ? y.enumerated().map { ExcelChartPoint(x: Double($0.offset), y: $0.element) }
            : zip(x, y).map { ExcelChartPoint(x: $0, y: $1) }
        let forecastChart = points.map { ExcelChartPoint(x: $0.x, y: $0.y) }
        return result(from: base,
            forecast: points,
            chartPoints: history + forecastChart,
            chartXLabel: xCol?.name ?? "Index",
            chartYLabel: yName,
            writeBack: forecastWriteOps(yName: yName, xName: xCol?.name)
        )
    }

    // MARK: - Result assembly helper

    private static func result(
        from base: ExcelAnalysisResult,
        equation: String? = nil,
        coefficients: [RegressionCoefficient]? = nil,
        rSquared: Double? = nil,
        adjustedRSquared: Double? = nil,
        fStatistic: Double? = nil,
        fPValue: Double? = nil,
        observationCount: Int? = nil,
        correlation: CorrelationMatrix? = nil,
        columnSummaries: [ColumnSummary]? = nil,
        groupSummary: GroupSummary? = nil,
        forecast: [ForecastPoint]? = nil,
        xColumns: [String]? = nil,
        chartPoints: [ExcelChartPoint]? = nil,
        chartXLabel: String? = nil,
        chartYLabel: String? = nil,
        writeBack: [ExcelWriteOperation] = []
    ) -> ExcelAnalysisResult {
        ExcelAnalysisResult(
            kind: base.kind,
            workbookName: base.workbookName,
            sheetName: base.sheetName,
            sourceAddress: base.sourceAddress,
            sourceFilePath: base.sourceFilePath,
            yColumn: base.yColumn,
            xColumns: xColumns ?? base.xColumns,
            groupColumn: base.groupColumn,
            equation: equation,
            coefficients: coefficients,
            rSquared: rSquared,
            adjustedRSquared: adjustedRSquared,
            fStatistic: fStatistic,
            fPValue: fPValue,
            observationCount: observationCount,
            correlation: correlation,
            columnSummaries: columnSummaries,
            groupSummary: groupSummary,
            forecast: forecast,
            interpretation: base.interpretation,
            chartPoints: chartPoints,
            chartXLabel: chartXLabel,
            chartYLabel: chartYLabel,
            writeBack: writeBack
        )
    }

    private static func failureResult(_ base: ExcelAnalysisResult, _ message: String) -> ExcelAnalysisResult {
        result(from: base, equation: nil, writeBack: [])
            .withInterpretation(message)
    }

    private static func regressionEquation(yName: String, coefficients: [RegressionCoefficient]) -> String {
        guard let intercept = coefficients.first else { return "" }
        var terms = [String(format: "%.4g", intercept.estimate)]
        for coef in coefficients.dropFirst() {
            let sign = coef.estimate >= 0 ? "+" : "−"
            terms.append("\(sign) \(String(format: "%.4g", abs(coef.estimate)))·\(coef.name)")
        }
        return "\(yName) = \(terms.joined(separator: " "))"
    }

    // MARK: - Write-back formula generation (illustrative; see performAction note)

    private static func regressionWriteOps(yName: String, xNames: [String]) -> [ExcelWriteOperation] {
        if xNames.count == 1 {
            return [
                ExcelWriteOperation(cell: "A1", content: "Regression: \(yName) ~ \(xNames[0])", isFormula: false),
                ExcelWriteOperation(cell: "A2", content: "Slope", isFormula: false),
                ExcelWriteOperation(cell: "B2", content: "=SLOPE(\(yName),\(xNames[0]))", isFormula: true),
                ExcelWriteOperation(cell: "A3", content: "Intercept", isFormula: false),
                ExcelWriteOperation(cell: "B3", content: "=INTERCEPT(\(yName),\(xNames[0]))", isFormula: true),
                ExcelWriteOperation(cell: "A4", content: "R²", isFormula: false),
                ExcelWriteOperation(cell: "B4", content: "=RSQ(\(yName),\(xNames[0]))", isFormula: true),
                ExcelWriteOperation(cell: "A5", content: "Std error", isFormula: false),
                ExcelWriteOperation(cell: "B5", content: "=STEYX(\(yName),\(xNames[0]))", isFormula: true),
            ]
        }
        let xRange = xNames.joined(separator: ", ")
        return [
            ExcelWriteOperation(cell: "A1", content: "Multiple regression: \(yName) ~ \(xRange)", isFormula: false),
            ExcelWriteOperation(cell: "A2", content: "LINEST", isFormula: false),
            ExcelWriteOperation(cell: "B2", content: "=LINEST(\(yName), (\(xRange)), TRUE, TRUE)", isFormula: true, isArrayFormula: true),
        ]
    }

    private static func correlationWriteOps(names: [String]) -> [ExcelWriteOperation] {
        var ops: [ExcelWriteOperation] = [ExcelWriteOperation(cell: "A1", content: "Correlation matrix", isFormula: false)]
        for (i, a) in names.enumerated() {
            for (j, b) in names.enumerated() where j > i {
                ops.append(ExcelWriteOperation(
                    cell: "B\(ops.count + 1)",
                    content: "=CORREL(\(a),\(b))",
                    isFormula: true
                ))
            }
        }
        return ops
    }

    private static func describeWriteOps(names: [String]) -> [ExcelWriteOperation] {
        names.enumerated().flatMap { idx, name -> [ExcelWriteOperation] in
            [
                ExcelWriteOperation(cell: "A\(idx + 2)", content: name, isFormula: false),
                ExcelWriteOperation(cell: "B\(idx + 2)", content: "=AVERAGE(\(name))", isFormula: true),
                ExcelWriteOperation(cell: "C\(idx + 2)", content: "=STDEV(\(name))", isFormula: true),
            ]
        }
    }

    private static func forecastWriteOps(yName: String, xName: String?) -> [ExcelWriteOperation] {
        let x = xName ?? "row index"
        return [
            ExcelWriteOperation(cell: "A1", content: "Forecast of \(yName) on \(x)", isFormula: false),
            ExcelWriteOperation(cell: "B1", content: "=FORECAST.LINEAR(nextX, \(yName), \(xName ?? "x"))", isFormula: true),
        ]
    }

    // MARK: - Actions

    static func performAction(_ action: ExcelAnalysisAction, result: ExcelAnalysisResult) async -> DocumentActionOutcome {
        switch action {
        case .copySummary:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(plainTextSummary(result), forType: .string)
            return DocumentActionOutcome(success: true, message: "Copied the analysis summary to the clipboard.")

        case .jumpToSource:
            // Read-only: select the source range in Excel so the user sees the data.
            guard !result.sourceAddress.isEmpty else {
                return DocumentActionOutcome(success: false, message: "I don't have the source range to jump to.")
            }
            let script = """
            tell application "Microsoft Excel"
                activate
                try
                    select range "\(result.sourceAddress.replacingOccurrences(of: "\"", with: ""))"
                end try
            end tell
            """
            _ = try? await AppleScriptHelper.executeVoid(script)
            return DocumentActionOutcome(success: true, message: "Selected \(result.sourceAddress) in \(result.workbookName).")

        case .writeAnalysisSheet:
            // STUB — pending validation against live Excel.
            //
            // Writing back mutates the user's workbook via AppleScript whose
            // dictionary terms (`formula array` vs dynamic-array `formula`,
            // `chart object`) vary by Excel version, so it is intentionally not
            // wired to modify the file in this build.
            //
            // Intended write-back (per the approved plan): back up the .xlsx via the
            // DocumentCopilot.createBackup pattern, then —
            //   make new worksheet at end of worksheets; set its name to "Analysis";
            //   for each ExcelWriteOperation: set value/formula of range "<cell>" of the
            //     new sheet (use dynamic-array `formula` for LINEST, falling back to
            //     `formula array` of the spilled range on older Excel, both wrapped in `try`);
            //   add a scatter chart object bound to the source range.
            // The formulas reference the source range so the workbook recalculates itself,
            // cross-checking Metamorphia's Swift numbers.
            let formulaPreview = result.writeBack.filter { $0.isFormula }.prefix(3).map(\.content).joined(separator: "  ·  ")
            let detail = formulaPreview.isEmpty ? "" : " Planned formulas: \(formulaPreview)"
            return DocumentActionOutcome(
                success: false,
                message: "Analysis is ready above. Writing the \"Analysis\" sheet into \(result.workbookName) is pending validation against live Excel in an Xcode build, so I haven't modified your workbook yet.\(detail)"
            )
        }
    }

    private static func plainTextSummary(_ result: ExcelAnalysisResult) -> String {
        var lines = ["\(result.kind.displayName) — \(result.workbookName) (\(result.sourceAddress))"]
        if let equation = result.equation { lines.append(equation) }
        if let r2 = result.rSquared { lines.append(String(format: "R² = %.4f", r2)) }
        if let coefficients = result.coefficients {
            for coef in coefficients {
                lines.append(String(format: "%@: %.4g (p = %.3g)", coef.name, coef.estimate, coef.pValue))
            }
        }
        if !result.interpretation.isEmpty { lines.append(result.interpretation) }
        return lines.joined(separator: "\n")
    }
}

private extension ExcelAnalysisResult {
    func withInterpretation(_ text: String) -> ExcelAnalysisResult {
        ExcelAnalysisResult(
            kind: kind,
            workbookName: workbookName,
            sheetName: sheetName,
            sourceAddress: sourceAddress,
            sourceFilePath: sourceFilePath,
            yColumn: yColumn,
            xColumns: xColumns,
            groupColumn: groupColumn,
            equation: equation,
            coefficients: coefficients,
            rSquared: rSquared,
            adjustedRSquared: adjustedRSquared,
            fStatistic: fStatistic,
            fPValue: fPValue,
            observationCount: observationCount,
            correlation: correlation,
            columnSummaries: columnSummaries,
            groupSummary: groupSummary,
            forecast: forecast,
            interpretation: text,
            chartPoints: chartPoints,
            chartXLabel: chartXLabel,
            chartYLabel: chartYLabel,
            writeBack: writeBack
        )
    }
}
