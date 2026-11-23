import XCTest
@testable import SatpaneEnhancePlan

final class PlannerTests: XCTestCase {
  // A view over Kanata (Ottawa): about 2 x 2 km at zoom 14.5.
  let kanata = Planner.Bounds(west: -75.93, south: 45.3, east: -75.9, north: 45.32)

  func testFiveTilesPerUnit() {
    let outs = Planner.unitOutputs(Planner.Unit(x: 10, y: 20))
    XCTAssertEqual(outs.map { [$0.z, $0.tx, $0.ty] }, [[14, 10, 20], [15, 20, 40], [15, 21, 40], [15, 20, 41], [15, 21, 41]])
    XCTAssertEqual([outs[0].x, outs[0].y, outs[0].size, outs[0].outSize], [0, 0, 1024, 512])
    XCTAssertEqual(outs.dropFirst().map { [$0.x, $0.y, $0.size] }, [[0, 0, 512], [512, 0, 512], [0, 512, 512], [512, 512, 512]])
  }

  func testNothingFarOutAndMiddle2x2Near13() {
    XCTAssertTrue(Planner.planView(kanata, zoom: 11).isEmpty)
    let near = Planner.planView(kanata, zoom: 13)
    XCTAssertEqual(near.count, 4)
    XCTAssertTrue(near.allSatisfy { $0.prio == 2 })
    let c = Planner.centerUnit(kanata)
    XCTAssertEqual([near[0].x, near[0].y], [c.x, c.y])
    let xs = Set(near.map(\.x)), ys = Set(near.map(\.y))
    XCTAssertEqual(xs.count, 2)
    XCTAssertEqual(ys.count, 2)
    XCTAssertTrue(xs.contains(c.x) && ys.contains(c.y))
  }

  func testOnScreenFirstThenRing() {
    let plan = Planner.planView(kanata, zoom: 14.5)
    let first = plan.filter { $0.prio == 0 }, later = plan.filter { $0.prio == 2 }
    XCTAssertFalse(first.isEmpty)
    XCTAssertLessThanOrEqual(first.count, Planner.perView)
    let c = Planner.centerUnit(kanata)
    XCTAssertEqual([first[0].x, first[0].y], [c.x, c.y])
    XCTAssertEqual(plan.firstIndex(of: later[0]), first.count)
    XCTAssertLessThanOrEqual(later.count, Planner.ring)
    let onScreen = Set(first.map { [$0.x, $0.y] })
    for u in later { XCTAssertFalse(onScreen.contains([u.x, u.y])) }
    let visible = Set(Planner.visibleTiles(kanata, 14).map { [$0.x, $0.y] })
    for u in first { XCTAssertTrue(visible.contains([u.x, u.y])) }
  }
}
