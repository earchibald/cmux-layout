import Foundation
import Testing
@testable import CMUXLayout

@Suite("Describer Tests")
struct DescriberTests {
    private func makeClient(workspaceRef: String = "workspace:1", workspaceId: String = "WS-UUID-001", workspaceTitle: String = "Dev") -> RecordingSocketClient {
        let client = RecordingSocketClient()
        client.stub(method: "workspace.list", result: [
            "workspaces": [["id": workspaceId, "ref": workspaceRef, "title": workspaceTitle]] as [[String: Any]]
        ])
        return client
    }

    private func stubPanes(_ client: RecordingSocketClient, panes: [[String: Any]]) {
        client.stub(method: "pane.list", result: ["panes": panes])
    }

    private func enqueueSurfaces(_ client: RecordingSocketClient, surfaces: [[String: Any]]) {
        client.enqueue(method: "pane.surfaces", result: ["surfaces": surfaces])
    }

    private func stubSurfaces(_ client: RecordingSocketClient, surfaces: [[String: Any]]) {
        client.stub(method: "pane.surfaces", result: ["surfaces": surfaces])
    }

    @Test func describeSinglePane() throws {
        let client = makeClient()
        stubPanes(client, panes: [["id": "PANE-1", "ref": "pane:1"]])
        stubSurfaces(client, surfaces: [["id": "SURF-1", "ref": "surface:1", "type": "terminal", "title": ""]])

        let model = try Describer(client: client).describe(workspace: "workspace:1")
        #expect(model.columns == [100.0])
        #expect(model.rows.isEmpty)
        #expect(Serializer().serialize(model) == "cols:100")
    }

    @Test func describeTwoEqualColumns() throws {
        let client = makeClient()
        stubPanes(client, panes: [
            ["id": "PANE-1", "ref": "pane:1", "x": 0.0, "y": 0.0, "width": 500.0, "height": 1000.0],
            ["id": "PANE-2", "ref": "pane:2", "x": 500.0, "y": 0.0, "width": 500.0, "height": 1000.0],
        ])
        enqueueSurfaces(client, surfaces: [["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""]])
        enqueueSurfaces(client, surfaces: [["id": "S2", "ref": "surface:2", "type": "terminal", "title": ""]])

        let model = try Describer(client: client).describe(workspace: "workspace:1")
        #expect(model.columns == [50.0, 50.0])
        #expect(model.rows.isEmpty)
        #expect(Serializer().serialize(model) == "cols:50,50")
    }

    @Test func describeThreeUnequalColumns() throws {
        let client = makeClient()
        stubPanes(client, panes: [
            ["id": "PANE-1", "ref": "pane:1", "x": 0.0, "y": 0.0, "width": 250.0, "height": 1000.0],
            ["id": "PANE-2", "ref": "pane:2", "x": 250.0, "y": 0.0, "width": 500.0, "height": 1000.0],
            ["id": "PANE-3", "ref": "pane:3", "x": 750.0, "y": 0.0, "width": 250.0, "height": 1000.0],
        ])
        enqueueSurfaces(client, surfaces: [["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""]])
        enqueueSurfaces(client, surfaces: [["id": "S2", "ref": "surface:2", "type": "terminal", "title": ""]])
        enqueueSurfaces(client, surfaces: [["id": "S3", "ref": "surface:3", "type": "terminal", "title": ""]])

        let model = try Describer(client: client).describe(workspace: "workspace:1")
        #expect(model.columns == [25.0, 50.0, 25.0])
        #expect(model.rows.isEmpty)
        #expect(Serializer().serialize(model) == "cols:25,50,25")
    }

    @Test func describeColumnWithRowSplits() throws {
        let client = makeClient()
        stubPanes(client, panes: [
            ["id": "P1", "ref": "pane:1", "x": 0.0, "y": 0.0, "width": 250.0, "height": 600.0],
            ["id": "P2", "ref": "pane:2", "x": 0.0, "y": 600.0, "width": 250.0, "height": 400.0],
            ["id": "P3", "ref": "pane:3", "x": 250.0, "y": 0.0, "width": 750.0, "height": 1000.0],
        ])
        enqueueSurfaces(client, surfaces: [["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""]])
        enqueueSurfaces(client, surfaces: [["id": "S2", "ref": "surface:2", "type": "terminal", "title": ""]])
        enqueueSurfaces(client, surfaces: [["id": "S3", "ref": "surface:3", "type": "terminal", "title": ""]])

        let model = try Describer(client: client).describe(workspace: "workspace:1")
        #expect(model.columns == [25.0, 75.0])
        #expect(model.rows[0] == [60.0, 40.0])
        #expect(model.rows[1] == nil)
        #expect(Serializer().serialize(model) == "cols:25,75 | rows[0]:60,40")
    }

    @Test func describeBrowserSurface() throws {
        let client = makeClient()
        stubPanes(client, panes: [
            ["id": "P1", "ref": "pane:1", "x": 0.0, "y": 0.0, "width": 500.0, "height": 1000.0],
            ["id": "P2", "ref": "pane:2", "x": 500.0, "y": 0.0, "width": 500.0, "height": 1000.0],
        ])
        enqueueSurfaces(client, surfaces: [["id": "S1", "ref": "surface:1", "type": "terminal", "title": "editor"]])
        enqueueSurfaces(client, surfaces: [["id": "S2", "ref": "surface:2", "type": "browser", "title": "docs", "url": "https://example.com"]])

        let descriptor = Serializer().serialize(try Describer(client: client).describe(workspace: "workspace:1"))
        #expect(descriptor == "cols:50,50 | names:editor,docs=b:https://example.com")
    }

    @Test func describeSurfaceNames() throws {
        let client = makeClient()
        stubPanes(client, panes: [
            ["id": "P1", "ref": "pane:1", "x": 0.0, "y": 0.0, "width": 333.0, "height": 1000.0],
            ["id": "P2", "ref": "pane:2", "x": 333.0, "y": 0.0, "width": 334.0, "height": 1000.0],
            ["id": "P3", "ref": "pane:3", "x": 667.0, "y": 0.0, "width": 333.0, "height": 1000.0],
        ])
        enqueueSurfaces(client, surfaces: [["id": "S1", "ref": "surface:1", "type": "terminal", "title": "nav"]])
        enqueueSurfaces(client, surfaces: [["id": "S2", "ref": "surface:2", "type": "terminal", "title": "main"]])
        enqueueSurfaces(client, surfaces: [["id": "S3", "ref": "surface:3", "type": "terminal", "title": "logs"]])

        let descriptor = Serializer().serialize(try Describer(client: client).describe(workspace: "workspace:1"))
        #expect(descriptor.contains("names:nav,main,logs"))
    }

    @Test func describeWithWorkspaceName() throws {
        let client = makeClient(workspaceTitle: "Dev")
        stubPanes(client, panes: [["id": "P1", "ref": "pane:1"]])
        stubSurfaces(client, surfaces: [["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""]])

        let descriptor = Serializer().serialize(try Describer(client: client).describe(workspace: "workspace:1", includeWorkspaceName: true))
        #expect(descriptor.hasPrefix("workspace:Dev"))
    }

    @Test func describeWorkspaceNotFound() throws {
        let client = RecordingSocketClient()
        client.stub(method: "workspace.list", result: ["workspaces": [] as [[String: Any]]])

        #expect(throws: DescriberError.workspaceNotFound("workspace:99")) {
            try Describer(client: client).describe(workspace: "workspace:99")
        }
    }

    @Test func describeEmptyPaneList() throws {
        let client = makeClient()
        stubPanes(client, panes: [])

        #expect(throws: DescriberError.cannotReadTopology) {
            try Describer(client: client).describe(workspace: "workspace:1")
        }
    }

    @Test func describeFlatLayoutWithoutGeometry() throws {
        let client = makeClient()
        // Panes without geometry fields
        stubPanes(client, panes: [
            ["id": "P1", "ref": "pane:1"],
            ["id": "P2", "ref": "pane:2"],
            ["id": "P3", "ref": "pane:3"],
        ])
        // Resize probe responses: 3 panes = 2 dividers
        // Divider 1 at 0.333, divider 2 at 0.667
        client.enqueue(method: "pane.resize", result: ["old_divider_position": 0.333, "new_divider_position": 0.334])
        client.enqueue(method: "pane.resize", result: ["old_divider_position": 0.334, "new_divider_position": 0.333])
        client.enqueue(method: "pane.resize", result: ["old_divider_position": 0.667, "new_divider_position": 0.668])
        client.enqueue(method: "pane.resize", result: ["old_divider_position": 0.668, "new_divider_position": 0.667])

        enqueueSurfaces(client, surfaces: [["id": "S1", "ref": "surface:1", "type": "terminal", "title": ""]])
        enqueueSurfaces(client, surfaces: [["id": "S2", "ref": "surface:2", "type": "terminal", "title": ""]])
        enqueueSurfaces(client, surfaces: [["id": "S3", "ref": "surface:3", "type": "terminal", "title": ""]])

        let model = try Describer(client: client).describe(workspace: "workspace:1")
        #expect(model.columns.count == 3)
        // All should be close to 33.3
        for col in model.columns {
            #expect(abs(col - 33.3) < 1.0)
        }
    }

    @Test func describeOutputParsesBack() throws {
        let client = makeClient()
        stubPanes(client, panes: [
            ["id": "P1", "ref": "pane:1", "x": 0.0, "y": 0.0, "width": 250.0, "height": 600.0],
            ["id": "P2", "ref": "pane:2", "x": 0.0, "y": 600.0, "width": 250.0, "height": 400.0],
            ["id": "P3", "ref": "pane:3", "x": 250.0, "y": 0.0, "width": 500.0, "height": 1000.0],
            ["id": "P4", "ref": "pane:4", "x": 750.0, "y": 0.0, "width": 250.0, "height": 1000.0],
        ])
        enqueueSurfaces(client, surfaces: [["id": "S1", "ref": "surface:1", "type": "terminal", "title": "nav"]])
        enqueueSurfaces(client, surfaces: [["id": "S2", "ref": "surface:2", "type": "terminal", "title": "sidebar"]])
        enqueueSurfaces(client, surfaces: [["id": "S3", "ref": "surface:3", "type": "terminal", "title": "main"]])
        enqueueSurfaces(client, surfaces: [["id": "S4", "ref": "surface:4", "type": "browser", "title": "docs", "url": "https://x.com"]])

        let model = try Describer(client: client).describe(workspace: "workspace:1")
        let descriptor = Serializer().serialize(model)
        let parsed = try Parser().parse(descriptor)
        #expect(parsed.columns.count == model.columns.count)
        #expect(parsed.cellCount == model.cellCount)
    }
}
