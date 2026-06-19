import XCTest

/// App-shell workflow UI tests (XCUITest). These drive Workroom through the accessibility tree —
/// sidebar, tabs, menus, badges. They do NOT assert on terminal *content*: the libghostty surface
/// is Metal-rendered and its text isn't in the a11y tree until CMT-3 lands (then content-level
/// assertions become possible — see TODOS.md).
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run,
/// so these are intentionally excluded from `make app-test` (the unit gate) via a separate scheme.
///
/// Workflow tests that need a project/workroom launch in **UI-test fixture mode**
/// (`-WorkroomUITestFixture 1`, see `UITestFixture`): the app loads fake projects/workrooms rooted at
/// a temp directory instead of the developer's real `~/.config/workroom`, and auto-selects the
/// fixture workroom — so they're deterministic and never depend on local config. The chrome smoke
/// test deliberately launches *without* the fixture, to prove the real bootstrap path renders chrome.
///
/// Still to add: notification badge + click-to-navigate (type `printf '\e]9;…\a'` → assert
/// sidebar/tab badge → click → navigates) and delete-workroom-clears-badges.
final class WorkroomWorkflowUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// Launch with the deterministic UI-test fixture (fake projects, auto-selected workroom). Fixture
  /// mode also suppresses the close/quit confirmations in-app, so ⌘W closes synchronously and teardown
  /// never blocks. Pass `fixture: false` to exercise the real bootstrap path (no fake projects).
  private func launchedApp(fixture: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    if fixture { app.launchArguments += ["-WorkroomUITestFixture", "1"] }
    app.launch()
    return app
  }

  private func assertCount(
    _ query: XCUIElementQuery, reaches expected: Int, timeout: TimeInterval = 4
  ) {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", expected), object: query)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "element count did not reach \(expected) within \(timeout)s")
  }

  /// Wait for an element's accessibility value to settle on `value` (the inspector toggle reports
  /// "shown"/"hidden", so this asserts the control reflects the open state).
  private func assertValue(
    _ element: XCUIElement, equals value: String, timeout: TimeInterval = 4
  ) {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", value), object: element)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "element value did not reach \"\(value)\" within \(timeout)s")
  }

  /// Wait for an element to stop existing (re-snapshotting via a predicate, so it tolerates the
  /// inspector's dismiss animation).
  private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  /// Regression: expanding/collapsing a project must commit on the click itself, not only after the
  /// pointer leaves the row. The collapse state lived in a `@Default`, which didn't re-evaluate the
  /// sidebar until some other state changed (e.g. `hovered` on mouse-move) — so the tree appeared to
  /// "stick" until you moved the mouse. Moving it to the store's `@Published` fixed it. This test
  /// keeps the cursor parked on the project row across the toggle (never moving it) and asserts the
  /// child rows appear/disappear anyway.
  func testExpandCollapseCommitsWithoutMouseMove() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let project = app.descendants(matching: .any)
      .matching(identifier: "sidebar.project.UITestProject").firstMatch
    let workroom = app.descendants(matching: .any)
      .matching(identifier: "sidebar.workroom.uitest-room").firstMatch
    XCTAssertTrue(workroom.waitForExistence(timeout: 10), "fixture project starts expanded")

    // Wait for an existence state by re-snapshotting (which never moves the cursor), so the assertion
    // tolerates the reveal animation while still failing if the change waits for a pointer move.
    func waitExists(_ want: Bool) -> Bool {
      let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
      return XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: p, object: workroom)], timeout: 3) == .completed
    }

    // Collapse: clicking parks the cursor on the row and leaves it there. The child must vanish
    // without any further pointer movement.
    project.click()
    XCTAssertTrue(
      waitExists(false),
      "collapse should commit on click, not wait for the pointer to leave the row")

    // Expand: same — the child must reappear with the cursor still parked on the row.
    project.click()
    XCTAssertTrue(
      waitExists(true),
      "expand should commit on click, not wait for the pointer to leave the row")
  }

  /// Deterministic smoke: the *real* bootstrap path (no fixture) launches and the shell chrome is
  /// present. The Add Project control lives in the sidebar's bottom bar regardless of config, so this
  /// has no dependency on the developer's projects.
  func testAppLaunchesWithChrome() {
    let app = launchedApp(fixture: false)
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app did not reach foreground")
    XCTAssertGreaterThan(app.windows.count, 0, "expected a main window")
    XCTAssertTrue(
      app.descendants(matching: .any)["AddProject"].waitForExistence(timeout: 5),
      "the Add Project control should always be present in the sidebar")
  }

  /// The fixture workroom is auto-selected on launch, so a terminal tab is already open; ⌘T / ⌘W add
  /// and close tabs. Deterministic via the fixture — no sidebar navigation, no skip.
  func testAddAndCloseTerminalTabs() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    // Count title StaticTexts only — a chip's title and its close button both carry the
    // `terminal.tab.<title>` identifier, so matching `.any` would double-count each tab.
    let tabs = app.staticTexts.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
    XCTAssertTrue(
      tabs.firstMatch.waitForExistence(timeout: 10),
      "the fixture workroom should open a terminal tab on launch")
    let initial = tabs.count

    app.typeKey("t", modifierFlags: .command)  // ⌘T → New Terminal
    assertCount(tabs, reaches: initial + 1)

    app.typeKey("w", modifierFlags: .command)  // ⌘W → Close Terminal
    assertCount(tabs, reaches: initial)
  }

  /// Run command lifecycle (issue #7): the fixture seeds a run command on its project, so the
  /// toolbar shows Run for the auto-selected workroom. Triggering Run launches the command in a real
  /// surface and the toolbar flips to Stop + Restart — proving end-to-end that libghostty's
  /// `config.command` parses the shell-wrapped command and that run-state lights up through a live
  /// surface (something the unit tests can't reach).
  ///
  /// The Stop→revert half is intentionally NOT asserted here: the Stop menu item is gated by a
  /// `@FocusedValue`, and clicking it once the menu is open is flaky under XCUITest's automation
  /// (focused-value timing) — a harness limitation, not a product bug. That path is covered
  /// deterministically by `RunCommandTests.testChildExitFlipsToStoppedButKeepsPane` and was verified
  /// live (the toolbar reverts and the pane stays open after Stop). Likewise the sidebar run dot is
  /// the same state in a selectable List row (flattened a11y), verified visually not here.
  func testRunCommandLifecycle() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    // Assert run-state via the toolbar buttons (existence is reliable even if a narrow window
    // collapses them into the toolbar overflow); drive Run via the always-hittable menu item.
    let run = app.buttons["runCommand.run"]
    let stop = app.buttons["runCommand.stop"]
    let restart = app.buttons["runCommand.restart"]

    XCTAssertTrue(
      run.waitForExistence(timeout: 10),
      "Run should show for a workroom whose project has a run command")
    XCTAssertFalse(stop.exists, "nothing running yet")

    // Scope to the Run menu's Run item (not a bare menuItems["Run"], which would also match other
    // "Run"-titled items) so this unambiguously starts the command.
    app.menuBars.menuBarItems["Run"].menuItems["Run"].click()

    XCTAssertTrue(stop.waitForExistence(timeout: 8), "Run should become Stop once the command runs")
    XCTAssertTrue(restart.exists, "Restart should appear alongside Stop")
    XCTAssertFalse(run.exists, "Run should be replaced while running")
  }

  /// The trailing title-bar controls (notifications bell + inspector toggle) live in an
  /// `NSTitlebarAccessoryViewController` bar, not `.toolbar` — `.primaryAction` is column-scoped in a
  /// NavigationSplitView, so they couldn't both sit at the window's trailing edge as toolbar items.
  /// This asserts both controls exist, the toggle reflects open/closed via its accessibility value,
  /// and that the bell drives the *same* inspector the toggle does (clicking the bell closes what the
  /// toggle opened — proving they're one control surface, not two independent ones).
  func testTitlebarControlsToggleInspector() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let bell = app.buttons["titlebar.notifications"]
    let toggle = app.buttons["titlebar.toggleInspector"]
    XCTAssertTrue(
      bell.waitForExistence(timeout: 10), "the notifications bell should be in the title bar")
    XCTAssertTrue(
      toggle.waitForExistence(timeout: 10), "the inspector toggle should be in the title bar")

    // The inspector starts closed (showNotifications defaults to false), so its first section header
    // isn't in the tree and the toggle reports "hidden".
    let changes = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Changes section")).firstMatch
    XCTAssertFalse(changes.exists, "the inspector should start closed")
    assertValue(toggle, equals: "hidden")

    // The toggle opens the inspector and flips to "shown".
    toggle.click()
    XCTAssertTrue(changes.waitForExistence(timeout: 5), "the toggle should open the inspector")
    assertValue(toggle, equals: "shown")

    // The bell drives the same inspector: clicking it closes what the toggle opened.
    bell.click()
    XCTAssertTrue(
      waitForDisappearance(changes),
      "the bell should close the same inspector the toggle opened")
    assertValue(toggle, equals: "hidden")
  }
}
