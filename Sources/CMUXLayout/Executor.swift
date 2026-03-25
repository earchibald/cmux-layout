import Foundation

public struct LayoutResult {
    public let workspaceRef: String
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
        let wsRef: String
        if let ws = workspace {
            wsRef = ws
        } else {
            let resp = try client.call(method: "workspace.create", params: [:])
            guard let ref = resp.result?["workspace_ref"] as? String else {
                throw ExecutorError.unexpectedResponse("workspace.create")
            }
            wsRef = ref
        }

        // 2. Select workspace and verify
        _ = try client.call(method: "workspace.select", params: ["workspace": wsRef])
        let identifyResp = try client.call(method: "system.identify", params: [:])
        if let focused = identifyResp.result?["focused"] as? [String: Any],
           let activeWs = focused["workspace_ref"] as? String,
           activeWs != wsRef {
            throw ExecutorError.workspaceSelectionFailed(expected: wsRef, got: activeWs)
        }

        // 3. Rename if specified
        if let name = model.workspaceName, workspace == nil {
            _ = try client.call(method: "workspace.rename", params: [
                "workspace": wsRef, "title": name
            ])
        }

        // 4. Get initial surface
        let paneListResp = try client.call(method: "pane.list", params: ["workspace": wsRef])
        guard let panes = paneListResp.result?["panes"] as? [[String: Any]],
              let firstPane = panes.first,
              let firstPaneRef = firstPane["ref"] as? String else {
            throw ExecutorError.unexpectedResponse("pane.list")
        }

        let surfResp = try client.call(method: "pane.surfaces", params: [
            "workspace": wsRef, "pane": firstPaneRef
        ])
        guard let surfaces = surfResp.result?["surfaces"] as? [[String: Any]],
              let firstSurf = surfaces.first,
              let initialSurface = firstSurf["ref"] as? String else {
            throw ExecutorError.unexpectedResponse("pane.surfaces")
        }

        let plan = Planner().plan(model)

        // 5. Create column splits
        var colSurfaces: [String] = [initialSurface]
        for splitOp in plan.splits where splitOp.direction == .right {
            let target = colSurfaces.last!
            let resp = try client.call(method: "surface.split", params: [
                "direction": "right", "workspace": wsRef, "surface": target
            ])
            guard let newSurf = resp.result?["surface_ref"] as? String else {
                throw ExecutorError.unexpectedResponse("surface.split right")
            }
            colSurfaces.append(newSurf)
        }

        // 6. Create row splits per column
        var colBottomSurfaces = colSurfaces
        for splitOp in plan.splits where splitOp.direction == .down {
            guard let col = splitOp.columnIndex else { continue }
            let target = colBottomSurfaces[col]
            let resp = try client.call(method: "surface.split", params: [
                "direction": "down", "workspace": wsRef, "surface": target
            ])
            guard let newSurf = resp.result?["surface_ref"] as? String else {
                throw ExecutorError.unexpectedResponse("surface.split down")
            }
            colBottomSurfaces[col] = newSurf
        }

        // 7. Resize dividers
        if !plan.resizes.isEmpty {
            try performResizes(plan.resizes, workspace: wsRef)
        }

        // 8. Collect cell map
        let cells = try collectCells(workspace: wsRef, model: model)

        return LayoutResult(workspaceRef: wsRef, cells: cells)
    }

    private func performResizes(_ resizes: [ResizeOp], workspace: String) throws {
        let probeResp = try client.call(method: "pane.list", params: ["workspace": workspace])
        guard let panes = probeResp.result?["panes"] as? [[String: Any]],
              panes.count > 1 else { return }

        // Calibration probe
        let probePaneRef = panes[1]["ref"] as? String ?? ""
        let probeResult = try client.call(method: "pane.resize", params: [
            "pane": probePaneRef, "workspace": workspace, "direction": "left", "amount": 100
        ])

        var pointsPerFraction: Double = 3000
        if let oldPos = probeResult.result?["old_divider_position"] as? Double,
           let newPos = probeResult.result?["new_divider_position"] as? Double {
            let delta = abs(newPos - oldPos)
            if delta > 0.001 {
                pointsPerFraction = 100.0 / delta
            }
            _ = try client.call(method: "pane.resize", params: [
                "pane": probePaneRef, "workspace": workspace, "direction": "right", "amount": 100
            ])
        }

        for resize in resizes {
            try applyResize(resize, workspace: workspace, pointsPerFraction: &pointsPerFraction)
        }
    }

    private func applyResize(_ resize: ResizeOp, workspace: String, pointsPerFraction: inout Double) throws {
        let paneListResp = try client.call(method: "pane.list", params: ["workspace": workspace])
        guard let panes = paneListResp.result?["panes"] as? [[String: Any]] else { return }

        let direction = resize.axis == .horizontal ? "left" : "up"
        let paneIndex = resize.dividerIndex + 1
        guard paneIndex < panes.count,
              let paneRef = panes[paneIndex]["ref"] as? String else { return }

        for _ in 0..<maxResizeIterations {
            let probeResp = try client.call(method: "pane.resize", params: [
                "pane": paneRef, "workspace": workspace, "direction": direction, "amount": 1
            ])
            guard let currentPos = probeResp.result?["new_divider_position"] as? Double else { break }

            let reverseDir = direction == "left" ? "right" : "down"
            _ = try client.call(method: "pane.resize", params: [
                "pane": paneRef, "workspace": workspace, "direction": reverseDir, "amount": 1
            ])

            let delta = resize.targetFraction - currentPos
            if abs(delta) < resizeTolerance { break }

            let amount = Int(abs(delta) * pointsPerFraction)
            guard amount > 0 else { break }

            let moveDir = delta < 0 ? direction : reverseDir
            let result = try client.call(method: "pane.resize", params: [
                "pane": paneRef, "workspace": workspace, "direction": moveDir, "amount": amount
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

    private func collectCells(workspace: String, model: LayoutModel) throws -> [CellInfo] {
        let paneListResp = try client.call(method: "pane.list", params: ["workspace": workspace])
        guard let panes = paneListResp.result?["panes"] as? [[String: Any]] else { return [] }

        var cells: [CellInfo] = []
        var cellIndex = 0
        for pane in panes {
            guard let paneRef = pane["ref"] as? String else { continue }
            let surfResp = try client.call(method: "pane.surfaces", params: [
                "workspace": workspace, "pane": paneRef
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
