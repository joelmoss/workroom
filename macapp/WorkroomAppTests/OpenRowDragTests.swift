import AppKit
import WorkroomDomain
import XCTest

@testable import Workroom

/// An Open row's drag followed past the List's table, which takes the mouse from the row's gesture
/// after its first report (#819 review A1): the pointer read on a timer stands in for the gesture's
/// later reports and its release.
@MainActor
final class OpenRowDragTests: XCTestCase {
  private var location = CGPoint(x: 400, y: 900)
  private var isDown = true
  private var moves: [OpenRowDrag.Report] = []
  private var ends: [OpenRowDrag.Report] = []
  private let item = OpenSectionItem.workroom(.terminalGroup(UUID()))

  private func follower() -> OpenRowDrag {
    OpenRowDrag(
      mouse: .init(location: { self.location }, isDown: { self.isDown }), startsTimer: false)
  }

  private func begin(_ drag: OpenRowDrag) {
    // The gesture's first report: 6 points down the window from where it was pressed.
    drag.changed(
      item, location: CGPoint(x: 100, y: 106), startLocation: CGPoint(x: 100, y: 100),
      onMove: { self.moves.append($0) }, onEnd: { self.ends.append($0) })
  }

  /// Value: protects=the drag's moves and release reach the row though its gesture reports only
  /// the first move, each in the gesture's own space; fails_when=only the first move arrives or the
  /// drag never ends (the bug: no drop, reorder or split from an Open row); why_new=#819 A1;
  /// seam=OpenRowDrag; no_claim=the table's tracking itself (VM UI tests)
  func testThePointerStandsInForTheGesturesLaterReportsAndItsRelease() {
    let drag = follower()
    begin(drag)
    XCTAssertEqual(moves.map(\.location), [CGPoint(x: 100, y: 106)])
    XCTAssertEqual(moves.first?.translation, CGSize(width: 0, height: 6))

    // 30 points lower on screen (y up) is 30 points further down the window (y down).
    location = CGPoint(x: 410, y: 870)
    drag.poll()
    drag.poll()
    XCTAssertEqual(moves.count, 2, "a pointer that stays reports nothing more")
    XCTAssertEqual(moves.last?.location, CGPoint(x: 110, y: 136))
    XCTAssertEqual(moves.last?.translation, CGSize(width: 10, height: 36))
    XCTAssertEqual(moves.last?.screen, CGPoint(x: 410, y: 870))
    XCTAssertTrue(ends.isEmpty)

    isDown = false
    drag.poll()
    XCTAssertEqual(ends.map(\.screen), [CGPoint(x: 410, y: 870)], "let go where the button came up")
    XCTAssertFalse(drag.isFollowing(item))
  }

  /// Value: protects=a drag ends once, whichever of the gesture's own end and the pointer's button
  /// up comes first, and later gesture reports move nothing twice; fails_when=a drop is made twice
  /// or a stale gesture end drops again; why_new=#819 A1; seam=OpenRowDrag; no_claim=timing
  func testADragEndsOnceWhoeverSeesTheReleaseFirst() {
    let drag = follower()
    begin(drag)
    begin(drag)
    XCTAssertEqual(moves.count, 1, "the gesture's later reports are the pointer's to make")

    drag.ended(item)
    isDown = false
    drag.poll()
    drag.ended(item)
    XCTAssertEqual(ends.count, 1)
  }
}
