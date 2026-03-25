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
}
