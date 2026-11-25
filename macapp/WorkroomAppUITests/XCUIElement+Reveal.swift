import XCTest

extension XCUIElement {
  /// Scroll the scroll view that holds this element until the element's centre is inside the
  /// scroll view's frame, and return whether it got there. A missing scroll view or a failed reveal
  /// fails the test here, so a caller does not click an element that is still out of view.
  ///
  /// Needed because the Changes panel shares the fixture window's height with History and Pull
  /// Request, leaving its scroll view roughly 190pt tall: the fourth file row is below the visible
  /// area. XCUITest still reports such a row as existing and hittable, and a click on it lands on
  /// whatever sits at those screen coordinates, so nothing opens and nothing says why (#269).
  @discardableResult
  func scrollIntoView(in app: XCUIApplication, maxScrolls: Int = 10) -> Bool {
    let holder = app.scrollViews.containing(.any, identifier: identifier).firstMatch
    guard holder.exists else {
      XCTFail("no scroll view holds \(identifier), so it cannot be scrolled into view")
      return false
    }
    /// How far the element's centre is outside the scroll view's frame; 0 once it is inside.
    func distance() -> CGFloat {
      let y = frame.midY
      return y < holder.frame.minY ? holder.frame.minY - y : max(0, y - holder.frame.maxY)
    }
    var delta: CGFloat = 40
    for _ in 0..<maxScrolls where distance() > 0 {
      let before = distance()
      holder.scroll(byDeltaX: 0, deltaY: delta)
      // The sign of `deltaY` is not something to guess: if that scroll moved the element away,
      // the next one goes the other way.
      if distance() >= before { delta = -delta }
    }
    let revealed = distance() == 0
    XCTAssertTrue(revealed, "could not scroll \(identifier) into view in \(maxScrolls) scrolls")
    return revealed
  }

  /// Click a sidebar row's trailing mark (its run control, its waiting hand) as a pointer reaches
  /// it: hover first, so the row's hover controls take the trailing column and the mark slides one
  /// slot left (`SidebarHoverTrailing`, 59cdd570), then click the mark where it settled. A bare
  /// `click()` jumps the pointer onto the mark at rest; the mark slides out from under it and the
  /// click lands on the row, which lists its terminals instead. The pointer goes by coordinate: an
  /// element's own `hover()` and `click()` scroll it into view first, and a row that moves lets go
  /// of its hover, so the mark slides back under the pointer.
  func clickWhereHoverSettlesIt(timeout: TimeInterval = 3) {
    // Resolved on each use, so it is wherever the element is by then.
    var center: XCUICoordinate { coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }
    let rest = frame
    center.hover()
    var last = rest
    var settled = false
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      let now = frame
      if now != rest, now == last {
        settled = true
        break
      }
      last = now
    }
    XCTAssertTrue(settled, "hovering its row never slid \(identifier) \(label) over: \(frame)")
    center.click()
  }
}
