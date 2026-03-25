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

    @Test func profileSaveLoadRoundTrip() throws {
        let store = ProfileStore(path: "/tmp/cmux-layout-test-profiles.json")
        let descriptor = "cols:50,50 | rows:50,50"
        try store.save(name: "test-profile", descriptor: descriptor)
        let loaded = try store.load("test-profile")
        #expect(loaded == descriptor)

        // Cleanup
        try? FileManager.default.removeItem(atPath: "/tmp/cmux-layout-test-profiles.json")
    }
}
