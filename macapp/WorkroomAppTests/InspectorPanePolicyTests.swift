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
  // MARK: The sidebar's split (#652): per-pane floors and a content-sized pane

  /// Value: protects=the sidebar's Terminals pane sized to its rows, with Projects taking the rest;
  /// fails_when=a preferred pane is split by weight, or Projects doesn't fill what's left
  func testAPreferredPaneTakesItsHeightAndTheOthersTheRest() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false], minHeights: [60, 120], preferred: [100, nil],
      capacity: 801, dividerThickness: divider)
    XCTAssertEqual(h[0], 100, accuracy: 0.5, "Terminals fits its rows")
    XCTAssertEqual(h[1], 700, accuracy: 0.5, "Projects takes the rest")
  }

  /// Value: protects=a long Terminals section stops at its cap, so Projects keeps most of the
  /// sidebar; fails_when=the preferred height isn't capped at `preferredCap` of the space
  func testAPreferredPaneIsCapped() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false], minHeights: [60, 120], preferred: [900, nil], preferredCap: 0.4,
      capacity: 1001, dividerThickness: divider)
    XCTAssertEqual(h[0], 400, accuracy: 0.5, "at most 40% of the sidebar")
    XCTAssertEqual(h[1], 600, accuracy: 0.5)
  }

  /// Value: protects=a one-row Terminals pane isn't padded to the inspector's 120pt floor;
  /// fails_when=`minHeights` is ignored for a preferred pane
  func testAPreferredPaneIsFlooredAtItsOwnMinimum() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false], minHeights: [60, 120], preferred: [10, nil],
      capacity: 801, dividerThickness: divider)
    XCTAssertEqual(h[0], 60, accuracy: 0.5, "its own floor, under the inspector's")
  }

  /// Value: protects=with Projects folded, the Terminals pane fills the sidebar under the
  /// Projects heading; fails_when=a lone expanded pane keeps its content height
  func testALonePreferredPaneFills() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, true], minHeights: [60, 120], preferred: [100, nil],
      capacity: 801, dividerThickness: divider)
    XCTAssertEqual(h[0], 800 - header, accuracy: 0.5)
    XCTAssertEqual(h[1], header, accuracy: 0.5)
  }

  /// Value: protects=collapsing Projects gives Terminals the space, floored at its own minimum;
  /// fails_when=`reallocateOnToggle` floors at the inspector's minimum instead of the pane's
  func testReallocateUsesPerPaneFloors() {
    let h = InspectorPanePolicy.reallocateOnToggle(
      previous: [60, 740], collapsed: [false, true], toggled: 1, minHeights: [40, 120],
      capacity: 801, dividerThickness: divider)
    XCTAssertEqual(h[1], header, accuracy: 0.5)
    XCTAssertEqual(h[0], 800 - header, accuracy: 0.5, "the neighbour absorbs it")
  }
}
