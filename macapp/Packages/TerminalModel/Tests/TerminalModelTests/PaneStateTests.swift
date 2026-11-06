import CoreGraphics
import Foundation
import TerminalModel
import WorkroomDomain
import XCTest

/// The id-only rules of one target's panes (`PaneState`). `TerminalSessions`' suites keep the tests
/// of its wiring: which rule each action runs, with which detached set, recency and split policy.
final class PaneStateTests: XCTestCase {
  private typealias State = PaneState<String>

  /// Evening off, so a removal leaves the survivors' dividers where they were.
  private let still = PaneSplitPolicy<String>(space: nil, autoEven: false)

  private func pair(
    _ first: String, _ second: String, _ orientation: SplitOrientation = .horizontal
  ) -> PaneLayout<String> {
    .split(
      id: UUID(), orientation: orientation, ratio: 0.5, first: .leaf(first), second: .leaf(second))
  }

  // MARK: Order

  func testNormalizedOrderRunsEachGroupContiguouslyAtItsEarliestMember() {
    let state = State(
      order: ["a", "c", "b", "d"], splits: PaneSplitGroups([pair("b", "c")]))
    XCTAssertEqual(state.normalizedOrder, ["a", "b", "c", "d"])
  }

  func testNormalizedOrderIsAFixedPoint() {
    var state = State(
      order: ["d", "c", "a", "b"], splits: PaneSplitGroups([pair("b", "c")]))
    let once = state.normalizedOrder
    state.order = once
    XCTAssertEqual(state.normalizedOrder, once)
  }

  func testDisplayedOrderHidesDetachedButNormalizedKeepsThem() {
    let state = State(order: ["a", "b", "c"])
    XCTAssertEqual(state.displayedOrder(hiding: ["b"]), ["a", "c"])
    XCTAssertEqual(state.displayedOrder(hiding: []), ["a", "b", "c"])
    XCTAssertEqual(state.normalizedOrder, ["a", "b", "c"])
  }

  func testPlaceAfterMovesTheIdBesideItsAnchor() {
    var state = State(order: ["a", "b", "c", "d"])
    state.place("d", after: "a")
    XCTAssertEqual(state.order, ["a", "d", "b", "c"])
    state.place("e", after: "c")
    XCTAssertEqual(state.order, ["a", "d", "b", "c", "e"])
  }

  func testPlaceAfterAMissingAnchorAppends() {
    var state = State(order: ["a", "b"])
    state.place("a", after: "gone")
    XCTAssertEqual(state.order, ["b", "a"])
  }

  func testMoveClampsToTheOrdersBounds() {
    var state = State(order: ["a", "b", "c"])
    state.move("a", toIndex: 99)
    XCTAssertEqual(state.order, ["b", "c", "a"])
    state.move("a", toIndex: -4)
    XCTAssertEqual(state.order, ["a", "b", "c"])
    state.move("b", toIndex: 2)
    XCTAssertEqual(state.order, ["a", "c", "b"])
  }

  func testMovingAnIdNotInTheOrderChangesNothing() {
    var state = State(order: ["a", "b"])
    state.move("z", toIndex: 0)
    XCTAssertEqual(state.order, ["a", "b"])
  }

  func testRemoveDropsTheIdFromTheOrderAndItsGroup() {
    var state = State(
      order: ["a", "b", "c", "d"],
      splits: PaneSplitGroups([
        .split(
          id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf("a"),
          second: pair("b", "c"))
      ]))
    state.remove("b", policy: still)
    XCTAssertEqual(state.order, ["a", "c", "d"])
    XCTAssertEqual(state.splits.groups.map(\.tabIDs), [["a", "c"]])
  }

  func testRemovingOneOfTwoMembersDissolvesTheGroup() {
    var state = State(order: ["a", "b"], splits: PaneSplitGroups([pair("a", "b")]))
    state.remove("a", policy: still)
    XCTAssertEqual(state.order, ["b"])
    XCTAssertTrue(state.splits.isEmpty)
  }

  // MARK: Splits and focus

  func testVisibleGroupIsTheFocusedTabsGroupOnly() {
    var state = State(order: ["a", "b", "c"], splits: PaneSplitGroups([pair("b", "c")]))
    state.focused = "a"
    XCTAssertNil(state.visibleGroup, "a solo focused tab shows no group")
    state.focused = "c"
    XCTAssertEqual(state.visibleGroup?.tabIDs, ["b", "c"])
  }

  func testShownSlotsCountTheVisibleGroupsPanesEachWay() {
    var state = State(
      order: ["a", "b", "c"],
      splits: PaneSplitGroups([
        .split(
          id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf("a"),
          second: pair("b", "c", .vertical))
      ]))
    state.focused = "b"
    XCTAssertEqual(state.shownSlots, [.horizontal: 2, .vertical: 2])
    state.focused = nil
    XCTAssertEqual(state.shownSlots, [.horizontal: 1, .vertical: 1])
  }

  func testUngroupLeavesASoloTabAlone() {
    var state = State(order: ["a", "b", "c"], splits: PaneSplitGroups([pair("b", "c")]))
    state.ungroup("a", policy: still)
    XCTAssertEqual(state.splits.groups.map(\.tabIDs), [["b", "c"]])
  }

  // MARK: Close successor

  func testCloseSuccessorPrefersTheMostRecentTabStillShown() {
    let state = State(order: ["a", "b", "c", "d"])
    XCTAssertEqual(state.closeSuccessor(of: "b", hiding: [], recency: ["b", "z", "d", "a"]), "d")
  }

  func testCloseSuccessorFallsBackToTheNeighbourSlidingIntoTheSlot() {
    let state = State(order: ["a", "b", "c"])
    XCTAssertEqual(state.closeSuccessor(of: "b", hiding: [], recency: []), "c")
    XCTAssertEqual(state.closeSuccessor(of: "c", hiding: [], recency: []), "b", "the last slot")
  }

  func testCloseSuccessorOfTheOnlyShownTabIsNil() {
    let state = State(order: ["a", "b"])
    XCTAssertNil(state.closeSuccessor(of: "a", hiding: ["b"], recency: ["b"]))
  }

  func testCloseSuccessorNeverLandsOnADetachedPane() {
    let state = State(order: ["a", "b", "c"])
    XCTAssertEqual(state.closeSuccessor(of: "a", hiding: ["b"], recency: ["b"]), "c")
  }

  func testCloseSuccessorOfAGroupMemberStaysInsideTheGroup() {
    let state = State(
      order: ["a", "b", "c", "d"],
      splits: PaneSplitGroups([
        .split(
          id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf("b"),
          second: pair("c", "d"))
      ]))
    XCTAssertEqual(
      state.closeSuccessor(of: "c", hiding: [], recency: ["a", "b"]), "b",
      "the recent tab outside the group is skipped")
    XCTAssertEqual(
      state.closeSuccessor(of: "c", hiding: [], recency: []), "d",
      "positional within the survivors")
  }

  func testCloseSuccessorOfATwoPaneMemberIsItsLoneSurvivor() {
    let state = State(order: ["a", "b", "c"], splits: PaneSplitGroups([pair("b", "c")]))
    XCTAssertEqual(state.closeSuccessor(of: "c", hiding: [], recency: ["a"]), "b")
  }

  // MARK: Whole state and counter

  func testEmptiedKeepsOnlyTheCounter() {
    var state = State(order: ["a", "b"], splits: PaneSplitGroups([pair("a", "b")]), focused: "a")
    _ = state.numberNextTerminal()
    _ = state.numberNextTerminal()
    XCTAssertEqual(state.emptied(), State(counter: 2))
  }

  func testNumberingStartsAtOneAndCountsOn() {
    var state = State()
    XCTAssertNil(state.counter, "nothing numbered yet")
    XCTAssertEqual(state.numberNextTerminal(), 1)
    XCTAssertEqual(state.numberNextTerminal(), 2)
    XCTAssertEqual(state.counter, 2)
  }

  func testRaiseCounterKeepsTheHigherNumber() {
    var state = State()
    state.raiseCounter(to: 0)
    XCTAssertEqual(state.counter, 0, "a raise always records a counter")
    state.raiseCounter(to: 7)
    XCTAssertEqual(state.counter, 7)
    state.raiseCounter(to: 3)
    XCTAssertEqual(state.counter, 7)
    XCTAssertEqual(state.numberNextTerminal(), 8)
  }
}
