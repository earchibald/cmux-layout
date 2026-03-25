import Foundation

public enum SurfaceType: Equatable, Sendable {
    case terminal(command: String?)
    case browser(url: String?)
}

public struct CellSpec: Equatable, Sendable {
    public let name: String?
    public let type: SurfaceType

    public init(name: String? = nil, type: SurfaceType = .terminal(command: nil)) {
        self.name = name
        self.type = type
    }
}

public struct LayoutModel: Equatable, Sendable {
    public var workspaceName: String?
    public var columns: [Double]
    public var rows: [Int: [Double]]
    public var cells: [CellSpec]?

    public init(
        workspaceName: String? = nil,
        columns: [Double],
        rows: [Int: [Double]] = [:],
        cells: [CellSpec]? = nil
    ) {
        self.workspaceName = workspaceName
        self.columns = columns
        self.rows = rows
        self.cells = cells
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
