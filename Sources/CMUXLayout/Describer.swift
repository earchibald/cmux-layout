import Foundation

public enum DescriberError: Error, Equatable {
    case workspaceNotFound(String)
    case cannotReadTopology
}

public struct Describer {
    private let client: CMUXSocketClient

    public init(client: CMUXSocketClient) {
        self.client = client
    }

    public func describe(workspace: String, includeWorkspaceName: Bool = false) throws -> LayoutModel {
        let (workspaceId, workspaceTitle) = try resolveWorkspace(ref: workspace)
        let panes = try getPanes(workspaceId: workspaceId)
        let surfaceInfos = try panes.map { pane -> SurfaceInfo in
            try getSurfaceInfo(paneId: pane.id)
        }

        let (columns, rows, paneOrder) = reconstructGeometry(panes: panes)
        let orderedSurfaces = paneOrder.map { surfaceInfos[$0] }
        let cells = buildCells(from: orderedSurfaces)

        return LayoutModel(
            workspaceName: includeWorkspaceName ? workspaceTitle : nil,
            columns: columns,
            rows: rows,
            cells: cells
        )
    }

    // MARK: - Private

    private struct PaneInfo {
        let id: String
        let ref: String
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
    }

    private struct SurfaceInfo {
        let type: String
        let title: String
        let url: String?
    }

    private func resolveWorkspace(ref: String) throws -> (id: String, title: String) {
        let resp = try client.call(method: "workspace.list", params: [:])
        guard let workspaces = resp.result?["workspaces"] as? [[String: Any]] else {
            throw DescriberError.workspaceNotFound(ref)
        }
        guard let ws = workspaces.first(where: { ($0["ref"] as? String) == ref }) else {
            throw DescriberError.workspaceNotFound(ref)
        }
        let id = ws["id"] as? String ?? ""
        let title = ws["title"] as? String ?? ""
        return (id, title)
    }

    private func getPanes(workspaceId: String) throws -> [PaneInfo] {
        let resp = try client.call(method: "pane.list", params: ["workspace_id": workspaceId])
        guard let paneList = resp.result?["panes"] as? [[String: Any]], !paneList.isEmpty else {
            throw DescriberError.cannotReadTopology
        }
        return paneList.map { p in
            PaneInfo(
                id: p["id"] as? String ?? "",
                ref: p["ref"] as? String ?? "",
                x: p["x"] as? Double,
                y: p["y"] as? Double,
                width: p["width"] as? Double,
                height: p["height"] as? Double
            )
        }
    }

    private func getSurfaceInfo(paneId: String) throws -> SurfaceInfo {
        let resp = try client.call(method: "pane.surfaces", params: ["pane_id": paneId])
        let surfaces = resp.result?["surfaces"] as? [[String: Any]] ?? []
        guard let surf = surfaces.first else {
            return SurfaceInfo(type: "terminal", title: "", url: nil)
        }
        return SurfaceInfo(
            type: surf["type"] as? String ?? "terminal",
            title: surf["title"] as? String ?? "",
            url: surf["url"] as? String
        )
    }

    private func reconstructGeometry(panes: [PaneInfo]) -> (columns: [Double], rows: [Int: [Double]], paneOrder: [Int]) {
        // Try geometry-based reconstruction if fields are present
        if let first = panes.first, first.x != nil && first.width != nil {
            return tryGeometryReconstruction(panes: panes)
        }
        // Fallback: equal widths, single row per column
        let count = panes.count
        let width = count > 0 ? 100.0 / Double(count) : 100.0
        let columns = normalizePercentages(Array(repeating: width, count: max(count, 1)))
        return (columns, [:], Array(0..<count))
    }

    private func tryGeometryReconstruction(panes: [PaneInfo]) -> (columns: [Double], rows: [Int: [Double]], paneOrder: [Int]) {
        // Sort panes by x then y, preserving original indices
        let indexed = panes.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            let ax = a.1.x ?? 0, bx = b.1.x ?? 0
            if abs(ax - bx) > 1.0 { return ax < bx }
            return (a.1.y ?? 0) < (b.1.y ?? 0)
        }

        // Group into columns by x-position (within tolerance)
        var columnGroups: [[(index: Int, pane: PaneInfo)]] = []
        for (idx, pane) in sorted {
            let x = pane.x ?? 0
            if let lastGroup = columnGroups.last, let lastX = lastGroup.first?.pane.x {
                if abs(x - lastX) <= 1.0 {
                    columnGroups[columnGroups.count - 1].append((idx, pane))
                    continue
                }
            }
            columnGroups.append([(idx, pane)])
        }

        // Calculate total workspace width
        let totalWidth = columnGroups.reduce(0.0) { total, group in
            total + (group.first?.pane.width ?? 0)
        }
        guard totalWidth > 0 else {
            let count = panes.count
            return (normalizePercentages(Array(repeating: 100.0 / Double(count), count: count)), [:], Array(0..<count))
        }

        // Column width percentages
        var columns: [Double] = columnGroups.map { group in
            (group.first?.pane.width ?? 0) / totalWidth * 100.0
        }
        columns = normalizePercentages(columns)

        // Row percentages within each column
        var rows: [Int: [Double]] = [:]
        var paneOrder: [Int] = []

        for (colIdx, group) in columnGroups.enumerated() {
            // Sort by y within column
            let sortedGroup = group.sorted { ($0.pane.y ?? 0) < ($1.pane.y ?? 0) }
            paneOrder.append(contentsOf: sortedGroup.map(\.index))

            if sortedGroup.count > 1 {
                let totalHeight = sortedGroup.reduce(0.0) { $0 + ($1.pane.height ?? 0) }
                guard totalHeight > 0 else { continue }
                var rowPcts = sortedGroup.map { ($0.pane.height ?? 0) / totalHeight * 100.0 }
                rowPcts = normalizePercentages(rowPcts)
                rows[colIdx] = rowPcts
            }
        }

        return (columns, rows, paneOrder)
    }

    private func normalizePercentages(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else { return values }
        var result = values.map { v -> Double in
            let rounded = v.rounded()
            return abs(v - rounded) < 0.1 ? rounded : v
        }
        // Adjust last element so sum is exactly 100
        let sum = result.dropLast().reduce(0, +)
        result[result.count - 1] = 100.0 - sum
        return result
    }

    private func buildCells(from surfaces: [SurfaceInfo]) -> [CellSpec]? {
        let cells = surfaces.map { surf -> CellSpec in
            let name: String? = surf.title.isEmpty ? nil : surf.title
            let type: SurfaceType
            if surf.type == "browser" {
                type = .browser(url: surf.url)
            } else {
                type = .terminal(command: nil)
            }
            return CellSpec(name: name, type: type)
        }
        // Only include cells if there's something meaningful
        let hasMeaningful = cells.contains { cell in
            cell.name != nil || {
                if case .browser = cell.type { return true }
                return false
            }()
        }
        return hasMeaningful ? cells : nil
    }
}
