import Foundation
import CMUXLayout

// Note: No @main — this is main.swift (top-level entry point in Swift)
enum CLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        guard let command = args.first else {
            printUsage()
            exit(1)
        }

        do {
            switch command {
            case "apply":
                try handleApply(Array(args.dropFirst()))
            case "validate":
                try handleValidate(Array(args.dropFirst()))
            case "plan":
                try handlePlan(Array(args.dropFirst()))
            case "verify":
                try handleVerify(Array(args.dropFirst()))
            case "save":
                try handleSave(Array(args.dropFirst()))
            case "load":
                try handleLoad(Array(args.dropFirst()))
            case "list":
                try handleList()
            case "--help", "-h":
                printUsage()
            default:
                fputs("Unknown command: \(command)\n", stderr)
                printUsage()
                exit(1)
            }
        } catch let error as ParseError {
            fputs("Parse error: \(error)\n", stderr)
            exit(1)
        } catch let error as SocketError {
            fputs("Connection error: \(error)\n", stderr)
            exit(2)
        } catch let error as ExecutorError {
            fputs("Layout error: \(error)\n", stderr)
            exit(3)
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func handleApply(_ args: [String]) throws {
        var workspace: String?
        var descriptor: String?
        var jsonOutput = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--workspace":
                i += 1; workspace = args[i]
            case "--json":
                jsonOutput = true
            default:
                descriptor = args[i]
            }
            i += 1
        }

        guard let desc = descriptor else {
            fputs("Usage: cmux-layout apply [--workspace WS] [--json] <descriptor>\n", stderr)
            exit(1)
        }

        let parser = Parser()
        let model = try parser.parse(desc)
        let client = LiveSocketClient()
        let executor = Executor(client: client)
        let result = try executor.apply(model, workspace: workspace)

        if jsonOutput {
            let output: [String: Any] = [
                "workspace": result.workspaceRef,
                "cells": result.cells.map { cell in
                    var dict: [String: Any] = [
                        "surface": cell.surfaceRef,
                        "pane": cell.paneRef,
                        "column": cell.column,
                        "row": cell.row,
                    ]
                    if let name = cell.name { dict["name"] = name }
                    return dict
                },
                "descriptor": desc
            ]
            let data = try JSONSerialization.data(withJSONObject: output, options: .prettyPrinted)
            print(String(data: data, encoding: .utf8)!)
        } else {
            print("Applied layout to \(result.workspaceRef)")
            print("Cells: \(result.cells.count)")
            for cell in result.cells {
                let label = cell.name ?? "[\(cell.row),\(cell.column)]"
                print("  \(label): \(cell.surfaceRef)")
            }
        }
    }

    static func handleValidate(_ args: [String]) throws {
        guard let descriptor = args.first else {
            fputs("Usage: cmux-layout validate <descriptor>\n", stderr)
            exit(1)
        }
        let model = try Parser().parse(descriptor)
        print("OK (\(model.columns.count) columns, \(model.cellCount) cells)")
    }

    static func handlePlan(_ args: [String]) throws {
        guard let descriptor = args.first else {
            fputs("Usage: cmux-layout plan <descriptor>\n", stderr)
            exit(1)
        }
        let model = try Parser().parse(descriptor)
        let plan = Planner().plan(model)
        print("Plan for \(model.columns.count) columns, \(model.cellCount) cells:")
        for (i, split) in plan.splits.enumerated() {
            let colInfo = split.columnIndex.map { " (col \($0))" } ?? ""
            print("  \(i + 1). split \(split.direction)\(colInfo)")
        }
        for (i, resize) in plan.resizes.enumerated() {
            let colInfo = resize.columnIndex.map { " col \($0)" } ?? ""
            print("  \(plan.splits.count + i + 1). resize \(resize.axis)\(colInfo) -> \(String(format: "%.1f%%", resize.targetFraction * 100))")
        }
    }

    static func handleVerify(_ args: [String]) throws {
        var workspace: String?
        var descriptor: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--workspace":
                i += 1; workspace = args[i]
            default:
                descriptor = args[i]
            }
            i += 1
        }
        guard let ws = workspace, let desc = descriptor else {
            fputs("Usage: cmux-layout verify --workspace WS <descriptor>\n", stderr)
            exit(1)
        }
        let model = try Parser().parse(desc)
        let client = LiveSocketClient()
        let verifier = Verifier(client: client)
        let result = try verifier.verify(workspace: ws, target: model)
        if result.passes() {
            print("OK (max deviation: \(String(format: "%.1f%%", result.maxDeviation)))")
        } else {
            print("FAIL (max deviation: \(String(format: "%.1f%%", result.maxDeviation)))")
            exit(3)
        }
    }

    static func handleSave(_ args: [String]) throws {
        guard args.count >= 2 else {
            fputs("Usage: cmux-layout save <name> <descriptor>\n", stderr)
            exit(1)
        }
        let name = args[0]
        let descriptor = args[1]
        _ = try Parser().parse(descriptor)
        try ProfileStore().save(name: name, descriptor: descriptor)
        print("Saved profile '\(name)'")
    }

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
        guard let profileName = name else {
            fputs("Usage: cmux-layout load [--workspace WS] <name>\n", stderr)
            exit(1)
        }
        let descriptor = try ProfileStore().load(profileName)
        let model = try Parser().parse(descriptor)
        let client = LiveSocketClient()
        let executor = Executor(client: client)
        let result = try executor.apply(model, workspace: workspace)
        print("Loaded profile '\(profileName)' -> \(result.workspaceRef)")
    }

    static func handleList() throws {
        let profiles = try ProfileStore().list()
        if profiles.isEmpty {
            print("No saved profiles")
        } else {
            for (name, descriptor) in profiles.sorted(by: { $0.key < $1.key }) {
                print("  \(name): \(descriptor)")
            }
        }
    }

    static func printUsage() {
        print("""
        cmux-layout — Declarative cmux layout tool

        Usage:
          cmux-layout apply [--workspace WS] [--json] <descriptor>
          cmux-layout validate <descriptor>
          cmux-layout plan <descriptor>
          cmux-layout verify --workspace WS <descriptor>
          cmux-layout save <name> <descriptor>
          cmux-layout load [--workspace WS] <name>
          cmux-layout list

        Descriptor examples:
          grid:3x3
          cols:33,33,34 | rows:50,50
          workspace:Dev | cols:25,50,25 | rows[0]:60,40 | names:nav,main,logs

        Exit codes: 0=success, 1=parse error, 2=connection error, 3=layout error
        """)
    }
}

CLI.main()
