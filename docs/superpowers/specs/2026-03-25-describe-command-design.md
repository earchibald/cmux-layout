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
    public func describe(workspace: String, includeWorkspaceName: Bool = false) throws -> LayoutModel
}

public enum DescriberError: Error {
    case workspaceNotFound(String)
    case cannotDetermineGeometry
    case cannotReadTopology
}
```

### Flow

1. **Resolve workspace:** Call `workspace.list`, find the entry matching the provided ref, extract `id` and `title`.
2. **Get panes:** Call `pane.list` with `workspace_id`. Attempt to extract geometry fields (`x`, `y`, `width`, `height` or similar) from the response.
3. **Get surfaces:** For each pane, call `pane.surfaces` to get surface type (`"terminal"` / `"browser"`), title, and URL (for browsers).
4. **Reconstruct geometry:** Convert pane positions/sizes into column percentages and row percentages per column.
5. **Build cells:** Create `CellSpec` array with surface names and types. Terminal commands are not recoverable (ephemeral). Browser URLs are captured when available.
6. **Return `LayoutModel`:** The caller feeds this to `Serializer().serialize()` for descriptor output.

### Geometry Reconstruction

Discovery fallback chain (geometry API is not yet verified):

1. **Direct geometry:** Parse `pane.list` response for position/size fields. If present, compute percentages from absolute values relative to workspace total dimensions.
2. **Resize probing (fallback):** Use the same probe technique from `Executor.performResizes`: call `pane.resize` with amount 1, read `old_divider_position`/`new_divider_position` (fractional 0.0–1.0), then reverse the resize. Gives divider positions directly.

**Topology inference:**
- Panes sharing the same x-position are in the same column
- Within a column, panes are ordered by y-position into rows
- Column widths = differences between consecutive horizontal divider positions × 100
- Row heights = differences between consecutive vertical divider positions × 100
- Round to nearest integer when within 0.5 of a whole number

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

**Error handling:** `DescriberError` for topology issues. Exit codes follow existing convention (exit 2 for socket errors).

**Usage line added to `printUsage()`:**
```
cmux-layout describe --workspace WS [--include-name] [--json]
```

## Testing

### Unit Tests: `Tests/CMUXLayoutTests/DescriberTests.swift`

Use `RecordingSocketClient` with canned responses. Test cases:

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

### Integration Tests

Extend `Tests/CMUXLayoutTests/IntegrationTests.swift` (gated by `CMUX_INTEGRATION`):

- Apply a known descriptor, describe the same workspace, validate the result parses and produces equivalent cell count
- Used during development for geometry API discovery — inspect actual `pane.list` responses

## What This Does NOT Change

- No modifications to existing commands (apply, validate, plan, verify, save, load, list, config)
- No changes to the descriptor syntax
- No external dependencies added
- Terminal commands remain unrecoverable (they're ephemeral)
