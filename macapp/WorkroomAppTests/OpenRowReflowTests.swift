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

    // Lifting one, over two's tabs: two and its tabs are one workroom, passed at their middle.
    var first = try XCTUnwrap(OpenRowReflow(items: items, dragged: .workroom(one)))
    first.pointer(at: y(2, 0.5), pitch: pitch)
    XCTAssertNil(first.movedIndex, "in two's upper half")
    first.pointer(at: y(3, 0.5), pitch: pitch)
    XCTAssertEqual(first.movedIndex, 1, "in its lower half: after two and its tabs")
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
  }
}
