import Foundation
import Testing
@testable import CMUXLayout

@Suite("Integration Tests", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_INTEGRATION"] != nil))
struct IntegrationTests {
    let client = LiveSocketClient()

    @Test func applyGrid2x2() throws {
        let model = try Parser().parse("grid:2x2")
        let executor = Executor(client: client)
        let result = try executor.apply(model)
        #expect(result.cells.count == 4)

        // Cleanup
        _ = try client.call(method: "workspace.close", params: ["workspace_id": result.workspaceId])
    }

    @Test func applyWithWorkspaceName() throws {
        let model = try Parser().parse("workspace:Test Layout | cols:50,50")
        let executor = Executor(client: client)
        let result = try executor.apply(model)
        #expect(result.cells.count == 2)

        // Cleanup
        _ = try client.call(method: "workspace.close", params: ["workspace_id": result.workspaceId])
    }

    @Test func applyUnevenCols() throws {
        let model = try Parser().parse("cols:70,30")
        let executor = Executor(client: client)
        let result = try executor.apply(model)
        #expect(result.cells.count == 2)

        // Cleanup
        _ = try client.call(method: "workspace.close", params: ["workspace_id": result.workspaceId])
    }

    @Test func workspaceNameApplied() throws {
        let model = try Parser().parse("workspace:Integration Test WS | grid:1x1")
        let executor = Executor(client: client)
        let result = try executor.apply(model)

        // Verify workspace was renamed by listing workspaces and checking title
        let listResp = try client.call(method: "workspace.list", params: [:])
        let workspaces = listResp.result?["workspaces"] as? [[String: Any]] ?? []
        let created = workspaces.first { ($0["id"] as? String) == result.workspaceId }
        #expect(created?["title"] as? String == "Integration Test WS")

        // Cleanup
        _ = try client.call(method: "workspace.close", params: ["workspace_id": result.workspaceId])
    }

    @Test func surfaceNamesApplied() throws {
        let model = try Parser().parse("workspace:Name Test | cols:50,50 | names:left-pane,right-pane")
        let executor = Executor(client: client)
        let result = try executor.apply(model)

        #expect(result.cells.count == 2)
        #expect(result.cells[0].name == "left-pane")
        #expect(result.cells[1].name == "right-pane")

        // Verify surfaces were actually renamed in cmux by querying pane.surfaces titles
        let paneListResp = try client.call(method: "pane.list", params: ["workspace_id": result.workspaceId])
        let panes = paneListResp.result?["panes"] as? [[String: Any]] ?? []
        var surfaceTitles: [String: String] = [:]
        for pane in panes {
            guard let paneId = pane["id"] as? String else { continue }
            let surfResp = try client.call(method: "pane.surfaces", params: [
                "workspace_id": result.workspaceId, "pane_id": paneId,
            ])
            let surfaces = surfResp.result?["surfaces"] as? [[String: Any]] ?? []
            for surf in surfaces {
                if let ref = surf["ref"] as? String, let title = surf["title"] as? String {
                    surfaceTitles[ref] = title
                }
            }
        }

        for cell in result.cells {
            #expect(surfaceTitles[cell.surfaceRef] == cell.name)
        }

        // Cleanup
        _ = try client.call(method: "workspace.close", params: ["workspace_id": result.workspaceId])
    }

    @Test func configSaveLoadRoundTrip() throws {
        let path = "/tmp/cmux-layout-test-config-\(UUID().uuidString)/config.toml"
        var config = try ConfigManager(path: path)
        let descriptor = "cols:50,50 | rows:50,50"
        try config.save(name: "test-template", descriptor: descriptor)
        let loaded = try config.load(name: "test-template")
        #expect(loaded == descriptor)

        // Cleanup
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }
}
