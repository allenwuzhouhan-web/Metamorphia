import Foundation

public enum ExcelAnalysisKind: String, Codable, Sendable, Hashable {
    case simpleRegression
    case multipleRegression
    case correlation
    case describe
    case groupBy
    case forecast

    public var displayName: String {
        switch self {
        case .simpleRegression:   return "Regression"
        case .multipleRegression: return "Multiple regression"
        case .correlation:        return "Correlation"
        case .describe:           return "Summary stats"
        case .groupBy:            return "Group by"
        case .forecast:           return "Forecast"
        }
    }

    public var symbolName: String {
        switch self {
        case .simpleRegression, .multipleRegression: return "chart.xyaxis.line"
        case .correlation:  return "square.grid.3x3"
        case .describe:     return "tablecells"
        case .groupBy:      return "rectangle.3.group"
        case .forecast:     return "chart.line.uptrend.xyaxis"
        }
    }
}

public struct ExcelChartPoint: Codable, Sendable, Hashable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A single cell to write during the (validation-pending) write-back. Formulas
/// reference the source range so the workbook recalculates itself.
public struct ExcelWriteOperation: Codable, Sendable, Hashable {
    public let cell: String       // e.g. "B2"
    public let content: String    // literal label OR "=LINEST(...)"
    public let isFormula: Bool
    public let isArrayFormula: Bool

    public init(cell: String, content: String, isFormula: Bool, isArrayFormula: Bool = false) {
        self.cell = cell
        self.content = content
        self.isFormula = isFormula
        self.isArrayFormula = isArrayFormula
    }
}

public enum ExcelAnalysisAction: Sendable, Hashable {
    case writeAnalysisSheet
    case jumpToSource
    case copySummary
}

/// The LLM's plan: which analysis to run on which columns, plus its narrative.
/// It contains NO computed numbers — Metamorphia computes every statistic.
public struct ExcelAnalysisPlan: Codable, Sendable, Hashable {
    public let kind: ExcelAnalysisKind
    public let yColumn: String?
    public let xColumns: [String]
    public let groupColumn: String?
    public let interpretation: String

    enum CodingKeys: String, CodingKey {
        case kind
        case yColumn
        case xColumns
        case groupColumn
        case interpretation
    }

    public init(kind: ExcelAnalysisKind, yColumn: String?, xColumns: [String], groupColumn: String? = nil, interpretation: String) {
        self.kind = kind
        self.yColumn = yColumn
        self.xColumns = xColumns
        self.groupColumn = groupColumn
        self.interpretation = interpretation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = (try container.decodeIfPresent(String.self, forKey: .kind) ?? "describe")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        kind = ExcelAnalysisPlan.matchKind(kindRaw)
        yColumn = try container.decodeIfPresent(String.self, forKey: .yColumn)
        xColumns = try container.decodeIfPresent([String].self, forKey: .xColumns) ?? []
        groupColumn = try container.decodeIfPresent(String.self, forKey: .groupColumn)
        interpretation = try container.decodeIfPresent(String.self, forKey: .interpretation) ?? ""
    }

    private static func matchKind(_ raw: String) -> ExcelAnalysisKind {
        switch raw {
        case "simpleregression", "regression", "linearregression", "ols": return .simpleRegression
        case "multipleregression", "multiregression": return .multipleRegression
        case "correlation", "correlate", "correlationmatrix": return .correlation
        case "describe", "summary", "summarystats", "descriptive": return .describe
        case "groupby", "group", "pivot", "aggregate": return .groupBy
        case "forecast", "trend", "projection": return .forecast
        default: return .describe
        }
    }
}

public struct ExcelAnalysisResult: Codable, Sendable, Hashable {
    public let kind: ExcelAnalysisKind
    public let workbookName: String
    public let sheetName: String
    public let sourceAddress: String
    public let sourceFilePath: String?
    public let yColumn: String?
    public let xColumns: [String]
    public let groupColumn: String?
    public let equation: String?
    public let coefficients: [RegressionCoefficient]?
    public let rSquared: Double?
    public let adjustedRSquared: Double?
    public let fStatistic: Double?
    public let fPValue: Double?
    public let observationCount: Int?
    public let correlation: CorrelationMatrix?
    public let columnSummaries: [ColumnSummary]?
    public let groupSummary: GroupSummary?
    public let forecast: [ForecastPoint]?
    public let interpretation: String
    public let chartPoints: [ExcelChartPoint]?
    public let chartXLabel: String?
    public let chartYLabel: String?
    public let writeBack: [ExcelWriteOperation]

    public init(
        kind: ExcelAnalysisKind,
        workbookName: String,
        sheetName: String,
        sourceAddress: String,
        sourceFilePath: String? = nil,
        yColumn: String? = nil,
        xColumns: [String] = [],
        groupColumn: String? = nil,
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
        interpretation: String,
        chartPoints: [ExcelChartPoint]? = nil,
        chartXLabel: String? = nil,
        chartYLabel: String? = nil,
        writeBack: [ExcelWriteOperation] = []
    ) {
        self.kind = kind
        self.workbookName = workbookName
        self.sheetName = sheetName
        self.sourceAddress = sourceAddress
        self.sourceFilePath = sourceFilePath
        self.yColumn = yColumn
        self.xColumns = xColumns
        self.groupColumn = groupColumn
        self.equation = equation
        self.coefficients = coefficients
        self.rSquared = rSquared
        self.adjustedRSquared = adjustedRSquared
        self.fStatistic = fStatistic
        self.fPValue = fPValue
        self.observationCount = observationCount
        self.correlation = correlation
        self.columnSummaries = columnSummaries
        self.groupSummary = groupSummary
        self.forecast = forecast
        self.interpretation = interpretation
        self.chartPoints = chartPoints
        self.chartXLabel = chartXLabel
        self.chartYLabel = chartYLabel
        self.writeBack = writeBack
    }
}
