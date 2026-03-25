import Foundation

public struct Serializer: Sendable {
    public init() {}

    public func serialize(_ model: LayoutModel) -> String {
        if let gridStr = tryGridShorthand(model) {
            var parts: [String] = []
            if let name = model.workspaceName {
                parts.append("workspace:\(name)")
            }
            parts.append(gridStr)
            if let cells = model.cells {
                parts.append("names:\(cells.map { $0.name ?? "" }.joined(separator: ","))")
            }
            return parts.joined(separator: " | ")
        }

        var parts: [String] = []
        if let name = model.workspaceName {
            parts.append("workspace:\(name)")
        }
        parts.append("cols:\(formatPercentages(model.columns))")

        let rowConfigs = model.rows
        if !rowConfigs.isEmpty {
            let values = Array(rowConfigs.values)
            let allSame = values.dropFirst().allSatisfy { $0 == values[0] }
            let coversAll = rowConfigs.count == model.columns.count

            if allSame && coversAll {
                parts.append("rows:\(formatPercentages(values[0]))")
            } else {
                for index in rowConfigs.keys.sorted() {
                    parts.append("rows[\(index)]:\(formatPercentages(rowConfigs[index]!))")
                }
            }
        }

        if let cells = model.cells {
            parts.append("names:\(cells.map { $0.name ?? "" }.joined(separator: ","))")
        }

        return parts.joined(separator: " | ")
    }

    private func tryGridShorthand(_ model: LayoutModel) -> String? {
        guard model.columns.count >= 1 else { return nil }
        let colPct = 100.0 / Double(model.columns.count)
        let colsEqual = model.columns.allSatisfy { abs($0 - colPct) < 0.5 }
        guard colsEqual else { return nil }

        if model.rows.isEmpty {
            return nil
        }

        guard model.rows.count == model.columns.count else { return nil }
        let firstRows = model.rows[0]!
        guard model.rows.values.allSatisfy({ $0 == firstRows }) else { return nil }

        let rowPct = 100.0 / Double(firstRows.count)
        let rowsEqual = firstRows.allSatisfy { abs($0 - rowPct) < 0.5 }
        guard rowsEqual else { return nil }

        return "grid:\(model.columns.count)x\(firstRows.count)"
    }

    private func formatPercentages(_ pcts: [Double]) -> String {
        pcts.map { pct in
            pct == pct.rounded() ? String(Int(pct)) : String(format: "%.1f", pct)
        }.joined(separator: ",")
    }
}
