# Browser Surfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend cmux-layout to support browser surfaces alongside terminals, with inline descriptor syntax and TOML expanded form.

**Architecture:** Add `SurfaceType` and `CellSpec` types to the data model, replacing `LayoutModel.names: [String]?` with `LayoutModel.cells: [CellSpec]?`. Extend the Parser to handle `name=b:url` syntax, the Serializer to round-trip it, and the Executor to swap terminal surfaces for browser surfaces via `surface.create` + `surface.close`. ConfigManager's `load` returns `LayoutModel` directly after merging TOML cell tables.

**Tech Stack:** Swift 6.0, Foundation-only, Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-03-24-browser-surfaces-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/CMUXLayout/LayoutModel.swift` | Modify | Add `SurfaceType`, `CellSpec`, replace `names` with `cells` |
| `Sources/CMUXLayout/Parser.swift` | Modify | Parse cell spec grammar in `names:` segment |
| `Sources/CMUXLayout/Serializer.swift` | Modify | Serialize `CellSpec` to compact syntax |
| `Sources/CMUXLayout/Executor.swift` | Modify | Browser surface swap + update `collectCells` and `renameSurfaces` for `CellSpec` |
| `Sources/CMUXLayout/ConfigManager.swift` | Modify | `load` returns `LayoutModel`, merge TOML cell tables |
| `Sources/cmux-layout/main.swift` | Modify | Update `handleLoad` for `LayoutModel` return, update `handleApply` output for surface type |
| `Tests/CMUXLayoutTests/ParserTests.swift` | Modify | Cell spec parsing tests |
| `Tests/CMUXLayoutTests/SerializerTests.swift` | Modify | Cell spec round-trip tests |
| `Tests/CMUXLayoutTests/ExecutorTests.swift` | Modify | Browser swap mock tests |
| `Tests/CMUXLayoutTests/IntegrationTests.swift` | Modify | Browser surface live tests |
| `Tests/CMUXLayoutTests/ConfigManagerTests.swift` | Modify | TOML cell table merge tests |

---

### Task 1: Add SurfaceType and CellSpec to Data Model

**Files:**
- Modify: `Sources/CMUXLayout/LayoutModel.swift`
- Modify: `Tests/CMUXLayoutTests/ParserTests.swift`

- [ ] **Step 1: Write failing tests for new types**

Append to `ParserTests.swift`:

```swift
    // MARK: - CellSpec parsing

    @Test func parseBareNamesAsCellSpecs() throws {
        let model = try parser.parse("cols:50,50 | names:nav,main")
        let cells = try #require(model.cells)
        #expect(cells.count == 2)
        #expect(cells[0] == CellSpec(name: "nav", type: .terminal))
        #expect(cells[1] == CellSpec(name: "main", type: .terminal))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ParserTests/parseBareNamesAsCellSpecs 2>&1 | tail -10`
Expected: FAIL — `CellSpec` not defined

- [ ] **Step 3: Add SurfaceType and CellSpec to LayoutModel.swift**

Replace the current `names` property and add new types:

```swift
import Foundation

public enum SurfaceType: Equatable, Sendable {
    case terminal
    case browser(url: String?)
}

public struct CellSpec: Equatable, Sendable {
    public let name: String?
    public let type: SurfaceType

    public init(name: String? = nil, type: SurfaceType = .terminal) {
        self.name = name
        self.type = type
    }
}

/// Describes a complete cmux layout
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
```

This removes `names: [String]?` and replaces it with `cells: [CellSpec]?`.

- [ ] **Step 4: Fix compilation errors in Parser.swift**

The Parser currently builds `names: [String]?` and passes it to `LayoutModel(... names: names)`. Update:

In `Parser.swift`, change the `names:` segment parsing (lines 54-57) to produce `[CellSpec]`:

```swift
            } else if segment.hasPrefix("names:") {
                let tokens = String(segment.dropFirst("names:".count))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                cells = tokens.map { CellSpec(name: $0, type: .terminal) }
```

Change the local variable from `var names: [String]?` (line 18) to `var cells: [CellSpec]?`.

Change the model construction (line 85) from `names: names` to `cells: cells`.

Change the count validation (lines 88-93):

```swift
        if let c = cells {
            let expected = model.cellCount
            guard c.count == expected else {
                throw ParseError.nameCountMismatch(expected: expected, got: c.count)
            }
        }
```

- [ ] **Step 5: Fix compilation errors in Serializer.swift**

Change the `names` references in `Serializer.swift`:

Line 13-14 — change from:
```swift
            if let names = model.names {
                parts.append("names:\(names.joined(separator: ","))")
```
to:
```swift
            if let cells = model.cells {
                parts.append("names:\(cells.map { $0.name ?? "" }.joined(separator: ","))")
```

Line 40-42 — same change for the non-grid branch.

(This is a temporary pass-through — Task 3 will implement proper CellSpec serialization.)

- [ ] **Step 6: Fix compilation errors in Executor.swift**

Change `collectCells` (line 210) from:
```swift
                let name = model.names?[safe: cellIndex]
```
to:
```swift
                let name = model.cells?[safe: cellIndex]?.name
```

Change the rename guard (line 117) from:
```swift
        if model.names != nil {
```
to:
```swift
        if model.cells != nil {
```

- [ ] **Step 7: Fix compilation errors in main.swift**

Any place that references `model.names` needs to become `model.cells`. Search for `names` references in main.swift — the apply handler's JSON output does not reference names directly (it uses CellInfo), so no change needed there.

- [ ] **Step 8: Fix compilation errors in tests**

In `SerializerTests.swift`, change `LayoutModel(columns: [50, 50], names: ["a", "b"])` to use `cells:`:
```swift
    @Test func serializeNames() {
        let model = LayoutModel(columns: [50, 50], cells: [
            CellSpec(name: "a"), CellSpec(name: "b")
        ])
```

Apply the same pattern to any other test that uses `names:` parameter.

In `ExecutorTests.swift`, any model with `names:` needs updating. The `surfaceRenameCalledForEachNamedCell` test:
```swift
        let model = try Parser().parse("grid:1x1 | names:my-terminal")
```
This still works because the Parser now produces `[CellSpec]` from `names:` — no change needed in tests that go through the Parser.

- [ ] **Step 9: Build and run all tests**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 10: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add -A
git commit -m "refactor: replace names with CellSpec in data model"
```

---

### Task 2: Parse Cell Spec Grammar

**Files:**
- Modify: `Sources/CMUXLayout/Parser.swift`
- Modify: `Tests/CMUXLayoutTests/ParserTests.swift`

- [ ] **Step 1: Write failing tests for cell spec parsing**

Append to `ParserTests.swift`:

```swift
    @Test func parseNamedBrowserWithUrl() throws {
        let model = try parser.parse("cols:100 | names:docs=b:https://x.com")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "docs", type: .browser(url: "https://x.com")))
    }

    @Test func parseUnnamedBrowserWithUrl() throws {
        let model = try parser.parse("cols:100 | names:b:https://x.com")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: nil, type: .browser(url: "https://x.com")))
    }

    @Test func parseBlankBrowser() throws {
        let model = try parser.parse("cols:100 | names:b:")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: nil, type: .browser(url: nil)))
    }

    @Test func parseNamedBlankBrowser() throws {
        let model = try parser.parse("cols:100 | names:docs=b:")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "docs", type: .browser(url: nil)))
    }

    @Test func parseExplicitTerminal() throws {
        let model = try parser.parse("cols:100 | names:nav=t:")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "nav", type: .terminal))
    }

    @Test func parseMixedCellSpecs() throws {
        let model = try parser.parse("cols:33,34,33 | names:nav,docs=b:https://x.com,logs")
        let cells = try #require(model.cells)
        #expect(cells.count == 3)
        #expect(cells[0] == CellSpec(name: "nav", type: .terminal))
        #expect(cells[1] == CellSpec(name: "docs", type: .browser(url: "https://x.com")))
        #expect(cells[2] == CellSpec(name: "logs", type: .terminal))
    }

    @Test func parseCellCountValidationStillWorks() throws {
        #expect(throws: ParseError.self) {
            try parser.parse("cols:50,50 | names:only-one")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ParserTests 2>&1 | tail -15`
Expected: FAIL — browser cell specs not parsed correctly

- [ ] **Step 3: Implement cell spec parsing**

In `Parser.swift`, add a private helper method and update the `names:` parsing:

```swift
    private func parseCellSpec(_ token: String) -> CellSpec {
        // Check for name=type:value pattern
        if let eqIndex = token.firstIndex(of: "=") {
            let name = String(token[token.startIndex..<eqIndex])
            let remainder = String(token[token.index(after: eqIndex)...])
            if remainder.hasPrefix("b:") {
                let urlStr = String(remainder.dropFirst(2))
                let url: String? = urlStr.isEmpty ? nil : urlStr
                return CellSpec(name: name, type: .browser(url: url))
            } else if remainder.hasPrefix("t:") {
                return CellSpec(name: name, type: .terminal)
            }
            // No recognized type prefix — treat "=" as part of name? No, name=value with unknown type.
            // Fall through to bare name (include the whole token as name)
            return CellSpec(name: token, type: .terminal)
        }

        // Check for unnamed type:value pattern
        if token.hasPrefix("b:") {
            let urlStr = String(token.dropFirst(2))
            let url: String? = urlStr.isEmpty ? nil : urlStr
            return CellSpec(name: nil, type: .browser(url: url))
        }

        // Bare name — terminal
        return CellSpec(name: token, type: .terminal)
    }
```

Update the `names:` segment (currently producing `CellSpec(name: $0, type: .terminal)`) to use the new helper:

```swift
            } else if segment.hasPrefix("names:") {
                let tokens = String(segment.dropFirst("names:".count))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                cells = tokens.map { parseCellSpec($0) }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ParserTests 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/Parser.swift Tests/CMUXLayoutTests/ParserTests.swift
git commit -m "feat: parse cell spec grammar (name=b:url) in names segment"
```

---

### Task 3: Serialize CellSpec to Compact Syntax

**Files:**
- Modify: `Sources/CMUXLayout/Serializer.swift`
- Modify: `Tests/CMUXLayoutTests/SerializerTests.swift`

- [ ] **Step 1: Write failing tests for CellSpec serialization**

Append to `SerializerTests.swift`:

```swift
    // MARK: - CellSpec serialization

    @Test func serializeTerminalCellSpec() {
        let model = LayoutModel(columns: [50, 50], cells: [
            CellSpec(name: "nav"), CellSpec(name: "main")
        ])
        let result = serializer.serialize(model)
        #expect(result == "cols:50,50 | names:nav,main")
    }

    @Test func serializeNamedBrowser() {
        let model = LayoutModel(columns: [100], cells: [
            CellSpec(name: "docs", type: .browser(url: "https://x.com"))
        ])
        let result = serializer.serialize(model)
        #expect(result == "cols:100 | names:docs=b:https://x.com")
    }

    @Test func serializeUnnamedBrowser() {
        let model = LayoutModel(columns: [100], cells: [
            CellSpec(name: nil, type: .browser(url: "https://x.com"))
        ])
        let result = serializer.serialize(model)
        #expect(result == "cols:100 | names:b:https://x.com")
    }

    @Test func serializeBlankBrowser() {
        let model = LayoutModel(columns: [100], cells: [
            CellSpec(name: nil, type: .browser(url: nil))
        ])
        let result = serializer.serialize(model)
        #expect(result == "cols:100 | names:b:")
    }

    @Test func serializeNamedBlankBrowser() {
        let model = LayoutModel(columns: [100], cells: [
            CellSpec(name: "docs", type: .browser(url: nil))
        ])
        let result = serializer.serialize(model)
        #expect(result == "cols:100 | names:docs=b:")
    }

    @Test func serializeMixedCells() {
        let model = LayoutModel(columns: [33, 34, 33], cells: [
            CellSpec(name: "nav"),
            CellSpec(name: "docs", type: .browser(url: "https://x.com")),
            CellSpec(name: "logs"),
        ])
        let result = serializer.serialize(model)
        #expect(result == "cols:33,34,33 | names:nav,docs=b:https://x.com,logs")
    }

    @Test func serializeExplicitTerminalLosesTPrefix() {
        // Parser accepts name=t: but serializer always emits bare name
        let model = try! parser.parse("cols:100 | names:nav=t:")
        let result = serializer.serialize(model)
        #expect(result == "cols:100 | names:nav")
    }

    @Test func cellSpecRoundTrip() throws {
        let input = "cols:33,34,33 | names:nav,docs=b:https://x.com,logs"
        let model = try parser.parse(input)
        let output = serializer.serialize(model)
        #expect(output == input)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter SerializerTests 2>&1 | tail -15`
Expected: FAIL — serializer still uses placeholder name-only output

- [ ] **Step 3: Implement CellSpec serialization**

In `Serializer.swift`, add a helper and update both `names` output locations:

```swift
    private func serializeCellSpec(_ cell: CellSpec) -> String {
        switch cell.type {
        case .terminal:
            return cell.name ?? ""
        case .browser(let url):
            let urlPart = url ?? ""
            if let name = cell.name {
                return "\(name)=b:\(urlPart)"
            }
            return "b:\(urlPart)"
        }
    }
```

Replace both `names:` output blocks (the grid shorthand branch and the regular branch). In the grid branch (around line 13):

```swift
            if let cells = model.cells {
                parts.append("names:\(cells.map { serializeCellSpec($0) }.joined(separator: ","))")
            }
```

And in the regular branch (around line 40):

```swift
        if let cells = model.cells {
            parts.append("names:\(cells.map { serializeCellSpec($0) }.joined(separator: ","))")
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter SerializerTests 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/Serializer.swift Tests/CMUXLayoutTests/SerializerTests.swift
git commit -m "feat: serialize CellSpec to compact names syntax"
```

---

### Task 4: Executor — Browser Surface Swap

**Files:**
- Modify: `Sources/CMUXLayout/Executor.swift`
- Modify: `Tests/CMUXLayoutTests/ExecutorTests.swift`

- [ ] **Step 1: Write failing tests for browser swap**

Append to `ExecutorTests.swift`:

```swift
    // MARK: - Browser surface swap

    @Test func browserCellTriggersSurfaceCreateAndClose() throws {
        let client = makeClient()
        // Stub surface.create to return a new browser surface
        client.stub(method: "surface.create", result: [
            "surface_id": "BROWSER-SURF-UUID",
            "surface_ref": "surface:99",
        ])
        client.stub(method: "surface.close", result: [:])

        let model = try Parser().parse("grid:1x1 | names:docs=b:https://x.com")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let createCalls = client.calls(to: "surface.create")
        #expect(createCalls.count == 1)
        #expect(createCalls[0].params["type"] as? String == "browser")
        #expect(createCalls[0].params["url"] as? String == "https://x.com")

        let closeCalls = client.calls(to: "surface.close")
        #expect(closeCalls.count == 1)
    }

    @Test func terminalCellDoesNotTriggerSwap() throws {
        let client = makeClient()
        let model = try Parser().parse("grid:1x1 | names:nav")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        #expect(client.calls(to: "surface.create").isEmpty)
        #expect(client.calls(to: "surface.close").isEmpty)
    }

    @Test func blankBrowserOmitsUrl() throws {
        let client = makeClient()
        client.stub(method: "surface.create", result: [
            "surface_id": "BROWSER-SURF-UUID",
            "surface_ref": "surface:99",
        ])
        client.stub(method: "surface.close", result: [:])

        let model = try Parser().parse("grid:1x1 | names:b:")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let createCalls = client.calls(to: "surface.create")
        #expect(createCalls.count == 1)
        #expect(createCalls[0].params["url"] == nil)
    }

    @Test func renameHappensAfterBrowserSwap() throws {
        let client = makeClient()
        client.stub(method: "surface.create", result: [
            "surface_id": "BROWSER-SURF-UUID",
            "surface_ref": "surface:99",
        ])
        client.stub(method: "surface.close", result: [:])

        let model = try Parser().parse("grid:1x1 | names:docs=b:https://x.com")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        // Find the tab.action rename call and verify it uses the browser surface ref
        let renameCalls = client.calls(to: "tab.action")
        #expect(renameCalls.count == 1)
        #expect(renameCalls[0].params["surface_id"] as? String == "surface:99")
        #expect(renameCalls[0].params["title"] as? String == "docs")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ExecutorTests 2>&1 | tail -15`
Expected: FAIL — browser swap not implemented

- [ ] **Step 3: Implement browser surface swap**

Update `Executor.swift`. First, update `CellInfo` to include surface type:

```swift
public struct CellInfo {
    public let surfaceRef: String
    public let paneRef: String
    public let paneId: String
    public let name: String?
    public let type: SurfaceType
    public let column: Int
    public let row: Int
}
```

Update `collectCells` to include `paneId` and cell type:

```swift
    private func collectCells(workspaceId: String, model: LayoutModel) throws -> [CellInfo] {
        let paneListResp = try client.call(method: "pane.list", params: ["workspace_id": workspaceId])
        guard let panes = paneListResp.result?["panes"] as? [[String: Any]] else { return [] }

        var cells: [CellInfo] = []
        var cellIndex = 0
        for pane in panes {
            guard let paneRef = pane["ref"] as? String,
                  let paneId = pane["id"] as? String else { continue }
            let surfResp = try client.call(method: "pane.surfaces", params: [
                "workspace_id": workspaceId, "pane_id": paneId
            ])
            guard let surfaces = surfResp.result?["surfaces"] as? [[String: Any]] else { continue }
            for surf in surfaces {
                guard let surfRef = surf["ref"] as? String else { continue }
                let col = cellIndex % model.columns.count
                let row = cellIndex / model.columns.count
                let cellSpec = model.cells?[safe: cellIndex]
                cells.append(CellInfo(
                    surfaceRef: surfRef,
                    paneRef: paneRef,
                    paneId: paneId,
                    name: cellSpec?.name,
                    type: cellSpec?.type ?? .terminal,
                    column: col,
                    row: row
                ))
                cellIndex += 1
            }
        }
        return cells
    }
```

Add the browser swap method:

```swift
    private func swapBrowserSurfaces(cells: inout [CellInfo], workspaceId: String) throws {
        for i in cells.indices {
            guard case .browser(let url) = cells[i].type else { continue }

            var createParams: [String: Any] = [
                "workspace_id": workspaceId,
                "pane_id": cells[i].paneId,
                "type": "browser",
            ]
            if let url = url {
                createParams["url"] = url
            }

            let createResp = try client.call(method: "surface.create", params: createParams)
            guard let newSurfRef = createResp.result?["surface_ref"] as? String else {
                throw ExecutorError.unexpectedResponse("surface.create browser")
            }

            // Close the original terminal surface
            _ = try client.call(method: "surface.close", params: [
                "workspace_id": workspaceId,
                "surface_id": cells[i].surfaceRef,
            ])

            // Update cell with new surface ref
            cells[i] = CellInfo(
                surfaceRef: newSurfRef,
                paneRef: cells[i].paneRef,
                paneId: cells[i].paneId,
                name: cells[i].name,
                type: cells[i].type,
                column: cells[i].column,
                row: cells[i].row
            )
        }
    }
```

Update the `apply` method to call `swapBrowserSurfaces` before `renameSurfaces`:

```swift
        // 8. Collect cell map
        var cells = try collectCells(workspaceId: wsId, model: model)

        // 9. Swap browser surfaces
        try swapBrowserSurfaces(cells: &cells, workspaceId: wsId)

        // 10. Rename surfaces if cells are specified
        if model.cells != nil {
            try renameSurfaces(cells: cells, workspaceId: wsId)
        }

        return LayoutResult(workspaceRef: wsRef, workspaceId: wsId, cells: cells)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ExecutorTests 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/Executor.swift Tests/CMUXLayoutTests/ExecutorTests.swift
git commit -m "feat: swap terminal surfaces for browser surfaces in executor"
```

---

### Task 5: ConfigManager — Load Returns LayoutModel with TOML Cell Merge

**Files:**
- Modify: `Sources/CMUXLayout/ConfigManager.swift`
- Modify: `Sources/cmux-layout/main.swift`
- Modify: `Tests/CMUXLayoutTests/ConfigManagerTests.swift`

- [ ] **Step 1: Write failing tests for TOML cell merge**

Append to `ConfigManagerTests.swift`:

```swift
    // MARK: - Cell table merge

    @Test func loadReturnsLayoutModel() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:50,50 | names:nav,main")
        let model = try mgr.loadModel(name: "dev")
        #expect(model.columns.count == 2)
        #expect(model.cells?.count == 2)
        #expect(model.cells?[0].name == "nav")
    }

    @Test func loadMergesTomlCellTables() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:50,50 | names:nav,docs")

        // Manually write TOML cell table
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + """

        [templates.dev.cells.docs]
        type = "browser"
        url = "https://docs.example.com"
        """
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "nav", type: .terminal))
        #expect(cells[1] == CellSpec(name: "docs", type: .browser(url: "https://docs.example.com")))
    }

    @Test func tomlCellTableOverridesInlineSpec() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:100 | names:docs=b:https://old.com")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + """

        [templates.dev.cells.docs]
        type = "browser"
        url = "https://new.com"
        """
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "docs", type: .browser(url: "https://new.com")))
    }

    @Test func missingTomlCellDefaultsToTerminal() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:50,50 | names:nav,docs")

        // Only define one cell in TOML — the other defaults to terminal
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + """

        [templates.dev.cells.docs]
        type = "browser"
        """
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "nav", type: .terminal))
        #expect(cells[1] == CellSpec(name: "docs", type: .browser(url: nil)))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -15`
Expected: FAIL — `loadModel` not defined

- [ ] **Step 3: Implement loadModel with TOML cell merge**

Add to `ConfigManager`:

```swift
    // MARK: - Model loading

    public func loadModel(name: String) throws -> LayoutModel {
        let descriptor = try load(name: name)
        var model = try Parser().parse(descriptor)

        // Merge TOML cell tables if they exist
        let cellTablePrefix = "templates.\(name).cells."
        let cellTables = document.tablesWithPrefix(cellTablePrefix)
        guard !cellTables.isEmpty else { return model }

        // Build a lookup of TOML cell overrides by name
        var overrides: [String: CellSpec] = [:]
        for tableName in cellTables {
            let cellName = String(tableName.dropFirst(cellTablePrefix.count))
            let typeStr = document.getString(table: tableName, key: "type") ?? "terminal"
            let url = document.getString(table: tableName, key: "url")
            let surfaceType: SurfaceType
            if typeStr == "browser" {
                surfaceType = .browser(url: url)
            } else {
                surfaceType = .terminal
            }
            overrides[cellName] = CellSpec(name: cellName, type: surfaceType)
        }

        // Apply overrides to matching cells by name
        if var cells = model.cells {
            for i in cells.indices {
                if let name = cells[i].name, let override = overrides[name] {
                    cells[i] = override
                }
            }
            model.cells = cells
        }

        return model
    }
```

- [ ] **Step 4: Update handleLoad in main.swift**

Change `handleLoad` (lines 198-200) from:
```swift
        let config = try ConfigManager()
        let descriptor = try config.load(name: templateName)
        let model = try Parser().parse(descriptor)
```
to:
```swift
        let config = try ConfigManager()
        let model = try config.loadModel(name: templateName)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/ConfigManager.swift Sources/cmux-layout/main.swift Tests/CMUXLayoutTests/ConfigManagerTests.swift
git commit -m "feat: loadModel returns LayoutModel with TOML cell table merge"
```

---

### Task 6: Integration Tests — Browser Surfaces Against Live cmux

**Files:**
- Modify: `Tests/CMUXLayoutTests/IntegrationTests.swift`

- [ ] **Step 1: Add integration tests**

Append to `IntegrationTests.swift`:

```swift
    @Test func browserSurfaceCreated() throws {
        let model = try Parser().parse("workspace:Browser Test | cols:100 | names:docs=b:https://example.com")
        let executor = Executor(client: client)
        let result = try executor.apply(model)

        #expect(result.cells.count == 1)

        // Verify the surface is actually a browser via pane.surfaces
        let paneListResp = try client.call(method: "pane.list", params: ["workspace_id": result.workspaceId])
        let panes = paneListResp.result?["panes"] as? [[String: Any]] ?? []
        let paneId = panes.first?["id"] as? String ?? ""
        let surfResp = try client.call(method: "pane.surfaces", params: [
            "workspace_id": result.workspaceId, "pane_id": paneId,
        ])
        let surfaces = surfResp.result?["surfaces"] as? [[String: Any]] ?? []
        #expect(surfaces.count == 1)
        #expect(surfaces[0]["type"] as? String == "browser")

        // Cleanup
        _ = try client.call(method: "workspace.close", params: ["workspace_id": result.workspaceId])
    }

    @Test func mixedTerminalAndBrowserSurfaces() throws {
        let model = try Parser().parse("workspace:Mixed Test | cols:50,50 | names:term,docs=b:https://example.com")
        let executor = Executor(client: client)
        let result = try executor.apply(model)

        #expect(result.cells.count == 2)

        // Collect surface types
        let paneListResp = try client.call(method: "pane.list", params: ["workspace_id": result.workspaceId])
        let panes = paneListResp.result?["panes"] as? [[String: Any]] ?? []
        var surfaceTypes: [String: String] = [:]
        for pane in panes {
            guard let paneId = pane["id"] as? String else { continue }
            let surfResp = try client.call(method: "pane.surfaces", params: [
                "workspace_id": result.workspaceId, "pane_id": paneId,
            ])
            let surfaces = surfResp.result?["surfaces"] as? [[String: Any]] ?? []
            for surf in surfaces {
                if let ref = surf["ref"] as? String, let type = surf["type"] as? String {
                    surfaceTypes[ref] = type
                }
            }
        }

        // First cell should be terminal, second should be browser
        #expect(surfaceTypes[result.cells[0].surfaceRef] == "terminal")
        #expect(surfaceTypes[result.cells[1].surfaceRef] == "browser")

        // Cleanup
        _ = try client.call(method: "workspace.close", params: ["workspace_id": result.workspaceId])
    }
```

- [ ] **Step 2: Build to verify compilation**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Run integration tests**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && CMUX_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Tests/CMUXLayoutTests/IntegrationTests.swift
git commit -m "test: add integration tests for browser surfaces"
```

---

### Task 7: Full Test Suite Verification and Release Build

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1`
Expected: All tests pass

- [ ] **Step 2: Run integration tests**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && CMUX_INTEGRATION=1 swift test --filter IntegrationTests 2>&1`
Expected: All tests pass

- [ ] **Step 3: Verify build in release mode**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift build -c release 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Smoke test CLI**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
# Validate descriptor with browser cell
.build/release/cmux-layout validate "cols:50,50 | names:nav,docs=b:https://example.com"
# Save template
.build/release/cmux-layout save browser-test "workspace:Browser Test | cols:50,50 | names:term,docs=b:https://example.com"
# List
.build/release/cmux-layout list
# Load and verify workspace
.build/release/cmux-layout load browser-test
```
Expected: All commands succeed. The loaded workspace has a terminal and a browser pane.
