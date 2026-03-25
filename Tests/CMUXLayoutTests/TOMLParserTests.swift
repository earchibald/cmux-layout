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
}
