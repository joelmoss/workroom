import WorkroomDomain
import XCTest

/// Pure-tree tests for `PaneLayout` (issue #3). No surfaces needed — leaves are tab ids.
final class PaneLayoutTests: XCTestCase {
  private let a = UUID()
  private let b = UUID()
  private let c = UUID()
  private let d = UUID()
  func testTabIDsReadingOrderNested() {
    // split(h, leaf(a), split(v, leaf(b), leaf(c)))  →  [a, b, c]
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
    )
    XCTAssertEqual(tree.tabIDs, [a, b, c])
    XCTAssertEqual(tree.firstTabID, a)
    XCTAssertTrue(tree.contains(c))
    XCTAssertFalse(tree.contains(d))
  }
  func testInsertingBesideLeaf() {
    // leaf(a) + b on the trailing side → split(a, b)
    let tree = PaneLayout.leaf(a)
      .inserting(b, beside: a, orientation: .horizontal, newLeafFirst: false, ratio: 0.5)
    XCTAssertEqual(tree.tabIDs, [a, b])
    // newLeafFirst puts the new pane first.
    let leading = PaneLayout.leaf(a)
      .inserting(b, beside: a, orientation: .vertical, newLeafFirst: true, ratio: 0.5)
    XCTAssertEqual(leading.tabIDs, [b, a])
  }
  func testInsertingDeepInTree() {
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)
    ).inserting(c, beside: b, orientation: .vertical, newLeafFirst: false, ratio: 0.5)
    XCTAssertEqual(tree.tabIDs, [a, b, c])
  }
  func testRemovingLeafCollapsesToSibling() {
    let split = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    // Remove a → the sibling leaf(b) remains (a single leaf — caller dissolves the split).
    let collapsed = split.removingLeaf(a)
    XCTAssertEqual(collapsed, .leaf(b))
    XCTAssertEqual(collapsed?.tabIDs.count, 1)
  }
  func testRemovingLeafFromThreePaneKeepsSplit() {
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    let collapsed = tree.removingLeaf(b)
    XCTAssertEqual(collapsed?.tabIDs, [a, c])  // inner split collapses to c; outer keeps a|c
  }
  func testRemovingWholeLeafReturnsNil() {
    XCTAssertNil(PaneLayout.leaf(a).removingLeaf(a))
    XCTAssertEqual(PaneLayout.leaf(a).removingLeaf(b), .leaf(a))  // not present → unchanged
  }
  func testReplacingLeafKeepsSlotAndStructure() {
    // split(h, 0.3, leaf(a), split(v, 0.7, leaf(b), leaf(c)))  →  swap b for d in place.
    let inner = UUID()
    let outer = UUID()
    let tree = PaneLayout.split(
      id: outer, orientation: .horizontal, ratio: 0.3,
      first: .leaf(a),
      second: .split(
        id: inner, orientation: .vertical, ratio: 0.7, first: .leaf(b), second: .leaf(c)))
    let replaced = tree.replacingLeaf(b, with: d)
    // d takes b's exact slot; reading order, sibling, orientations, ratios, and node ids all survive.
    XCTAssertEqual(
      replaced,
      .split(
        id: outer, orientation: .horizontal, ratio: 0.3,
        first: .leaf(a),
        second: .split(
          id: inner, orientation: .vertical, ratio: 0.7, first: .leaf(d), second: .leaf(c))))
    XCTAssertEqual(replaced.tabIDs, [a, d, c])
  }
  func testReplacingAbsentLeafIsUnchanged() {
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    XCTAssertEqual(tree.replacingLeaf(c, with: d), tree)  // c not present → no change
    XCTAssertEqual(PaneLayout.leaf(a).replacingLeaf(a, with: d), .leaf(d))  // bare leaf swaps
  }
  func testSettingRatioTargetsOneNode() {
    let inner = UUID()
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(
        id: inner, orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    let updated = tree.settingRatio(0.8, forSplit: inner)
    if case .split(_, _, _, _, .split(_, _, let r, _, _)) = updated {
      XCTAssertEqual(r, 0.8, accuracy: 0.0001)
    } else {
      XCTFail("inner split not found")
    }
  }
  /// A divider drag draws its in-flight ratio over the tree, and only while its node still holds
  /// the ratio the drag began from: a node that moved underneath it (a re-even, issue #126) or
  /// went away is drawn as it is, so the divider re-anchors.
  func testShowingDragOverlaysOnlyWhileItsNodeIsUnmoved() {
    let id = UUID()
    let tree = PaneLayout.split(
      id: id, orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    XCTAssertEqual(
      tree.showingDrag(0.7, forSplit: id, from: 0.5).ratio(forSplit: id) ?? 0, 0.7,
      accuracy: 0.0001, "the live ratio is drawn")
    XCTAssertEqual(
      tree.showingDrag(0.7, forSplit: id, from: 0.4), tree, "a moved node is drawn as stored")
    XCTAssertEqual(
      tree.showingDrag(0.7, forSplit: UUID(), from: 0.5), tree, "a gone node changes nothing")
  }
  func testContainsSplitFindsRootAndNestedNodesOnly() {
    // The lookup a holder of SEVERAL trees uses to find which one owns a dragged divider
    // (`AppStore.setWorkroomSplitRatio` over `workroomSplits`).
    let outer = UUID()
    let inner = UUID()
    let tree = PaneLayout.split(
      id: outer, orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(
        id: inner, orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    XCTAssertTrue(tree.containsSplit(outer))
    XCTAssertTrue(tree.containsSplit(inner), "nested nodes count too")
    XCTAssertFalse(tree.containsSplit(UUID()), "an id from another tree must not match")
    XCTAssertFalse(PaneLayout.leaf(a).containsSplit(outer), "a lone leaf owns no split node")
  }
  func testRatioSanitizeClampsOpenInterval() {
    XCTAssertEqual(PaneRatio.sanitize(0), 0.001, accuracy: 0.0001)
    XCTAssertEqual(PaneRatio.sanitize(1), 0.999, accuracy: 0.0001)
    XCTAssertEqual(PaneRatio.sanitize(0.5), 0.5, accuracy: 0.0001)
  }
  // MARK: leafCount + equalized (issue #83)

  func testLeafCount() {
    XCTAssertEqual(PaneLayout.leaf(a).leafCount, 1)
    let two = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    XCTAssertEqual(two.leafCount, 2)
    let three = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    XCTAssertEqual(three.leafCount, 3)
  }
  func testEqualizedLeafIsNoop() {
    XCTAssertEqual(PaneLayout.leaf(a).equalized(), .leaf(a))
  }
  func testEqualizedBalancedSplitIsHalf() {
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.2, first: .leaf(a), second: .leaf(b))
    if case .split(_, _, let r, _, _) = tree.equalized() {
      XCTAssertEqual(r, 0.5, accuracy: 0.0001)
    } else {
      XCTFail("expected a split")
    }
  }
  func testEqualizedUnbalancedWeightsByLeafCount() {
    // split(A, split(B, C)) → outer leans 1/3 (A is 1 of 3 leaves), inner 1/2.
    let outer = UUID()
    let inner = UUID()
    let tree = PaneLayout.split(
      id: outer, orientation: .horizontal, ratio: 0.9,
      first: .leaf(a),
      second: .split(
        id: inner, orientation: .horizontal, ratio: 0.1, first: .leaf(b), second: .leaf(c)))
    if case .split(_, _, let ro, _, .split(_, _, let ri, _, _)) = tree.equalized() {
      XCTAssertEqual(ro, 1.0 / 3.0, accuracy: 0.0001)
      XCTAssertEqual(ri, 0.5, accuracy: 0.0001)
    } else {
      XCTFail("expected a nested split")
    }
  }
  func testAxisAroundIsTheOrientationOfTheSplitHoldingTheLeaf() {
    // A | (B / C)
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    XCTAssertEqual(tree.axis(around: a), .horizontal)
    XCTAssertEqual(tree.axis(around: c), .vertical)
    XCTAssertNil(tree.axis(around: d))
    XCTAssertNil(PaneLayout.leaf(a).axis(around: a))
  }
  func testEqualizedAlongAnAxisKeepsTheOtherAxis() {
    // (A / B) | C | D: the vertical divider inside the first column keeps its 0.8 while the
    // horizontal chain below and above it is still evened.
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.9,
      first: .split(
        id: UUID(), orientation: .vertical, ratio: 0.8, first: .leaf(a), second: .leaf(b)),
      second: .split(
        id: UUID(), orientation: .horizontal, ratio: 0.1, first: .leaf(c), second: .leaf(d)))
    guard
      case .split(_, _, let root, .split(_, _, let column, _, _), .split(_, _, let row, _, _)) =
        tree.equalized(along: .horizontal)
    else { return XCTFail("expected the same shape") }
    XCTAssertEqual(root, 1.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(row, 0.5, accuracy: 0.0001)
    XCTAssertEqual(column, 0.8, accuracy: 0.0001)
  }
  /// Value: protects=weighted, a stacked column counts as its widest member, while unweighted it
  /// still counts as one (#126); fails_when=the other-axis rule ignores weights, or applies to
  /// unweighted trees; seam=none; no_claim=AppStore's weights
  func testAWeightedStackCountsAsItsWidestMember() {
    // A | (B / C) with B two columns wide: the B/C column needs two shares, so A gets a third.
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    let wide = b
    let weighted = tree.equalized(leafSlots: { leaf, o in leaf == wide && o == .horizontal ? 2 : 1 }
    )
    guard case .split(_, _, let rw, _, _) = weighted,
      case .split(_, _, let ru, _, _) = tree.equalized()
    else { return XCTFail("expected splits") }
    XCTAssertEqual(rw, 1.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(ru, 0.5, accuracy: 0.0001, "unweighted, the stack is still one column")
  }

  /// Value: protects=maxSlots counts the widest row / tallest column, not the root chain;
  /// fails_when=an other-axis split counts as one or as the sum; seam=none; no_claim=none
  func testMaxSlotsCountsTheWidestRowAndTheTallestColumn() {
    // A / (B | C): one pane on top, two side by side below.
    let tree = PaneLayout.split(
      id: UUID(), orientation: .vertical, ratio: 0.5,
      first: .leaf(a),
      second: .split(
        id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    XCTAssertEqual(tree.maxSlots(along: .horizontal), 2, "the bottom row is two panes wide")
    XCTAssertEqual(tree.maxSlots(along: .vertical), 2, "and the tree is two panes tall")
    XCTAssertEqual(tree.slots(along: .horizontal), 1, "where the root chain counts one column")
    XCTAssertEqual(PaneLayout.leaf(a).maxSlots(along: .horizontal), 1)
  }

  /// Value: protects=a leaf weighted 2 along an axis takes two shares there and one on the other;
  /// fails_when=leafSlots is ignored, read for the wrong orientation, or a zero weight divides by
  /// zero; seam=none; no_claim=what weight a workroom gets (AppStore's job)
  func testEqualizedWeightsEachLeafByItsSlotsAlongTheSplitsAxis() {
    // A | B with B two columns wide: A gets a third.
    let row = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    let wide = b
    let widths: (UUID, SplitOrientation) -> Int = { leaf, o in
      leaf == wide && o == .horizontal ? 2 : 1
    }
    guard case .split(_, _, let r, _, _) = row.equalized(leafSlots: widths) else {
      return XCTFail("expected a split")
    }
    XCTAssertEqual(r, 1.0 / 3.0, accuracy: 0.0001)
    // A / B with the same weights: B is two columns, not two rows, so the heights stay even.
    let column = PaneLayout.split(
      id: UUID(), orientation: .vertical, ratio: 0.2, first: .leaf(a), second: .leaf(b))
    guard case .split(_, _, let rc, _, _) = column.equalized(leafSlots: widths) else {
      return XCTFail("expected a split")
    }
    XCTAssertEqual(rc, 0.5, accuracy: 0.0001)
    // A weight below one still counts as one pane.
    guard case .split(_, _, let rz, _, _) = row.equalized(leafSlots: { _, _ in 0 }) else {
      return XCTFail("expected a split")
    }
    XCTAssertEqual(rz, 0.5, accuracy: 0.0001)
  }
}
