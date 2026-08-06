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

  /// The title-bar Open / New Workroom buttons render even with NO tabs in the bar — they're the
  /// mouse route to a first workroom, so gating them on a tab already existing left a fresh window
  /// with nothing to click. Launched with the empty fixture, which has no workroom targets and so an
  /// empty chip run.
  func testTitleBarWorkroomButtonsRenderWithNoTabs() throws {
    let app = launchedApp(extraArgs: ["-WorkroomUITestNoProjects", "1"])
    XCTAssertTrue(
      app.windows.firstMatch.waitForExistence(timeout: 15),
      "a window should appear even with no projects")
    XCTAssertTrue(
      el(app, "OpenWorkroom").waitForExistence(timeout: 6),
      "the Open Workroom button should render with an empty tab bar")
    XCTAssertTrue(
      el(app, "NewWorkroom").exists,
      "…and so should the New Workroom button")
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

  // MARK: - The dialog blocks (issue: it looked modal but wasn't)

  /// Every test below pairs "the shortcut did nothing while the dialog was up" with "…and it works
  /// once the dialog closes". Without the second half they'd pass on a shortcut that was simply
  /// broken — and, worse, an assertion that only checks the dialog is *still open* passes on
  /// completely unfixed code, since nothing in `focusTerminalTab` or `newTerminalInSelectedTarget`
  /// touches `activePicker`. That was the flaw in the first draft of this test plan.

  private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// The visible terminal pane whose a11y label names `title` — the signal for "which tab is showing".
  private func pane(_ app: XCUIApplication, titled title: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(
        NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "terminal.pane", title)
      )
      .firstMatch
  }

  private func openNewWorkroomDialog(_ app: XCUIApplication) -> XCUIElement {
    newWorkroomMenuItem(app).click()
    let filter = app.textFields["newWorkroom.filter"]
    XCTAssertTrue(filter.waitForExistence(timeout: 4), "the dialog should open")
    return filter
  }

  /// Open a second terminal tab so "which tab is selected" is observable at all — with the fixture's
  /// single tab, ⌘1 is a no-op even on broken code.
  private func openSecondTerminal(_ app: XCUIApplication) {
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(
      el(app, "terminal.tab.Terminal 2").waitForExistence(timeout: 8),
      "⌘T should open a second terminal tab (baseline, no dialog up)")
    XCTAssertTrue(
      pane(app, titled: "Terminal 2").waitForExistence(timeout: 8),
      "…and it should become the visible pane")
  }

  /// ⌘T behind the dialog must not open a tab — then must open one the moment the dialog closes.
  func testNewTerminalShortcutIsInertWhileTheDialogIsUp() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    _ = openNewWorkroomDialog(app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertFalse(
      el(app, "terminal.tab.Terminal 2").waitForExistence(timeout: 3),
      "⌘T must not open a terminal tab behind the dialog")

    // The mechanism, asserted directly: a disabled menu item drops its key equivalent, which is what
    // makes the keypress above inert (and greys the item, so the user can see why).
    XCTAssertFalse(
      fileMenuItemIsEnabled(app, Self.newTerminalTitle),
      "File ▸ New Terminal should be disabled while the dialog is up")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      app.textFields["newWorkroom.filter"].waitForNonExistence(timeout: 4), "Esc closes the dialog")

    // Observe the item come back BEFORE pressing ⌘T again. `@FocusedValue` re-publication is async, so
    // a keypress fired the instant the dialog disappears can still land while the item is disabled and
    // be silently dropped — which is a race in the test, not a bug in the app.
    XCTAssertTrue(
      waitForFileMenuItemEnabled(app, Self.newTerminalTitle),
      "New Terminal should re-enable once the dialog closes")
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(
      el(app, "terminal.tab.Terminal 2").waitForExistence(timeout: 8),
      "…and ⌘T works again afterwards — so it was blocked, not broken")
  }

  /// ⌘1 behind the dialog must not switch tabs. Goes through the AppDelegate key monitor rather than
  /// a menu item, so it covers the `shortcutStore` routing rather than menu enablement.
  func testTabSwitchShortcutIsInertWhileTheDialogIsUp() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    openSecondTerminal(app)
    _ = openNewWorkroomDialog(app)

    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(
      pane(app, titled: "Terminal 2").waitForExistence(timeout: 3),
      "⌘1 must not switch tabs behind the dialog — Terminal 2 stays visible")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      app.textFields["newWorkroom.filter"].waitForNonExistence(timeout: 4), "Esc closes the dialog")
    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(
      pane(app, titled: "Terminal 1").waitForExistence(timeout: 6),
      "…and ⌘1 switches again afterwards — so it was blocked, not broken")
  }

  /// Text editing inside the filter keeps working. There is no key allowlist any more (the fix routes
  /// shortcuts instead of swallowing events), so this is the regression guard for ever reintroducing
  /// one: an allowlist is exactly what broke ⌘⌫ and non-Latin-layout ⌘V last time.
  func testTextEditingKeysStillWorkInsideTheDialog() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let filter = openNewWorkroomDialog(app)
    let row = app.descendants(matching: .any).matching(
      identifier: "newWorkroom.project.UITestProject")

    filter.click()
    filter.typeText("zzzznomatch")
    XCTAssertTrue(row.firstMatch.waitForNonExistence(timeout: 4), "baseline: the filter filters")

    // ⌘⌫ = deleteToBeginningOfLine. An allowlist-based gate missed this one entirely.
    filter.typeKey(.delete, modifierFlags: .command)
    XCTAssertTrue(
      row.firstMatch.waitForExistence(timeout: 4), "⌘⌫ should clear the filter, restoring the row")

    // ⌘A then retype replaces the selection — proves ⌘A reached the field rather than being eaten.
    filter.typeText("zzzznomatch")
    XCTAssertTrue(row.firstMatch.waitForNonExistence(timeout: 4))
    filter.typeKey("a", modifierFlags: .command)
    filter.typeText("UITest")
    XCTAssertTrue(
      row.firstMatch.waitForExistence(timeout: 4), "⌘A + retype should replace the whole query")
  }

  /// The terminal gives up keyboard focus to the dialog: typing goes into the filter field without
  /// anyone clicking it first.
  ///
  /// Asserted via where the characters LAND, not via the pane's `.isSelected` trait. That trait
  /// reflects `PaneTreeView`'s model focus (which the fix deliberately leaves alone, so the focus ring
  /// doesn't drop), not the AppKit first responder — so it stays true here and cannot answer this
  /// question. Where a keystroke goes is also the thing the user actually experiences.
  func testTypingGoesToTheDialogNotTheTerminal() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    let filter = openNewWorkroomDialog(app)
    let row = app.descendants(matching: .any).matching(
      identifier: "newWorkroom.project.UITestProject")
    XCTAssertTrue(
      row.firstMatch.waitForExistence(timeout: 4), "the project row lists to begin with")

    // Deliberately NOT clicking the field first — the dialog must already own the keyboard.
    app.typeText("zzzznomatch")
    XCTAssertTrue(
      row.firstMatch.waitForNonExistence(timeout: 4),
      "keystrokes must reach the filter field, not the terminal surface behind it")
    XCTAssertEqual(
      filter.value as? String, "zzzznomatch",
      "…and land in the field verbatim")

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      app.textFields["newWorkroom.filter"].waitForNonExistence(timeout: 4),
      "Esc closes the dialog — which also proves Esc reached it rather than the terminal")
  }

  /// The title-bar accessory is a separate window-level hosting tree the dialog's backdrop can never
  /// cover, so its buttons stay clickable unless explicitly disabled.
  func testTitleBarOpenButtonIsInertWhileTheNewDialogIsUp() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    _ = openNewWorkroomDialog(app)

    // Asserted, not `if`-guarded: a missing button would otherwise make this test pass vacuously.
    let openButton = el(app, "OpenWorkroom")
    XCTAssertTrue(
      openButton.waitForExistence(timeout: 6), "the title-bar Open Workroom button should render")
    openButton.click()
    XCTAssertFalse(
      app.textFields["openWorkroom.filter"].waitForExistence(timeout: 3),
      "the title-bar Open button must not raise the Open dialog through the New dialog")
    XCTAssertTrue(app.textFields["newWorkroom.filter"].exists, "…and the New dialog stays up")
  }

  /// The root-cause regression guard: a shortcut must never act on a workroom window that ISN'T key.
  ///
  /// Replaces the two-window case this test plan originally called for, which could not have caught
  /// the defect: `WindowRegistry.keyStore` only falls back when the key window is **unregistered**, and
  /// two workroom windows are both registered, so the fallback never fires. A foreign key window is
  /// the case that triggers it — with `keyStore`, ⌘1 pressed while Settings is frontmost resolves
  /// `store(for:) ?? lastActiveStore` and switches tabs in the workroom window behind it.
  func testShortcutDoesNotReachAWorkroomWindowThatIsNotKey() throws {
    let app = launchedApp()
    waitForLaunchWindow(app)
    openSecondTerminal(app)

    app.typeKey(",", modifierFlags: .command)  // Settings — its own window, never registered
    let settings = app.windows.matching(NSPredicate(format: "title CONTAINS %@", "Settings"))
    guard settings.firstMatch.waitForExistence(timeout: 8) else {
      throw XCTSkip("Settings window did not open; nothing to assert about a foreign key window")
    }

    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(
      pane(app, titled: "Terminal 2").waitForExistence(timeout: 3),
      "⌘1 with Settings key must NOT switch tabs in the workroom window behind it")

    app.typeKey("w", modifierFlags: .command)  // close Settings
    XCTAssertTrue(settings.firstMatch.waitForNonExistence(timeout: 6), "Settings closes with ⌘W")
    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(
      pane(app, titled: "Terminal 1").waitForExistence(timeout: 6),
      "…and ⌘1 works again once a workroom window is key — so it was routed, not broken")
  }

  /// File-menu item titles. Held as constants for the same reason `newWorkroomTitle` is: XCUITest
  /// matches menu items by exact title, so a rename otherwise makes these tests match nothing and pass
  /// vacuously.
  private static let newTerminalTitle = "New Terminal"

  /// Open the File menu, read one item's enabled state, close the menu again. Opening the menu is
  /// necessary — enablement isn't queryable on an unopened menu.
  private func fileMenuItemIsEnabled(_ app: XCUIApplication, _ title: String) -> Bool {
    let file = app.menuBars.menuBarItems["File"]
    file.click()
    let item = file.menuItems[title]
    let enabled = item.waitForExistence(timeout: 4) && item.isEnabled
    app.typeKey(.escape, modifierFlags: [])
    return enabled
  }

  /// Poll `fileMenuItemIsEnabled` until it turns true — `@FocusedValue` re-publication is async.
  private func waitForFileMenuItemEnabled(
    _ app: XCUIApplication, _ title: String, timeout: TimeInterval = 8
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if fileMenuItemIsEnabled(app, title) { return true }
    }
    return false
  }
}
