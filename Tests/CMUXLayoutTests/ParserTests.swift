import Testing
@testable import CMUXLayout

@Suite("Parser Tests")
struct ParserTests {
    let parser = Parser()

    @Test func parseGridShorthand3x3() throws {
        let model = try parser.parse("grid:3x3")
        #expect(model.columns.count == 3)
        #expect(model.columns.allSatisfy { abs($0 - 33.33) < 1 })
        #expect(model.rows.count == 3)
        for col in 0..<3 {
            #expect(model.rows[col]?.count == 3)
        }
    }

    @Test func parseGridShorthand2x1() throws {
        let model = try parser.parse("grid:2x1")
        #expect(model.columns == [50, 50])
        #expect(model.rows.isEmpty)
    }

    @Test func parseGridShorthand1x4() throws {
        let model = try parser.parse("grid:1x4")
        #expect(model.columns == [100])
        #expect(model.rows[0]?.count == 4)
    }

    @Test func parseGrid1x1() throws {
        let model = try parser.parse("grid:1x1")
        #expect(model.columns == [100])
        #expect(model.rows.isEmpty)
        #expect(model.cellCount == 1)
    }

    @Test func parseCols() throws {
        let model = try parser.parse("cols:33,33,34")
        #expect(model.columns == [33, 33, 34])
        #expect(model.rows.isEmpty)
    }

    @Test func parseColsWithRows() throws {
        let model = try parser.parse("cols:40,60 | rows[0]:50,50")
        #expect(model.columns == [40, 60])
        #expect(model.rows[0] == [50, 50])
        #expect(model.rows[1] == nil)
    }

    @Test func parseRowsAppliedToAll() throws {
        let model = try parser.parse("cols:33,33,34 | rows:33,33,34")
        #expect(model.rows.count == 3)
        for col in 0..<3 {
            #expect(model.rows[col] == [33, 33, 34])
        }
    }

    @Test func parseRowsIndexedOverridesGlobal() throws {
        let model = try parser.parse("cols:50,50 | rows:50,50 | rows[1]:33,33,34")
        #expect(model.rows[0] == [50, 50])
        #expect(model.rows[1] == [33, 33, 34])
    }

    @Test func parseWorkspaceName() throws {
        let model = try parser.parse("workspace:Dev Layout | cols:50,50")
        #expect(model.workspaceName == "Dev Layout")
        #expect(model.columns == [50, 50])
    }

    @Test func parseNames() throws {
        let model = try parser.parse("cols:30,70 | rows[0]:50,50 | names:editor,terminal,preview")
        let cells = try #require(model.cells)
        #expect(cells.map(\.name) == ["editor", "terminal", "preview"])
        #expect(model.cellCount == 3)
    }

    @Test func parseNameCountMismatch() throws {
        #expect(throws: ParseError.nameCountMismatch(expected: 2, got: 3)) {
            try parser.parse("cols:50,50 | names:a,b,c")
        }
    }

    @Test func parseEmptyDescriptor() throws {
        #expect(throws: ParseError.emptyDescriptor) {
            try parser.parse("")
        }
    }

    @Test func parseMissingColumns() throws {
        #expect(throws: ParseError.missingColumns) {
            try parser.parse("rows:50,50")
        }
    }

    @Test func parseColumnIndexOutOfRange() throws {
        #expect(throws: ParseError.columnIndexOutOfRange(5)) {
            try parser.parse("cols:50,50 | rows[5]:50,50")
        }
    }

    // MARK: - CellSpec parsing

    @Test func parseBareNamesAsCellSpecs() throws {
        let model = try parser.parse("cols:50,50 | names:nav,main")
        let cells = try #require(model.cells)
        #expect(cells.count == 2)
        #expect(cells[0] == CellSpec(name: "nav", type: .terminal))
        #expect(cells[1] == CellSpec(name: "main", type: .terminal))
    }

    @Test func parseNormalizesPercentages() throws {
        let model = try parser.parse("cols:33,33,33")
        let sum = model.columns.reduce(0, +)
        #expect(abs(sum - 100) < 0.01)
    }
}
