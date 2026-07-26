import XCTest

/// New Workroom dialog UI smoke (issue #81): File ▸ New Workroom (⌘N) opens the project picker,
/// which lists the fixture project and filters as you type. Driven in UI-test fixture mode
/// (`-WorkroomUITestFixture 1`), which loads exactly one project ("UITestProject") — so the menu
/// item is enabled and the list has a known row.
///
/// Scope note (no silent cap): this asserts the menu→dialog→filter path. It deliberately does NOT
/// drive the actual pick→create, because creation calls the real `workroom` CLI against the
/// fixture's temp dirs — non-hermetic and flaky in a UI test. The create+open wiring is covered by
/// `ProjectPickerModelTests` (the selection logic) plus the already-tested `AppStore.createWorkroom`.
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run), so
/// this is excluded from the `make app-test` unit gate.
final class NewWorkroomDialogUITests: XCTestCase {
  /// The File-menu item's exact title. **The ellipsis is load-bearing** — XCUITest matches menu
  /// items by exact title, so the plain "New Workroom" these tests used to query matched nothing
  /// once `8e34748a` renamed the item to "New Workroom…" (the standard macOS marker for an action
  /// that opens a dialog). All three tests here failed on it for a month. Held in one constant so a
  /// future rename is a one-line fix rather than three, and named so the reason survives.
  private static let newWorkroomTitle = "New Workroom…"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  private func launchedApp(extraArgs: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += extraArgs
    app.launch()
    return app
  }

  private func terminalPanes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  /// Wait for the fixture launch window to be fully up — its one terminal pane is in the a11y tree.
  private func waitForLaunchWindow(_ app: XCUIApplication) {
    XCTAssertTrue(
      terminalPanes(app).firstMatch.waitForExistence(timeout: 15),
      "fixture launch window (with its terminal) should appear")
  }

  private func newWorkroomMenuItem(_ app: XCUIApplication) -> XCUIElement {
    app.menuBars.menuBarItems["File"].menuItems[Self.newWorkroomTitle]
  }

  /// The File menu carries an enabled "New Workroom" item (the fixture has one project).
  func testNewWorkroomMenuItemPresentAndEnabled() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let file = app.menuBars.menuBarItems["File"]
    file.click()
    let item = file.menuItems[Self.newWorkroomTitle]
    XCTAssertTrue(item.waitForExistence(timeout: 4), "File ▸ New Workroom should exist")
    XCTAssertTrue(item.isEnabled, "New Workroom is enabled when ≥1 project exists")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// With no projects (issue #81 D3), the File ▸ New Workroom item still exists but is DISABLED —
  /// ⌘N is then a silent no-op instead of opening an empty dialog. Launched with an empty fixture.
  func testNewWorkroomMenuItemDisabledWithNoProjects() throws {
    let app = launchedApp(extraArgs: ["-WorkroomUITestNoProjects", "1"])
    XCTAssertTrue(
      app.windows.firstMatch.waitForExistence(timeout: 15),
      "a window should appear even with no projects")
    let file = app.menuBars.menuBarItems["File"]
    XCTAssertTrue(file.waitForExistence(timeout: 4), "File menu should exist")
    file.click()
    let item = file.menuItems[Self.newWorkroomTitle]
    XCTAssertTrue(item.waitForExistence(timeout: 4), "the item still exists when disabled")
    XCTAssertFalse(item.isEnabled, "New Workroom is disabled with no projects (issue #81 D3)")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Opening New Workroom shows the picker (filter field + the fixture project row); typing a
  /// non-matching query hides the row, and clearing the query brings it back.
  func testDialogOpensListsAndFiltersProjects() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    newWorkroomMenuItem(app).click()

    let filter = app.textFields["newWorkroom.filter"]
    XCTAssertTrue(filter.waitForExistence(timeout: 4), "the filter field should appear")

    let row = app.descendants(matching: .any).matching(
      identifier: "newWorkroom.project.UITestProject")
    XCTAssertTrue(
      row.firstMatch.waitForExistence(timeout: 4), "the fixture project row should list")

    // A non-matching filter removes the row.
    filter.click()
    filter.typeText("zzzznomatch")
    XCTAssertTrue(
      row.firstMatch.waitForNonExistence(timeout: 4),
      "a non-matching filter hides the project row")

    // Clearing the filter restores it.
    filter.typeKey("a", modifierFlags: .command)
    filter.typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(
      row.firstMatch.waitForExistence(timeout: 4),
      "clearing the filter restores the project row")
  }
}
