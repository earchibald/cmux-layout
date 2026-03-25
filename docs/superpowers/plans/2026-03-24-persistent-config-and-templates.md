# Persistent Config and Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the JSON-based ProfileStore with a TOML-based config system that holds settings and workspace templates in a single self-documenting `config.toml` file.

**Architecture:** A minimal hand-rolled TOML parser handles the subset we need (tables, string key/values, comments). A ConfigManager sits on top, handling scaffold creation, version upgrades, and template CRUD. The CLI rewires `save`/`load`/`list` to ConfigManager and adds a `config` subcommand.

**Tech Stack:** Swift 6.0, Foundation-only, Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-03-24-persistent-config-and-templates-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `Sources/CMUXLayout/TOMLParser.swift` | Create: Parse/serialize minimal TOML subset with round-trip fidelity |
| `Sources/CMUXLayout/ConfigManager.swift` | Create: Bootstrap, version management, template CRUD, settings access |
| `Tests/CMUXLayoutTests/TOMLParserTests.swift` | Create: Parser unit tests |
| `Tests/CMUXLayoutTests/ConfigManagerTests.swift` | Create: Config manager unit tests |
| `Sources/cmux-layout/main.swift` | Modify: Rewire save/load/list, add config subcommand, update usage |
| `Sources/CMUXLayout/ProfileStore.swift` | Delete: Replaced by ConfigManager |

---

### Task 1: TOMLParser — Data Model and Basic Parsing

**Files:**
- Create: `Sources/CMUXLayout/TOMLParser.swift`
- Create: `Tests/CMUXLayoutTests/TOMLParserTests.swift`

- [ ] **Step 1: Write failing tests for entry types and basic parsing**

```swift
import Testing
@testable import CMUXLayout

@Suite("TOML Parser Tests")
struct TOMLParserTests {

    // MARK: - Parse basic structures

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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter TOMLParserTests 2>&1 | tail -20`
Expected: FAIL — `TOMLParser` not defined

- [ ] **Step 3: Implement TOMLParser with entry types and parse function**

Create `Sources/CMUXLayout/TOMLParser.swift`:

```swift
import Foundation

public enum TOMLEntry: Equatable, Sendable {
    case blank
    case comment(String)       // full line including "# "
    case table(String)         // table name, e.g. "templates.dev"
    case keyValue(String, String) // key, value (unescaped)
}

public struct TOMLDocument: Equatable, Sendable {
    public var entries: [TOMLEntry]

    public init(entries: [TOMLEntry] = []) {
        self.entries = entries
    }
}

public enum TOMLError: Error, Equatable {
    case unterminatedString(Int)     // line number
    case invalidLine(Int, String)    // line number, content
    case unsupportedFeature(Int, String) // line number, description
}

public struct TOMLParser: Sendable {
    public init() {}

    public static func parse(_ input: String) throws -> TOMLDocument {
        let lines = input.components(separatedBy: "\n")
        var entries: [TOMLEntry] = []

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .init(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineNum = lineIndex + 1

            // blank line
            if trimmed.isEmpty {
                entries.append(.blank)
                continue
            }

            // comment line
            if trimmed.hasPrefix("#") {
                entries.append(.comment(line))
                continue
            }

            // table header
            if trimmed.hasPrefix("[") {
                // reject arrays-of-tables
                if trimmed.hasPrefix("[[") {
                    throw TOMLError.unsupportedFeature(lineNum, "arrays-of-tables ([[...]])")
                }
                guard let close = trimmed.firstIndex(of: "]") else {
                    throw TOMLError.invalidLine(lineNum, line)
                }
                let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    throw TOMLError.invalidLine(lineNum, line)
                }
                entries.append(.table(name))
                continue
            }

            // key = value
            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                throw TOMLError.invalidLine(lineNum, line)
            }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            guard isValidBareKey(key) else {
                throw TOMLError.invalidLine(lineNum, line)
            }
            let afterEq = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)
            let value = try parseStringValue(afterEq, lineNum: lineNum)
            entries.append(.keyValue(key, value))
        }

        // remove trailing blank if input ended without newline
        if let last = entries.last, case .blank = last, !input.hasSuffix("\n") {
            // keep it — parse is line-based, trailing blank from split is expected
        }

        return TOMLDocument(entries: entries)
    }

    private static func isValidBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func parseStringValue(_ raw: String, lineNum: Int) throws -> String {
        var s = raw
        guard s.hasPrefix("\"") else {
            // check for unsupported value types
            if s == "true" || s == "false" {
                throw TOMLError.unsupportedFeature(lineNum, "boolean values")
            }
            if s.first?.isNumber == true || s.first == "-" || s.first == "+" {
                throw TOMLError.unsupportedFeature(lineNum, "numeric values")
            }
            if s.hasPrefix("[") {
                throw TOMLError.unsupportedFeature(lineNum, "array values")
            }
            if s.hasPrefix("{") {
                throw TOMLError.unsupportedFeature(lineNum, "inline table values")
            }
            throw TOMLError.invalidLine(lineNum, raw)
        }
        s.removeFirst() // opening quote

        var result = ""
        var escaped = false
        var closed = false
        for ch in s {
            if escaped {
                switch ch {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append("\\"); result.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                closed = true
                break
            } else {
                result.append(ch)
            }
        }
        guard closed else {
            throw TOMLError.unterminatedString(lineNum)
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter TOMLParserTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/TOMLParser.swift Tests/CMUXLayoutTests/TOMLParserTests.swift
git commit -m "feat: add TOML parser with basic parsing and entry types"
```

---

### Task 2: TOMLParser — Serialization and Round-Trip

**Files:**
- Modify: `Sources/CMUXLayout/TOMLParser.swift`
- Modify: `Tests/CMUXLayoutTests/TOMLParserTests.swift`

- [ ] **Step 1: Write failing tests for serialization and round-trip**

Append to `TOMLParserTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter TOMLParserTests 2>&1 | tail -20`
Expected: FAIL — `serialize` not defined

- [ ] **Step 3: Implement serialize function**

Add to `TOMLParser` struct in `TOMLParser.swift`:

```swift
    public static func serialize(_ doc: TOMLDocument) -> String {
        var lines: [String] = []
        for entry in doc.entries {
            switch entry {
            case .blank:
                lines.append("")
            case .comment(let text):
                lines.append(text)
            case .table(let name):
                lines.append("[\(name)]")
            case .keyValue(let key, let value):
                lines.append("\(key) = \"\(escapeString(value))\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func escapeString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter TOMLParserTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/TOMLParser.swift Tests/CMUXLayoutTests/TOMLParserTests.swift
git commit -m "feat: add TOML serializer with round-trip fidelity"
```

---

### Task 3: TOMLParser — Higher-Level Query/Mutation API

**Files:**
- Modify: `Sources/CMUXLayout/TOMLParser.swift`
- Modify: `Tests/CMUXLayoutTests/TOMLParserTests.swift`

- [ ] **Step 1: Write failing tests for getString, setString, removeTable, insertTable**

Append to `TOMLParserTests.swift`:

```swift
    // MARK: - Query and mutation API

    @Test func getStringReturnsValue() throws {
        let input = """
        [templates.dev]
        descriptor = "grid:2x2"
        """
        var doc = try TOMLParser.parse(input)
        #expect(doc.getString(table: "templates.dev", key: "descriptor") == "grid:2x2")
    }

    @Test func getStringReturnsNilForMissingKey() throws {
        let input = "[templates.dev]"
        var doc = try TOMLParser.parse(input)
        #expect(doc.getString(table: "templates.dev", key: "nope") == nil)
    }

    @Test func getStringReturnsNilForMissingTable() throws {
        let input = "[settings]"
        var doc = try TOMLParser.parse(input)
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
        var doc = try TOMLParser.parse(input)
        let names = doc.tablesWithPrefix("templates.")
        #expect(names == ["templates.dev", "templates.ops"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter TOMLParserTests 2>&1 | tail -20`
Expected: FAIL — methods not defined

- [ ] **Step 3: Implement query/mutation methods on TOMLDocument**

Add as extension on `TOMLDocument` in `TOMLParser.swift`:

```swift
extension TOMLDocument {
    /// Returns the index range of entries belonging to a table (header + its key/values).
    private func tableRange(_ name: String) -> (headerIndex: Int, endIndex: Int)? {
        guard let headerIdx = entries.firstIndex(where: {
            if case .table(let n) = $0 { return n == name }
            return false
        }) else { return nil }

        var end = headerIdx + 1
        while end < entries.count {
            if case .table(_) = entries[end] { break }
            end += 1
        }
        return (headerIdx, end)
    }

    public func getString(table: String, key: String) -> String? {
        guard let range = tableRange(table) else { return nil }
        for i in (range.headerIndex + 1)..<range.endIndex {
            if case .keyValue(let k, let v) = entries[i], k == key {
                return v
            }
        }
        return nil
    }

    public mutating func setString(table: String, key: String, value: String) {
        guard let range = tableRange(table) else { return }
        // update existing
        for i in (range.headerIndex + 1)..<range.endIndex {
            if case .keyValue(let k, _) = entries[i], k == key {
                entries[i] = .keyValue(key, value)
                return
            }
        }
        // append new key after last non-blank entry in table
        var insertAt = range.endIndex
        // back up past trailing blanks
        while insertAt > range.headerIndex + 1 {
            if case .blank = entries[insertAt - 1] { insertAt -= 1 }
            else { break }
        }
        entries.insert(.keyValue(key, value), at: insertAt)
    }

    public mutating func removeTable(_ name: String) {
        guard let range = tableRange(name) else { return }
        // also remove a trailing blank line if present
        var end = range.endIndex
        if end < entries.count, case .blank = entries[end] { end += 1 }
        entries.removeSubrange(range.headerIndex..<end)
    }

    public mutating func insertTable(_ name: String, after: String) {
        if let range = tableRange(after) {
            entries.insert(.blank, at: range.endIndex)
            entries.insert(.table(name), at: range.endIndex + 1)
        } else {
            entries.append(.blank)
            entries.append(.table(name))
        }
    }

    public func tablesWithPrefix(_ prefix: String) -> [String] {
        entries.compactMap {
            if case .table(let name) = $0, name.hasPrefix(prefix) { return name }
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter TOMLParserTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/TOMLParser.swift Tests/CMUXLayoutTests/TOMLParserTests.swift
git commit -m "feat: add TOML document query and mutation API"
```

---

### Task 4: TOMLParser — Error Cases for Unsupported Features

**Files:**
- Modify: `Tests/CMUXLayoutTests/TOMLParserTests.swift`

- [ ] **Step 1: Write tests for unsupported TOML features**

Append to `TOMLParserTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they pass** (implementation already handles these)

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter TOMLParserTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Tests/CMUXLayoutTests/TOMLParserTests.swift
git commit -m "test: add TOML parser error cases for unsupported features"
```

---

### Task 5: ConfigManager — Scaffold and Bootstrap

**Files:**
- Create: `Sources/CMUXLayout/ConfigManager.swift`
- Create: `Tests/CMUXLayoutTests/ConfigManagerTests.swift`

- [ ] **Step 1: Write failing tests for scaffold creation**

```swift
import Testing
import Foundation
@testable import CMUXLayout

@Suite("Config Manager Tests")
struct ConfigManagerTests {
    /// Create a temp directory and return its path. Caller is responsible for cleanup.
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "cmux-layout-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func bootstrapCreatesConfigFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        let mgr = try ConfigManager(path: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func bootstrapScaffoldContainsVersionAndSections() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        let mgr = try ConfigManager(path: path)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("# Version: 1"))
        #expect(content.contains("[settings]"))
        #expect(content.contains("[templates]"))
    }

    @Test func bootstrapPreservesExistingFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        // Create initial
        let _ = try ConfigManager(path: path)
        // Save a template
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "grid:2x2")
        // Re-bootstrap — should preserve template
        let mgr2 = try ConfigManager(path: path)
        let templates = try mgr2.list()
        #expect(templates.count == 1)
        #expect(templates[0].name == "dev")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -20`
Expected: FAIL — `ConfigManager` not defined

- [ ] **Step 3: Implement ConfigManager with bootstrap**

Create `Sources/CMUXLayout/ConfigManager.swift`:

```swift
import Foundation

public enum ConfigError: Error, Equatable {
    case templateNotFound(String)
    case versionTooNew(fileVersion: Int, maxSupported: Int)
    case invalidConfig(String)
}

public struct ConfigManager: Sendable {
    public static let currentSchemaVersion = 1
    private let path: String
    private var document: TOMLDocument

    public static let defaultScaffold = """
    # cmux-layout configuration
    # Version: 1

    [settings]
    # No settings defined yet. Future options will appear here.

    [templates]
    # Save workspace templates using: cmux-layout save <name> <descriptor>
    # Example:
    # [templates.dev]
    # descriptor = "workspace:Dev | cols:25,50,25 | rows[0]:60,40"
    """

    public init(path: String? = nil) throws {
        self.path = path
            ?? (NSHomeDirectory() + "/.config/cmux-layout/config.toml")

        let dir = (self.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: self.path) {
            let content = try String(contentsOfFile: self.path, encoding: .utf8)
            self.document = try TOMLParser.parse(content)
            try checkVersion()
        } else {
            self.document = try TOMLParser.parse(Self.defaultScaffold)
            try save()
        }
    }

    // MARK: - Version management

    private func fileVersion() -> Int? {
        for entry in document.entries {
            if case .comment(let text) = entry {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# Version:") {
                    let numStr = trimmed.dropFirst("# Version:".count)
                        .trimmingCharacters(in: .whitespaces)
                    return Int(numStr)
                }
            }
        }
        return nil
    }

    private func checkVersion() throws {
        guard let version = fileVersion() else { return } // no version = v1 assumed
        if version > Self.currentSchemaVersion {
            throw ConfigError.versionTooNew(
                fileVersion: version,
                maxSupported: Self.currentSchemaVersion
            )
        }
        // future: if version < currentSchemaVersion, run upgrade
    }

    // MARK: - Persistence

    private func save() throws {
        let content = TOMLParser.serialize(document)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Public path accessor

    public var configPath: String { path }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -20`
Expected: All tests PASS (except `save`/`list` — those are next task)

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/ConfigManager.swift Tests/CMUXLayoutTests/ConfigManagerTests.swift
git commit -m "feat: add ConfigManager with bootstrap and version check"
```

---

### Task 6: ConfigManager — Template CRUD

**Files:**
- Modify: `Sources/CMUXLayout/ConfigManager.swift`
- Modify: `Tests/CMUXLayoutTests/ConfigManagerTests.swift`

- [ ] **Step 1: Write failing tests for save, load, list, delete**

Append to `ConfigManagerTests.swift`:

```swift
    // MARK: - Template CRUD

    @Test func saveAndLoadTemplate() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.save(name: "dev", descriptor: "grid:2x2")
        let loaded = try mgr.load(name: "dev")
        #expect(loaded == "grid:2x2")
    }

    @Test func saveValidatesDescriptor() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        #expect(throws: ParseError.self) {
            try mgr.save(name: "bad", descriptor: "not-a-valid-descriptor")
        }
    }

    @Test func loadThrowsForMissingTemplate() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let mgr = try ConfigManager(path: dir + "/config.toml")
        #expect(throws: ConfigError.self) {
            try mgr.load(name: "nope")
        }
    }

    @Test func listReturnsAllTemplatesSorted() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.save(name: "zeta", descriptor: "grid:2x2")
        try mgr.save(name: "alpha", descriptor: "grid:3x3")
        let all = try mgr.list()
        #expect(all.count == 2)
        #expect(all[0].name == "alpha")
        #expect(all[1].name == "zeta")
    }

    @Test func deleteRemovesTemplate() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.save(name: "dev", descriptor: "grid:2x2")
        try mgr.delete(name: "dev")
        #expect(throws: ConfigError.self) {
            try mgr.load(name: "dev")
        }
    }

    @Test func savePersistsAcrossInstances() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr1 = try ConfigManager(path: path)
        try mgr1.save(name: "dev", descriptor: "grid:2x2")
        let mgr2 = try ConfigManager(path: path)
        let loaded = try mgr2.load(name: "dev")
        #expect(loaded == "grid:2x2")
    }

    @Test func saveOverwritesExistingTemplate() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.save(name: "dev", descriptor: "grid:2x2")
        try mgr.save(name: "dev", descriptor: "grid:3x3")
        let loaded = try mgr.load(name: "dev")
        #expect(loaded == "grid:3x3")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -20`
Expected: FAIL — `save`, `load`, `list`, `delete` not defined

- [ ] **Step 3: Implement template CRUD methods**

Add to `ConfigManager` struct:

```swift
    // MARK: - Template CRUD

    public mutating func save(name: String, descriptor: String) throws {
        // validate descriptor
        _ = try Parser().parse(descriptor)

        let tableName = "templates.\(name)"
        if document.getString(table: tableName, key: "descriptor") != nil {
            // update existing
            document.setString(table: tableName, key: "descriptor", value: descriptor)
        } else {
            // create new table after [templates] or last templates.* table
            let existing = document.tablesWithPrefix("templates.")
            let insertAfter = existing.last ?? "templates"
            document.insertTable(tableName, after: insertAfter)
            document.setString(table: tableName, key: "descriptor", value: descriptor)
        }
        try self.save()
    }

    public func load(name: String) throws -> String {
        let tableName = "templates.\(name)"
        guard let descriptor = document.getString(table: tableName, key: "descriptor") else {
            throw ConfigError.templateNotFound(name)
        }
        return descriptor
    }

    public func list() throws -> [(name: String, descriptor: String)] {
        document.tablesWithPrefix("templates.")
            .compactMap { tableName in
                let name = String(tableName.dropFirst("templates.".count))
                guard let desc = document.getString(table: tableName, key: "descriptor") else {
                    return nil
                }
                return (name: name, descriptor: desc)
            }
            .sorted { $0.name < $1.name }
    }

    public mutating func delete(name: String) throws {
        let tableName = "templates.\(name)"
        guard document.getString(table: tableName, key: "descriptor") != nil else {
            throw ConfigError.templateNotFound(name)
        }
        document.removeTable(tableName)
        try self.save()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/ConfigManager.swift Tests/CMUXLayoutTests/ConfigManagerTests.swift
git commit -m "feat: add template CRUD to ConfigManager"
```

---

### Task 7: ConfigManager — Version Upgrade Logic

**Files:**
- Modify: `Sources/CMUXLayout/ConfigManager.swift`
- Modify: `Tests/CMUXLayoutTests/ConfigManagerTests.swift`

- [ ] **Step 1: Write failing tests for version upgrade and downgrade detection**

Append to `ConfigManagerTests.swift`:

```swift
    // MARK: - Version management

    @Test func rejectNewerVersion() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        let content = """
        # cmux-layout configuration
        # Version: 999

        [settings]
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: ConfigError.self) {
            try ConfigManager(path: path)
        }
    }

    @Test func upgradeFromOlderVersion() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        // Simulate a v0 file (hypothetical older version with no templates section)
        let content = """
        # cmux-layout configuration
        # Version: 0

        [settings]
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        // Should upgrade to current version, adding missing sections
        let mgr = try ConfigManager(path: path)
        let updated = try String(contentsOfFile: path, encoding: .utf8)
        #expect(updated.contains("# Version: \(ConfigManager.currentSchemaVersion)"))
        #expect(updated.contains("[templates]"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -20`
Expected: FAIL — upgrade logic not implemented

- [ ] **Step 3: Implement version upgrade logic**

Update `checkVersion()` and add upgrade methods in `ConfigManager`:

```swift
    private mutating func checkVersion() throws {
        let version = fileVersion() ?? 0
        if version > Self.currentSchemaVersion {
            throw ConfigError.versionTooNew(
                fileVersion: version,
                maxSupported: Self.currentSchemaVersion
            )
        }
        if version < Self.currentSchemaVersion {
            try upgradeFrom(version: version)
        }
    }

    private mutating func upgradeFrom(version: Int) throws {
        var v = version

        if v < 1 {
            // v0 -> v1: ensure [templates] section exists
            if document.tablesWithPrefix("templates").isEmpty {
                // Insert after [settings] if present, else at end
                document.insertTable("templates", after: "settings")
                // Add example comments
                if let range = document.tableRange("templates") {
                    document.entries.insert(
                        .comment("# Save workspace templates using: cmux-layout save <name> <descriptor>"),
                        at: range.headerIndex + 1
                    )
                    document.entries.insert(
                        .comment("# Example:"),
                        at: range.headerIndex + 2
                    )
                    document.entries.insert(
                        .comment("# [templates.dev]"),
                        at: range.headerIndex + 3
                    )
                    document.entries.insert(
                        .comment(#"# descriptor = "workspace:Dev | cols:25,50,25 | rows[0]:60,40""#),
                        at: range.headerIndex + 4
                    )
                }
            }
            v = 1
        }

        // Update version comment
        updateVersionComment(to: Self.currentSchemaVersion)
        try save()
    }

    private mutating func updateVersionComment(to version: Int) {
        for (i, entry) in document.entries.enumerated() {
            if case .comment(let text) = entry,
               text.trimmingCharacters(in: .whitespaces).hasPrefix("# Version:") {
                document.entries[i] = .comment("# Version: \(version)")
                return
            }
        }
    }
```

Note: `tableRange` needs to be made `internal` (not `private`) in `TOMLDocument` for `ConfigManager` to use it. Update the access level in `TOMLParser.swift`:

```swift
    // Change from: private func tableRange
    // Change to:   func tableRange
    func tableRange(_ name: String) -> (headerIndex: Int, endIndex: Int)? {
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/TOMLParser.swift Sources/CMUXLayout/ConfigManager.swift Tests/CMUXLayoutTests/ConfigManagerTests.swift
git commit -m "feat: add config version upgrade logic"
```

---

### Task 8: ConfigManager — Settings Access (Future-Proofing)

**Files:**
- Modify: `Sources/CMUXLayout/ConfigManager.swift`
- Modify: `Tests/CMUXLayoutTests/ConfigManagerTests.swift`

- [ ] **Step 1: Write failing tests for getSetting/setSetting**

Append to `ConfigManagerTests.swift`:

```swift
    // MARK: - Settings

    @Test func getSettingReturnsNilWhenEmpty() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let mgr = try ConfigManager(path: dir + "/config.toml")
        #expect(mgr.getSetting(key: "anything") == nil)
    }

    @Test func setAndGetSetting() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        var mgr = try ConfigManager(path: dir + "/config.toml")
        try mgr.setSetting(key: "some-option", value: "enabled")
        #expect(mgr.getSetting(key: "some-option") == "enabled")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -20`
Expected: FAIL — methods not defined

- [ ] **Step 3: Implement settings access**

Add to `ConfigManager`:

```swift
    // MARK: - Settings

    public func getSetting(key: String) -> String? {
        document.getString(table: "settings", key: key)
    }

    public mutating func setSetting(key: String, value: String) throws {
        document.setString(table: "settings", key: key, value: value)
        try save()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/ConfigManager.swift Tests/CMUXLayoutTests/ConfigManagerTests.swift
git commit -m "feat: add settings read/write to ConfigManager"
```

---

### Task 9: CLI — Rewire save/load/list to ConfigManager

**Files:**
- Modify: `Sources/cmux-layout/main.swift:164-210`

- [ ] **Step 1: Update handleSave to use ConfigManager**

Replace `handleSave` (lines 164-174):

```swift
    static func handleSave(_ args: [String]) throws {
        guard args.count >= 2 else {
            fputs("Usage: cmux-layout save <name> <descriptor>\n", stderr)
            exit(1)
        }
        let name = args[0]
        let descriptor = args[1]
        var config = try ConfigManager()
        try config.save(name: name, descriptor: descriptor)
        print("Saved template '\(name)'")
    }
```

- [ ] **Step 2: Update handleLoad to use ConfigManager**

Replace `handleLoad` (lines 176-199):

```swift
    static func handleLoad(_ args: [String]) throws {
        var workspace: String?
        var name: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--workspace":
                i += 1; workspace = args[i]
            default:
                name = args[i]
            }
            i += 1
        }
        guard let templateName = name else {
            fputs("Usage: cmux-layout load [--workspace WS] <name>\n", stderr)
            exit(1)
        }
        let config = try ConfigManager()
        let descriptor = try config.load(name: templateName)
        let model = try Parser().parse(descriptor)
        let client = LiveSocketClient()
        let executor = Executor(client: client)
        let result = try executor.apply(model, workspace: workspace)
        print("Loaded template '\(templateName)' -> \(result.workspaceRef)")
    }
```

- [ ] **Step 3: Update handleList to use ConfigManager**

Replace `handleList` (lines 201-210):

```swift
    static func handleList() throws {
        let config = try ConfigManager()
        let templates = try config.list()
        if templates.isEmpty {
            print("No saved templates")
        } else {
            for t in templates {
                print("  \(t.name): \(t.descriptor)")
            }
        }
    }
```

- [ ] **Step 4: Add ConfigError to the error handling switch**

Add after the `ExecutorError` catch in the `do/catch` block (~line 43):

```swift
        } catch let error as ConfigError {
            fputs("Config error: \(error)\n", stderr)
            exit(1)
```

- [ ] **Step 5: Build to verify compilation**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift build 2>&1 | tail -10`
Expected: Build succeeded

- [ ] **Step 6: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/cmux-layout/main.swift
git commit -m "feat: rewire save/load/list CLI commands to ConfigManager"
```

---

### Task 10: CLI — Add config subcommand

**Files:**
- Modify: `Sources/cmux-layout/main.swift`

- [ ] **Step 1: Add config case to command switch**

Add after the `"list"` case in the switch statement:

```swift
            case "config":
                try handleConfig(Array(args.dropFirst()))
```

- [ ] **Step 2: Implement handleConfig**

Add the handler function:

```swift
    static func handleConfig(_ args: [String]) throws {
        guard let sub = args.first else {
            fputs("Usage: cmux-layout config <path|show|init>\n", stderr)
            exit(1)
        }
        switch sub {
        case "path":
            let config = try ConfigManager()
            print(config.configPath)
        case "show":
            let config = try ConfigManager()
            let content = try String(contentsOfFile: config.configPath, encoding: .utf8)
            print(content)
        case "init":
            let force = args.contains("--force")
            let path = ConfigManager.defaultPath
            if FileManager.default.fileExists(atPath: path) && !force {
                fputs("Config file already exists at \(path). Use --force to overwrite.\n", stderr)
                exit(1)
            }
            if force {
                try? FileManager.default.removeItem(atPath: path)
            }
            let _ = try ConfigManager()
            print("Initialized config at \(path)")
        default:
            fputs("Unknown config command: \(sub)\n", stderr)
            fputs("Usage: cmux-layout config <path|show|init>\n", stderr)
            exit(1)
        }
    }
```

Note: Add a `defaultPath` static property to `ConfigManager`:

```swift
    public static let defaultPath = NSHomeDirectory() + "/.config/cmux-layout/config.toml"
```

- [ ] **Step 3: Update printUsage to include config commands**

Add to the usage string:

```swift
          cmux-layout config path
          cmux-layout config show
          cmux-layout config init [--force]
```

- [ ] **Step 4: Build to verify compilation**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift build 2>&1 | tail -10`
Expected: Build succeeded

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/cmux-layout/main.swift Sources/CMUXLayout/ConfigManager.swift
git commit -m "feat: add config subcommand (path, show, init)"
```

---

### Task 11: Delete ProfileStore

**Files:**
- Delete: `Sources/CMUXLayout/ProfileStore.swift`

- [ ] **Step 1: Remove ProfileStore.swift**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git rm Sources/CMUXLayout/ProfileStore.swift
```

- [ ] **Step 2: Build and run all tests to verify nothing breaks**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift build 2>&1 | tail -10`
Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1 | tail -20`
Expected: Build succeeded, all tests pass

- [ ] **Step 3: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add -A
git commit -m "refactor: remove ProfileStore, replaced by ConfigManager"
```

---

### Task 12: Full Test Suite Verification

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1`
Expected: All tests pass (TOMLParser, ConfigManager, Parser, Serializer, Planner, Verifier, Integration)

- [ ] **Step 2: Verify build in release mode**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift build -c release 2>&1 | tail -10`
Expected: Build succeeded

- [ ] **Step 3: Smoke test CLI**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
.build/release/cmux-layout config path
.build/release/cmux-layout validate "grid:2x2"
.build/release/cmux-layout save test-template "grid:2x2"
.build/release/cmux-layout list
.build/release/cmux-layout config show
```
Expected: All commands produce expected output, config.toml is created and contains the saved template.
