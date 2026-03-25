# Persistent Storage for Configuration and Templates

**Date:** 2026-03-24
**Issue:** #1
**Status:** Approved

## Overview

Replace the existing `ProfileStore` (JSON-based profile storage) with a TOML-based configuration system. A single `config.toml` file at `~/.config/cmux-layout/config.toml` holds both application settings and workspace templates. The file is self-documenting with commented-out examples and auto-upgrades across schema versions.

## Config File Format & Schema

**Location:** `~/.config/cmux-layout/config.toml`

On first use of any command, if the file is missing, it is created with a scaffolded template:

```toml
# cmux-layout configuration
# Version: 1

[settings]
# No settings defined yet. Future options will appear here.

[templates]
# Save workspace templates using: cmux-layout save <name> <descriptor>
# Example:
# [templates.dev]
# descriptor = "workspace:Dev | cols:25,50,25 | rows[0]:60,40"
```

### Version Management

The schema version is embedded as a comment (`# Version: N`) at the top of the file. On each run, cmux-layout compares the file version against the code's current schema version:

- **File older than code:** Upgrade — append new commented-out sections, preserve existing values, prepend `# DEPRECATED:` warning to deprecated keys.
- **File newer than code:** Error — "config.toml is version N but this binary supports up to version M. Please upgrade cmux-layout."
- **Unsupported/removed keys:** Error with a message explaining what changed.

## TOML Parser (Minimal Subset)

A hand-rolled `TOMLParser` supporting only the subset required. Zero external dependencies.

### Supported

- Key/value pairs: `key = "string value"`
- Table headers: `[section]` and `[section.subsection]`
- Comments: `# ...` (full-line and inline)
- String values: basic quoted strings with `\"` and `\\` escapes
- Bare keys: alphanumeric, dash, underscore

### Not Supported

Arrays, inline tables, multi-line strings, datetime, integer/float/boolean values, arrays-of-tables (`[[...]]`). These produce a clear parse error if encountered.

### Data Model

The parser produces an ordered list of entries: comment lines, blank lines, key/value pairs, and table headers. This preserves the file's structure for round-trip read/write. A higher-level API provides:

- `getString(table:key:) -> String?`
- `setString(table:key:value:)`
- `removeTable(name:)`
- `insertTable(name:after:)` — for upgrade logic

Writing back reproduces the original file with only targeted modifications. Estimated size: ~150-200 lines.

## ConfigManager

A new `ConfigManager` struct replaces `ProfileStore` as the single interface for configuration and templates.

### Responsibilities

- **Bootstrap:** Creates `~/.config/cmux-layout/` and scaffolds `config.toml` if missing.
- **Version check:** Reads version comment, compares to current schema version. Runs upgrade if stale, errors if file version exceeds code version.
- **Template CRUD:**
  - `save(name:descriptor:)` — validates descriptor, writes `[templates.<name>]` table with `descriptor` key
  - `load(name:) -> String` — reads descriptor from `[templates.<name>]`
  - `list() -> [(name: String, descriptor: String)]` — all templates sorted by name
  - `delete(name:)` — removes `[templates.<name>]` table
- **Settings access (future use):**
  - `getSetting(key:) -> String?`
  - `setSetting(key:value:)`

### Validation

`save` validates the descriptor by parsing it through the existing `Parser`, matching current behavior.

### Path

Defaults to `~/.config/cmux-layout/config.toml`. Accepts a custom path in `init` for testing.

## CLI Changes

### Modified Commands

- **`save`**, **`load`**, **`list`** — same interface and arguments, rewired from `ProfileStore` to `ConfigManager`.

### New Command

- **`config`** subcommand:
  - `cmux-layout config path` — prints the config file path
  - `cmux-layout config show` — prints the current config file contents
  - `cmux-layout config init` — force-creates/resets scaffolded config (errors if file exists, unless `--force` is passed)

### Unchanged Commands

`apply`, `validate`, `plan`, `verify` — no modifications.

## Template Format

Templates are stored as TOML tables under `[templates]`:

```toml
[templates.dev]
descriptor = "workspace:Dev | cols:25,50,25 | rows[0]:60,40"

[templates.monitoring]
name = "Monitoring Dashboard"
descriptor = "grid:3x2"
```

- **Key** (e.g., `dev`) is the identifier used in CLI commands
- **`descriptor`** (required) — compressed descriptor string
- **`name`** (optional) — display name for `list` output
- Future: expanded form fields will be added alongside `descriptor`

## Testing Strategy

### Unit Tests

- **`TOMLParserTests`** — parse valid subset, reject unsupported features, round-trip preservation (comments, ordering, whitespace)
- **`ConfigManagerTests`** — scaffold creation, template CRUD, version upgrade logic (stale file upgraded, deprecated keys warned, unsupported keys error), settings read/write

### Test Isolation

Both suites use temporary directories via custom path parameter. No filesystem pollution.

### Removed

`ProfileStore` and its tests are deleted.

### Unchanged

Existing integration tests (live cmux) are unaffected — `apply`/`verify` commands are not modified.

## Files Changed

### New

- `Sources/CMUXLayout/TOMLParser.swift`
- `Sources/CMUXLayout/ConfigManager.swift`
- `Tests/CMUXLayoutTests/TOMLParserTests.swift`
- `Tests/CMUXLayoutTests/ConfigManagerTests.swift`

### Modified

- `Sources/cmux-layout/main.swift` — rewire `save`/`load`/`list` to `ConfigManager`, add `config` subcommand

### Removed

- `Sources/CMUXLayout/ProfileStore.swift`
