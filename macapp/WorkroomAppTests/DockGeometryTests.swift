import XCTest

@testable import Workroom

/// The screen → pane-tree coordinate conversion behind docking a detached pane (issue #172).
///
/// Pulled out and tested on its own because it crosses two origins in one step: AppKit screen space
/// is bottom-left origin, while SwiftUI `.global` — the space the pane tree's frame is measured in —
/// is top-left origin from the window's top edge, title bar included. Getting either flip wrong puts
/// every drop on the wrong pane, or silently off the tree entirely, and only a real mouse would show
/// it.
final class DockGeometryTests: XCTestCase {
  /// A 1000x800 window whose bottom-left sits at (100, 200) on screen, with the pane tree inset 60pt
  /// from the window's top (the title bar + tab strip).
  private let windowFrame = CGRect(x: 100, y: 200, width: 1000, height: 800)
  private let contentFrame = CGRect(x: 0, y: 60, width: 1000, height: 740)

  private func local(_ screen: CGPoint) -> CGPoint {
    AppStore.paneLocalPoint(
      screenPoint: screen, windowFrame: windowFrame, contentFrame: contentFrame)
  }

  /// The pane tree's own top-left corner. Screen y counts up from the bottom, so this is the window's
  /// top (200 + 800 = 1000) minus the 60pt of chrome above the tree.
  func testTheContentOriginMapsToZero() {
    XCTAssertEqual(local(CGPoint(x: 100, y: 940)), CGPoint(x: 0, y: 0))
  }

  /// Moving UP the screen must move UP the tree — i.e. toward smaller y. Reversing this is the
  /// mistake that puts a drop meant for a pane's top edge on its bottom one.
  func testScreenYIsInverted() {
    let high = local(CGPoint(x: 600, y: 900))
    let low = local(CGPoint(x: 600, y: 500))
    XCTAssertLessThan(high.y, low.y)
    XCTAssertEqual(high.y, 40)
    XCTAssertEqual(low.y, 440)
  }

  /// x is a plain translation.
  func testScreenXIsATranslation() {
    XCTAssertEqual(local(CGPoint(x: 350, y: 940)).x, 250)
  }

  /// A point above the window's top edge lands at a negative y — the same "above the panes" reading
  /// the drag fence uses, so a drop over the title bar is outside the tree rather than in it.
  func testAbovePanesIsNegative() {
    XCTAssertLessThan(local(CGPoint(x: 600, y: 980)).y, 0)
  }

  /// Round trip: the centre of the window's content maps to the centre of the tree.
  func testWindowContentCentreMapsToTreeCentre() {
    let centre = local(CGPoint(x: 600, y: 200 + 800 - 60 - 370))
    XCTAssertEqual(centre, CGPoint(x: 500, y: 370))
  }
}
