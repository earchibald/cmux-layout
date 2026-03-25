import Testing
@testable import CMUXLayout

@Suite("Verifier Tests")
struct VerifierTests {
    @Test func verifyMatchingLayout() throws {
        let actual = VerificationResult(
            columnWidths: [50.0, 50.0],
            rowHeights: [:],
            maxDeviation: 0.0
        )
        #expect(actual.passes(tolerance: 5.0))
    }

    @Test func verifyDeviationTooLarge() {
        let actual = VerificationResult(
            columnWidths: [60.0, 40.0],
            rowHeights: [:],
            maxDeviation: 10.0
        )
        #expect(!actual.passes(tolerance: 5.0))
    }

    @Test func verifyWithinTolerance() {
        let actual = VerificationResult(
            columnWidths: [48.0, 52.0],
            rowHeights: [:],
            maxDeviation: 2.0
        )
        #expect(actual.passes(tolerance: 5.0))
    }
}
