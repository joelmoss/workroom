import XCTest

@testable import Workroom

/// The inspector pane count is now dynamic: the active activity-bar section decides how many
/// sub-sections its pane stacks (2 for Changes + Pull Request, 1 for Files). `InspectorPanePolicy`
/// was already count-agnostic (it operates on `collapsed.count`), so these pin the 1- and 2-pane
/// cases the activity bar actually produces, alongside the existing 3-pane coverage in
/// `InspectorPanePolicyTests`.
final class InspectorPaneDynamicCountTests: XCTestCase {
  private let minH = InspectorPanePolicy.expandedMinHeight
  private let divider: CGFloat = 1

  /// A solo pane (Files): the single expanded section fills the whole capacity, no dividers.
  func testSinglePaneFillsCapacity() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [false], capacity: 400, dividerThickness: divider)
    XCTAssertEqual(h.count, 1)
    XCTAssertEqual(h[0], 400, accuracy: 0.5, "the lone pane takes the full height")
  }

  /// A two-pane stack (Changes + Pull Request), both expanded: equal split minus the one divider.
  func testTwoPanesSplitEqually() {
    let capacity: CGFloat = 401  // 400 usable + one divider
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false], capacity: capacity, dividerThickness: divider)
    XCTAssertEqual(h.count, 2)
    XCTAssertEqual(h[0], h[1], accuracy: 0.5, "two expanded panes share equally")
    XCTAssertEqual(h.reduce(0, +) + divider, capacity, accuracy: 0.5, "panes + divider fill")
    XCTAssertGreaterThan(h[0], minH, "each half is above the floor at this capacity")
  }

  /// Two panes honour persisted weights (a dragged divider): a 2:1 weighting splits the usable space
  /// two-thirds / one-third.
  func testTwoPanesHonourWeights() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false], weights: [2, 1], capacity: 401, dividerThickness: divider)
    XCTAssertEqual(h[0], 800.0 / 3.0, accuracy: 1.0, "weight 2 of 3 → two-thirds of 400")
    XCTAssertEqual(h[1], 400.0 / 3.0, accuracy: 1.0, "weight 1 of 3 → one-third of 400")
  }

  /// A collapsed sub-section in a two-pane stack pins to the header; the other fills the rest.
  func testTwoPanesOneCollapsed() {
    let header = InspectorPanePolicy.headerHeight
    let h = InspectorPanePolicy.allocate(
      collapsed: [true, false], capacity: 401, dividerThickness: divider)
    XCTAssertEqual(h[0], header, accuracy: 0.5, "collapsed pane is exactly the header")
    XCTAssertEqual(h[1], 401 - header - divider, accuracy: 0.5, "the expanded pane takes the rest")
  }
}
