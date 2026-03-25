# Design: `describe` Command

**Date:** 2026-03-25
**Issue:** #7
**Branch:** `feature/describe-command`

## Purpose

Reverse-engineer a live cmux workspace topology into a descriptor string — the inverse of `apply`. Enables capturing existing layouts as reusable templates without manually writing descriptors.

## Requirements

- Query workspace topology via cmux socket API
- Reconstruct column/row percentages from pane geometry
- Detect surface types (terminal vs browser) and names/titles
- Capture browser URLs when available
- Output valid descriptor parseable by `cmux-layout validate`
- Semantic equivalence is the fidelity target (not byte-identical round-trips)

## Architecture

### New File: `Sources/CMUXLayout/Describer.swift`

A standalone `Describer` struct following the same pattern as `Verifier` and `Executor`:

```swift
public struct Describer {
    private let client: CMUXSocketClient

    public init(client: CMUXSocketClient) {
        self.client = client
    }

    /// Describes a workspace's current topology as a LayoutModel.
    /// The `workspace` parameter is a user-facing ref (e.g., "workspace:1").
    /// Internally resolved to a workspace_id UUID via workspace.list.
    public func describe(workspace: String, includeWorkspaceName: Bool = false) throws -> LayoutModel
}

public enum DescriberError: Error {
    case workspaceNotFound(String)
    case cannotDetermineGeometry
    case cannotReadTopology
}
```

### Flow

1. **Resolve workspace:** Call `workspace.list`, find the entry whose `ref` matches the provided workspace ref string, extract `id` (UUID) and `title`. Throw `DescriberError.workspaceNotFound` if no match. Note: `Verifier` passes the workspace as key `"workspace"` to `pane.list`, while `Executor` uses `"workspace_id"`. Describer will use `"workspace_id"` (the UUID) for consistency with `Executor`.
2. **Get panes:** Call `pane.list` with `workspace_id` (UUID). Attempt to extract geometry fields (`x`, `y`, `width`, `height` or similar) from the response.
3. **Get surfaces:** For each pane, call `pane.surfaces` to get surface type (`"terminal"` / `"browser"`), title, and URL (for browsers).
4. **Reconstruct geometry:** Convert pane positions/sizes into column percentages and row percentages per column.
5. **Build cells:** Create `CellSpec` array with surface names and types. Terminal commands are not recoverable (ephemeral). Browser URLs are captured when available.
6. **Return `LayoutModel`:** The caller feeds this to `Serializer().serialize()` for descriptor output.

### Geometry Reconstruction

Discovery fallback chain (geometry API is not yet verified):

1. **Direct geometry:** Parse `pane.list` response for position/size fields. If present, compute percentages from absolute values relative to workspace total dimensions.
2. **Pane ordering assumption (fallback):** If no geometry fields are available, assume `pane.list` returns panes in left-to-right, top-to-bottom order (consistent with how `Executor.collectCells` maps panes to column/row indices). Use the total pane count and expected column structure to infer the layout.
3. **Resize probing (fallback for percentages):** If divider positions are needed but not in the pane data, use the probe technique from `Executor.performResizes`: call `pane.resize` with amount 1, read `old_divider_position`/`new_divider_position` (fractional 0.0–1.0), then reverse. This gives divider positions but not spatial relationships — combine with pane ordering to get full topology.

**Topology inference:**
- With geometry fields: panes sharing the same x-position are in the same column; within a column, panes are ordered by y-position
- Without geometry fields: panes are assumed ordered left-to-right, top-to-bottom; column/row membership is inferred from the ordered list
- Column widths = differences between consecutive horizontal divider positions × 100
- Row heights = differences between consecutive vertical divider positions × 100

**Percentage normalization:**
- Round to nearest integer when within 0.5 of a whole number
- If column percentages don't sum to 100 after rounding (e.g., three columns of 33.3 = 99.9), allocate the remainder to the last column to ensure sum = 100
- The Serializer's `formatPercentages` handles output formatting (integers for whole numbers, one decimal otherwise)

### CLI Integration

Add `case "describe"` to `Sources/cmux-layout/main.swift`.

```
cmux-layout describe --workspace workspace:1 [--include-name] [--json]
```

- `--workspace` — **required**, which workspace to describe
- `--include-name` — include `workspace:Name` prefix in output
- `--json` — structured JSON output instead of descriptor string

**Default output:** Raw descriptor string on stdout (no framing). Pipeable:
```bash
cmux-layout describe --workspace workspace:1 | xargs -I{} cmux-layout save my-layout "{}"
```

**JSON output:**
```json
{
  "descriptor": "cols:25,50,25 | rows[0]:60,40 | names:nav,main,logs",
  "workspace": "workspace:1",
  "workspace_name": "Dev",
  "cells": [
    {"name": "nav", "type": "terminal", "column": 0, "row": 0},
    {"name": "main", "type": "terminal", "column": 1, "row": 0},
    {"name": "logs", "type": "terminal", "column": 1, "row": 1}
  ]
}
```

**Error handling:** `DescriberError` for topology issues. Exit codes: `SocketError` → exit 2, `DescriberError` → exit 3 (same as `ExecutorError`). Add `catch let error as DescriberError` to `main.swift`.

**Usage line added to `printUsage()`:**
```
cmux-layout describe --workspace WS [--include-name] [--json]
```

## Testing

### Unit Tests: `Tests/CMUXLayoutTests/DescriberTests.swift`

Use `RecordingSocketClient` with canned responses.

**Note:** The existing `RecordingSocketClient` returns the same canned response for every call to a given method. The `describe` flow calls `pane.surfaces` once per pane, needing different responses for different pane IDs. The client needs to be extended to support per-call differentiation — either by keying on method + a param value, or using an ordered response queue for repeated methods.

Test cases:

| Scenario | Expected Output |
|----------|----------------|
| Single pane | `cols:100` |
| Two equal columns | `cols:50,50` |
| Three unequal columns | `cols:25,50,25` |
| Column with row splits | `cols:25,50,25 \| rows[0]:60,40` |
| Browser surface | `names:docs=b:https://example.com` |
| Surface names | `names:nav,main,logs` |
| Include workspace name | `workspace:Dev \| cols:...` |
| Grid shorthand (via Serializer) | `grid:2x2` |
| Round-trip: output parses back | `Parser().parse(output)` succeeds |
| Workspace not found | Throws `DescriberError.workspaceNotFound` |
| Empty pane list | Throws `DescriberError.cannotReadTopology` |
| Socket error during describe | Propagates `SocketError` |

### Integration Tests

Extend `Tests/CMUXLayoutTests/IntegrationTests.swift` (gated by `CMUX_INTEGRATION`):

- Apply a known descriptor, describe the same workspace, validate the result parses and produces equivalent cell count
- Used during development for geometry API discovery — inspect actual `pane.list` responses

## What This Does NOT Change

- No modifications to existing commands (apply, validate, plan, verify, save, load, list, config)
- No changes to the descriptor syntax
- No external dependencies added
- Terminal commands remain unrecoverable (they're ephemeral)
