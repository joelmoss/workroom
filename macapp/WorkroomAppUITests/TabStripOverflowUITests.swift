import XCTest

/// UI tests for the tab strips' overflow behaviour (issue #129): once the chips scroll, the "+" must
/// lift out of the scroller and pin at the trailing edge — always visible, always clickable, and never
/// abutting the per-tab toolbar. While the chips fit, it must stay inline hugging the last chip.
///
/// Driven through the real app in fixture mode (`-WorkroomUITestFixture 1`) with the overflow seams
/// added for these tests: `-WorkroomUITestTerminalTabs <n>` (terminal strip) and
/// `-WorkroomUITestWorkroomCount <n>` (title-bar workroom bar). Both seed tab *models*; only the
/// selected workroom's pane mounts a real shell, so a high chip count is cheap.
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run).
final class TabStripOverflowUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// Enough terminal tabs that the strip overflows at any sane window width (chip titles cap at 180pt,
  /// so 12 chips is ≥ 1000pt of run).
  private let overflowTabs = 12
  /// Enough workroom chips to overflow the title bar's tab area.
  private let overflowWorkrooms = 10

  private func launchedApp(terminalTabs: Int? = nil, workrooms: Int? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    if let terminalTabs {
      app.launchArguments += ["-WorkroomUITestTerminalTabs", "\(terminalTabs)"]
    }
    if let workrooms { app.launchArguments += ["-WorkroomUITestWorkroomCount", "\(workrooms)"] }
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// One strip chip per terminal. The chip's title and close button share the `terminal.tab.<title>`
  /// identifier, so match only the title StaticText to count chips 1:1 (as `SplitPaneUITests` does).
  private func terminalChips(_ app: XCUIApplication) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 10) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  // MARK: Terminal tab strip

  /// Issue #129, symptom 2: the "+" must never scroll out of view. With the strip overflowing it is
  /// pinned, so it stays on screen inside the window.
  ///
  /// Asserts geometry, not `isHittable`: XCUITest reports `isHittable == false` for this button even
  /// when clicking it demonstrably works (`testPinnedAddButtonStillAddsATab` drives the same element
  /// successfully), so that property is a false negative here and clickability is covered by the click
  /// test instead.
  func testAddTabButtonStaysVisibleWhenTabsOverflow() {
    let app = launchedApp(terminalTabs: overflowTabs)
    assertCount(terminalChips(app), reaches: overflowTabs)
    let plus = element(app, id: "NewTerminal")
    XCTAssertTrue(plus.waitForExistence(timeout: 10))
    XCTAssertFalse(plus.frame.isEmpty, "the + must have a real on-screen frame")
    XCTAssertTrue(
      app.windows.firstMatch.frame.contains(plus.frame),
      "the + scrolled out of the window — issue #129")
  }

  /// Issue #129, symptom 1: the pinned "+" sits immediately left of the per-tab toolbar with a gutter —
  /// no abutting, no overlap.
  ///
  /// The upper bound is also the witness that the strip really is in its PINNED state: an inline "+" on
  /// a row that fits would be hundreds of points from the toolbar. So if the overflow predicate never
  /// fires (e.g. the in-scroller width measurement reporting the viewport instead of the content), this
  /// fails loudly rather than silently asserting nothing.
  func testPinnedAddButtonKeepsGutterFromToolbar() {
    let app = launchedApp(terminalTabs: overflowTabs)
    let plus = element(app, id: "NewTerminal")
    let toolbar = element(app, id: "tab.toolbar.splitRight")
    XCTAssertTrue(plus.waitForExistence(timeout: 10))
    XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
    let gap = toolbar.frame.minX - plus.frame.maxX
    XCTAssertGreaterThanOrEqual(gap, 4, "the + must not abut the trailing toolbar (issue #129)")
    XCTAssertLessThanOrEqual(
      gap, 28, "the + is not pinned — is the window wide enough that \(overflowTabs) tabs fit?")
  }

  /// The pinned "+" is still functional: the trailing fade is a mask, and a mask composites away hit
  /// testing in its transparent region, so this guards that the button itself never falls into it.
  func testPinnedAddButtonStillAddsATab() {
    let app = launchedApp(terminalTabs: overflowTabs)
    assertCount(terminalChips(app), reaches: overflowTabs)
    element(app, id: "NewTerminal").click()
    assertCount(terminalChips(app), reaches: overflowTabs + 1)
  }

  /// The other half of adaptive placement: while everything fits, the "+" stays INLINE hugging the last
  /// chip (today's look) and far from the toolbar. This is the regression guard against pinning
  /// unconditionally.
  ///
  /// The hug bound is measured from the chip's **title** (`terminalChips` matches the title StaticText,
  /// which is how chips are counted 1:1), so it has to clear the chip's own trailing furniture: the
  /// close button, the chip's 4pt trailing pad, the hairline, and the row spacing — ~40pt in total. The
  /// load-bearing assertion is the second one: an inline "+" is hundreds of points from the toolbar,
  /// a pinned one is within ~28pt of it.
  func testAddButtonStaysInlineWhenTabsFit() {
    let app = launchedApp()
    let chip = terminalChips(app).firstMatch
    let plus = element(app, id: "NewTerminal")
    XCTAssertTrue(chip.waitForExistence(timeout: 10))
    XCTAssertTrue(plus.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(
      plus.frame.minX - chip.frame.maxX, 56, "the + should hug the last tab when the row fits")
    let toolbar = element(app, id: "tab.toolbar.splitRight")
    XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
    XCTAssertGreaterThan(
      toolbar.frame.minX - plus.frame.maxX, 40,
      "with one tab the + must NOT be pinned beside the toolbar")
  }

  // MARK: Workroom tab bar (title bar)

  /// The `WorkroomTabBar` half: both trailing controls pin as one block, so neither the "+" nor the
  /// open-workroom chevron can be scrolled out of reach.
  ///
  /// Geometry only, for the same reason as the terminal case: `isHittable` is a false negative for these
  /// hover-washed SwiftUI buttons. Clickability of a control inside the pinned `safeAreaInset` under the
  /// trailing mask is proven by `testPinnedAddButtonStillAddsATab`, which exercises the identical
  /// mechanism in the terminal strip.
  func testWorkroomBarControlsStayVisibleWhenChipsOverflow() {
    let app = launchedApp(workrooms: overflowWorkrooms)
    let newWorkroom = element(app, id: "NewWorkroom")
    let openWorkroom = element(app, id: "OpenWorkroom")
    XCTAssertTrue(newWorkroom.waitForExistence(timeout: 10))
    XCTAssertTrue(openWorkroom.waitForExistence(timeout: 10))
    XCTAssertFalse(newWorkroom.frame.isEmpty, "the + must have a real on-screen frame")
    XCTAssertFalse(openWorkroom.frame.isEmpty, "the chevron must have a real on-screen frame")
    let window = app.windows.firstMatch.frame
    XCTAssertTrue(window.contains(newWorkroom.frame), "the + left the window — issue #129")
    XCTAssertTrue(window.contains(openWorkroom.frame), "the chevron left the window — issue #129")
    // They move as ONE block: the chevron stays immediately left of the "+".
    XCTAssertLessThanOrEqual(
      newWorkroom.frame.minX - openWorkroom.frame.maxX, 12,
      "open + new should remain adjacent when pinned")
  }
}
