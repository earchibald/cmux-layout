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
