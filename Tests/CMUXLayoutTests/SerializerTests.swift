import Testing
@testable import CMUXLayout

@Suite("Serializer Tests")
struct SerializerTests {
    let serializer = Serializer()
    let parser = Parser()

    @Test func serializeSimpleCols() {
        let model = LayoutModel(columns: [33, 33, 34])
        let result = serializer.serialize(model)
        #expect(result == "cols:33,33,34")
    }

    @Test func serializeColsWithRows() {
        let model = LayoutModel(columns: [40, 60], rows: [0: [50, 50]])
        let result = serializer.serialize(model)
        #expect(result == "cols:40,60 | rows[0]:50,50")
    }

    @Test func serializeWorkspaceName() {
        let model = LayoutModel(workspaceName: "Dev", columns: [50, 50])
        let result = serializer.serialize(model)
        #expect(result == "workspace:Dev | cols:50,50")
    }

    @Test func serializeNames() {
        let model = LayoutModel(columns: [50, 50], names: ["a", "b"])
        let result = serializer.serialize(model)
        #expect(result == "cols:50,50 | names:a,b")
    }

    @Test func serializeUniformRowsAsGlobal() {
        let model = LayoutModel(columns: [60, 40], rows: [0: [50, 50], 1: [50, 50]])
        let result = serializer.serialize(model)
        #expect(result == "cols:60,40 | rows:50,50")
    }

    @Test func serializeGridShorthand() {
        let model = LayoutModel(
            columns: [50, 50],
            rows: [0: [50, 50], 1: [50, 50]]
        )
        let result = serializer.serialize(model)
        #expect(result == "grid:2x2")
    }

    @Test func roundTripColsWithIndexedRows() throws {
        let original = "cols:25,50,25 | rows[0]:60,40 | rows[1]:33,33,34"
        let model = try parser.parse(original)
        let serialized = serializer.serialize(model)
        let reparsed = try parser.parse(serialized)
        #expect(model == reparsed)
    }

    @Test func roundTripGrid() throws {
        let original = "grid:4x3"
        let model = try parser.parse(original)
        let serialized = serializer.serialize(model)
        #expect(serialized == "grid:4x3")
    }
}
