import CoreGraphics
import WorkroomDomain
import XCTest

@testable import Workroom

/// The Open list's order while a drag has lifted one of its rows (#819): the gap the rows open
/// under the pointer, where the drop lands, and where the drag's drop zones are hit.
final class OpenRowReflowTests: XCTestCase {
  private let pitch: CGFloat = 30
  private let one = SidebarID.workroom(project: "/p", name: "one")
  private let two = SidebarID.workroom(project: "/p", name: "two")
  private let three = SidebarID.workroom(project: "/p", name: "three")
  private let a = UUID()
  private let b = UUID()
  private let c = UUID()

  /// one (folded), two with tabs a, b and c, three.
  private var items: [OpenSectionItem] {
    [
      .workroom(one), .workroom(two), .tab(a, in: two), .tab(b, in: two), .tab(c, in: two),
      .workroom(three),
    ]
  }

  /// The middle of list row `row`, plus `by` rows.
  private func y(_ row: Int, _ by: CGFloat = 0.5) -> CGFloat { (CGFloat(row) + by) * pitch }

  /// Value: protects=a lifted tab's gap follows the pointer among its workroom's tabs, passing a
  /// row at its middle, so the row slides under a pointer that is then in the gap; fails_when=the
  /// gap flickers between two places or lands a row off; seam=OpenRowReflow
  func testATabsGapFollowsThePointerAndLandsWhereItShows() throws {
    var reflow = try XCTUnwrap(OpenRowReflow(items: items, dragged: .tab(a, in: two)))
    XCTAssertEqual(reflow.order, items, "lifted, it holds its own slot")
    XCTAssertNil(reflow.movedIndex)

    // Over b's upper half: b is just under the gap already, so nothing moves.
    reflow.pointer(at: y(3, 0.3), pitch: pitch)
    XCTAssertNil(reflow.movedIndex)
    // Past b's middle: the gap goes below b, which slides up under the pointer.
    reflow.pointer(at: y(3, 0.6), pitch: pitch)
    XCTAssertEqual(reflow.movedIndex, 1)
    XCTAssertEqual(
      reflow.order,
      [
        .workroom(one), .workroom(two), .tab(b, in: two), .tab(a, in: two), .tab(c, in: two),
        .workroom(three),
      ])
    // The pointer, still where it was, is in the gap now: it stays.
    reflow.pointer(at: y(3, 0.6), pitch: pitch)
    XCTAssertEqual(reflow.movedIndex, 1)
    // Back up past b's middle, now one row higher: it goes back.
    reflow.pointer(at: y(2, 0.4), pitch: pitch)
    XCTAssertNil(reflow.movedIndex)

    // Far below its workroom, or above it: it stays among its own tabs, at their end or start.
    reflow.pointer(at: y(5), pitch: pitch)
    XCTAssertEqual(reflow.movedIndex, 2)
    reflow.pointer(at: y(0), pitch: pitch)
    XCTAssertNil(reflow.movedIndex, "back at the start, where it was")
  }

  /// Value: protects=a lifted workroom row's tabs leave the list with it, and it lands past whole
  /// workrooms; fails_when=it lands between another workroom and its tabs; seam=OpenRowReflow
  func testAWorkroomsGapPassesWholeWorkrooms() throws {
    var reflow = try XCTUnwrap(OpenRowReflow(items: items, dragged: .workroom(two)))
    XCTAssertEqual(
      reflow.order, [.workroom(one), .workroom(two), .workroom(three)], "its tabs go with it")

    reflow.pointer(at: y(2, 0.7), pitch: pitch)
    XCTAssertEqual(reflow.movedIndex, 2, "past three")
    XCTAssertEqual(reflow.order, [.workroom(one), .workroom(three), .workroom(two)])
    reflow.pointer(at: y(0, 0.2), pitch: pitch)
    XCTAssertEqual(reflow.movedIndex, 0, "above one")

    // Lifting one, over two: two and its tabs are one workroom, passed at its row's middle.
    var first = try XCTUnwrap(OpenRowReflow(items: items, dragged: .workroom(one)))
    first.pointer(at: y(1, 0.3), pitch: pitch)
    XCTAssertNil(first.movedIndex, "in the upper half of two's row")
    first.pointer(at: y(1, 0.8), pitch: pitch)
    XCTAssertEqual(first.movedIndex, 1, "in its lower half: after two and its tabs")
    first.pointer(at: y(2, 0.5), pitch: pitch)
    XCTAssertEqual(first.movedIndex, 1, "over two's tabs, still after two")
    XCTAssertEqual(
      first.order,
      [
        .workroom(two), .tab(a, in: two), .tab(b, in: two), .tab(c, in: two), .workroom(one),
        .workroom(three),
      ])
  }

  /// Value: protects=out of the list the gap closes and the lifted row leaves it; back in, it
  /// opens again under the pointer; a cancel puts the row back; fails_when=a drag over the panes
  /// keeps a gap, or a cancel leaves the rows reordered; seam=OpenRowReflow
  func testTheGapClosesOutsideTheListAndACancelRestoresTheOrder() throws {
    var reflow = try XCTUnwrap(OpenRowReflow(items: items, dragged: .tab(a, in: two)))
    reflow.pointer(at: nil, pitch: pitch)
    XCTAssertNil(reflow.landing)
    XCTAssertEqual(
      reflow.order,
      [.workroom(one), .workroom(two), .tab(b, in: two), .tab(c, in: two), .workroom(three)])

    // In again over c's lower half (row 3 with the gap closed).
    reflow.pointer(at: y(3, 0.8), pitch: pitch)
    XCTAssertEqual(reflow.movedIndex, 2)

    reflow.restore()
    XCTAssertNil(reflow.movedIndex)
    XCTAssertEqual(reflow.order, items)
  }

  /// Value: protects=while the pointer is onto a row that takes the drop (or refuses it) the gap
  /// stays, so that row is shown, not a gap; fails_when=a join's row slides away under the
  /// pointer; seam=OpenRowReflow
  func testOntoARowTheGapStays() throws {
    // Lifting three, up into two's block from below: over two's tabs and its row's lower half the
    // gap stays under the block, so two's row stays put for the pointer to reach its middle.
    var up = try XCTUnwrap(OpenRowReflow(items: items, dragged: .workroom(three)))
    for at in [y(4, 0.5), y(2, 0.5), y(1, 0.8)] {
      up.pointer(at: at, pitch: pitch)
      XCTAssertNil(up.movedIndex, "still under two at \(at)")
    }
    up.pointer(at: y(1, 0.2), pitch: pitch)
    XCTAssertEqual(up.movedIndex, 1, "its row's upper half: above two")

    var reflow = try XCTUnwrap(OpenRowReflow(items: items, dragged: .workroom(one)))
    reflow.pointer(at: y(5, 0.9), pitch: pitch, holds: true)
    XCTAssertNil(reflow.movedIndex, "held where it was")
    reflow.pointer(at: y(5, 0.9), pitch: pitch)
    XCTAssertEqual(reflow.movedIndex, 2, "between rows again, it moves")
  }

  /// Value: protects=the drag's drop zones, measured as the row lifted, are hit on the row the
  /// pointer is over now, and the gap and the lifted tab's own workroom are no zone;
  /// fails_when=a join lands on the row that used to be there, or a reorder in its own workroom
  /// shows an insertion line; seam=OpenRowReflow.liftedY
  func testTheDropZonesAreHitOnTheRowsAsTheyShow() throws {
    var reflow = try XCTUnwrap(OpenRowReflow(items: items, dragged: .workroom(one)))
    reflow.pointer(at: y(5, 0.9), pitch: pitch)
    // Now: two, a, b, c, three, [one]. Row 4 is three, which was row 5.
    XCTAssertEqual(reflow.liftedY(for: y(4, 0.5), pitch: pitch), y(5, 0.5))
    XCTAssertNil(reflow.liftedY(for: y(5, 0.5), pitch: pitch), "the gap")

    let tab = try XCTUnwrap(OpenRowReflow(items: items, dragged: .tab(b, in: two)))
    XCTAssertNil(tab.liftedY(for: y(2), pitch: pitch), "a sibling: this reorder's")
    XCTAssertNil(tab.liftedY(for: y(1), pitch: pitch), "its own workroom's row")
    XCTAssertEqual(tab.liftedY(for: y(5), pitch: pitch), y(5), "another workroom's")

    // A tab that can leave its workroom: another workroom row's quarters are between workrooms.
    let leaving = try XCTUnwrap(
      OpenRowReflow(items: items, dragged: .tab(b, in: two), leavesWorkroom: true))
    XCTAssertNil(leaving.liftedY(for: y(5, 0.1), pitch: pitch), "three's upper quarter")
    XCTAssertEqual(leaving.liftedY(for: y(5, 0.5), pitch: pitch), y(5, 0.5), "its middle: onto it")
    XCTAssertNil(leaving.liftedY(for: y(5, 0.9), pitch: pitch), "its lower quarter")
    XCTAssertNil(leaving.liftedY(for: y(1, 0.5), pitch: pitch), "its own workroom's row")
  }

  // MARK: A tab between workrooms

  /// Value: protects=a lifted tab that can become a standalone terminal opens its gap between
  /// whole workrooms elsewhere in the list, the start and the end included, each workroom judged
  /// on its own row's halves, and says where between them it lands; a cancel puts it back;
  /// fails_when=the gap splits another workroom from its tabs, flickers, names the wrong
  /// neighbours, or a cancel leaves it out; why_new=#819 owner report; seam=OpenRowReflow
  func testATabsGapOpensBetweenWorkroomsAndSaysWhere() throws {
    var reflow = try XCTUnwrap(
      OpenRowReflow(items: items, dragged: .tab(b, in: two), leavesWorkroom: true))

    // one's upper half: above one, at the start.
    reflow.pointer(at: y(0, 0.2), pitch: pitch)
    XCTAssertNil(reflow.movedIndex)
    XCTAssertEqual(reflow.standalonePlace?.after, .some(nil))
    XCTAssertEqual(reflow.standalonePlace?.before, one)
    XCTAssertEqual(
      reflow.order,
      [
        .tab(b, in: two), .workroom(one), .workroom(two), .tab(a, in: two), .tab(c, in: two),
        .workroom(three),
      ])
    // The pointer, still there, is in the gap now: it stays.
    reflow.pointer(at: y(0, 0.2), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.before, one)

    // one, slid down a row, by its lower half: after it, before two.
    reflow.pointer(at: y(1, 0.8), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.after, one)
    XCTAssertEqual(reflow.standalonePlace?.before, two)
    XCTAssertEqual(
      reflow.order,
      [
        .workroom(one), .tab(b, in: two), .workroom(two), .tab(a, in: two), .tab(c, in: two),
        .workroom(three),
      ])

    // three by its upper half: past two and its tabs, before three.
    reflow.pointer(at: y(5, 0.2), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.after, two)
    XCTAssertEqual(reflow.standalonePlace?.before, three)
    XCTAssertEqual(
      reflow.order,
      [
        .workroom(one), .workroom(two), .tab(a, in: two), .tab(c, in: two), .tab(b, in: two),
        .workroom(three),
      ])

    // three by its lower half, then below the last row: at the end.
    reflow.pointer(at: y(5, 0.8), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.after, three)
    XCTAssertEqual(reflow.standalonePlace?.before, .some(nil))
    XCTAssertEqual(reflow.order.last, .tab(b, in: two))
    reflow.pointer(at: y(9), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.after, three)

    // Above the first row: the start.
    reflow.pointer(at: -4, pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.before, one)

    reflow.restore()
    XCTAssertNil(reflow.standalonePlace)
    XCTAssertNil(reflow.movedIndex)
    XCTAssertEqual(reflow.order, items)
  }

  /// Value: protects=at its own workroom's edges the gap has one rule: the workroom's row from its
  /// middle down and its tabs reorder, its row's upper half and anything outside the workroom are
  /// between workrooms; let go in its own slot without leaving it, a tab never becomes standalone;
  /// fails_when=the gap flickers between a reorder and a standalone at the block's edges, or a
  /// lifted last tab let go in place is made standalone; why_new=#819 owner report;
  /// seam=OpenRowReflow
  func testAtItsOwnWorkroomsEdgesTheGapHasOneRule() throws {
    var reflow = try XCTUnwrap(
      OpenRowReflow(items: items, dragged: .tab(c, in: two), leavesWorkroom: true))

    // c is two's last tab: over its own slot, grabbed by either half, it stays.
    for at in [y(4, 0.2), y(4, 0.9)] {
      reflow.pointer(at: at, pitch: pitch)
      XCTAssertNil(reflow.movedIndex)
      XCTAssertNil(reflow.standalonePlace, "in place at \(at)")
    }
    // Past the block's end (three's upper half): between two and three, the same slot.
    reflow.pointer(at: y(5, 0.2), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.before, three)
    XCTAssertEqual(reflow.order, items, "the same place in the list")
    // Back over its gap it stays standalone; over b's lower half it is the tabs' end again.
    reflow.pointer(at: y(4, 0.5), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.before, three)
    reflow.pointer(at: y(3, 0.7), pitch: pitch)
    XCTAssertNil(reflow.standalonePlace)
    XCTAssertNil(reflow.movedIndex, "back where it was")

    // Its own workroom's row: the upper half is above the workroom, which slides down.
    reflow.pointer(at: y(1, 0.3), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.after, one)
    XCTAssertEqual(reflow.standalonePlace?.before, two)
    XCTAssertEqual(
      reflow.order,
      [
        .workroom(one), .tab(c, in: two), .workroom(two), .tab(a, in: two), .tab(b, in: two),
        .workroom(three),
      ])
    // Down onto two's row, now a row lower, by its upper half: still above it, nothing moves.
    reflow.pointer(at: y(2, 0.3), pitch: pitch)
    XCTAssertEqual(reflow.standalonePlace?.before, two)
    // Its lower half: the start of its tabs, and two slides back up.
    reflow.pointer(at: y(2, 0.7), pitch: pitch)
    XCTAssertNil(reflow.standalonePlace)
    XCTAssertEqual(reflow.movedIndex, 0)
    XCTAssertEqual(
      reflow.order,
      [
        .workroom(one), .workroom(two), .tab(c, in: two), .tab(a, in: two), .tab(b, in: two),
        .workroom(three),
      ])
  }

  /// Value: protects=a tab that can't become a standalone terminal (refused) keeps today's gap,
  /// among its own workroom's tabs only, and another workroom row's whole height is onto it;
  /// fails_when=a refused terminal opens a gap it can't drop in; why_new=#819 owner report;
  /// seam=OpenRowReflow
  func testATabThatCantLeaveItsWorkroomStaysAmongItsTabs() throws {
    var reflow = try XCTUnwrap(OpenRowReflow(items: items, dragged: .tab(b, in: two)))
    reflow.pointer(at: y(0, 0.2), pitch: pitch)
    XCTAssertNil(reflow.standalonePlace)
    XCTAssertEqual(reflow.movedIndex, 0, "at its tabs' start")
    reflow.pointer(at: y(5, 0.2), pitch: pitch)
    XCTAssertNil(reflow.standalonePlace)
    XCTAssertEqual(reflow.movedIndex, 2, "at its tabs' end")
    XCTAssertNotNil(reflow.liftedY(for: y(0, 0.1), pitch: pitch))
  }
}
