import WorkroomDomain
import XCTest

@testable import Workroom

/// How `PaneTreeLayout` renders a `PaneLayout` tree: the geometry half of the split-pane tests. The
/// tree's own transforms are tested beside it, in the WorkroomDomain package.
final class PaneLayoutGeometryTests: XCTestCase {
  private let a = UUID()
  private let b = UUID()
  private let c = UUID()
  private let d = UUID()

  func testEqualizedSameOrientationGivesEqualWidths() {
    // All-horizontal A | B | C — equalized lays out to equal widths (within a divider's rounding).
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.7,
      first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .horizontal, ratio: 0.2, first: .leaf(b), second: .leaf(c)))
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 600)
    let widths = [a, b, c].compactMap {
      PaneTreeLayout.plan(tree.equalized(), in: rect).panes[$0]?.width
    }
    XCTAssertEqual(widths.count, 3)
    for w in widths {
      XCTAssertEqual(w, 400, accuracy: PaneTreeLayout.dividerThickness * 2)
    }
  }
  func testEqualizedMixedOrientationKeepsThePerpendicularDivider() {
    // A | (B / C). The nested split runs the other way, so it is ONE column: A and the stacked pair
    // each get half the width, and the pair splits its own height. Weighting by leaf count instead
    // gave A a third of the width — a split made inside the right column resizing the left one,
    // which is the defect #126 reported ("split down, then split right, and the untouched pane
    // shrinks"). Deliberately NOT equal-area: A is twice either stacked pane, as in every tiler.
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.8,
      first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: 0.8, first: .leaf(b), second: .leaf(c)))
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 900)
    let panes = PaneTreeLayout.plan(tree.equalized(), in: rect).panes
    XCTAssertEqual(panes[a]?.width ?? 0, 599, accuracy: 2, "half the width")
    XCTAssertEqual(panes[a]?.height ?? 0, 900, accuracy: 2, "full height, untouched")
    XCTAssertEqual(panes[b]?.width ?? 0, 599, accuracy: 2)
    XCTAssertEqual(panes[b]?.height ?? 0, 449, accuracy: 2, "the pair splits its own height")
    XCTAssertEqual(panes[c]?.height ?? 0, 449, accuracy: 2)
  }
  func testEqualizedGridGivesFourIdenticalPanes() {
    // (A / B) | (C / D): two columns, each split in half. Every pane the same size.
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.8,
      first: .split(
        id: UUID(), orientation: .vertical, ratio: 0.2, first: .leaf(a), second: .leaf(b)),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: 0.7, first: .leaf(c), second: .leaf(d)))
    let panes = PaneTreeLayout.plan(
      tree.equalized(), in: CGRect(x: 0, y: 0, width: 1200, height: 900)
    ).panes
    for id in [a, b, c, d] {
      XCTAssertEqual(panes[id]?.width ?? 0, 599, accuracy: 2)
      XCTAssertEqual(panes[id]?.height ?? 0, 449, accuracy: 2)
    }
  }
  // MARK: divider hit-zone (issue #83)

  func testDividerHitRectWidensSplitAxisOnly() {
    let rect = CGRect(x: 0, y: 0, width: 1000, height: 800)

    let hSplit = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    let hDiv = PaneTreeLayout.plan(hSplit, in: rect).dividers[0]
    XCTAssertEqual(hDiv.hitRect.width, PaneTreeLayout.dividerHitThickness, accuracy: 0.0001)
    // Full perpendicular length, centered on the gutter.
    XCTAssertEqual(hDiv.hitRect.height, hDiv.rect.height, accuracy: 0.0001)
    XCTAssertEqual(hDiv.hitRect.midX, hDiv.rect.midX, accuracy: 0.0001)

    let vSplit = PaneLayout.split(
      id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    let vDiv = PaneTreeLayout.plan(vSplit, in: rect).dividers[0]
    XCTAssertEqual(vDiv.hitRect.height, PaneTreeLayout.dividerHitThickness, accuracy: 0.0001)
    XCTAssertEqual(vDiv.hitRect.width, vDiv.rect.width, accuracy: 0.0001)
    XCTAssertEqual(vDiv.hitRect.midY, vDiv.rect.midY, accuracy: 0.0001)
  }
}
