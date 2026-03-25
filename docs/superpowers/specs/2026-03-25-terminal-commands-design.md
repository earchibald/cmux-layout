# Terminal Surfaces with Initial Commands and Env Var Interpolation

**Date:** 2026-03-25
**Issue:** #5
**Status:** Approved

## Overview

Extend terminal surfaces to support initial commands that run when the surface is created. Commands are specified in TOML cell tables only (not in compact descriptor syntax). Environment variables in commands are interpolated at execution time, supporting `$VAR`, `${VAR}`, and `${VAR:-default}` patterns.

## Data Model Change

`SurfaceType.terminal` gains an associated value for the command:

```swift
public enum SurfaceType: Equatable, Sendable {
    case terminal(command: String?)  // nil = default shell, no command
    case browser(url: String?)
}
```

`CellSpec` is unchanged. The command is stored pre-interpolation — resolution happens at apply time.

### Backwards Compatibility

All existing code matching `.terminal` must update to match `.terminal(_)` or `.terminal(command: nil)`. The compact descriptor syntax is unaffected — `t:` remains a bare terminal marker producing `.terminal(command: nil)`. The parser produces `.terminal(command: nil)` for all terminals. Commands come exclusively from TOML cell tables.

## Compact Syntax

No changes. `t:` in the `names:` segment means explicit terminal with no command. Commands are TOML-only to avoid descriptor parsing complexity (commands contain spaces, pipes, commas).

## TOML Cell Table Extension

The existing cell table format gains a `command` key:

```toml
[templates.dev.cells.editor]
type = "terminal"
command = "cd ${PROJECT_DIR} && nvim"

[templates.dev.cells.logs]
type = "terminal"
command = "tail -f ${LOG_PATH:-/var/log/system.log}"
```

`ConfigManager.loadModel` already reads `type` and `url`. It now also reads `command` and populates `.terminal(command:)`. If `type` is `"browser"` and `command` is present, `command` is silently ignored.

## Environment Variable Interpolation

A new `Interpolator` struct resolves env vars in command strings at apply time.

### Supported Patterns

| Pattern | Behavior |
|---------|----------|
| `$VAR` | Resolves to value, or empty string if unset |
| `${VAR}` | Same as `$VAR` |
| `${VAR:-default}` | Uses default if VAR is unset or empty |
| `$$` | Literal `$` |

### Resolution

Uses `ProcessInfo.processInfo.environment`. Unresolved vars without defaults become empty string (no error). This is a pure function with no side effects.

### Implementation

A new file `Sources/CMUXLayout/Interpolator.swift`, approximately 50 lines. Single static method:

```swift
public struct Interpolator: Sendable {
    public static func resolve(_ input: String, environment: [String: String]? = nil) -> String
}
```

The optional `environment` parameter defaults to `ProcessInfo.processInfo.environment` but can be overridden for testing.

## Executor — Command Injection

After layout creation, browser swaps, and renames, the Executor injects commands into terminal surfaces that have them.

### Flow

For each cell with `.terminal(command: let cmd)` where `cmd` is non-nil:

1. Interpolate: `Interpolator.resolve(cmd)`
2. Wait 100ms (fixed delay for terminal initialization)
3. Shell out: `Process` running `cmux send --workspace WS --surface SURF "interpolated_command\n"`

### Mechanism

The cmux socket API does not expose `send` — only the CLI does. The Executor shells out via `Foundation.Process` to `/usr/bin/env cmux send`.

### Error Handling

If `cmux send` fails (non-zero exit), log a warning to stderr but do not fail the layout creation. The workspace is already built — a failed command injection should not tear it down.

### Timing

The 100ms delay is per-command. For a workspace with 3 commands, total added delay is ~300ms.

## Files Changed

### New

- `Sources/CMUXLayout/Interpolator.swift` — env var resolution
- `Tests/CMUXLayoutTests/InterpolatorTests.swift` — interpolator unit tests

### Modified

- `Sources/CMUXLayout/LayoutModel.swift` — `.terminal` gains `command: String?` associated value
- `Sources/CMUXLayout/Parser.swift` — update `.terminal` to `.terminal(command: nil)`
- `Sources/CMUXLayout/Serializer.swift` — update `.terminal` pattern matching
- `Sources/CMUXLayout/Executor.swift` — add command injection step, extract into `injectCommands` method
- `Sources/CMUXLayout/ConfigManager.swift` — read `command` from TOML cell tables
- `Sources/cmux-layout/main.swift` — no changes expected (uses CellInfo, not SurfaceType directly)
- `Tests/CMUXLayoutTests/ParserTests.swift` — update `.terminal` matches
- `Tests/CMUXLayoutTests/SerializerTests.swift` — update `.terminal` matches
- `Tests/CMUXLayoutTests/ExecutorTests.swift` — add command injection tests
- `Tests/CMUXLayoutTests/ConfigManagerTests.swift` — add TOML command tests
- `Tests/CMUXLayoutTests/IntegrationTests.swift` — add command injection live test

## Testing Strategy

### Interpolator Tests (unit)

- `$VAR` resolves from environment
- `${VAR}` braced form
- `${VAR:-default}` uses default when var unset
- `${VAR:-default}` uses value when var is set
- `$$` produces literal `$`
- Unresolved var without default → empty string
- Mixed patterns in one string
- No vars → string unchanged

### ConfigManager Tests (unit)

- TOML cell table with `command` → `.terminal(command: "...")`
- TOML cell table without `command` → `.terminal(command: nil)`
- `command` on browser cell → ignored

### Executor Tests (unit)

Command injection is triggered via shell-out to `cmux send`. To make this testable, extract the command sender as a closure or protocol that can be stubbed in tests. The mock verifies:
- Commands are sent for terminal cells with commands
- Commands are not sent for terminal cells without commands
- Commands are not sent for browser cells
- Interpolation is applied before sending

### Integration Tests (live cmux)

- Create workspace with a command terminal, verify no error during layout creation
- Verify the layout is created successfully (surfaces exist, correct types)
