import Foundation

public struct Parser: Sendable {
    public init() {}

    public func parse(_ descriptor: String) throws -> LayoutModel {
        let trimmed = descriptor.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.emptyDescriptor }

        let segments = trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        var workspaceName: String?
        var columns: [Double]?
        var globalRows: [Double]?
        var indexedRows: [Int: [Double]] = [:]
        var cells: [CellSpec]?

        for segment in segments {
            if segment.hasPrefix("workspace:") {
                workspaceName = String(segment.dropFirst("workspace:".count))
            } else if segment.hasPrefix("grid:") {
                let gridPart = String(segment.dropFirst("grid:".count))
                let parts = gridPart.split(separator: "x")
                guard parts.count == 2,
                      let cols = Int(parts[0]), cols > 0,
                      let rows = Int(parts[1]), rows > 0 else {
                    throw ParseError.invalidSegment(segment)
                }
                columns = equalPercentages(cols)
                if rows > 1 {
                    let rowPcts = equalPercentages(rows)
                    for i in 0..<cols {
                        indexedRows[i] = rowPcts
                    }
                }
            } else if segment.hasPrefix("cols:") {
                columns = try parsePercentages(String(segment.dropFirst("cols:".count)))
            } else if segment.hasPrefix("rows[") {
                guard let closeBracket = segment.firstIndex(of: "]"),
                      let colonIdx = segment.firstIndex(of: ":"),
                      colonIdx > closeBracket else {
                    throw ParseError.invalidSegment(segment)
                }
                let indexStr = segment[segment.index(segment.startIndex, offsetBy: 5)..<closeBracket]
                guard let index = Int(indexStr) else {
                    throw ParseError.invalidSegment(segment)
                }
                let pcts = try parsePercentages(String(segment[segment.index(after: colonIdx)...]))
                indexedRows[index] = pcts
            } else if segment.hasPrefix("rows:") {
                globalRows = try parsePercentages(String(segment.dropFirst("rows:".count)))
            } else if segment.hasPrefix("names:") {
                let tokens = String(segment.dropFirst("names:".count))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                cells = tokens.map { parseCellSpec($0) }
            } else {
                throw ParseError.invalidSegment(segment)
            }
        }

        guard let cols = columns else {
            throw ParseError.missingColumns
        }

        if let gr = globalRows {
            for i in 0..<cols.count {
                if indexedRows[i] == nil {
                    indexedRows[i] = gr
                }
            }
        }

        for index in indexedRows.keys {
            if index < 0 || index >= cols.count {
                throw ParseError.columnIndexOutOfRange(index)
            }
        }

        let model = LayoutModel(
            workspaceName: workspaceName,
            columns: normalize(cols),
            rows: indexedRows.mapValues { normalize($0) },
            cells: cells
        )

        if let c = cells {
            let expected = model.cellCount
            guard c.count == expected else {
                throw ParseError.nameCountMismatch(expected: expected, got: c.count)
            }
        }

        return model
    }

    private func parseCellSpec(_ token: String) -> CellSpec {
        if let eqIndex = token.firstIndex(of: "=") {
            let name = String(token[token.startIndex..<eqIndex])
            let remainder = String(token[token.index(after: eqIndex)...])
            if remainder.hasPrefix("b:") {
                let urlStr = String(remainder.dropFirst(2))
                return CellSpec(name: name, type: .browser(url: urlStr.isEmpty ? nil : urlStr))
            } else if remainder.hasPrefix("t:") {
                return CellSpec(name: name, type: .terminal(command: nil))
            }
            return CellSpec(name: token, type: .terminal(command: nil))
        }
        if token.hasPrefix("b:") {
            let urlStr = String(token.dropFirst(2))
            return CellSpec(name: nil, type: .browser(url: urlStr.isEmpty ? nil : urlStr))
        }
        return CellSpec(name: token, type: .terminal(command: nil))
    }

    private func parsePercentages(_ str: String) throws -> [Double] {
        let parts = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { throw ParseError.invalidPercentages(str) }
        var values: [Double] = []
        for part in parts {
            guard let val = Double(part), val > 0 else {
                throw ParseError.invalidPercentages(str)
            }
            values.append(val)
        }
        return values
    }

    private func equalPercentages(_ count: Int) -> [Double] {
        let base = 100.0 / Double(count)
        var result = Array(repeating: base, count: count)
        let sum = result.dropLast().reduce(0, +)
        result[count - 1] = 100.0 - sum
        return result
    }

    private func normalize(_ percentages: [Double]) -> [Double] {
        let sum = percentages.reduce(0, +)
        guard abs(sum - 100) > 0.01 else { return percentages }
        let factor = 100.0 / sum
        return percentages.map { $0 * factor }
    }
}
