# Handoff: Issue #7 — `describe` Command

**Date:** 2026-03-25
**Branch:** `feature/describe-command` (already created, based on main)
**Issue:** https://github.com/earchibald/cmux-layout/issues/7

## What To Build

A `describe` command that queries a live cmux workspace and outputs its topology as a descriptor string — the inverse of `apply`. This lets users capture existing layouts as reusable templates.

```bash
cmux-layout describe --workspace workspace:1
# → cols:25,50,25 | rows[0]:60,40 | names:nav,main,logs

cmux-layout describe --workspace workspace:1 --include-name
# → workspace:Dev | cols:25,50,25 | rows[0]:60,40 | names:nav,main,logs
```

## Process

1. Read this document and the issue (#7)
2. Start with `/brainstorming` — the issue says to use superpowers brainstorming
3. Follow: brainstorm → spec → plan → subagent-driven execution → PR
4. Create PR against `main` from this branch, referencing issue #7
5. Seek human approval before merging

## Project Overview

**cmux-layout** is a Swift 6.0 CLI tool (zero external dependencies) that creates declarative cmux layouts from a descriptor DSL. It communicates with cmux via a Unix domain socket (JSON-RPC).

**Descriptor syntax:** `workspace:Name | cols:25,50,25 | rows[0]:60,40 | names:nav,docs=b:https://x.com,logs`

**Surface types:** terminals (optionally with commands via TOML) and browsers (with URLs).

## Key Files To Read First

| File | Why | Lines |
|------|-----|-------|
| `Sources/CMUXLayout/LayoutModel.swift` | The data model: `SurfaceType`, `CellSpec`, `LayoutModel` | ~50 |
| `Sources/CMUXLayout/Serializer.swift` | Converts `LayoutModel` → descriptor string. **describe will need the inverse.** | ~87 |
| `Sources/CMUXLayout/Verifier.swift` | Already reads workspace topology via socket. **Closest existing code to what describe needs.** | ~41 |
| `Sources/CMUXLayout/Executor.swift` | `collectCells` gathers pane/surface refs — describe needs similar logic but also extracts dimensions. | ~320 |
| `Sources/CMUXLayout/SocketClient.swift` | `CMUXSocketClient` protocol and `LiveSocketClient`. All cmux communication goes through here. | ~118 |
| `Sources/cmux-layout/main.swift` | CLI dispatch — add the `describe` case here. | ~250 |

## cmux Socket API (Verified Working)

These are the socket methods relevant to describe:

| Method | Params | Returns | Notes |
|--------|--------|---------|-------|
| `pane.list` | `workspace_id` | `panes: [{id, ref, ...}]` | Gets all panes in a workspace |
| `pane.surfaces` | `workspace_id`, `pane_id` | `surfaces: [{id, ref, type, title, ...}]` | Gets surfaces per pane, includes `type` ("terminal"/"browser") and `title` |
| `workspace.list` | none | `workspaces: [{id, ref, title, ...}]` | To resolve workspace ref → id and get title |

**Unknown:** How to get pane dimensions/percentages. The Verifier currently only counts panes — it doesn't extract actual widths/heights. You'll need to discover what the socket API returns for pane geometry. Try:
- Check if `pane.list` response includes `width`/`height`/`x`/`y` fields
- Check if there's a `workspace.layout` or `workspace.topology` method
- The `pane.resize` response returns `old_divider_position`/`new_divider_position` — these are fractional positions that could be useful

## Architecture Decisions Already Made

- **Zero dependencies** — no external packages, Foundation only
- **Swift Testing** framework (`@Suite`, `@Test`, `#expect`)
- **Socket client is mockable** — `CMUXSocketClient` protocol, `RecordingSocketClient` in tests
- **Serializer already exists** — once you have a `LayoutModel`, `Serializer().serialize(model)` gives you the descriptor string. The hard part is building the `LayoutModel` from live topology.
- **CellSpec includes surface type** — `.terminal(command: String?)` and `.browser(url: String?)`. The describe command can detect type from `pane.surfaces` response (`type` field) but cannot recover commands (they're ephemeral).

## Testing Patterns

- Unit tests use `RecordingSocketClient` with canned responses (`Tests/CMUXLayoutTests/ExecutorTests.swift`)
- Integration tests are gated by `CMUX_INTEGRATION` env var (`Tests/CMUXLayoutTests/IntegrationTests.swift`)
- All tests use Swift Testing: `import Testing`, `@Suite`, `@Test`, `#expect`, `try #require`
- Temp directories for ConfigManager tests: `makeTempDir()` + `defer { cleanup(dir) }`

## Specs and Plans Location

- Specs: `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`
- Plans: `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`

## What NOT To Change

- Don't modify existing commands (apply, validate, plan, verify, save, load, list, config)
- Don't change the descriptor syntax
- Don't add external dependencies
