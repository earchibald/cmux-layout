# Browser Surfaces Support

**Date:** 2026-03-24
**Issue:** #3
**Status:** Approved

## Overview

Extend cmux-layout to support browser surfaces alongside terminal surfaces. Cells can be marked as browser type with an optional URL via compact inline syntax in the descriptor or expanded TOML tables in templates.

## Descriptor Syntax Extension

The `names:` segment accepts cell specs with optional type and URL.

### Grammar

```
names: <cell>[,<cell>]*

cell := name                   # terminal (default): "nav"
      | name=b:url             # named browser with URL: "docs=b:https://x.com"
      | name=b:                # named browser, blank
      | b:url                  # unnamed browser with URL
      | b:                     # unnamed browser, blank
      | name=t:                # explicit terminal (future-proof)
```

### Examples

```
names:nav,docs=b:https://docs.rs,logs
names:nav,b:https://grafana.local/dash,logs
names:main,b:,sidebar
```

### Constraints

- URLs cannot contain bare commas — commas are cell delimiters. Use `%2C` for literal commas.
- Backwards compatible: bare names (`names:nav,main,logs`) parse as all terminals, identical to current behavior.

## Data Model Changes

### New Types

```swift
public enum SurfaceType: Equatable, Sendable {
    case terminal
    case browser(url: String?)  // nil = blank browser
}

public struct CellSpec: Equatable, Sendable {
    public let name: String?
    public let type: SurfaceType
}
```

### LayoutModel Change

`LayoutModel.names: [String]?` is replaced by `LayoutModel.cells: [CellSpec]?`. When `cells` is nil, all surfaces are terminals. When present, count must match `cellCount` (same validation as current `nameCountMismatch`).

## Parser Changes

The `names:` segment parsing is extended to handle the cell spec grammar. For each comma-separated token:

1. If it contains `=`, split into `name=remainder`. Parse `remainder` for type prefix.
2. If it starts with `b:`, it's an unnamed browser. The rest is the URL (empty string → nil URL).
3. If it starts with `t:`, it's an explicit terminal.
4. Otherwise, it's a bare name — terminal type, no URL.

The parser produces `[CellSpec]` which is stored in `LayoutModel.cells`.

## Serializer Changes

The `Serializer` round-trips `CellSpec` back to compact syntax:
- Terminal with name → `name`
- Terminal with name and explicit type → `name=t:`
- Browser with name and URL → `name=b:url`
- Browser with name, no URL → `name=b:`
- Browser without name, with URL → `b:url`
- Browser without name, no URL → `b:`

Only emit `t:` prefix when the CellSpec was explicitly typed (to preserve round-trip fidelity). Default behavior: omit `t:` for terminals.

## Executor Changes

After layout creation (splits + resizes + collectCells), the Executor swaps terminal surfaces for browser surfaces where specified:

1. For each cell with `type: .browser(url:)`:
   - Call `surface.create` with `type: "browser"`, optional `url` param, targeting the cell's pane
   - Call `surface.close` on the original terminal surface
   - Update the cell's `surfaceRef` to the new browser surface ref
2. After all swaps, rename all named cells (as today via `tab.action`)

The rename step happens after browser swaps so it targets the final surface.

### Socket API

- **Create browser:** `surface.create` with params `workspace_id`, `pane_id`, `type: "browser"`, optional `url`
- **Close terminal:** `surface.close` with params `workspace_id`, `surface_id`

Both verified working against live cmux.

## TOML Expanded Form

Templates can specify per-cell metadata via nested tables in `config.toml`:

```toml
[templates.dev]
descriptor = "workspace:Dev | cols:25,50,25 | names:nav,docs,logs"

[templates.dev.cells.docs]
type = "browser"
url = "https://docs.example.com"
```

### Resolution Rules

- If TOML cell tables exist AND the descriptor has inline cell specs, TOML tables take precedence.
- If only the descriptor has cell specs, use those.
- If only TOML cell tables exist, the descriptor must have `names:` with matching names for positional mapping.
- Cells not listed in TOML tables default to terminal.

### ConfigManager Changes

- `load(name:)` returns a `LayoutModel` instead of a raw descriptor string. It parses the descriptor and merges any TOML cell tables.
- `save(name:descriptor:)` stores the compact descriptor as-is. TOML cell tables are hand-edited by users. No CLI support for writing cell tables (YAGNI for now).

### TOML Parser Note

The TOML parser already supports dotted table names (`[templates.dev.cells.docs]`) and string values. No parser changes needed — ConfigManager just reads deeper-nested tables.

## Files Changed

### Modified

- `Sources/CMUXLayout/LayoutModel.swift` — add `SurfaceType`, `CellSpec`, replace `names` with `cells`
- `Sources/CMUXLayout/Parser.swift` — extend `names:` segment parsing for cell spec grammar
- `Sources/CMUXLayout/Serializer.swift` — serialize `CellSpec` back to compact syntax
- `Sources/CMUXLayout/Executor.swift` — add browser surface swap logic after layout creation
- `Sources/CMUXLayout/ConfigManager.swift` — `load` returns `LayoutModel`, merge TOML cell tables
- `Sources/cmux-layout/main.swift` — update `handleLoad` for new `load` return type
- `Tests/CMUXLayoutTests/ParserTests.swift` — cell spec parsing tests
- `Tests/CMUXLayoutTests/SerializerTests.swift` — cell spec round-trip tests
- `Tests/CMUXLayoutTests/ExecutorTests.swift` — browser swap mock tests
- `Tests/CMUXLayoutTests/IntegrationTests.swift` — browser surface live tests
- `Tests/CMUXLayoutTests/ConfigManagerTests.swift` — TOML cell table merge tests

### No New Files

All changes are modifications to existing files.

## Testing Strategy

### Parser Tests

- Bare names backwards compat → terminal CellSpecs
- Named browser with URL: `docs=b:https://x.com`
- Unnamed browser: `b:https://x.com`
- Blank browser: `b:` and `docs=b:`
- Explicit terminal: `nav=t:`
- Mixed: `nav,docs=b:https://x.com,logs`
- Cell count validation still works

### Serializer Tests

- Round-trip each CellSpec variant through serialize → parse

### Executor Unit Tests (mock client)

- Browser cell triggers `surface.create` + `surface.close`
- Terminal cell does not trigger swap
- Rename happens after browser swap (targets correct surface)

### Integration Tests (live cmux)

- Create layout with browser cell, verify surface type via `pane.surfaces`
- Create mixed layout, verify each surface type

### ConfigManager Tests

- `load` merges TOML cell tables onto parsed descriptor
- TOML tables override inline cell specs
- Missing TOML cell entries default to terminal
