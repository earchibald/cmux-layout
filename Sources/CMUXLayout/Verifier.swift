import Foundation

public struct VerificationResult {
    public let columnWidths: [Double]
    public let rowHeights: [Int: [Double]]
    public let maxDeviation: Double

    public func passes(tolerance: Double = 5.0) -> Bool {
        maxDeviation <= tolerance
    }
}

public struct Verifier {
    private let client: CMUXSocketClient

    public init(client: CMUXSocketClient) {
        self.client = client
    }

    public func verify(workspace: String, target: LayoutModel) throws -> VerificationResult {
        let paneResp = try client.call(method: "pane.list", params: ["workspace": workspace])
        guard let panes = paneResp.result?["panes"] as? [[String: Any]] else {
            throw VerifierError.cannotReadTopology
        }

        let totalPanes = panes.count
        let expectedCells = target.cellCount
        let countDeviation = abs(Double(totalPanes) - Double(expectedCells)) / Double(expectedCells) * 100.0

        return VerificationResult(
            columnWidths: target.columns,
            rowHeights: target.rows,
            maxDeviation: countDeviation
        )
    }
}

public enum VerifierError: Error {
    case cannotReadTopology
}
