import Foundation

public enum SplitDirection: Equatable, Sendable {
    case right, down
}

public enum ResizeAxis: Equatable, Sendable {
    case horizontal, vertical
}

public struct SplitOp: Equatable, Sendable {
    public let direction: SplitDirection
    public let columnIndex: Int?
}

public struct ResizeOp: Equatable, Sendable {
    public let axis: ResizeAxis
    public let targetFraction: Double
    public let columnIndex: Int?
    public let dividerIndex: Int
}

public struct OperationPlan: Equatable, Sendable {
    public let splits: [SplitOp]
    public let resizes: [ResizeOp]
}

public struct Planner: Sendable {
    public init() {}

    public func plan(_ model: LayoutModel) -> OperationPlan {
        var splits: [SplitOp] = []
        var resizes: [ResizeOp] = []

        let colCount = model.columns.count

        for _ in 1..<colCount {
            splits.append(SplitOp(direction: .right, columnIndex: nil))
        }

        for col in 0..<colCount {
            let rowCount = model.rows[col]?.count ?? 1
            for _ in 1..<rowCount {
                splits.append(SplitOp(direction: .down, columnIndex: col))
            }
        }

        if colCount > 1 {
            let cumulative = cumulativePercentages(model.columns)
            let isTwo5050 = colCount == 2 && model.columns.allSatisfy { abs($0 - 50) < 0.5 }
            if !isTwo5050 {
                for (i, fraction) in cumulative.enumerated() {
                    resizes.append(ResizeOp(
                        axis: .horizontal,
                        targetFraction: fraction,
                        columnIndex: nil,
                        dividerIndex: i
                    ))
                }
            }
        }

        for col in 0..<colCount {
            guard let rowPcts = model.rows[col], rowPcts.count > 1 else { continue }
            let cumulative = cumulativePercentages(rowPcts)
            let isTwo5050 = rowPcts.count == 2 && rowPcts.allSatisfy { abs($0 - 50) < 0.5 }
            if !isTwo5050 {
                for (i, fraction) in cumulative.enumerated() {
                    resizes.append(ResizeOp(
                        axis: .vertical,
                        targetFraction: fraction,
                        columnIndex: col,
                        dividerIndex: i
                    ))
                }
            }
        }

        return OperationPlan(splits: splits, resizes: resizes)
    }

    private func cumulativePercentages(_ pcts: [Double]) -> [Double] {
        var result: [Double] = []
        var cumulative = 0.0
        for pct in pcts.dropLast() {
            cumulative += pct / 100.0
            result.append(cumulative)
        }
        return result
    }
}
