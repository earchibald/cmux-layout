import Foundation
import Testing
@testable import CMUXLayout

/// Records all socket calls for verification without hitting a live cmux instance.
final class RecordingSocketClient: CMUXSocketClient {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    private(set) var calls: [Call] = []
    private var responses: [String: CMUXResponse] = [:]

    /// Register a canned response for a method name.
    func stub(method: String, result: [String: Any]) {
        responses[method] = CMUXResponse(data: ["ok": true, "result": result])
    }

    func call(method: String, params: [String: Any]) throws -> CMUXResponse {
        calls.append(Call(method: method, params: params))
        if let resp = responses[method] { return resp }
        return CMUXResponse(data: ["ok": true, "result": [:]])
    }

    /// Returns all calls to a given method.
    func calls(to method: String) -> [Call] {
        calls.filter { $0.method == method }
    }
}

@Suite("Executor Tests")
struct ExecutorTests {

    private func makeClient() -> RecordingSocketClient {
        let client = RecordingSocketClient()
        let wsId = "WS-UUID-001"
        let paneId = "PANE-UUID-001"
        let surfId = "SURF-UUID-001"

        client.stub(method: "workspace.create", result: [
            "workspace_ref": "workspace:99",
            "workspace_id": wsId,
        ])
        client.stub(method: "workspace.select", result: [:])
        client.stub(method: "workspace.rename", result: [
            "workspace_id": wsId, "title": "renamed",
        ])
        client.stub(method: "pane.list", result: [
            "panes": [
                ["id": paneId, "ref": "pane:1"],
            ] as [[String: Any]],
        ])
        client.stub(method: "pane.surfaces", result: [
            "surfaces": [
                ["id": surfId, "ref": "surface:1"],
            ] as [[String: Any]],
        ])
        client.stub(method: "surface.split", result: [
            "surface_id": "SURF-UUID-002", "surface_ref": "surface:2",
        ])
        client.stub(method: "tab.action", result: [:])
        return client
    }

    // MARK: - Workspace naming

    @Test func workspaceRenameCalledWhenNameSpecified() throws {
        let client = makeClient()
        let model = try Parser().parse("workspace:MyWorkspace | grid:1x1")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let renameCalls = client.calls(to: "workspace.rename")
        #expect(renameCalls.count == 1)
        #expect(renameCalls[0].params["title"] as? String == "MyWorkspace")
    }

    @Test func workspaceRenameNotCalledWhenNoName() throws {
        let client = makeClient()
        let model = try Parser().parse("grid:1x1")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let renameCalls = client.calls(to: "workspace.rename")
        #expect(renameCalls.isEmpty)
    }

    @Test func workspaceRenameNotCalledWhenExistingWorkspaceProvided() throws {
        let client = makeClient()
        let model = try Parser().parse("workspace:Ignored | grid:1x1")
        let executor = Executor(client: client)
        let _ = try executor.apply(model, workspace: "workspace:existing")

        let renameCalls = client.calls(to: "workspace.rename")
        #expect(renameCalls.isEmpty)
    }

    // MARK: - Surface naming

    @Test func surfaceRenameCalledForEachNamedCell() throws {
        let client = makeClient()
        let model = try Parser().parse("grid:1x1 | names:my-terminal")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let tabCalls = client.calls(to: "tab.action")
        #expect(tabCalls.count == 1)
        #expect(tabCalls[0].params["action"] as? String == "rename")
        #expect(tabCalls[0].params["title"] as? String == "my-terminal")
    }

    @Test func surfaceRenameNotCalledWhenNoNames() throws {
        let client = makeClient()
        let model = try Parser().parse("grid:1x1")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let tabCalls = client.calls(to: "tab.action")
        #expect(tabCalls.isEmpty)
    }

    // MARK: - Browser surface swap

    @Test func browserCellTriggersSurfaceCreateAndClose() throws {
        let client = makeClient()
        client.stub(method: "surface.create", result: [
            "surface_id": "BROWSER-SURF-UUID",
            "surface_ref": "surface:99",
        ])
        client.stub(method: "surface.close", result: [:])

        let model = try Parser().parse("grid:1x1 | names:docs=b:https://x.com")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let createCalls = client.calls(to: "surface.create")
        #expect(createCalls.count == 1)
        #expect(createCalls[0].params["type"] as? String == "browser")
        #expect(createCalls[0].params["url"] as? String == "https://x.com")

        let closeCalls = client.calls(to: "surface.close")
        #expect(closeCalls.count == 1)
    }

    @Test func terminalCellDoesNotTriggerSwap() throws {
        let client = makeClient()
        let model = try Parser().parse("grid:1x1 | names:nav")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        #expect(client.calls(to: "surface.create").isEmpty)
        #expect(client.calls(to: "surface.close").isEmpty)
    }

    @Test func blankBrowserOmitsUrl() throws {
        let client = makeClient()
        client.stub(method: "surface.create", result: [
            "surface_id": "BROWSER-SURF-UUID",
            "surface_ref": "surface:99",
        ])
        client.stub(method: "surface.close", result: [:])

        let model = try Parser().parse("grid:1x1 | names:b:")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let createCalls = client.calls(to: "surface.create")
        #expect(createCalls.count == 1)
        #expect(createCalls[0].params["url"] == nil)
    }

    @Test func renameHappensAfterBrowserSwap() throws {
        let client = makeClient()
        client.stub(method: "surface.create", result: [
            "surface_id": "BROWSER-SURF-UUID",
            "surface_ref": "surface:99",
        ])
        client.stub(method: "surface.close", result: [:])

        let model = try Parser().parse("grid:1x1 | names:docs=b:https://x.com")
        let executor = Executor(client: client)
        let _ = try executor.apply(model)

        let renameCalls = client.calls(to: "tab.action")
        #expect(renameCalls.count == 1)
        #expect(renameCalls[0].params["surface_id"] as? String == "surface:99")
        #expect(renameCalls[0].params["title"] as? String == "docs")
    }
}
