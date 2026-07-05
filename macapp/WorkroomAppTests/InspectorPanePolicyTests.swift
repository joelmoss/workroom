import AppKit
import XCTest

@testable import Workroom

/// Headless unit tests for the inspector's pure sizing policy (`InspectorPanePolicy`). These run in
/// `make app-test` with no GUI session — the bug-prone sizing decisions (collapse pinning, equal
/// default, weighted resize, floors) are verified here, not in XCUITest (which needs a GUI and is
/// blocked in some dev sessions). The raw `NSSplitView`'s actual frame distribution is Apple's code,
/// verified by manual QA; this file covers the policy that feeds it in isolation.
final class InspectorPanePolicyTests: XCTestCase {
  private let header = InspectorPanePolicy.headerHeight
  private let minH = InspectorPanePolicy.expandedMinHeight
  private let divider: CGFloat = 1

  // MARK: constraints

  func testCollapsedPaneIsPinnedToHeader() {
    let con = InspectorPanePolicy.constraints(collapsed: true)
    XCTAssertEqual(con.minHeight, header)
    XCTAssertEqual(con.maxHeight, header)
    XCTAssertTrue(con.isPinned)
  }

  func testExpandedPaneIsFlooredAndUnbounded() {
    let con = InspectorPanePolicy.constraints(collapsed: false)
    XCTAssertEqual(con.minHeight, minH, "expanded pane floors at the sensible minimum")
    XCTAssertEqual(con.maxHeight, .greatestFiniteMagnitude, "expanded pane has no ceiling")
    XCTAssertFalse(con.isPinned)
    XCTAssertLessThan(
      con.holdingPriority.rawValue, NSLayoutConstraint.Priority.defaultHigh.rawValue,
      "expanded panes hold low so a window resize is absorbed here, not by a pinned pane")
  }

  // MARK: allocate — equal default when all expanded

  func testAllExpandedSplitsEqually() {
    let capacity: CGFloat = 600
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false, false], capacity: capacity, dividerThickness: divider)
    XCTAssertEqual(h[0], h[1], accuracy: 0.5)
    XCTAssertEqual(h[1], h[2], accuracy: 0.5)
    XCTAssertEqual(h.reduce(0, +) + 2 * divider, capacity, accuracy: 0.5, "panes + dividers fill")
    XCTAssertGreaterThan(h[0], minH, "each equal third is well above the floor at this capacity")
  }

  // MARK: allocate — collapse pins to header and redistributes the rest

  func testCollapsedSectionPinnedAndRestSplitEqually() {
    let capacity: CGFloat = 600
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, true, false], capacity: capacity, dividerThickness: divider)
    XCTAssertEqual(h[1], header, accuracy: 0.5, "collapsed pane is exactly the header")
    XCTAssertEqual(h[0], h[2], accuracy: 0.5, "the two expanded panes share the rest equally")
    XCTAssertEqual(h.reduce(0, +) + 2 * divider, capacity, accuracy: 0.5)
  }

  func testAllCollapsedAreAllHeaders() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [true, true, true], capacity: 600, dividerThickness: divider)
    XCTAssertEqual(h, [header, header, header])
  }

  // MARK: allocate — persisted weights drive proportional resize

  func testWeightsDriveProportionalSplit() {
    let capacity: CGFloat = 600
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false, false], weights: [2, 1, 1], capacity: capacity,
      dividerThickness: divider)
    XCTAssertEqual(h[1], h[2], accuracy: 0.5, "equal weights → equal heights")
    XCTAssertEqual(h[0], 2 * h[1], accuracy: 1.0, "double weight → double height")
  }

  func testWeightsRenormaliseAmongExpandedPanes() {
    // Pane 0 collapsed: its weight is irrelevant; panes 1 & 2 keep their 1:1 ratio.
    let h = InspectorPanePolicy.allocate(
      collapsed: [true, false, false], weights: [99, 1, 1], capacity: 600, dividerThickness: divider
    )
    XCTAssertEqual(h[0], header, accuracy: 0.5)
    XCTAssertEqual(h[1], h[2], accuracy: 0.5, "collapsed pane's weight doesn't distort the rest")
  }

  // MARK: allocate — floors hold when the split is too short (panes scroll)

  func testCrampedExpandedPanesGetTheirFloor() {
    // Three expanded panes can't all fit their floor in this capacity; each still gets the floor
    // (and overflows into its own scroll view rather than vanishing).
    let capacity = minH * 2  // less than 3 * floor
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false, false], capacity: capacity, dividerThickness: divider)
    for height in h {
      XCTAssertGreaterThanOrEqual(height, minH, "expanded panes never dip below floor")
    }
  }

  func testZeroCapacityIsAllZeros() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false, false], capacity: 0, dividerThickness: divider)
    XCTAssertEqual(h, [0, 0, 0])
  }

  // MARK: reallocateOnToggle — a single collapse preserves the other panes' dividers

  func testCollapseLastFreesSpaceToNeighbourPreservingTopDivider() {
    // User dragged the Changes/Files divider (Changes big), then collapsed the last section (PR).
    // The freed space goes to Files (the only neighbour); Changes keeps its exact height, so the
    // divider the user set does not move.
    let h = InspectorPanePolicy.reallocateOnToggle(
      previous: [600, 148, 150], collapsed: [false, false, true], toggled: 2,
      capacity: 900, dividerThickness: divider)
    XCTAssertEqual(h[0], 600, accuracy: 0.5, "the untouched top pane keeps its height")
    XCTAssertEqual(h[2], header, accuracy: 0.5, "the collapsed pane is pinned to its header")
    XCTAssertEqual(h[1], 264, accuracy: 0.5, "the neighbour absorbs the freed space")
    XCTAssertEqual(h.reduce(0, +) + 2 * divider, 900, accuracy: 0.5, "panes + dividers fill")
  }

  func testCollapseMiddleGivesSpaceBelowPreservingTopDivider() {
    // Collapsing the middle section routes its freed space to the pane below (PR), so the top
    // section (Changes) — and the Changes/Files divider — stays put.
    let h = InspectorPanePolicy.reallocateOnToggle(
      previous: [600, 148, 150], collapsed: [false, true, false], toggled: 1,
      capacity: 900, dividerThickness: divider)
    XCTAssertEqual(h[0], 600, accuracy: 0.5, "the untouched top pane keeps its height")
    XCTAssertEqual(h[1], header, accuracy: 0.5, "the collapsed pane is pinned to its header")
    XCTAssertEqual(h[2], 264, accuracy: 0.5, "the pane below absorbs the freed space")
  }

  func testExpandTakesFromNeighbourPreservingOthers() {
    // Re-expanding a section takes the space it needs from its nearest expanded neighbour; the
    // untouched pane keeps its height and its divider.
    let h = InspectorPanePolicy.reallocateOnToggle(
      previous: [600, 264, header], collapsed: [false, false, false], toggled: 2,
      capacity: 900, dividerThickness: divider)
    XCTAssertEqual(h[0], 600, accuracy: 0.5, "the untouched pane keeps its height")
    XCTAssertEqual(h[2], minH, accuracy: 0.5, "the re-expanded pane opens to its floor")
    XCTAssertEqual(h[1], 178, accuracy: 0.5, "the neighbour yields exactly the needed space")
  }

  func testExpandCrampedSpillsToFurtherNeighbourAndFloors() {
    // Not enough room for the re-expanded pane's floor from the nearest neighbour alone: it drops to
    // the floor first, then the deficit spills to the next-nearest expanded pane.
    let h = InspectorPanePolicy.reallocateOnToggle(
      previous: [200, 150, header], collapsed: [false, false, false], toggled: 2,
      capacity: 400, dividerThickness: divider)
    XCTAssertEqual(h[1], minH, accuracy: 0.5, "the nearest neighbour is drained to its floor first")
    XCTAssertEqual(h[0], 158, accuracy: 0.5, "the remaining deficit spills to the next neighbour")
    XCTAssertEqual(h[2], minH, accuracy: 0.5, "the re-expanded pane holds its floor")
    XCTAssertEqual(h.reduce(0, +) + 2 * divider, 400, accuracy: 0.5)
  }

  func testExpandingOnlySectionTakesAllTheSpace() {
    // The toggled pane is the only expanded one (the rest already collapsed): it fills whatever the
    // collapsed headers leave, with no neighbour to anchor against.
    let h = InspectorPanePolicy.reallocateOnToggle(
      previous: [header, header, 300], collapsed: [true, true, false], toggled: 2,
      capacity: 900, dividerThickness: divider)
    XCTAssertEqual(h[0], header, accuracy: 0.5)
    XCTAssertEqual(h[1], header, accuracy: 0.5)
    XCTAssertEqual(h[2], 830, accuracy: 0.5, "the lone expanded pane takes the remaining space")
    XCTAssertEqual(h.reduce(0, +) + 2 * divider, 900, accuracy: 0.5)
  }

  func testReallocateGuardsInvalidInput() {
    let previous: [CGFloat] = [300, 300, 300]
    XCTAssertEqual(
      InspectorPanePolicy.reallocateOnToggle(
        previous: previous, collapsed: [false, false, false], toggled: 9, capacity: 900,
        dividerThickness: divider),
      previous, "an out-of-range toggle index leaves the layout untouched")
    XCTAssertEqual(
      InspectorPanePolicy.reallocateOnToggle(
        previous: previous, collapsed: [false, false, false], toggled: 0, capacity: 0,
        dividerThickness: divider),
      [0, 0, 0], "zero capacity is all zeros")
  }
}
