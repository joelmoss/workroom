import XCTest

/// UI tests for the workroom tab bar's drag behaviour (issue #23). The chips live in the custom
/// title bar, drawn in the window's full-size content — a region where AppKit otherwise turns a
/// click-drag into a *window move*, stealing the chip's own reorder `DragGesture`. The reported bug:
/// "cannot drag any workroom tabs, the whole window is dragged". These tests drive a real drag
/// through XCUITest (synthetic HID events, so AppKit's window-drag actually responds) and assert the
/// window does NOT move — and, with two chips, that the drag reorders them.
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run).
final class WindowDragUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(extraArgs: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += extraArgs
    app.launch()
    app.activate()
    return app
  }

  /// Every workroom tab chip carries a `workroom.tab.<target.id>` identifier.
  private func workroomChips(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'workroom.tab.'"))
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 10) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "workroom chip count did not reach \(n) within \(timeout)s")
  }

  /// The chips sorted left→right by their on-screen x position, paired with their identifiers.
  private func chipsByX(_ app: XCUIApplication) -> [(id: String, minX: CGFloat)] {
    let chips = workroomChips(app)
    return (0..<chips.count)
      .map { i -> (id: String, minX: CGFloat) in
        let e = chips.element(boundBy: i)
        return (e.identifier, e.frame.minX)
      }
      .sorted { $0.minX < $1.minX }
  }

  /// `chipsByX`, but polled until the left-to-right ID order stops changing between two reads. The
  /// reorder commits synchronously on drop, but `WorkroomTabBar.commitDrag` animates each chip's own
  /// `.offset` into its new slot over 0.2s — so a same-instant read after the drag gesture returns can
  /// still see the OLD on-screen positions (a genuine flake, reproduced back-to-back: the gesture
  /// itself lands the right translation every time, but the settle race is timing-dependent).
  private func chipsByXSettled(_ app: XCUIApplication, timeout: TimeInterval = 3)
    -> [(id: String, minX: CGFloat)]
  {
    let deadline = Date().addingTimeInterval(timeout)
    var previous = chipsByX(app)
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      let current = chipsByX(app)
      if current.map(\.id) == previous.map(\.id) { return current }
      previous = current
    }
    return previous
  }

  /// The other half of the contract: dragging an *empty* part of the title bar still MOVES the window
  /// (`WindowDragBackground` re-enables movement for its explicit `performDrag`). Uses the thin strip
  /// just above the chips, clear of every control.
  func testDraggingEmptyTitlebarMovesWindow() {
    let app = launchedApp()
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    // Wait for the bar to be live (a chip exists) before grabbing the empty strip beside it.
    XCTAssertTrue(workroomChips(app).firstMatch.waitForExistence(timeout: 10))
    let before = window.frame

    // ~3pt below the window's top edge (above the chips, which start ~5pt down), mid-width — the
    // draggable bar background, not a chip or control.
    let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0))
      .withOffset(CGVector(dx: 0, dy: 3))
    start.press(forDuration: 0.25, thenDragTo: start.withOffset(CGVector(dx: 120, dy: 0)))

    let after = window.frame
    XCTAssertEqual(
      Double(after.origin.x), Double(before.origin.x) + 120, accuracy: 12,
      "dragging the empty title bar should move the window")
  }

  /// The core regression: dragging a single workroom tab chip horizontally must NOT move the window.
  func testDraggingWorkroomTabDoesNotMoveWindow() {
    let app = launchedApp()
    let chip = workroomChips(app).firstMatch
    XCTAssertTrue(
      chip.waitForExistence(timeout: 10),
      "the fixture workroom should show a tab chip in the title bar")
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))
    let before = window.frame

    // A clearly-past-threshold horizontal drag (the reorder gesture's minimumDistance is 6pt).
    let start = chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(forDuration: 0.25, thenDragTo: start.withOffset(CGVector(dx: 140, dy: 0)))

    let after = window.frame
    XCTAssertEqual(
      Double(after.origin.x), Double(before.origin.x), accuracy: 5,
      "dragging a workroom tab moved the window horizontally — it dragged the window, not the tab")
    XCTAssertEqual(
      Double(after.origin.y), Double(before.origin.y), accuracy: 5,
      "dragging a workroom tab moved the window vertically — it dragged the window, not the tab")
  }

  /// With two chips, dragging the leading chip past the trailing one swaps their order — proving the
  /// chip's reorder gesture wins over the title bar's window-drag.
  func testDraggingWorkroomTabReordersTwoChips() {
    let app = launchedApp(extraArgs: ["-WorkroomUITestTwoTabs", "1"])
    assertCount(workroomChips(app), reaches: 2)

    let before = chipsByX(app)
    let leadingID = before[0].id
    let dx = (before[1].minX - before[0].minX) + 40  // past the trailing chip's slot

    let window = app.windows.firstMatch
    let windowBefore = window.frame

    let leading = workroomChips(app)
      .matching(NSPredicate(format: "identifier == %@", leadingID)).firstMatch
    let start = leading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    // A slow, native MOUSE drag (`click…`, not the touch-oriented `press…`) with a hold at the end:
    // SwiftUI's reorder `DragGesture` needs the interpolated `onChanged` events and a settle before
    // release so `onEnded` commits, and `press(forDuration:thenDragTo:)`'s touch-event synthesis was a
    // measured, reproduced flake here (back-to-back reruns of the identical test disagreed) — the
    // native mouse-event path this app actually receives from is the more faithful simulation.
    start.click(
      forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
      withVelocity: .slow, thenHoldForDuration: 0.5)

    let after = chipsByXSettled(app)
    XCTAssertEqual(
      after.last?.id, leadingID,
      "the dragged chip should have moved to the trailing position — the reorder did not happen")
    XCTAssertEqual(
      Double(window.frame.origin.x), Double(windowBefore.origin.x), accuracy: 5,
      "reordering chips must not move the window")
  }
}
