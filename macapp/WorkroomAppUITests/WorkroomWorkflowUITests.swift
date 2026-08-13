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
final class WorkroomWorkflowUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// Launch with the deterministic UI-test fixture (fake projects, auto-selected workroom). Fixture
  /// mode also suppresses the close/quit confirmations in-app, so ⌘W closes synchronously and teardown
  /// never blocks. Pass `fixture: false` to exercise the real bootstrap path (no fake projects).
  private func launchedApp(fixture: Bool = true, extraArgs: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    if fixture { app.launchArguments += ["-WorkroomUITestFixture", "1"] }
    // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += extraArgs
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

    // Assert run-state via the run buttons, and drive Run via the always-hittable menu item. Since
    // issue #139 those buttons live in the workroom PANE's title bar rather than the window title bar,
    // one set per visible workroom — so these unscoped lookups hold only because this fixture shows a
    // single workroom. A future split fixture here would need scoping to a `workroom.pane` element (see
    // `WorkroomPaneHeaderUITests`), or `XCTAssertFalse(run.exists)` below would match the other member.
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

  /// Wait for an element's accessibility label to settle on `label` (the bell's label carries the live
  /// unread total, so opening a notification drops the count it reports).
  private func assertLabel(
    _ element: XCUIElement, equals label: String, timeout: TimeInterval = 4
  ) {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", label), object: element)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "element label did not reach \"\(label)\" within \(timeout)s")
  }

  /// The trailing title-bar controls (notifications bell + inspector toggle) live in an
  /// `NSTitlebarAccessoryViewController` bar, not `.toolbar` — `.primaryAction` is column-scoped in a
  /// NavigationSplitView, so they couldn't both sit at the window's trailing edge as toolbar items.
  /// The notifications bell lives at the bottom of the activity bar (issue #118 → moved off the title
  /// bar). A plain click opens the all-notifications popover WITHOUT dismissing anything; ⇧⌘N (the
  /// "walk the backlog" path a ⌘-click on the bell also drives) opens the oldest and drops the unread
  /// total.
  func testNotificationsBellOpensPopoverAndWalksBacklog() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let bell = app.buttons["activityBar.notifications"]
    XCTAssertTrue(
      bell.waitForExistence(timeout: 10), "the notifications bell should be in the activity bar")

    // The fixture seeds a backlog (5 entries totalling 7 unread; the oldest is a ×3 coalesced
    // "Tests passed"). A plain bell click opens the all-notifications popover and does NOT dismiss
    // anything — the unread total stays 7.
    XCTAssertTrue(bell.isEnabled, "the bell is enabled while notifications are pending")
    assertLabel(bell, equals: "Notifications, 7 unread")
    bell.click()
    let popover = app.popovers.firstMatch
    XCTAssertTrue(
      popover.waitForExistence(timeout: 4), "a bell click opens the notifications popover")
    assertLabel(bell, equals: "Notifications, 7 unread")
    app.typeKey(.escape, modifierFlags: [])  // dismiss the transient popover before the next step

    // ⇧⌘N (Next Notification) opens the oldest pending notification's terminal and dismisses it — the
    // same `openOldestNotification` path a ⌘-click on the bell drives. The oldest is the ×3 "Tests
    // passed", so the unread total the bell reports drops from 7 to 4.
    app.typeKey("n", modifierFlags: [.command, .shift])
    assertLabel(bell, equals: "Notifications, 4 unread")
  }

  /// The left-sidebar notification band (issue #118): the fixture's 5-entry backlog surfaces the
  /// oldest entry as a strip at the bottom of the sidebar with a `+4` badge for the rest; clicking the
  /// badge opens a popover listing those others.
  func testSidebarNotificationStripAndPlusPopover() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    // The oldest seeded entry ("Tests passed", ×3) surfaces as a row at the sidebar bottom with a +N
    // badge for the rest (five seeded ⇒ "+4").
    let plus = app.buttons["sidebar.notifications.plus"]
    XCTAssertTrue(
      plus.waitForExistence(timeout: 10),
      "the oldest notification should surface as a strip with a +N badge for the rest")
    assertLabel(plus, equals: "4 more notifications")

    // Clicking the badge opens the popover of the other notifications.
    plus.click()
    let popover = app.descendants(matching: .any)
      .matching(identifier: "notifications.popover").firstMatch
    XCTAssertTrue(
      popover.waitForExistence(timeout: 4),
      "clicking the +N badge opens the extra-notifications popover")
  }

  /// The workroom tab-bar chips (title bar), for tests exercising more than one workroom.
  private func workroomChips(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'workroom.tab.'"))
  }

  /// A REAL OSC 9 notification (not the fixture's seeded backlog) must reach the same notification
  /// spine the bell already reads: the badge must appear, and clicking its row in the bell popover
  /// must navigate to (and dismiss on) the terminal that raised it. The two-workroom fixture
  /// (`-WorkroomUITestTwoTabs`) supplies a second, off-screen target to raise it from and navigate
  /// back to — `handleActivity`'s `selected + cursor → SEEN: suppress` rule means firing it while
  /// its OWN workroom is focused would drop it, exactly as looking straight at a terminal suppresses
  /// its own notification, so the command sleeps 1s and this switches away before it fires.
  func testLiveNotificationBadgeAppearsAndClickNavigatesToTheRightTerminal() throws {
    let app = launchedApp(extraArgs: ["-WorkroomUITestTwoTabs", "1"])
    let chips = workroomChips(app)
    assertCount(chips, reaches: 2)

    let a = chips.element(boundBy: 0)
    let b = chips.element(boundBy: 1)
    XCTAssertNotEqual(
      a.isSelected, b.isSelected, "exactly one workroom should be selected on launch")
    let (focused, background) = a.isSelected ? (a, b) : (b, a)

    background.click()
    XCTAssertTrue(background.isSelected, "clicking a chip should select its workroom")
    app.typeText("sleep 1; printf '\\e]9;Live OSC Ping\\a'\r")
    focused.click()  // switch away before the OSC fires — the notification must survive off-screen
    XCTAssertTrue(focused.isSelected)

    let bell = app.buttons["activityBar.notifications"]
    XCTAssertTrue(bell.waitForExistence(timeout: 10))
    bell.click()
    var popover = app.popovers.firstMatch
    XCTAssertTrue(popover.waitForExistence(timeout: 4), "the bell should open its popover")
    let row = popover.buttons.matching(NSPredicate(format: "label CONTAINS 'Live OSC Ping'"))
      .firstMatch
    XCTAssertTrue(
      row.waitForExistence(timeout: 8),
      "a live OSC 9 notification raised off-screen should reach the bell's popover")

    row.click()
    XCTAssertTrue(
      background.isSelected,
      "clicking the notification should navigate to the workroom it came from")
    XCTAssertFalse(focused.isSelected)

    // Opening it dismisses it (`AppStore.openTerminal`'s `notifications.dismiss(notifID:)`) — it must
    // not still be in the backlog. Re-open the popover (clicking a row closes it) to check.
    bell.click()
    popover = app.popovers.firstMatch
    XCTAssertTrue(popover.waitForExistence(timeout: 4))
    XCTAssertFalse(
      popover.buttons.matching(NSPredicate(format: "label CONTAINS 'Live OSC Ping'")).firstMatch
        .exists,
      "opening the notification should have dismissed it")
  }

  // "Deleting a workroom withdraws its notifications" is covered by
  // `AppStoreDeleteRaceTests.testDeletingAWorkroomWithdrawsItsNotifications` (a unit test, not
  // here): fixture-mode workrooms are never registered with the real CLI, so `deleteWorkroom`'s
  // teardown always fails in THIS harness (see `UITestFixture`'s doc + `testFailedTeardownRestoresWorkroom`),
  // and a failed teardown legitimately restores the workroom and its notifications — there is no
  // stable "withdrawn" state to assert here, only a transient one racing a real CLI round trip.
  // `DeleteRaceFakeCLI` gives the succeeding-teardown case a fast, deterministic answer instead.
}
