import XCTest
@testable import WLKit

final class PlaceholderTests: XCTestCase {
    func testPadGeometry() {
        XCTAssertEqual(Pad.rows.flatMap { $0 }.count, Pad.keyCount)
        // Reading order: the top row is wired right to left.
        XCTAssertEqual(Pad.agentKeyIDs, [1, 0, 2, 3, 4, 5])
        // Display order differs from firmware order in exactly one way: the
        // top row is mirrored. Comparing sorted sets would miss a wrong order.
        XCTAssertEqual(Pad.displayRows[0], Array(Pad.rows[0].reversed()))
        XCTAssertEqual(Array(Pad.displayRows.dropFirst()), Array(Pad.rows.dropFirst()))
    }
}
