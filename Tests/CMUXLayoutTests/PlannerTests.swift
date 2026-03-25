import Testing
@testable import CMUXLayout

@Suite("Planner Tests")
struct PlannerTests {
    let planner = Planner()

    @Test func planGrid1x1() throws {
        let model = try Parser().parse("grid:1x1")
        let ops = planner.plan(model)
        #expect(ops.splits.isEmpty)
        #expect(ops.resizes.isEmpty)
    }

    @Test func planGrid2x1() throws {
        let model = try Parser().parse("grid:2x1")
        let ops = planner.plan(model)
        #expect(ops.splits.count == 1)
        #expect(ops.splits[0].direction == .right)
        #expect(ops.resizes.isEmpty)
    }

    @Test func planGrid2x2() throws {
        let model = try Parser().parse("grid:2x2")
        let ops = planner.plan(model)
        #expect(ops.splits.count == 3)
        #expect(ops.splits[0].direction == .right)
        #expect(ops.splits[1].direction == .down)
        #expect(ops.splits[2].direction == .down)
        #expect(ops.resizes.isEmpty)
    }

    @Test func planUnevenCols() throws {
        let model = try Parser().parse("cols:70,30")
        let ops = planner.plan(model)
        #expect(ops.splits.count == 1)
        #expect(ops.resizes.count == 1)
        #expect(abs(ops.resizes[0].targetFraction - 0.70) < 0.01)
    }

    @Test func plan3EqualCols() throws {
        let model = try Parser().parse("cols:33,33,34")
        let ops = planner.plan(model)
        #expect(ops.splits.count == 2)
        #expect(ops.resizes.count == 2)
        #expect(abs(ops.resizes[0].targetFraction - 0.33) < 0.01)
        #expect(abs(ops.resizes[1].targetFraction - 0.66) < 0.01)
    }

    @Test func planColsWithRows() throws {
        let model = try Parser().parse("cols:50,50 | rows[0]:60,40")
        let ops = planner.plan(model)
        #expect(ops.splits.count == 2)
        #expect(ops.resizes.count == 1)
        #expect(abs(ops.resizes[0].targetFraction - 0.60) < 0.01)
    }

    @Test func targetDividerFractions() throws {
        let model = try Parser().parse("cols:25,50,25")
        let ops = planner.plan(model)
        let colResizes = ops.resizes.filter { $0.axis == .horizontal }
        #expect(colResizes.count == 2)
        #expect(abs(colResizes[0].targetFraction - 0.25) < 0.01)
        #expect(abs(colResizes[1].targetFraction - 0.75) < 0.01)
    }

    @Test func splitChainOrder() throws {
        let model = try Parser().parse("cols:33,33,34 | rows:50,50")
        let ops = planner.plan(model)
        let rights = ops.splits.filter { $0.direction == .right }
        let downs = ops.splits.filter { $0.direction == .down }
        #expect(rights.count == 2)
        #expect(downs.count == 3)
        let lastRightIdx = ops.splits.lastIndex { $0.direction == .right }!
        let firstDownIdx = ops.splits.firstIndex { $0.direction == .down }!
        #expect(lastRightIdx < firstDownIdx)
    }
}
