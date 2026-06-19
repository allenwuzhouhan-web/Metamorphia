import Foundation
import CoreGraphics

/// A named XY series for scatter/line plotting.
public struct DataSeries: Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var points: [CGPoint]

    public init(id: UUID = UUID(), name: String, points: [CGPoint]) {
        self.id = id
        self.name = name
        self.points = points
    }
}

/// Parses CSV / TSV text (e.g. pasted from the clipboard) into one or more `DataSeries`.
///
/// Layout assumptions, in order of robustness:
///   • The first column is the shared X axis.
///   • Every remaining numeric column becomes its own Y series.
///   • A non-numeric first row is treated as a header and supplies series names.
///   • With a single numeric column, X is the row index (0, 1, 2, …).
///
/// The parser is forgiving: it auto-detects the delimiter, tolerates quoted fields,
/// blank lines, thousands separators, and rows of differing length, and never crashes
/// on malformed input — it simply skips cells/rows it can't read.
public enum CSVPlotParser {

    public static func parse(_ text: String) -> [DataSeries] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rawLines.isEmpty else { return [] }

        let delimiter = detectDelimiter(in: rawLines)
        let rows = rawLines.map { splitFields($0, delimiter: delimiter) }

        // Determine column count from the widest row.
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount >= 1 else { return [] }

        // Detect a header row: present when the first row has no parseable number in
        // any column that later rows fill with numbers.
        let firstRowNumbers = rows[0].map { parseNumber($0) }
        let hasHeader = rows.count > 1 && firstRowNumbers.allSatisfy { $0 == nil }
            && !rows[0].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }

        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows
        let headers = hasHeader ? rows[0] : []

        if columnCount == 1 {
            return parseSingleColumn(dataRows, header: headers.first)
        }
        return parseMultiColumn(dataRows, columnCount: columnCount, headers: headers)
    }

    // MARK: - Column strategies

    private static func parseSingleColumn(_ rows: [[String]], header: String?) -> [DataSeries] {
        var points: [CGPoint] = []
        for (index, row) in rows.enumerated() {
            guard let cell = row.first, let y = parseNumber(cell) else { continue }
            points.append(CGPoint(x: Double(index), y: y))
        }
        guard !points.isEmpty else { return [] }
        let name = header.map(cleanName) ?? "Series 1"
        return [DataSeries(name: name.isEmpty ? "Series 1" : name, points: points)]
    }

    private static func parseMultiColumn(_ rows: [[String]],
                                         columnCount: Int,
                                         headers: [String]) -> [DataSeries] {
        // First column is X; build one series per remaining column.
        var seriesPoints: [[CGPoint]] = Array(repeating: [], count: max(columnCount - 1, 0))

        for row in rows {
            guard let xCell = row.first, let x = parseNumber(xCell) else { continue }
            for col in 1..<columnCount {
                guard col < row.count, let y = parseNumber(row[col]) else { continue }
                seriesPoints[col - 1].append(CGPoint(x: x, y: y))
            }
        }

        var result: [DataSeries] = []
        for (offset, pts) in seriesPoints.enumerated() where !pts.isEmpty {
            let columnIndex = offset + 1
            let rawName = columnIndex < headers.count ? cleanName(headers[columnIndex]) : ""
            let name = rawName.isEmpty ? "Series \(offset + 1)" : rawName
            result.append(DataSeries(name: name, points: pts))
        }
        return result
    }

    // MARK: - Lexing helpers

    /// Picks the delimiter that yields the most consistent, widest split across rows.
    private static func detectDelimiter(in lines: [String]) -> Character {
        let candidates: [Character] = ["\t", ",", ";", "|"]
        let sample = Array(lines.prefix(10))
        var best: Character = ","
        var bestScore = -1.0

        for delimiter in candidates {
            let counts = sample.map { line in
                splitFields(line, delimiter: delimiter).count
            }
            let maxCols = counts.max() ?? 0
            guard maxCols > 1 else { continue }
            // Reward many columns and consistency (low variance in column count).
            let mean = Double(counts.reduce(0, +)) / Double(max(counts.count, 1))
            let variance = counts.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
                / Double(max(counts.count, 1))
            let score = Double(maxCols) - variance
            if score > bestScore {
                bestScore = score
                best = delimiter
            }
        }
        return best
    }

    /// Splits a single line on `delimiter`, honouring double-quoted fields.
    private static func splitFields(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()

        while let c = pending {
            pending = iterator.next()
            if c == "\"" {
                if inQuotes && pending == "\"" {
                    current.append("\"")     // escaped quote
                    pending = iterator.next()
                } else {
                    inQuotes.toggle()
                }
            } else if c == delimiter && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        fields.append(current)
        return fields
    }

    /// Parses a numeric cell, tolerating surrounding whitespace, quotes, currency
    /// symbols, thousands separators, trailing percent, and parenthesised negatives.
    private static func parseNumber(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        text = text.replacingOccurrences(of: "\"", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Accounting-style negatives: (1,234) -> -1234
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }

        // Strip a leading currency symbol and a trailing percent.
        var isPercent = false
        if text.hasSuffix("%") {
            isPercent = true
            text = String(text.dropLast())
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "$€£¥ "))

        // Remove thousands separators (commas) but keep the decimal dot.
        text = text.replacingOccurrences(of: ",", with: "")

        guard var value = Double(text), value.isFinite else { return nil }
        if isPercent { value /= 100 }
        if negative { value = -value }
        return value
    }

    /// Tidies a header cell into a display name.
    private static func cleanName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
