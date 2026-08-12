import XCTest

/// Multi-window UI tests (issue #70): File ▸ New Window opens a second, independent window that
/// starts blank (no open workroom/terminal), and closing it leaves the app — and the first window —
/// alive. Driven through the accessibility tree in UI-test fixture mode (`-WorkroomUITestFixture 1`),
/// where the launch window auto-selects the fixture workroom (so it has one terminal) and a ⌘N window
/// does not (it starts blank), mirroring production.
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run), so
/// these are excluded from the `make app-test` unit gate. Window counts come and go transiently as
/// windows appear/close, so the assertions wait for the launch window to settle and then check
/// deltas, never absolute counts.
final class NewWindowUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    // Ignore any persisted window state so each test starts with exactly one window, regardless of
    // what a prior run left behind.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  /// Terminal panes across the whole app (every window). The fixture launch window has exactly one;
  /// a blank ⌘N window adds none.
  private func terminalPanes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func newWindowMenuItem(_ app: XCUIApplication) -> XCUIElement {
    app.menuBars.menuBarItems["File"].menuItems["New Window"]
  }

  /// Wait for the fixture launch window to be fully up — its one terminal pane is in the a11y tree.
  private func waitForLaunchWindow(_ app: XCUIApplication) {
    XCTAssertTrue(
      terminalPanes(app).firstMatch.waitForExistence(timeout: 15),
      "fixture launch window (with its terminal) should appear")
  }

  /// Poll `app.windows.count` until it reaches `target` (windows settle asynchronously).
  private func waitForWindowCount(_ app: XCUIApplication, _ target: Int, timeout: TimeInterval = 6)
    -> Bool
  {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", target), object: app.windows)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  /// New Window opens a second window, and it's BLANK: the app-wide terminal-pane count stays at the
  /// launch window's one — the new window has no open workroom or terminal (issue #70).
  func testNewWindowOpensBlankSecondWindow() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let windowsBefore = app.windows.count
    let panesBefore = terminalPanes(app).count

    newWindowMenuItem(app).click()

    XCTAssertTrue(
      waitForWindowCount(app, windowsBefore + 1),
      "New Window should add exactly one window (had \(windowsBefore))")
    // Let the new window's bootstrap run, then confirm it added no terminal — it's blank.
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertEqual(
      terminalPanes(app).count, panesBefore,
      "the new window is blank — it adds no terminal, so the app-wide pane count is unchanged")
  }

  /// A new window opens at the same size as the existing window, not the minimum (issue #70). The
  /// launch window opens larger than the 900 minimum (it restores its saved frame, else a default),
  /// so a "new window opens at the minimum" bug would make the two windows differ and fail; the fix
  /// makes every window match the existing one.
  func testNewWindowMatchesExistingWindowSize() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let windowsBefore = app.windows.count
    let existing = app.windows.firstMatch.frame.size
    XCTAssertGreaterThan(
      existing.width, 900, "the launch window opens larger than the bare minimum")

    newWindowMenuItem(app).click()
    XCTAssertTrue(waitForWindowCount(app, windowsBefore + 1), "second window opened")
    Thread.sleep(forTimeInterval: 1.0)  // let sizing settle

    // Assert WIDTH only: it cleanly reflects "opens small" (a min-sized new window is 900 wide vs the
    // existing window's larger width). Height is excluded because XCUITest reports a content window's
    // frame ~one titlebar shorter than a blank window's, which is a measurement artifact, not a real
    // difference (verified equal via NSWindow frames live).
    for i in 0..<app.windows.count {
      let width = app.windows.element(boundBy: i).frame.size.width
      XCTAssertEqual(
        width, existing.width, accuracy: 2,
        "every window matches the existing window's width (window \(i) was \(width))")
    }
  }

  // Closing a window cleanly (no live run command) and the confirm-then-stop path are covered by the
  // close-guard unit test (`MultiWindowTests.testCloseGuardAllowsCloseWithoutRunCommand`) plus manual
  // verification — ⌘W's window-vs-tab routing is too key-window-timing sensitive to assert reliably
  // through XCUITest.
}
