# Terminal Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add initial command support to terminal surfaces with env var interpolation, enabling workspace templates that auto-start services, editors, and log tails.

**Architecture:** Extend `SurfaceType.terminal` with an optional command string. A new `Interpolator` resolves `$VAR`, `${VAR}`, and `${VAR:-default}` at apply time. The Executor injects commands via `cmux send` CLI after a 100ms delay. Commands are TOML-only — no compact syntax changes.

**Tech Stack:** Swift 6.0, Foundation-only, Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-03-25-terminal-commands-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/CMUXLayout/LayoutModel.swift` | Modify | `.terminal` gains `command: String?` |
| `Sources/CMUXLayout/Interpolator.swift` | Create | Env var resolution |
| `Sources/CMUXLayout/Parser.swift` | Modify | Update `.terminal` references to `.terminal(command: nil)` |
| `Sources/CMUXLayout/Serializer.swift` | Modify | Update `.terminal` pattern match |
| `Sources/CMUXLayout/Executor.swift` | Modify | Add command injection step |
| `Sources/CMUXLayout/ConfigManager.swift` | Modify | Read `command` from TOML cell tables |
| `Tests/CMUXLayoutTests/InterpolatorTests.swift` | Create | Interpolator unit tests |
| `Tests/CMUXLayoutTests/ParserTests.swift` | Modify | Update `.terminal` assertions |
| `Tests/CMUXLayoutTests/SerializerTests.swift` | Modify | Update `.terminal` pattern |
| `Tests/CMUXLayoutTests/ExecutorTests.swift` | Modify | Command injection tests |
| `Tests/CMUXLayoutTests/ConfigManagerTests.swift` | Modify | TOML command tests |
| `Tests/CMUXLayoutTests/IntegrationTests.swift` | Modify | Live command injection test |

---

### Task 1: Interpolator — Env Var Resolution

**Files:**
- Create: `Sources/CMUXLayout/Interpolator.swift`
- Create: `Tests/CMUXLayoutTests/InterpolatorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/CMUXLayoutTests/InterpolatorTests.swift`:

```swift
import Testing
import Foundation
@testable import CMUXLayout

@Suite("Interpolator Tests")
struct InterpolatorTests {
    let env = ["HOME": "/Users/test", "PROJECT": "myapp", "EMPTY": ""]

    @Test func simpleVar() {
        #expect(Interpolator.resolve("$HOME/logs", environment: env) == "/Users/test/logs")
    }

    @Test func bracedVar() {
        #expect(Interpolator.resolve("${HOME}/logs", environment: env) == "/Users/test/logs")
    }

    @Test func varWithDefault_unset() {
        #expect(Interpolator.resolve("${MISSING:-fallback}", environment: env) == "fallback")
    }

    @Test func varWithDefault_set() {
        #expect(Interpolator.resolve("${PROJECT:-fallback}", environment: env) == "myapp")
    }

    @Test func varWithDefault_empty() {
        // Empty string counts as unset for :- syntax
        #expect(Interpolator.resolve("${EMPTY:-fallback}", environment: env) == "fallback")
    }

    @Test func escapedDollar() {
        #expect(Interpolator.resolve("price is $$5", environment: env) == "price is $5")
    }

    @Test func unresolvedVarBecomesEmpty() {
        #expect(Interpolator.resolve("$NOPE/path", environment: env) == "/path")
    }

    @Test func mixedPatterns() {
        #expect(Interpolator.resolve("cd $HOME/${PROJECT:-default} && echo $$done", environment: env)
            == "cd /Users/test/myapp && echo $done")
    }

    @Test func noVars() {
        #expect(Interpolator.resolve("just plain text", environment: env) == "just plain text")
    }

    @Test func emptyString() {
        #expect(Interpolator.resolve("", environment: env) == "")
    }

    @Test func varAtEnd() {
        #expect(Interpolator.resolve("path/$PROJECT", environment: env) == "path/myapp")
    }

    @Test func bracedVarAtEnd() {
        #expect(Interpolator.resolve("path/${PROJECT}", environment: env) == "path/myapp")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter InterpolatorTests 2>&1 | tail -10`
Expected: FAIL — `Interpolator` not defined

- [ ] **Step 3: Implement Interpolator**

Create `Sources/CMUXLayout/Interpolator.swift`:

```swift
import Foundation

public struct Interpolator: Sendable {
    /// Resolve environment variables in a string.
    /// Supports: $VAR, ${VAR}, ${VAR:-default}, $$ (literal $)
    public static func resolve(
        _ input: String,
        environment: [String: String]? = nil
    ) -> String {
        let env = environment ?? ProcessInfo.processInfo.environment
        var result = ""
        var i = input.startIndex

        while i < input.endIndex {
            if input[i] == "$" {
                let next = input.index(after: i)

                // $$ → literal $
                if next < input.endIndex && input[next] == "$" {
                    result.append("$")
                    i = input.index(after: next)
                    continue
                }

                // ${VAR} or ${VAR:-default}
                if next < input.endIndex && input[next] == "{" {
                    let braceStart = input.index(after: next)
                    if let braceEnd = input[braceStart...].firstIndex(of: "}") {
                        let content = String(input[braceStart..<braceEnd])
                        if let sepRange = content.range(of: ":-") {
                            let varName = String(content[content.startIndex..<sepRange.lowerBound])
                            let defaultVal = String(content[sepRange.upperBound...])
                            let value = env[varName]
                            result.append((value?.isEmpty == false) ? value! : defaultVal)
                        } else {
                            result.append(env[content] ?? "")
                        }
                        i = input.index(after: braceEnd)
                        continue
                    }
                }

                // $VAR (bare)
                if next < input.endIndex && (input[next].isLetter || input[next] == "_") {
                    var end = next
                    while end < input.endIndex && (input[end].isLetter || input[end].isNumber || input[end] == "_") {
                        end = input.index(after: end)
                    }
                    let varName = String(input[next..<end])
                    result.append(env[varName] ?? "")
                    i = end
                    continue
                }

                // Bare $ at end or followed by non-var char
                result.append("$")
                i = next
                continue
            }

            result.append(input[i])
            i = input.index(after: i)
        }

        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter InterpolatorTests 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/Interpolator.swift Tests/CMUXLayoutTests/InterpolatorTests.swift
git commit -m "feat: add env var interpolator with \$VAR, \${VAR}, \${VAR:-default}"
```

---

### Task 2: Data Model — Add command to SurfaceType.terminal

**Files:**
- Modify: `Sources/CMUXLayout/LayoutModel.swift`
- Modify: `Sources/CMUXLayout/Parser.swift`
- Modify: `Sources/CMUXLayout/Serializer.swift`
- Modify: `Sources/CMUXLayout/Executor.swift`
- Modify: `Sources/CMUXLayout/ConfigManager.swift`
- Modify: `Tests/CMUXLayoutTests/ParserTests.swift`
- Modify: `Tests/CMUXLayoutTests/ConfigManagerTests.swift`

This is a cascading refactor — changing `.terminal` to `.terminal(command: String?)` and fixing all references.

- [ ] **Step 1: Update SurfaceType in LayoutModel.swift**

Change line 4 from:
```swift
    case terminal
```
to:
```swift
    case terminal(command: String?)
```

Change the CellSpec default (line 12) from:
```swift
    public init(name: String? = nil, type: SurfaceType = .terminal) {
```
to:
```swift
    public init(name: String? = nil, type: SurfaceType = .terminal(command: nil)) {
```

- [ ] **Step 2: Fix Parser.swift**

Change all three `.terminal` references (lines 107, 109, 115) to `.terminal(command: nil)`:

```swift
// line 107
                return CellSpec(name: name, type: .terminal(command: nil))
// line 109
            return CellSpec(name: token, type: .terminal(command: nil))
// line 115
        return CellSpec(name: token, type: .terminal(command: nil))
```

- [ ] **Step 3: Fix Serializer.swift**

Change line 49 from:
```swift
        case .terminal:
```
to:
```swift
        case .terminal:
```

Actually, with the associated value, the pattern must become:
```swift
        case .terminal(_):
```
or simply:
```swift
        case .terminal:
```
Swift allows omitting associated values in pattern matches. Verify this compiles — if not, use `case .terminal(_):`.

- [ ] **Step 4: Fix Executor.swift**

Line 221 — change `.terminal` to `.terminal(command: nil)`:
```swift
                    type: cellSpec?.type ?? .terminal(command: nil),
```

The `swapBrowserSurfaces` method guards on `case .browser` — no change needed there since the non-match falls through.

- [ ] **Step 5: Fix ConfigManager.swift**

Line 183 — change `.terminal` to `.terminal(command: nil)`:
```swift
                surfaceType = .terminal(command: nil)
```

(We'll add `command` reading in Task 4.)

- [ ] **Step 6: Fix test files**

In `ParserTests.swift`, update all `CellSpec(name: "...", type: .terminal)` assertions. Since `.terminal(command: nil)` is the default for `CellSpec.init`, existing `CellSpec(name: "nav")` calls should still work. But explicit `.terminal` comparisons need updating:

Lines 107-108, 144, 151, 153 — change `type: .terminal` to `type: .terminal(command: nil)`.

In `ConfigManagerTests.swift`, lines 201, 236 — same change.

- [ ] **Step 7: Build and run all tests**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1 | tail -15`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add -A
git commit -m "refactor: add command associated value to SurfaceType.terminal"
```

---

### Task 3: ConfigManager — Read command from TOML Cell Tables

**Files:**
- Modify: `Sources/CMUXLayout/ConfigManager.swift`
- Modify: `Tests/CMUXLayoutTests/ConfigManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ConfigManagerTests.swift`:

```swift
    // MARK: - Terminal commands from TOML

    @Test func loadModelWithCommand() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:50,50 | names:editor,logs")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + "\n\n[templates.dev.cells.editor]\ntype = \"terminal\"\ncommand = \"nvim\""
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "editor", type: .terminal(command: "nvim")))
        #expect(cells[1] == CellSpec(name: "logs", type: .terminal(command: nil)))
    }

    @Test func loadModelCommandOnBrowserIgnored() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:100 | names:docs")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + "\n\n[templates.dev.cells.docs]\ntype = \"browser\"\nurl = \"https://x.com\"\ncommand = \"ignored\""
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "docs", type: .browser(url: "https://x.com")))
    }

    @Test func loadModelTerminalWithoutCommand() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = dir + "/config.toml"
        var mgr = try ConfigManager(path: path)
        try mgr.save(name: "dev", descriptor: "cols:100 | names:shell")

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let updated = content + "\n\n[templates.dev.cells.shell]\ntype = \"terminal\""
        try updated.write(toFile: path, atomically: true, encoding: .utf8)

        let mgr2 = try ConfigManager(path: path)
        let model = try mgr2.loadModel(name: "dev")
        let cells = try #require(model.cells)
        #expect(cells[0] == CellSpec(name: "shell", type: .terminal(command: nil)))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -15`
Expected: FAIL — command not read from TOML

- [ ] **Step 3: Update loadModel to read command**

In `ConfigManager.swift`, update `loadModel` (around line 177-185):

```swift
        for tableName in cellTables {
            let cellName = String(tableName.dropFirst(cellTablePrefix.count))
            let typeStr = document.getString(table: tableName, key: "type") ?? "terminal"
            let url = document.getString(table: tableName, key: "url")
            let command = document.getString(table: tableName, key: "command")
            let surfaceType: SurfaceType
            if typeStr == "browser" {
                surfaceType = .browser(url: url)
                // command is silently ignored for browsers
            } else {
                surfaceType = .terminal(command: command)
            }
            overrides[cellName] = CellSpec(name: cellName, type: surfaceType)
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ConfigManagerTests 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/ConfigManager.swift Tests/CMUXLayoutTests/ConfigManagerTests.swift
git commit -m "feat: read terminal command from TOML cell tables"
```

---

### Task 4: Executor — Command Injection via cmux send

**Files:**
- Modify: `Sources/CMUXLayout/Executor.swift`
- Modify: `Tests/CMUXLayoutTests/ExecutorTests.swift`

- [ ] **Step 1: Write failing tests**

The Executor shells out via `Process` which is hard to mock directly. To make this testable, add a `CommandSender` protocol and inject it. Append to `ExecutorTests.swift`:

```swift
    // MARK: - Command injection

    @Test func commandInjectedForTerminalWithCommand() throws {
        let client = makeClient()
        var sentCommands: [(surface: String, command: String)] = []
        let sender: CommandSender = { surface, workspace, command in
            sentCommands.append((surface: surface, command: command))
        }

        let model = LayoutModel(
            columns: [100],
            cells: [CellSpec(name: "editor", type: .terminal(command: "nvim"))]
        )
        let executor = Executor(client: client, commandSender: sender)
        let _ = try executor.apply(model)

        #expect(sentCommands.count == 1)
        #expect(sentCommands[0].command == "nvim")
    }

    @Test func noCommandInjectionForTerminalWithoutCommand() throws {
        let client = makeClient()
        var sentCommands: [(surface: String, command: String)] = []
        let sender: CommandSender = { surface, workspace, command in
            sentCommands.append((surface: surface, command: command))
        }

        let model = LayoutModel(
            columns: [100],
            cells: [CellSpec(name: "shell", type: .terminal(command: nil))]
        )
        let executor = Executor(client: client, commandSender: sender)
        let _ = try executor.apply(model)

        #expect(sentCommands.isEmpty)
    }

    @Test func noCommandInjectionForBrowser() throws {
        let client = makeClient()
        client.stub(method: "surface.create", result: [
            "surface_id": "BROWSER-SURF-UUID", "surface_ref": "surface:99",
        ])
        client.stub(method: "surface.close", result: [:])

        var sentCommands: [(surface: String, command: String)] = []
        let sender: CommandSender = { surface, workspace, command in
            sentCommands.append((surface: surface, command: command))
        }

        let model = LayoutModel(
            columns: [100],
            cells: [CellSpec(name: "docs", type: .browser(url: "https://x.com"))]
        )
        let executor = Executor(client: client, commandSender: sender)
        let _ = try executor.apply(model)

        #expect(sentCommands.isEmpty)
    }

    @Test func commandIsInterpolated() throws {
        let client = makeClient()
        var sentCommands: [(surface: String, command: String)] = []
        let sender: CommandSender = { surface, workspace, command in
            sentCommands.append((surface: surface, command: command))
        }

        let model = LayoutModel(
            columns: [100],
            cells: [CellSpec(name: "editor", type: .terminal(command: "cd ${MISSING:-/tmp} && nvim"))]
        )
        let executor = Executor(client: client, commandSender: sender)
        let _ = try executor.apply(model)

        #expect(sentCommands.count == 1)
        #expect(sentCommands[0].command == "cd /tmp && nvim")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test --filter ExecutorTests 2>&1 | tail -15`
Expected: FAIL — `CommandSender` not defined

- [ ] **Step 3: Implement CommandSender protocol and injection**

In `Executor.swift`, add the type alias and update the struct:

```swift
/// Closure type for sending commands to terminal surfaces.
/// Parameters: surfaceRef, workspaceId, command (already interpolated, without trailing newline)
public typealias CommandSender = (String, String, String) -> Void

/// Default command sender that shells out to cmux send CLI.
public func defaultCommandSender(surfaceRef: String, workspaceId: String, command: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["cmux", "send", "--workspace", workspaceId, "--surface", surfaceRef, command + "\n"]
    process.standardOutput = nil
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            fputs("Warning: cmux send failed for \(surfaceRef)\n", stderr)
        }
    } catch {
        fputs("Warning: could not run cmux send: \(error)\n", stderr)
    }
}
```

Update `Executor`:

```swift
public struct Executor {
    private let client: CMUXSocketClient
    private let commandSender: CommandSender
    private let maxResizeIterations = 3
    private let resizeTolerance = 0.02

    public init(client: CMUXSocketClient, commandSender: CommandSender? = nil) {
        self.client = client
        self.commandSender = commandSender ?? defaultCommandSender
    }
```

Add the `injectCommands` method:

```swift
    private func injectCommands(cells: [CellInfo], workspaceId: String) {
        for cell in cells {
            guard case .terminal(let command) = cell.type, let cmd = command else { continue }
            let interpolated = Interpolator.resolve(cmd)
            // 100ms delay for terminal initialization
            Thread.sleep(forTimeInterval: 0.1)
            commandSender(cell.surfaceRef, workspaceId, interpolated)
        }
    }
```

Add the call in `apply`, after rename (step 10), before the return:

```swift
        // 11. Inject commands into terminal surfaces
        injectCommands(cells: cells, workspaceId: wsId)

        return LayoutResult(workspaceRef: wsRef, workspaceId: wsId, cells: cells)
```

- [ ] **Step 4: Fix existing Executor tests**

Existing tests construct `Executor(client: client)` without a commandSender — this still works because the parameter has a default. No changes needed unless compilation errors arise.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1 | tail -15`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Sources/CMUXLayout/Executor.swift Tests/CMUXLayoutTests/ExecutorTests.swift
git commit -m "feat: inject commands into terminal surfaces via cmux send"
```

---

### Task 5: Integration Test — Command Injection Against Live cmux

**Files:**
- Modify: `Tests/CMUXLayoutTests/IntegrationTests.swift`

- [ ] **Step 1: Add integration test**

Append to `IntegrationTests.swift`:

```swift
    @Test func terminalCommandInjected() throws {
        let model = try Parser().parse("workspace:Cmd Test | cols:100 | names:shell")
        // Manually set a command on the cell
        var mutableModel = model
        mutableModel.cells = [CellSpec(name: "shell", type: .terminal(command: "echo CMUX_CMD_TEST_MARKER"))]

        let executor = Executor(client: client)
        let result = try executor.apply(mutableModel)

        // Verify layout was created successfully (command injection is best-effort)
        #expect(result.cells.count == 1)
        #expect(result.cells[0].name == "shell")

        // Cleanup
        _ = try client.call(method: "workspace.close", params: ["workspace_id": result.workspaceId])
    }
```

- [ ] **Step 2: Build and run integration tests**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && CMUX_INTEGRATION=1 swift test --filter IntegrationTests 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout
git add Tests/CMUXLayoutTests/IntegrationTests.swift
git commit -m "test: add integration test for terminal command injection"
```

---

### Task 6: Full Test Suite Verification and Smoke Test

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift test 2>&1`
Expected: All tests pass

- [ ] **Step 2: Run integration tests**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && CMUX_INTEGRATION=1 swift test --filter IntegrationTests 2>&1`
Expected: All tests pass

- [ ] **Step 3: Release build**

Run: `cd /Users/earchibald/work/github/earchibald/cmux-layout && swift build -c release 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Smoke test**

```bash
cd /Users/earchibald/work/github/earchibald/cmux-layout

# Save a template with a command via TOML
.build/release/cmux-layout save cmd-test "workspace:Cmd Test | cols:50,50 | names:editor,logs"
.build/release/cmux-layout config show

# Manually add command to config.toml, then load
# (This verifies the TOML → loadModel → Executor → cmux send pipeline)
```
Expected: Template saves, config shows correctly. Manual TOML edit + load creates workspace with command auto-running.
