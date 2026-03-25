import Foundation

/// Describes a complete cmux layout
public struct LayoutModel: Equatable, Sendable {
    public var workspaceName: String?
    public var columns: [Double]
    public var rows: [Int: [Double]]
    public var names: [String]?

    public init(
        workspaceName: String? = nil,
        columns: [Double],
        rows: [Int: [Double]] = [:],
        names: [String]? = nil
    ) {
        self.workspaceName = workspaceName
        self.columns = columns
        self.rows = rows
        self.names = names
    }

    public var cellCount: Int {
        columns.indices.reduce(0) { total, col in
            total + (rows[col]?.count ?? 1)
        }
    }
}

public enum ParseError: Error, Equatable {
    case emptyDescriptor
    case invalidSegment(String)
    case invalidPercentages(String)
    case columnIndexOutOfRange(Int)
    case nameCountMismatch(expected: Int, got: Int)
    case missingColumns
}
