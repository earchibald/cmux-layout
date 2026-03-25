import Foundation

public struct LayoutResult {
    public let workspaceRef: String
    public let workspaceId: String
    public let cells: [CellInfo]
}

public struct CellInfo {
    public let surfaceRef: String
    public let paneRef: String
    public let name: String?
    public let column: Int
    public let row: Int
}

public struct Executor {
    private let client: CMUXSocketClient
    private let maxResizeIterations = 3
    private let resizeTolerance = 0.02

    public init(client: CMUXSocketClient) {
        self.client = client
    }

    public func apply(_ model: LayoutModel, workspace: String? = nil) throws -> LayoutResult {
        // 1. Create or use existing workspace
        // Socket API requires workspace_id (UUID), not workspace ref
        let wsRef: String
        let wsId: String
        if let ws = workspace {
            // Caller provided a ref — we need the UUID too. Use identify to find it.
            // For now, try passing the ref as-is (some methods accept both)
            wsRef = ws
            wsId = ws // will be resolved below if needed
        } else {
            let resp = try client.call(method: "workspace.create", params: [:])
            guard let ref = resp.result?["workspace_ref"] as? String,
                  let id = resp.result?["workspace_id"] as? String else {
                throw ExecutorError.unexpectedResponse("workspace.create")
            }
            wsRef = ref
            wsId = id
        }

        // 2. Select workspace (required for resize to work)
        // workspace.select requires workspace_id (UUID)
        let selectResp = try client.call(method: "workspace.select", params: ["workspace_id": wsId])
        guard selectResp.ok else {
            throw ExecutorError.unexpectedResponse("workspace.select failed for \(wsRef)")
        }

        // 3. Rename if specified
        if let name = model.workspaceName, workspace == nil {
            _ = try client.call(method: "workspace.rename", params: [
                "workspace_id": wsId, "title": name
            ])
        }

        // 4. Get initial surface
        let paneListResp = try client.call(method: "pane.list", params: ["workspace_id": wsId])
        guard let panes = paneListResp.result?["panes"] as? [[String: Any]],
              let firstPane = panes.first,
              let firstPaneId = firstPane["id"] as? String else {
            throw ExecutorError.unexpectedResponse("pane.list")
        }

        let surfResp = try client.call(method: "pane.surfaces", params: [
            "workspace_id": wsId, "pane_id": firstPaneId
        ])
        guard let surfaces = surfResp.result?["surfaces"] as? [[String: Any]],
              let firstSurf = surfaces.first,
              let initialSurfaceId = firstSurf["id"] as? String else {
            throw ExecutorError.unexpectedResponse("pane.surfaces")
        }

        let plan = Planner().plan(model)

        // 5. Create column splits — track surface IDs (UUIDs)
        var colSurfaceIds: [String] = [initialSurfaceId]
        for splitOp in plan.splits where splitOp.direction == .right {
            let target = colSurfaceIds.last!
            let resp = try client.call(method: "surface.split", params: [
                "direction": "right", "workspace_id": wsId, "surface_id": target
            ])
            guard let newSurfId = resp.result?["surface_id"] as? String
                    ?? resp.result?["surface_ref"] as? String else {
                throw ExecutorError.unexpectedResponse("surface.split right: \(resp.result ?? [:])")
            }
            colSurfaceIds.append(newSurfId)
        }

        // 6. Create row splits per column
        var colBottomSurfaceIds = colSurfaceIds
        for splitOp in plan.splits where splitOp.direction == .down {
            guard let col = splitOp.columnIndex else { continue }
            let target = colBottomSurfaceIds[col]
            let resp = try client.call(method: "surface.split", params: [
                "direction": "down", "workspace_id": wsId, "surface_id": target
            ])
            guard let newSurfId = resp.result?["surface_id"] as? String
                    ?? resp.result?["surface_ref"] as? String else {
                throw ExecutorError.unexpectedResponse("surface.split down: \(resp.result ?? [:])")
            }
            colBottomSurfaceIds[col] = newSurfId
        }

        // 7. Resize dividers
        if !plan.resizes.isEmpty {
            try performResizes(plan.resizes, workspaceId: wsId)
        }

        // 8. Collect cell map
        let cells = try collectCells(workspaceId: wsId, model: model)

        return LayoutResult(workspaceRef: wsRef, workspaceId: wsId, cells: cells)
    }

    private func performResizes(_ resizes: [ResizeOp], workspaceId: String) throws {
        let probeResp = try client.call(method: "pane.list", params: ["workspace_id": workspaceId])
        guard let panes = probeResp.result?["panes"] as? [[String: Any]],
              panes.count > 1 else { return }

        // Calibration probe
        let probePaneId = panes[1]["id"] as? String ?? ""
        let probeResult = try client.call(method: "pane.resize", params: [
            "pane_id": probePaneId, "workspace_id": workspaceId, "direction": "left", "amount": 100
        ])

        var pointsPerFraction: Double = 3000
        if let oldPos = probeResult.result?["old_divider_position"] as? Double,
           let newPos = probeResult.result?["new_divider_position"] as? Double {
            let delta = abs(newPos - oldPos)
            if delta > 0.001 {
                pointsPerFraction = 100.0 / delta
            }
            _ = try client.call(method: "pane.resize", params: [
                "pane_id": probePaneId, "workspace_id": workspaceId, "direction": "right", "amount": 100
            ])
        }

        for resize in resizes {
            try applyResize(resize, workspaceId: workspaceId, pointsPerFraction: &pointsPerFraction)
        }
    }

    private func applyResize(_ resize: ResizeOp, workspaceId: String, pointsPerFraction: inout Double) throws {
        let paneListResp = try client.call(method: "pane.list", params: ["workspace_id": workspaceId])
        guard let panes = paneListResp.result?["panes"] as? [[String: Any]] else { return }

        let direction = resize.axis == .horizontal ? "left" : "up"
        let paneIndex = resize.dividerIndex + 1
        guard paneIndex < panes.count,
              let paneId = panes[paneIndex]["id"] as? String else { return }

        for _ in 0..<maxResizeIterations {
            let probeResp = try client.call(method: "pane.resize", params: [
                "pane_id": paneId, "workspace_id": workspaceId, "direction": direction, "amount": 1
            ])
            guard let currentPos = probeResp.result?["new_divider_position"] as? Double else { break }

            let reverseDir = direction == "left" ? "right" : "down"
            _ = try client.call(method: "pane.resize", params: [
                "pane_id": paneId, "workspace_id": workspaceId, "direction": reverseDir, "amount": 1
            ])

            let delta = resize.targetFraction - currentPos
            if abs(delta) < resizeTolerance { break }

            let amount = Int(abs(delta) * pointsPerFraction)
            guard amount > 0 else { break }

            let moveDir = delta < 0 ? direction : reverseDir
            let result = try client.call(method: "pane.resize", params: [
                "pane_id": paneId, "workspace_id": workspaceId, "direction": moveDir, "amount": amount
            ])

            if let oldPos = result.result?["old_divider_position"] as? Double,
               let newPos = result.result?["new_divider_position"] as? Double {
                let actualDelta = abs(newPos - oldPos)
                if actualDelta > 0.001 {
                    pointsPerFraction = Double(amount) / actualDelta
                }
            }
        }
    }

    private func collectCells(workspaceId: String, model: LayoutModel) throws -> [CellInfo] {
        let paneListResp = try client.call(method: "pane.list", params: ["workspace_id": workspaceId])
        guard let panes = paneListResp.result?["panes"] as? [[String: Any]] else { return [] }

        var cells: [CellInfo] = []
        var cellIndex = 0
        for pane in panes {
            guard let paneRef = pane["ref"] as? String,
                  let paneId = pane["id"] as? String else { continue }
            let surfResp = try client.call(method: "pane.surfaces", params: [
                "workspace_id": workspaceId, "pane_id": paneId
            ])
            guard let surfaces = surfResp.result?["surfaces"] as? [[String: Any]] else { continue }
            for surf in surfaces {
                guard let surfRef = surf["ref"] as? String else { continue }
                let col = cellIndex % model.columns.count
                let row = cellIndex / model.columns.count
                let name = model.names?[safe: cellIndex]
                cells.append(CellInfo(
                    surfaceRef: surfRef,
                    paneRef: paneRef,
                    name: name,
                    column: col,
                    row: row
                ))
                cellIndex += 1
            }
        }
        return cells
    }
}

public enum ExecutorError: Error {
    case unexpectedResponse(String)
    case resizeFailed(String)
    case workspaceSelectionFailed(expected: String, got: String)
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
