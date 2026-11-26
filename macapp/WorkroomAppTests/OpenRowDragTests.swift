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
  /// Escape pressed, until the drag reads it.
  private var escape = false
  private var moves: [OpenRowDrag.Report] = []
  private var ends: [OpenRowDrag.Report] = []
  private let item = OpenSectionItem.workroom(.terminalGroup(UUID()))

  private func follower() -> OpenRowDrag {
    OpenRowDrag(
      mouse: .init(
        location: { self.location }, isDown: { self.isDown },
        escape: {
          defer { self.escape = false }
          return self.escape
        }), startsTimer: false)
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

  /// The gesture's first report as the press makes it: where the row was pressed.
  private func press(_ drag: OpenRowDrag) {
    drag.changed(
      item, location: CGPoint(x: 100, y: 100), startLocation: CGPoint(x: 100, y: 100),
      onMove: { self.moves.append($0) }, onEnd: { self.ends.append($0) })
  }

  /// Value: protects=a drag armed by the press alone follows the pointer once it travels the
  /// threshold, though the row's gesture reports nothing after the press; fails_when=a drag the
  /// table takes before the gesture's first move never starts (#819: a straight, quick drag of a
  /// standalone row reordered nothing in the VM); why_new=#819 final; seam=OpenRowDrag;
  /// no_claim=the table's tracking itself (VM UI tests)
  func testAPressArmsTheDragAndItsMovesBeginPastTheThreshold() {
    let drag = follower()
    press(drag)
    XCTAssertTrue(moves.isEmpty, "a press is no move yet")

    location = CGPoint(x: 400, y: 897)
    drag.poll()
    XCTAssertTrue(moves.isEmpty, "3 points is a click's wobble, not a drag")

    location = CGPoint(x: 400, y: 880)
    drag.poll()
    XCTAssertEqual(moves.map(\.translation), [CGSize(width: 0, height: 20)])

    // Let go further on than the last read: the release's own place is the last move.
    location = CGPoint(x: 400, y: 850)
    isDown = false
    drag.poll()
    XCTAssertEqual(moves.last?.translation, CGSize(width: 0, height: 50))
    XCTAssertEqual(ends.map(\.translation), [CGSize(width: 0, height: 50)])
  }

  /// Value: protects=a click on an Open row, now that every press arms a drag, makes no drag: no
  /// move and no end, so no session, ghost or drop; fails_when=a click reorders, drops or shows a
  /// ghost; why_new=#819 final; seam=OpenRowDrag; no_claim=the tap's own selection
  func testAPressLetGoWithoutTravelMakesNoDrag() {
    let drag = follower()
    press(drag)
    location = CGPoint(x: 402, y: 899)
    drag.poll()
    isDown = false
    drag.poll()
    drag.ended(item)
    XCTAssertTrue(moves.isEmpty)
    XCTAssertTrue(ends.isEmpty)
    XCTAssertFalse(drag.isFollowing(item))
  }

  /// Value: protects=a press let go past the threshold is a drag though no read of the pointer saw
  /// it travel, so a quick drag still drops or reorders where it was let go; fails_when=a drag whose
  /// move and release fall between two reads is taken for a click and drops nothing (#819: a
  /// standalone row dragged 24 points onto another's middle in the VM never grouped them);
  /// why_new=#819 diag; seam=OpenRowDrag; no_claim=the timer's own cadence
  func testAPressLetGoPastTheThresholdBeforeAnyReadIsADrag() {
    let drag = follower()
    press(drag)
    drag.poll()

    location = CGPoint(x: 400, y: 924)
    isDown = false
    drag.poll()
    XCTAssertEqual(
      moves.map(\.translation), [CGSize(width: 0, height: -24)], "one move, at the release")
    XCTAssertEqual(ends.map(\.translation), [CGSize(width: 0, height: -24)])
    XCTAssertFalse(drag.isFollowing(item))
  }

  /// Value: protects=a drag makes one drop: the row's gesture's report that comes in late, once the
  /// table hands the mouse back after the release, arms no second drag; fails_when=the late report
  /// starts a drag that its own gesture end then drops or reorders again (#819 diag: every VM drag
  /// of an Open row ended twice); why_new=#819 diag; seam=OpenRowDrag; no_claim=SwiftUI's delivery
  func testAGesturesReportAfterTheReleaseArmsNoSecondDrag() {
    let drag = follower()
    press(drag)
    location = CGPoint(x: 400, y: 940)
    drag.poll()
    isDown = false
    drag.poll()
    XCTAssertEqual(ends.count, 1)

    // The gesture's queued report of the drag, then its end, both after the button came up.
    drag.changed(
      item, location: CGPoint(x: 100, y: 60), startLocation: CGPoint(x: 100, y: 100),
      onMove: { self.moves.append($0) }, onEnd: { self.ends.append($0) })
    drag.ended(item)
    XCTAssertEqual(moves.count, 1, "no move from the late report")
    XCTAssertEqual(ends.count, 1, "and no second end")
    XCTAssertFalse(drag.isFollowing(item))
  }

  /// Value: protects=Escape during a drag cancels it once, and the moves and release after it
  /// drop nothing; fails_when=the release after Escape still drops or reorders;
  /// seam=OpenRowDrag; no_claim=reading the key from the queue
  func testEscapeCancelsTheDragAndItsReleaseDropsNothing() {
    let drag = follower()
    var cancels = 0
    drag.changed(
      item, location: CGPoint(x: 100, y: 100), startLocation: CGPoint(x: 100, y: 100),
      onMove: { self.moves.append($0) }, onEnd: { self.ends.append($0) },
      onCancel: { cancels += 1 })
    location = CGPoint(x: 400, y: 880)
    drag.poll()
    XCTAssertEqual(moves.count, 1)

    escape = true
    drag.poll()
    XCTAssertEqual(cancels, 1)
    location = CGPoint(x: 400, y: 850)
    drag.poll()
    XCTAssertTrue(drag.isFollowing(item), "followed to the release, so its reports arm nothing")
    isDown = false
    drag.poll()
    drag.ended(item)
    XCTAssertEqual(moves.count, 1, "no move after Escape")
    XCTAssertTrue(ends.isEmpty, "and no drop")
    XCTAssertEqual(cancels, 1)
    XCTAssertFalse(drag.isFollowing(item))
  }
}
