import CoreGraphics
import WorkroomDomain
import XCTest

@testable import Workroom

/// A tab dragged into its target's panes to split them (`TabContentDrop`), the seam the strip chip
/// and the sidebar's Open rows (#819) share: where a window point lands among the panes the content
/// lays out. The split itself is `TerminalPanes.dropTabFromStrip`'s, tested there.
@MainActor
final class TabContentDropTests: XCTestCase {
  private let left = UUID()
  private let right = UUID()
  /// Two panes side by side, the content 400 by 200 at (100, 50) in its window.
  private var layout: TerminalPaneLayout {
    .split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(right))
  }

  private func drop() -> TabContentDrop {
    let drop = TabContentDrop()
    drop.frame = CGRect(x: 100, y: 50, width: 400, height: 200)
    return drop
  }

  func testAPointOverAPaneLandsOnItsNearestEdge() throws {
    let hit = try XCTUnwrap(drop().dropTarget(at: CGPoint(x: 310, y: 150), in: layout))

    XCTAssertEqual(hit.tab, right)
    XCTAssertEqual(hit.edge, .left, "just inside the right pane's left side")
  }

  func testAPointOutsideThePanesLandsNowhere() {
    XCTAssertNil(drop().dropTarget(at: CGPoint(x: 50, y: 150), in: layout), "over the sidebar")
  }

  func testPanesNotOnScreenTakeNoDrop() {
    let drop = drop()
    drop.frame = nil

    XCTAssertNil(drop.dropTarget(at: CGPoint(x: 310, y: 150), in: layout))
  }
}
