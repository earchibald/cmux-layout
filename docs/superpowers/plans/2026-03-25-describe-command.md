# Describe Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `describe` command that queries a live cmux workspace and outputs its topology as a descriptor string — the inverse of `apply`.

**Architecture:** New `Describer` struct in `Sources/CMUXLayout/Describer.swift` queries the socket API (`workspace.list`, `pane.list`, `pane.surfaces`) to reconstruct a `LayoutModel`, which is then serialized using the existing `Serializer`. CLI integration in `main.swift` adds the `describe` subcommand with `--workspace`, `--include-name`, and `--json` flags.

**Tech Stack:** Swift 6.0, Foundation, Swift Testing, no external dependencies.

**Spec:** `docs/superpowers/specs/2026-03-25-describe-command-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/CMUXLayout/Describer.swift` | Create | Core logic: query socket, reconstruct LayoutModel |
| `Tests/CMUXLayoutTests/DescriberTests.swift` | Create | Unit tests with RecordingSocketClient |
| `Tests/CMUXLayoutTests/ExecutorTests.swift` | Modify | Extend RecordingSocketClient to support response queues |
| `Sources/cmux-layout/main.swift` | Modify | Add `describe` case, `handleDescribe`, error handling, usage |

---

### Task 1: Extend RecordingSocketClient for Multi-Response Support

The `describe` flow calls `pane.surfaces` once per pane with different `pane_id` values. The current `RecordingSocketClient` returns the same canned response for every call to a method. We need to add a response queue so that repeated calls to the same method can return different responses.

**Files:**
- Modify: `Tests/CMUXLayoutTests/ExecutorTests.swift:6-30` (RecordingSocketClient class)

- [ ] **Step 1: Write failing test to verify queue behavior**

Add this test at the bottom of `ExecutorTests.swift` (inside the `ExecutorTests` struct):

```swift
@Test func recordingClientReturnsQueuedResponses() throws {
    let client = RecordingSocketClient()
    client.stub(method: "pane.surfaces", result: ["surfaces": [["id": "S1", "ref": "surface:1"]] as [[String: Any]]])
    client.enqueue(method: "pane.surfaces", result: ["surfaces": [["id": "S2", "ref": "surface:2"]] as [[String: Any]]])
    client.enqueue(method: "pane.surfaces", result: ["surfaces": [["id": "S3", "ref": "surface:3"]] as [[String: Any]]])

    let resp1 = try client.call(method: "pane.surfaces", params: ["pane_id": "P1"])
    let resp2 = try client.call(method: "pane.surfaces", params: ["pane_id": "P2"])
    let resp3 = try client.call(method: "pane.surfaces", params: ["pane_id": "P3"])

    let surfs1 = resp1.result?["surfaces"] as? [[String: Any]]
    let surfs2 = resp2.result?["surfaces"] as? [[String: Any]]
    let surfs3 = resp3.result?["surfaces"] as? [[String: Any]]

    #expect(surfs1?[0]["id"] as? String == "S2")  // queue takes priority
    #expect(surfs2?[0]["id"] as? String == "S3")
    #expect(surfs3?[0]["id"] as? String == "S1")  // falls back to stub
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "recordingClientReturnsQueuedResponses" 2>&1`
Expected: FAIL — `enqueue` method does not exist.

- [ ] **Step 3: Add `enqueue` method and queue logic to RecordingSocketClient**

Modify `RecordingSocketClient` in `Tests/CMUXLayoutTests/ExecutorTests.swift`:

```swift
final class RecordingSocketClient: CMUXSocketClient {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    private(set) var calls: [Call] = []
    private var responses: [String: CMUXResponse] = [:]
    private var responseQueues: [String: [CMUXResponse]] = [:]

    /// Register a canned response for a method name (default fallback).
    func stub(method: String, result: [String: Any]) {
        responses[method] = CMUXResponse(data: ["ok": true, "result": result])
    }

    /// Enqueue a response that will be returned once, in FIFO order, before falling back to stub.
    func enqueue(method: String, result: [String: Any]) {
        var queue = responseQueues[method] ?? []
        queue.append(CMUXResponse(data: ["ok": true, "result": result]))
        responseQueues[method] = queue
    }

    func call(method: String, params: [String: Any]) throws -> CMUXResponse {
        calls.append(Call(method: method, params: params))
        if var queue = responseQueues[method], !queue.isEmpty {
            let resp = queue.removeFirst()
            responseQueues[method] = queue
            return resp
        }
        if let resp = responses[method] { return resp }
        return CMUXResponse(data: ["ok": true, "result": [:]])
    }

    /// Returns all calls to a given method.
    func calls(to method: String) -> [Call] {
        calls.filter { $0.method == method }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "recordingClientReturnsQueuedResponses" 2>&1`
Expected: PASS

- [ ] **Step 5: Run all existing tests to verify no regressions**

Run: `swift test 2>&1`
Expected: All 132 tests pass (131 existing + 1 new).

- [ ] **Step 6: Commit**

```bash
git add Tests/CMUXLayoutTests/ExecutorTests.swift
git commit -m "test: extend RecordingSocketClient with response queue support"
```

---

### Task 2: Describer Core — Single-Pane Workspace

Implement the simplest case: describe a workspace with exactly one pane (one terminal surface). This establishes the full query pipeline (workspace resolution → pane list → surface query → LayoutModel construction) without geometry complexity.

**Files:**
- Create: `Tests/CMUXLayoutTests/DescriberTests.swift`
- Create: `Sources/CMUXLayout/Describer.swift`

- [ ] **Step 1: Write failing test for single-pane describe**

Create `Tests/CMUXLayoutTests/DescriberTests.swift`:

```swift
import Foundation
import Testing
@testable import CMUXLayout

@Suite("Describer Tests")
struct DescriberTests {

    // MARK: - Helpers

    /// Build a RecordingSocketClient with workspace.list returning one workspace.
    private func makeClient(
        workspaceRef: String = "workspace:1",
        workspaceId: String = "WS-UUID-001",
        workspaceTitle: String = "Dev"
    ) -> RecordingSocketClient {
        let client = RecordingSocketClient()
        client.stub(method: "workspace.list", result: [
            "workspaces": [
                ["id": workspaceId, "ref": workspaceRef, "title": workspaceTitle],
            ] as [[String: Any]],
        ])
        return client
    }

    /// Stub pane.list to return panes with optional geometry fields.
    private func stubPanes(
        _ client: RecordingSocketClient,
        workspaceId: String = "WS-UUID-001",
        panes: [[String: Any]]
    ) {
        client.stub(method: "pane.list", result: ["panes": panes])
    }

    /// Enqueue a pane.surfaces response (use for multi-pane scenarios).
    private func enqueueSurfaces(
        _ client: RecordingSocketClient,
        surfaces: [[String: Any]]
    ) {
        client.enqueue(method: "pane.surfaces", result: ["surfaces": surfaces])
    }

    /// Stub pane.surfaces as default fallback (use for single-pane scenarios).
    private func stubSurfaces(
        _ client: RecordingSocketClient,
        surfaces: [[String: Any]]
    ) {
        client.stub(method: "pane.surfaces", result: ["surfaces": surfaces])
    }

    // MARK: - Single pane

    @Test func describeSinglePane() throws {
        let client = makeClient()
        stubPanes(client, panes: [
            ["id": "PANE-1", "ref": "pane:1"],
        ])
        stubSurfaces(client, surfaces: [
            ["id": "SURF-1", "ref": "surface:1", "type": "terminal", "title": ""],
        ])

        let describer = Describer(client: client)
        let model = try describer.describe(workspace: "workspace:1")

        #expect(model.columns == [100.0])
        #expect(model.rows.isEmpty)

        let descriptor = Serializer().serialize(model)
        #expect(descriptor == "cols:100")
    }
}
```

**Note:** `RecordingSocketClient` is defined in `ExecutorTests.swift`. Since both test files are in the same test target, the class is accessible without import. If the compiler complains, add `internal` explicitly (it should already be the default).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "describeSinglePane" 2>&1`
Expected: FAIL — `Describer` type does not exist.

- [ ] **Step 3: Write minimal Describer implementation**

Create `Sources/CMUXLayout/Describer.swift`:

```swift
import Foundation

public enum DescriberError: Error, Equatable {
    case workspaceNotFound(String)
    case cannotReadTopology
}

public struct Describer {
    private let client: CMUXSocketClient

    public init(client: CMUXSocketClient) {
        self.client = client
    }

    /// Describes a workspace's current topology as a LayoutModel.
    /// The `workspace` parameter is a user-facing ref (e.g., "workspace:1").
    public func describe(workspace: String, includeWorkspaceName: Bool = false) throws -> LayoutModel {
        // 1. Resolve workspace ref → id + title
        let (workspaceId, workspaceTitle) = try resolveWorkspace(ref: workspace)

        // 2. Get panes
        let panes = try getPanes(workspaceId: workspaceId)
        guard !panes.isEmpty else {
            throw DescriberError.cannotReadTopology
        }

        // 3. Get surfaces for each pane
        var surfaceInfos: [(type: String, title: String, url: String?)] = []
        for pane in panes {
            guard let paneId = pane["id"] as? String else { continue }
            let surfResp = try client.call(method: "pane.surfaces", params: [
                "workspace_id": workspaceId, "pane_id": paneId,
            ])
            guard let surfaces = surfResp.result?["surfaces"] as? [[String: Any]],
                  let surface = surfaces.first else { continue }
            let type = surface["type"] as? String ?? "terminal"
            let title = surface["title"] as? String ?? ""
            let url = surface["url"] as? String
            surfaceInfos.append((type: type, title: title, url: url))
        }

        // 4. For single pane, simple case
        let columns: [Double] = surfaceInfos.count == 1 ? [100.0] : Array(repeating: 100.0 / Double(surfaceInfos.count), count: surfaceInfos.count)

        // 5. Build cells
        let cells = surfaceInfos.map { info -> CellSpec in
            let name = info.title.isEmpty ? nil : info.title
            let surfaceType: SurfaceType
            if info.type == "browser" {
                surfaceType = .browser(url: info.url)
            } else {
                surfaceType = .terminal(command: nil)
            }
            return CellSpec(name: name, type: surfaceType)
        }

        let hasMeaningfulCells = cells.contains { $0.name != nil || $0.type != .terminal(command: nil) }

        return LayoutModel(
            workspaceName: includeWorkspaceName ? workspaceTitle : nil,
            columns: columns,
            rows: [:],
            cells: hasMeaningfulCells ? cells : nil
        )
    }

    private func resolveWorkspace(ref: String) throws -> (id: String, title: String) {
        let resp = try client.call(method: "workspace.list", params: [:])
        guard let workspaces = resp.result?["workspaces"] as? [[String: Any]] else {
            throw DescriberError.workspaceNotFound(ref)
        }
        for ws in workspaces {
            if ws["ref"] as? String == ref {
                guard let id = ws["id"] as? String else { continue }
                let title = ws["title"] as? String ?? ""
                return (id: id, title: title)
            }
        }
        throw DescriberError.workspaceNotFound(ref)
    }

    private func getPanes(workspaceId: String) throws -> [[String: Any]] {
        let resp = try client.call(method: "pane.list", params: ["workspace_id": workspaceId])
        guard let panes = resp.result?["panes"] as? [[String: Any]] else {
            throw DescriberError.cannotReadTopology
        }
        return panes
    }
}
```

This is deliberately minimal — handles single pane only. Geometry reconstruction is added in Task 3.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "describeSinglePane" 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/CMUXLayout/Describer.swift Tests/CMUXLayoutTests/DescriberTests.swift
git commit -m "feat: add Describer with single-pane support (#7)"
```

---

### Task 3: Describer — Multi-Column Geometry Reconstruction

Add geometry handling for workspaces with multiple columns. Use pane geometry fields from `pane.list` (x, y, width, height) when available. For now, treat each pane as one column (no row splits yet).

**Files:**
- Modify: `Tests/CMUXLayoutTests/DescriberTests.swift`
- Modify: `Sources/CMUXLayout/Describer.swift`

- [ ] **Step 1: Write failing test for two equal columns**

Add to `DescriberTests`:

```swift
@Test func describeTwoEqualColumns() throws {
    let client = makeClient()
    stubPanes(client, panes: [
        ["id": "PANE-1", "ref": "pane:1", "x": 0, "y": 0, "width": 500, "height": 1000],
        ["id": "PANE-2", "ref": "pane:2", "x": 500, "y": 0, "width": 500, "height": 1000],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S2", "ref": "surface:2", "type": "terminal", "title": ""],
    ])

    let model = try Describer(client: client).describe(workspace: "workspace:1")
    #expect(model.columns == [50.0, 50.0])
    #expect(model.rows.isEmpty)

    let descriptor = Serializer().serialize(model)
    #expect(descriptor == "cols:50,50")
}
```

- [ ] **Step 2: Write failing test for three unequal columns**

```swift
@Test func describeThreeUnequalColumns() throws {
    let client = makeClient()
    stubPanes(client, panes: [
        ["id": "PANE-1", "ref": "pane:1", "x": 0, "y": 0, "width": 250, "height": 1000],
        ["id": "PANE-2", "ref": "pane:2", "x": 250, "y": 0, "width": 500, "height": 1000],
        ["id": "PANE-3", "ref": "pane:3", "x": 750, "y": 0, "width": 250, "height": 1000],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S2", "ref": "surface:2", "type": "terminal", "title": ""],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S3", "ref": "surface:3", "type": "terminal", "title": ""],
    ])

    let model = try Describer(client: client).describe(workspace: "workspace:1")
    #expect(model.columns == [25.0, 50.0, 25.0])

    let descriptor = Serializer().serialize(model)
    #expect(descriptor == "cols:25,50,25")
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter "describeTwoEqualColumns|describeThreeUnequalColumns" 2>&1`
Expected: FAIL — geometry not being used.

- [ ] **Step 4: Implement geometry-based column reconstruction**

Replace the simple `columns` calculation in `Describer.describe()` with geometry-aware logic. In `Sources/CMUXLayout/Describer.swift`, replace the section from `// 4. For single pane` through building the `LayoutModel`:

```swift
        // 4. Reconstruct geometry (also returns pane ordering if reordered by position)
        let (columns, rows, paneOrder) = reconstructGeometry(panes: panes, surfaceCount: surfaceInfos.count, workspaceId: workspaceId)

        // Reorder surfaces to match geometry column grouping
        let orderedSurfaceInfos: [(type: String, title: String, url: String?)]
        if let order = paneOrder {
            orderedSurfaceInfos = order.map { surfaceInfos[$0] }
        } else {
            orderedSurfaceInfos = surfaceInfos
        }
        let surfaceInfos = orderedSurfaceInfos

        // 5. Build cells
        let cells = surfaceInfos.map { info -> CellSpec in
            let name = info.title.isEmpty ? nil : info.title
            let surfaceType: SurfaceType
            if info.type == "browser" {
                surfaceType = .browser(url: info.url)
            } else {
                surfaceType = .terminal(command: nil)
            }
            return CellSpec(name: name, type: surfaceType)
        }

        let hasMeaningfulCells = cells.contains { $0.name != nil || $0.type != .terminal(command: nil) }

        return LayoutModel(
            workspaceName: includeWorkspaceName ? workspaceTitle : nil,
            columns: columns,
            rows: rows,
            cells: hasMeaningfulCells ? cells : nil
        )
```

Add a new private method to Describer:

```swift
    private func reconstructGeometry(panes: [[String: Any]], surfaceCount: Int) -> (columns: [Double], rows: [Int: [Double]]) {
        // Try geometry-based reconstruction if panes have position fields
        if let result = tryGeometryReconstruction(panes: panes) {
            return result
        }

        // Fallback: assume flat layout, equal widths
        if surfaceCount == 1 {
            return ([100.0], [:])
        }
        let pct = 100.0 / Double(surfaceCount)
        var columns = Array(repeating: pct, count: surfaceCount)
        normalizePercentages(&columns)
        return (columns, [:])
    }

    private func tryGeometryReconstruction(panes: [[String: Any]]) -> (columns: [Double], rows: [Int: [Double]], paneOrder: [Int])? {
        // Check if panes have geometry fields
        guard let firstPane = panes.first,
              firstPane["x"] != nil, firstPane["width"] != nil else {
            return nil
        }

        struct PaneGeometry {
            let originalIndex: Int
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        let geometries: [PaneGeometry] = panes.enumerated().compactMap { (idx, pane) in
            guard let x = (pane["x"] as? NSNumber)?.doubleValue,
                  let y = (pane["y"] as? NSNumber)?.doubleValue,
                  let w = (pane["width"] as? NSNumber)?.doubleValue,
                  let h = (pane["height"] as? NSNumber)?.doubleValue else { return nil }
            return PaneGeometry(originalIndex: idx, x: x, y: y, width: w, height: h)
        }
        guard geometries.count == panes.count else { return nil }

        // Group by unique x positions to find columns
        let uniqueXs = Array(Set(geometries.map { $0.x })).sorted()
        let totalWidth = geometries.map { $0.x + $0.width }.max() ?? 1.0

        // Column percentages and pane ordering (sorted by x then y)
        var columns: [Double] = []
        var rowsByColumn: [Int: [Double]] = [:]
        var paneOrder: [Int] = []

        for (colIndex, x) in uniqueXs.enumerated() {
            let colPanes = geometries.filter { $0.x == x }.sorted { $0.y < $1.y }
            let colWidth = colPanes.first!.width
            columns.append(colWidth / totalWidth * 100.0)

            // Track reordered pane indices
            for p in colPanes {
                paneOrder.append(p.originalIndex)
            }

            // Row splits within this column
            if colPanes.count > 1 {
                let totalHeight = colPanes.map { $0.y + $0.height }.max()! - colPanes.first!.y
                var rowPcts: [Double] = colPanes.map { $0.height / totalHeight * 100.0 }
                normalizePercentages(&rowPcts)
                rowsByColumn[colIndex] = rowPcts
            }
        }

        normalizePercentages(&columns)
        return (columns, rowsByColumn, paneOrder)
    }

    /// Ensure percentages sum to exactly 100 by adjusting the last element.
    private func normalizePercentages(_ pcts: inout [Double]) {
        // Round values that are very close to integers (floating-point drift)
        for i in pcts.indices {
            let rounded = pcts[i].rounded()
            if abs(pcts[i] - rounded) < 0.1 {
                pcts[i] = rounded
            }
        }
        // Adjust last element so sum == 100
        let sum = pcts.dropLast().reduce(0, +)
        if !pcts.isEmpty {
            pcts[pcts.count - 1] = 100.0 - sum
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "Describer" 2>&1`
Expected: All Describer tests pass.

- [ ] **Step 6: Run full test suite**

Run: `swift test 2>&1`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/CMUXLayout/Describer.swift Tests/CMUXLayoutTests/DescriberTests.swift
git commit -m "feat: add multi-column geometry reconstruction to Describer (#7)"
```

---

### Task 4: Describer — Row Splits

Add support for detecting row splits within columns (e.g., `cols:25,50,25 | rows[0]:60,40`).

**Files:**
- Modify: `Tests/CMUXLayoutTests/DescriberTests.swift`
- Modify: `Sources/CMUXLayout/Describer.swift` (likely already handled by Task 3 geometry code)

- [ ] **Step 1: Write failing test for column with row splits**

Add to `DescriberTests`:

```swift
@Test func describeColumnWithRowSplits() throws {
    let client = makeClient()
    // 2 columns: first column has 2 rows (60/40 split), second has 1 row
    stubPanes(client, panes: [
        ["id": "P1", "ref": "pane:1", "x": 0, "y": 0, "width": 250, "height": 600],
        ["id": "P2", "ref": "pane:2", "x": 0, "y": 600, "width": 250, "height": 400],
        ["id": "P3", "ref": "pane:3", "x": 250, "y": 0, "width": 750, "height": 1000],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S2", "ref": "surface:2", "type": "terminal", "title": ""],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S3", "ref": "surface:3", "type": "terminal", "title": ""],
    ])

    let model = try Describer(client: client).describe(workspace: "workspace:1")
    #expect(model.columns == [25.0, 75.0])
    #expect(model.rows[0] == [60.0, 40.0])
    #expect(model.rows[1] == nil)

    let descriptor = Serializer().serialize(model)
    #expect(descriptor == "cols:25,75 | rows[0]:60,40")
}
```

- [ ] **Step 2: Run test to check if it already passes**

Run: `swift test --filter "describeColumnWithRowSplits" 2>&1`
Expected: Likely PASS if Task 3's geometry code handles row grouping correctly. If FAIL, fix the geometry logic.

- [ ] **Step 3: Fix if needed, verify pass**

If the test failed, debug and fix the `tryGeometryReconstruction` method's row detection logic. The key issue would be in how panes are grouped by x-position and how row heights are calculated.

Run: `swift test --filter "Describer" 2>&1`
Expected: All Describer tests pass.

- [ ] **Step 4: Commit (if changes were needed)**

```bash
git add Sources/CMUXLayout/Describer.swift Tests/CMUXLayoutTests/DescriberTests.swift
git commit -m "feat: add row split detection to Describer (#7)"
```

---

### Task 5: Describer — Surface Types and Names

Add tests for browser surfaces, surface names, and the include-workspace-name flag.

**Files:**
- Modify: `Tests/CMUXLayoutTests/DescriberTests.swift`
- Modify: `Sources/CMUXLayout/Describer.swift` (likely already handled)

- [ ] **Step 1: Write test for browser surface detection**

```swift
@Test func describeBrowserSurface() throws {
    let client = makeClient()
    stubPanes(client, panes: [
        ["id": "P1", "ref": "pane:1", "x": 0, "y": 0, "width": 500, "height": 1000],
        ["id": "P2", "ref": "pane:2", "x": 500, "y": 0, "width": 500, "height": 1000],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S1", "ref": "surface:1", "type": "terminal", "title": "editor"],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S2", "ref": "surface:2", "type": "browser", "title": "docs", "url": "https://example.com"],
    ])

    let model = try Describer(client: client).describe(workspace: "workspace:1")
    let descriptor = Serializer().serialize(model)
    #expect(descriptor == "cols:50,50 | names:editor,docs=b:https://example.com")
}
```

- [ ] **Step 2: Write test for surface names without browser**

```swift
@Test func describeSurfaceNames() throws {
    let client = makeClient()
    stubPanes(client, panes: [
        ["id": "P1", "ref": "pane:1", "x": 0, "y": 0, "width": 333, "height": 1000],
        ["id": "P2", "ref": "pane:2", "x": 333, "y": 0, "width": 334, "height": 1000],
        ["id": "P3", "ref": "pane:3", "x": 667, "y": 0, "width": 333, "height": 1000],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S1", "ref": "surface:1", "type": "terminal", "title": "nav"],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S2", "ref": "surface:2", "type": "terminal", "title": "main"],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S3", "ref": "surface:3", "type": "terminal", "title": "logs"],
    ])

    let model = try Describer(client: client).describe(workspace: "workspace:1")
    let descriptor = Serializer().serialize(model)
    // 333/1000 = 33.3%, 334/1000 = 33.4%, 333/1000 = 33.3%
    // After normalization: last column adjusted so sum = 100
    #expect(descriptor.contains("names:nav,main,logs"))
}
```

- [ ] **Step 3: Write test for include-workspace-name**

```swift
@Test func describeWithWorkspaceName() throws {
    let client = makeClient(workspaceTitle: "Dev")
    stubPanes(client, panes: [
        ["id": "P1", "ref": "pane:1"],
    ])
    stubSurfaces(client, surfaces: [
        ["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""],
    ])

    let model = try Describer(client: client).describe(workspace: "workspace:1", includeWorkspaceName: true)
    let descriptor = Serializer().serialize(model)
    #expect(descriptor.hasPrefix("workspace:Dev"))
}
```

- [ ] **Step 4: Run all Describer tests**

Run: `swift test --filter "Describer" 2>&1`
Expected: All pass. The surface type/name logic was implemented in Task 2.

- [ ] **Step 5: Commit**

```bash
git add Tests/CMUXLayoutTests/DescriberTests.swift
git commit -m "test: add surface type, name, and workspace name tests for Describer (#7)"
```

---

### Task 6: Describer — Error Cases

Add tests for error scenarios.

**Files:**
- Modify: `Tests/CMUXLayoutTests/DescriberTests.swift`

- [ ] **Step 1: Write test for workspace not found**

```swift
@Test func describeWorkspaceNotFound() throws {
    let client = RecordingSocketClient()
    client.stub(method: "workspace.list", result: [
        "workspaces": [] as [[String: Any]],
    ])

    let describer = Describer(client: client)
    #expect(throws: DescriberError.workspaceNotFound("workspace:99")) {
        try describer.describe(workspace: "workspace:99")
    }
}
```

- [ ] **Step 2: Write test for empty pane list**

```swift
@Test func describeEmptyPaneList() throws {
    let client = makeClient()
    stubPanes(client, panes: [])

    let describer = Describer(client: client)
    #expect(throws: DescriberError.cannotReadTopology) {
        try describer.describe(workspace: "workspace:1")
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter "Describer" 2>&1`
Expected: All pass. (`DescriberError` already conforms to `Equatable` from Task 2.)

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/CMUXLayoutTests/DescriberTests.swift
git commit -m "test: add error case tests for Describer (#7)"
```

---

### Task 7: Describer — Round-Trip Validation

Add a test that verifies describe output can be parsed back by Parser.

**Files:**
- Modify: `Tests/CMUXLayoutTests/DescriberTests.swift`

- [ ] **Step 1: Write round-trip test**

```swift
@Test func describeOutputParsesBack() throws {
    let client = makeClient()
    stubPanes(client, panes: [
        ["id": "P1", "ref": "pane:1", "x": 0, "y": 0, "width": 250, "height": 600],
        ["id": "P2", "ref": "pane:2", "x": 0, "y": 600, "width": 250, "height": 400],
        ["id": "P3", "ref": "pane:3", "x": 250, "y": 0, "width": 500, "height": 1000],
        ["id": "P4", "ref": "pane:4", "x": 750, "y": 0, "width": 250, "height": 1000],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S1", "ref": "surface:1", "type": "terminal", "title": "nav"],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S2", "ref": "surface:2", "type": "terminal", "title": "sidebar"],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S3", "ref": "surface:3", "type": "terminal", "title": "main"],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S4", "ref": "surface:4", "type": "browser", "title": "docs", "url": "https://x.com"],
    ])

    let model = try Describer(client: client).describe(workspace: "workspace:1")
    let descriptor = Serializer().serialize(model)

    // Verify it parses back
    let parsed = try Parser().parse(descriptor)
    #expect(parsed.columns.count == model.columns.count)
    #expect(parsed.cellCount == model.cellCount)
}
```

- [ ] **Step 2: Run test**

Run: `swift test --filter "describeOutputParsesBack" 2>&1`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/CMUXLayoutTests/DescriberTests.swift
git commit -m "test: add round-trip validation for Describer output (#7)"
```

---

### Task 8: CLI Integration — handleDescribe

Wire up the `describe` command in `main.swift`.

**Files:**
- Modify: `Sources/cmux-layout/main.swift`

- [ ] **Step 1: Add describe case to switch and error handling**

In `Sources/cmux-layout/main.swift`, add `case "describe"` to the switch statement (after the `case "config"` line, before `case "--help"`):

```swift
            case "describe":
                try handleDescribe(Array(args.dropFirst()))
```

Add the error catch clause (after `catch let error as ConfigError`):

```swift
        } catch let error as DescriberError {
            fputs("Describe error: \(error)\n", stderr)
            exit(3)
```

- [ ] **Step 2: Implement handleDescribe**

Add the `handleDescribe` static method to `CLI` (before `printUsage()`):

```swift
    static func handleDescribe(_ args: [String]) throws {
        var workspace: String?
        var includeName = false
        var jsonOutput = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--workspace":
                i += 1
                guard i < args.count else {
                    fputs("--workspace requires a value\n", stderr)
                    exit(1)
                }
                workspace = args[i]
            case "--include-name":
                includeName = true
            case "--json":
                jsonOutput = true
            default:
                fputs("Unknown option: \(args[i])\n", stderr)
                exit(1)
            }
            i += 1
        }

        guard let ws = workspace else {
            fputs("Usage: cmux-layout describe --workspace WS [--include-name] [--json]\n", stderr)
            exit(1)
        }

        let client = LiveSocketClient()
        let describer = Describer(client: client)
        let model = try describer.describe(workspace: ws, includeWorkspaceName: includeName)
        let descriptor = Serializer().serialize(model)

        if jsonOutput {
            var output: [String: Any] = [
                "descriptor": descriptor,
                "workspace": ws,
            ]
            if let name = model.workspaceName {
                output["workspace_name"] = name
            }
            if let cells = model.cells {
                // Compute column/row for each cell from model geometry
                var cellPositions: [(column: Int, row: Int)] = []
                for col in 0..<model.columns.count {
                    let rowCount = model.rows[col]?.count ?? 1
                    for row in 0..<rowCount {
                        cellPositions.append((column: col, row: row))
                    }
                }
                output["cells"] = cells.enumerated().map { (idx, cell) -> [String: Any] in
                    let pos = idx < cellPositions.count ? cellPositions[idx] : (column: idx, row: 0)
                    var dict: [String: Any] = [
                        "column": pos.column,
                        "row": pos.row,
                    ]
                    if let name = cell.name { dict["name"] = name }
                    switch cell.type {
                    case .terminal: dict["type"] = "terminal"
                    case .browser(let url):
                        dict["type"] = "browser"
                        if let url = url { dict["url"] = url }
                    }
                    return dict
                }
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } else {
            print(descriptor)
        }
    }
```

- [ ] **Step 3: Update printUsage**

Add the describe usage line after the `verify` line in `printUsage()`:

```swift
          cmux-layout describe --workspace WS [--include-name] [--json]
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1`
Expected: Build succeeds.

- [ ] **Step 5: Run full test suite**

Run: `swift test 2>&1`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/cmux-layout/main.swift
git commit -m "feat: add describe CLI command with --workspace, --include-name, --json (#7)"
```

---

### Task 9: Geometry Fallback — Pane Ordering Without Geometry Fields

Add fallback path for when `pane.list` doesn't return geometry fields. Assumes panes are in left-to-right, top-to-bottom order. Uses resize probing to get divider positions.

**Files:**
- Modify: `Tests/CMUXLayoutTests/DescriberTests.swift`
- Modify: `Sources/CMUXLayout/Describer.swift`

- [ ] **Step 1: Write test for flat layout without geometry fields**

```swift
@Test func describeFlatLayoutWithoutGeometry() throws {
    let client = makeClient()
    // Panes without x/y/width/height fields — geometry fallback kicks in
    stubPanes(client, panes: [
        ["id": "P1", "ref": "pane:1"],
        ["id": "P2", "ref": "pane:2"],
        ["id": "P3", "ref": "pane:3"],
    ])
    // Stub resize probing: 3 panes means 2 dividers
    // Divider 1 at 0.333, divider 2 at 0.667
    client.enqueue(method: "pane.resize", result: ["old_divider_position": 0.333, "new_divider_position": 0.334])
    client.enqueue(method: "pane.resize", result: ["old_divider_position": 0.334, "new_divider_position": 0.333])  // reverse
    client.enqueue(method: "pane.resize", result: ["old_divider_position": 0.667, "new_divider_position": 0.668])
    client.enqueue(method: "pane.resize", result: ["old_divider_position": 0.668, "new_divider_position": 0.667])  // reverse

    enqueueSurfaces(client, surfaces: [
        ["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S2", "ref": "surface:2", "type": "terminal", "title": ""],
    ])
    enqueueSurfaces(client, surfaces: [
        ["id": "S3", "ref": "surface:3", "type": "terminal", "title": ""],
    ])

    let model = try Describer(client: client).describe(workspace: "workspace:1")
    // 0 to 0.333 = 33%, 0.333 to 0.667 = 33%, 0.667 to 1.0 = 33%
    #expect(model.columns.count == 3)
    // All should be close to 33.3
    for col in model.columns {
        #expect(abs(col - 33.3) < 1.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "describeFlatLayoutWithoutGeometry" 2>&1`
Expected: FAIL — fallback produces equal-width estimate without probing.

- [ ] **Step 3: Implement resize probing fallback**

Update `reconstructGeometry` in `Sources/CMUXLayout/Describer.swift` to probe dividers when geometry fields are absent:

```swift
    /// Returns (columns, rows, paneOrder). paneOrder is non-nil when geometry-based
    /// reconstruction reorders panes by position (indices into original pane array).
    private func reconstructGeometry(panes: [[String: Any]], surfaceCount: Int, workspaceId: String) -> (columns: [Double], rows: [Int: [Double]], paneOrder: [Int]?) {
        // Try geometry-based reconstruction if panes have position fields
        if let result = tryGeometryReconstruction(panes: panes) {
            return (result.columns, result.rows, result.paneOrder)
        }

        // Fallback: assume flat layout (all columns, no rows)
        // Use resize probing to get actual divider positions
        if panes.count > 1, let result = tryResizeProbing(panes: panes, workspaceId: workspaceId) {
            return (result.columns, result.rows, nil)
        }

        // Last resort: single pane or equal widths
        if surfaceCount == 1 {
            return ([100.0], [:], nil)
        }
        let pct = 100.0 / Double(surfaceCount)
        var columns = Array(repeating: pct, count: surfaceCount)
        normalizePercentages(&columns)
        return (columns, [:], nil)
    }

    /// Probe divider positions using pane.resize (non-destructive: probe + reverse).
    /// Assumes flat layout: each pane = one column, no row splits.
    private func tryResizeProbing(panes: [[String: Any]], workspaceId: String) -> (columns: [Double], rows: [Int: [Double]])? {
        var dividerPositions: [Double] = [0.0]

        // Probe each divider (between pane i and pane i+1)
        for i in 1..<panes.count {
            guard let paneId = panes[i]["id"] as? String else { return nil }
            // Probe: resize left by 1, read position, then reverse
            guard let probeResp = try? client.call(method: "pane.resize", params: [
                "pane_id": paneId, "workspace_id": workspaceId,
                "direction": "left", "amount": 1,
            ]),
            let pos = probeResp.result?["old_divider_position"] as? Double else {
                return nil
            }
            // Reverse the probe
            _ = try? client.call(method: "pane.resize", params: [
                "pane_id": paneId, "workspace_id": workspaceId,
                "direction": "right", "amount": 1,
            ])
            dividerPositions.append(pos)
        }
        dividerPositions.append(1.0)

        // Convert divider positions to percentages
        var columns: [Double] = []
        for i in 0..<(dividerPositions.count - 1) {
            columns.append((dividerPositions[i + 1] - dividerPositions[i]) * 100.0)
        }
        normalizePercentages(&columns)

        return (columns, [:])
    }
```

**Note:** The `reconstructGeometry` call in `describe()` must pass `workspaceId`:
```swift
        let (columns, rows, paneOrder) = reconstructGeometry(panes: panes, surfaceCount: surfaceInfos.count, workspaceId: workspaceId)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "describeFlatLayoutWithoutGeometry" 2>&1`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `swift test 2>&1`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CMUXLayout/Describer.swift Tests/CMUXLayoutTests/DescriberTests.swift
git commit -m "feat: add resize probing fallback for geometry reconstruction (#7)"
```

---

### Task 10: Grid Shorthand and Final Polish

Verify that the Serializer's grid shorthand detection works with describe output (e.g., 2x2 equal grid produces `grid:2x2`). Clean up any rough edges.

**Files:**
- Modify: `Tests/CMUXLayoutTests/DescriberTests.swift`

- [ ] **Step 1: Write test for grid shorthand**

```swift
@Test func describeEqualGridProducesShorthand() throws {
    let client = makeClient()
    stubPanes(client, panes: [
        ["id": "P1", "ref": "pane:1", "x": 0, "y": 0, "width": 500, "height": 500],
        ["id": "P2", "ref": "pane:2", "x": 0, "y": 500, "width": 500, "height": 500],
        ["id": "P3", "ref": "pane:3", "x": 500, "y": 0, "width": 500, "height": 500],
        ["id": "P4", "ref": "pane:4", "x": 500, "y": 500, "width": 500, "height": 500],
    ])
    for _ in 0..<4 {
        enqueueSurfaces(client, surfaces: [
            ["id": "S\(Int.random(in: 1000...9999))", "ref": "surface:\(Int.random(in: 1...99))", "type": "terminal", "title": ""],
        ])
    }

    let model = try Describer(client: client).describe(workspace: "workspace:1")
    let descriptor = Serializer().serialize(model)
    #expect(descriptor == "grid:2x2")
}
```

- [ ] **Step 2: Run test**

Run: `swift test --filter "describeEqualGridProducesShorthand" 2>&1`
Expected: PASS (Serializer handles grid shorthand automatically).

- [ ] **Step 3: Run full test suite one final time**

Run: `swift test 2>&1`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/CMUXLayoutTests/DescriberTests.swift
git commit -m "test: verify grid shorthand output from Describer (#7)"
```

---

### Task 11: Create Pull Request

**Files:** None (git operations only)

- [ ] **Step 1: Push branch**

```bash
git push origin feature/describe-command
```

- [ ] **Step 2: Create PR**

```bash
gh pr create --title "feat: add describe command (#7)" --body "$(cat <<'EOF'
## Summary

- Adds `describe` command that reverse-engineers a live cmux workspace topology into a descriptor string
- New `Describer` struct queries socket API (`workspace.list`, `pane.list`, `pane.surfaces`) to reconstruct a `LayoutModel`
- Geometry reconstruction from pane position fields, with resize-probing fallback
- CLI supports `--workspace` (required), `--include-name`, and `--json` flags
- Output is pipeable and round-trip validated (parses back via `cmux-layout validate`)

Closes #7

## Test plan

- [ ] Unit tests cover: single pane, multi-column, row splits, browser surfaces, surface names, workspace name, grid shorthand, error cases, round-trip validation
- [ ] All tests pass (`swift test`)
- [ ] Manual test: `cmux-layout describe --workspace workspace:1` on a live cmux instance
- [ ] Manual test: pipe output to `cmux-layout validate` to confirm valid descriptor

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Report PR URL**
