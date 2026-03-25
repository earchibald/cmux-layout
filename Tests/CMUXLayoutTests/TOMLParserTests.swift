import Testing
@testable import CMUXLayout

@Suite("TOML Parser Tests")
struct TOMLParserTests {

    @Test func parseEmptyString() throws {
        let doc = try TOMLParser.parse("")
        #expect(doc.entries.isEmpty)
    }

    @Test func parseCommentLine() throws {
        let doc = try TOMLParser.parse("# a comment")
        #expect(doc.entries.count == 1)
        if case .comment(let text) = doc.entries[0] {
            #expect(text == "# a comment")
        } else {
            Issue.record("Expected comment entry")
        }
    }

    @Test func parseBlankLine() throws {
        let doc = try TOMLParser.parse("\n\n")
        #expect(doc.entries.allSatisfy {
            if case .blank = $0 { return true }
            return false
        })
    }

    @Test func parseTableHeader() throws {
        let doc = try TOMLParser.parse("[settings]")
        #expect(doc.entries.count == 1)
        if case .table(let name) = doc.entries[0] {
            #expect(name == "settings")
        } else {
            Issue.record("Expected table entry")
        }
    }

    @Test func parseDottedTableHeader() throws {
        let doc = try TOMLParser.parse("[templates.dev]")
        if case .table(let name) = doc.entries[0] {
            #expect(name == "templates.dev")
        } else {
            Issue.record("Expected table entry")
        }
    }

    @Test func parseKeyValue() throws {
        let doc = try TOMLParser.parse("key = \"value\"")
        if case .keyValue(let k, let v) = doc.entries[0] {
            #expect(k == "key")
            #expect(v == "value")
        } else {
            Issue.record("Expected keyValue entry")
        }
    }

    @Test func parseEscapedStringValue() throws {
        let doc = try TOMLParser.parse(#"key = "hello \"world\" \\""#)
        if case .keyValue(_, let v) = doc.entries[0] {
            #expect(v == #"hello "world" \"#)
        } else {
            Issue.record("Expected keyValue entry")
        }
    }

    @Test func parseInlineComment() throws {
        let doc = try TOMLParser.parse(#"key = "value" # comment"#)
        if case .keyValue(let k, let v) = doc.entries[0] {
            #expect(k == "key")
            #expect(v == "value")
        } else {
            Issue.record("Expected keyValue entry")
        }
    }

    @Test func parseBareKeyWithDashUnderscore() throws {
        let doc = try TOMLParser.parse(#"my-key_2 = "val""#)
        if case .keyValue(let k, _) = doc.entries[0] {
            #expect(k == "my-key_2")
        } else {
            Issue.record("Expected keyValue entry")
        }
    }

    // MARK: - Serialization

    @Test func serializeEmptyDocument() {
        let doc = TOMLDocument(entries: [])
        #expect(TOMLParser.serialize(doc) == "")
    }

    @Test func roundTripPreservesStructure() throws {
        let input = """
        # cmux-layout configuration
        # Version: 1

        [settings]
        # No settings yet.

        [templates.dev]
        descriptor = "workspace:Dev | cols:25,50,25"
        """
        let doc = try TOMLParser.parse(input)
        let output = TOMLParser.serialize(doc)
        #expect(output == input)
    }

    @Test func roundTripPreservesCommentedOutExample() throws {
        let input = """
        [templates]
        # Example:
        # [templates.dev]
        # descriptor = "grid:2x2"
        """
        let doc = try TOMLParser.parse(input)
        #expect(TOMLParser.serialize(doc) == input)
    }

    // MARK: - Query and mutation API

    @Test func getStringReturnsValue() throws {
        let input = """
        [templates.dev]
        descriptor = "grid:2x2"
        """
        let doc = try TOMLParser.parse(input)
        #expect(doc.getString(table: "templates.dev", key: "descriptor") == "grid:2x2")
    }

    @Test func getStringReturnsNilForMissingKey() throws {
        let input = "[templates.dev]"
        let doc = try TOMLParser.parse(input)
        #expect(doc.getString(table: "templates.dev", key: "nope") == nil)
    }

    @Test func getStringReturnsNilForMissingTable() throws {
        let input = "[settings]"
        let doc = try TOMLParser.parse(input)
        #expect(doc.getString(table: "nope", key: "key") == nil)
    }

    @Test func setStringUpdatesExistingKey() throws {
        let input = """
        [templates.dev]
        descriptor = "grid:2x2"
        """
        var doc = try TOMLParser.parse(input)
        doc.setString(table: "templates.dev", key: "descriptor", value: "grid:3x3")
        #expect(doc.getString(table: "templates.dev", key: "descriptor") == "grid:3x3")
    }

    @Test func setStringAddsNewKeyToExistingTable() throws {
        let input = "[templates.dev]"
        var doc = try TOMLParser.parse(input)
        doc.setString(table: "templates.dev", key: "descriptor", value: "grid:2x2")
        #expect(doc.getString(table: "templates.dev", key: "descriptor") == "grid:2x2")
    }

    @Test func removeTableDeletesTableAndKeys() throws {
        let input = """
        [templates.dev]
        descriptor = "grid:2x2"

        [templates.ops]
        descriptor = "grid:3x3"
        """
        var doc = try TOMLParser.parse(input)
        doc.removeTable("templates.dev")
        #expect(doc.getString(table: "templates.dev", key: "descriptor") == nil)
        #expect(doc.getString(table: "templates.ops", key: "descriptor") == "grid:3x3")
    }

    @Test func insertTableAddsAfterTarget() throws {
        let input = """
        [settings]
        # empty

        [templates]
        # examples here
        """
        var doc = try TOMLParser.parse(input)
        doc.insertTable("templates.dev", after: "templates")
        doc.setString(table: "templates.dev", key: "descriptor", value: "grid:2x2")
        let output = TOMLParser.serialize(doc)
        #expect(output.contains("[templates.dev]"))
        #expect(output.contains("descriptor = \"grid:2x2\""))
    }

    @Test func listTablesWithPrefix() throws {
        let input = """
        [settings]
        [templates]
        [templates.dev]
        descriptor = "grid:2x2"
        [templates.ops]
        descriptor = "grid:3x3"
        """
        let doc = try TOMLParser.parse(input)
        let names = doc.tablesWithPrefix("templates.")
        #expect(names == ["templates.dev", "templates.ops"])
    }

    // MARK: - Unsupported features

    @Test func rejectArraysOfTables() {
        #expect(throws: TOMLError.self) {
            try TOMLParser.parse("[[items]]")
        }
    }

    @Test func rejectBooleanValue() {
        #expect(throws: TOMLError.self) {
            try TOMLParser.parse(#"enabled = true"#)
        }
    }

    @Test func rejectNumericValue() {
        #expect(throws: TOMLError.self) {
            try TOMLParser.parse("port = 8080")
        }
    }

    @Test func rejectArrayValue() {
        #expect(throws: TOMLError.self) {
            try TOMLParser.parse(#"items = ["a", "b"]"#)
        }
    }

    @Test func rejectInlineTableValue() {
        #expect(throws: TOMLError.self) {
            try TOMLParser.parse(#"point = { x = 1, y = 2 }"#)
        }
    }

    @Test func rejectUnterminatedString() {
        #expect(throws: TOMLError.self) {
            try TOMLParser.parse(#"key = "unclosed"#)
        }
    }
}
