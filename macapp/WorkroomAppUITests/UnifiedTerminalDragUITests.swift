import XCTest

/// One rule set for every terminal drag (#652): any sidebar row, title-bar tab, pane tab or group
/// title bar dragged onto any other of them. A container takes the terminals at its end, a
/// terminal's place takes them there, and a pause before letting go changes nothing. Seeded by the
/// fixture's standalone terminals and two groups, never a real project or config.
final class UnifiedTerminalDragUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private let standalone = "standalone:00000000-0000-0000-0000-000000000651"
  private let ops = "group:00000000-0000-0000-0000-000000000658"
  private let dev = "group:00000000-0000-0000-0000-000000006520"

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestStandaloneTerminals", "1"]
    app.launchArguments += ["-WorkroomUITestTerminalGroup", "1"]
    app.launchArguments += ["-WorkroomUITestSecondTerminalGroup", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 8) -> Bool {
    let met = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter().wait(for: [met], timeout: timeout) == .completed
  }

  /// The selected target's pane tabs, left to right.
  private func paneTabs(_ app: XCUIApplication) -> [XCUIElement] {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format:
          "identifier BEGINSWITH 'terminal.tab.' AND NOT (identifier BEGINSWITH 'terminal.tab.splitBracket') AND NOT (identifier BEGINSWITH 'terminal.tab.waitingEdge')"
      )
    ).allElementsBoundByIndex.filter { $0.frame.width > 0 }.sorted { $0.frame.minX < $1.frame.minX }
  }

  /// The frames of the selected target's pane tabs, one per tab.
  private func paneTabCount(_ app: XCUIApplication) -> Int {
    Set(paneTabs(app).map { "\(Int($0.frame.minX))" }).count
  }

  /// Drags `from` onto `to` at normalized `(dx, dy)`, holding `hold` seconds before letting go.
  private func drag(
    _ from: XCUIElement, onto to: XCUIElement, dx: CGFloat = 0.5, dy: CGFloat = 0.5,
    hold: TimeInterval = 0
  ) {
    let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
    let end = to.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
    if hold > 0 {
      start.click(
        forDuration: 0.6, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
    } else {
      start.click(forDuration: 0.6, thenDragTo: end)
    }
  }

  /// Selects `sid`'s target by its title-bar tab, and waits for its pane tabs.
  private func select(_ app: XCUIApplication, _ sid: String, tabs: Int) {
    let tab = element(app, "workroom.tab.\(sid)")
    XCTAssertTrue(tab.waitForExistence(timeout: 15))
    tab.click()
    XCTAssertTrue(waitFor { self.paneTabCount(app) == tabs }, "\(sid) shows \(tabs) pane tabs")
  }

  /// How many terminals' rows Ops lists under its row (above Dev's, while Dev is there). The
  /// sidebar, not the strip: a hovered pane tab hides its title under its close button.
  private func opsTerminals(_ app: XCUIApplication) -> Int {
    let opsRow = element(app, "sidebar.group.\(ops)")
    let devRow = element(app, "sidebar.group.\(dev)")
    guard opsRow.exists else { return 0 }
    let top = opsRow.frame.maxY
    let bottom = devRow.exists ? devRow.frame.minY : .greatestFiniteMagnitude
    let rows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.terminal.'")
    ).allElementsBoundByIndex.filter { $0.frame.midY > top && $0.frame.midY < bottom }
    return Set(rows.map(\.identifier)).count
  }

  private func groupRows(_ app: XCUIApplication) -> Int {
    [ops, dev].filter { element(app, "sidebar.group.\($0)").exists }.count
  }

  // MARK: Sidebar rows

  private func assertStandaloneRowJoinsAGroupsTitleBarTab(hold: TimeInterval) {
    let app = launchedApp()
    let row = element(app, "sidebar.standalone.\(standalone)")
    let opsTab = element(app, "workroom.tab.\(ops)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(opsTab.waitForExistence(timeout: 5))
    select(app, ops, tabs: 2)

    drag(row, onto: opsTab, hold: hold)

    XCTAssertTrue(waitFor { !row.exists }, "the standalone row goes")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 3 }, "Ops has its terminal")
  }

  /// Value: protects=a sidebar standalone row dropped on a group's title-bar tab joins the group;
  /// fails_when=the title-bar tab isn't a destination for a sidebar drag; why_new=#652 unify;
  /// seam=the real sidebar drag; no_claim=sessions (TerminalDropTests)
  func testAStandaloneRowDroppedOnAGroupsTitleBarTabJoinsIt() {
    assertStandaloneRowJoinsAGroupsTitleBarTab(hold: 0)
  }

  /// Value: protects=the same drop with a pause before letting go, as a person makes;
  /// fails_when=a held release never reaches the drag session; why_new=#652 owner report;
  /// seam=the real sidebar drag; no_claim=sessions
  func testAStandaloneRowHeldThenDroppedOnAGroupsTitleBarTabJoinsIt() {
    assertStandaloneRowJoinsAGroupsTitleBarTab(hold: 0.8)
  }

  /// Value: protects=a standalone row held still over a group's row before letting go joins the
  /// group, as a person drops; fails_when=the held release never reaches the drag session (the
  /// #652 report); why_new=#652 owner report; seam=the real sidebar drag; no_claim=order
  func testAStandaloneRowHeldThenDroppedOnAGroupsRowJoinsIt() {
    let app = launchedApp()
    let row = element(app, "sidebar.standalone.\(standalone)")
    let opsRow = element(app, "sidebar.group.\(ops)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 2 })

    drag(row, onto: opsRow, hold: 0.8)

    XCTAssertTrue(waitFor { !row.exists }, "the standalone row goes")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 3 }, "Ops has its terminal")
  }

  private func assertGroupRowMergesIntoAnother(hold: TimeInterval) {
    let app = launchedApp()
    let opsRow = element(app, "sidebar.group.\(ops)")
    let devRow = element(app, "sidebar.group.\(dev)")
    XCTAssertTrue(opsRow.waitForExistence(timeout: 15))
    XCTAssertTrue(devRow.waitForExistence(timeout: 5))

    drag(devRow, onto: opsRow, hold: hold)

    XCTAssertTrue(waitFor { !devRow.exists }, "Dev, emptied, goes")
    XCTAssertTrue(opsRow.exists)
    XCTAssertFalse(element(app, "workroom.tab.\(dev)").exists)
  }

  /// Value: protects=a group's sidebar row dropped on another group's row merges into it;
  /// fails_when=a group row only reorders; why_new=#652 unify; seam=the real sidebar drag;
  /// no_claim=order and sessions (TerminalDropTests)
  func testAGroupRowDroppedOnAnotherGroupsRowMerges() {
    assertGroupRowMergesIntoAnother(hold: 0)
  }

  /// Value: protects=the same with a pause before letting go; fails_when=a held release never
  /// drops; why_new=#652 owner report; seam=the real sidebar drag; no_claim=order
  func testAGroupRowHeldThenDroppedOnAnotherGroupsRowMerges() {
    assertGroupRowMergesIntoAnother(hold: 0.8)
  }

  /// Value: protects=a sidebar standalone row dropped on a group's pane tab joins the group there;
  /// fails_when=pane tabs aren't destinations; why_new=#652 unify; seam=the real sidebar drag;
  /// no_claim=the exact position (TerminalDropTests)
  func testAStandaloneRowDroppedOnAPaneTabJoinsThatGroup() {
    let app = launchedApp()
    let row = element(app, "sidebar.standalone.\(standalone)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    select(app, ops, tabs: 2)
    let second = paneTabs(app)[1]

    drag(row, onto: second, dx: 0.2, hold: 1.5)

    XCTAssertTrue(waitFor { !row.exists }, "the standalone row goes")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 3 }, "Ops has its terminal")
  }

  // MARK: Tabs

  /// Value: protects=a pane tab dropped on another group's sidebar row moves into that group;
  /// fails_when=the drop is refused; why_new=#652 unify; seam=the real pane tab drag;
  /// no_claim=the position (TerminalDropTests)
  func testAPaneTabDroppedOnAGroupsRowMovesThere() {
    let app = launchedApp()
    let opsRow = element(app, "sidebar.group.\(ops)")
    XCTAssertTrue(opsRow.waitForExistence(timeout: 15))
    select(app, dev, tabs: 1)

    drag(paneTabs(app)[0], onto: opsRow, hold: 0.8)

    XCTAssertTrue(waitFor { self.groupRows(app) == 1 }, "Dev, emptied, goes")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 3 }, "Ops has its terminal")
  }

  /// Value: protects=a group's pane tab dropped on another group's title-bar tab joins it;
  /// fails_when=a title-bar tab takes no drop from a pane tab; why_new=#652 unify; seam=the real
  /// pane tab drag; no_claim=sessions (TerminalDropTests)
  func testAPaneTabDroppedOnAnotherGroupsTitleBarTabJoinsIt() {
    let app = launchedApp()
    let opsTab = element(app, "workroom.tab.\(ops)")
    XCTAssertTrue(opsTab.waitForExistence(timeout: 15))
    select(app, dev, tabs: 1)

    drag(paneTabs(app)[0], onto: opsTab, hold: 1.5)

    XCTAssertTrue(waitFor { self.groupRows(app) == 1 }, "Dev, emptied, goes")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 3 }, "Ops has its terminal")
  }

  /// Value: protects=a standalone terminal's title-bar tab dropped on a group's pane tab joins
  /// that group; fails_when=a title-bar tab dragged into the panes only splits; why_new=#652
  /// unify; seam=the real title-bar drag; no_claim=the position (TerminalDropTests)
  func testATitleBarTabDroppedOnAPaneTabJoinsThatGroup() {
    let app = launchedApp()
    let tab = element(app, "workroom.tab.\(standalone)")
    XCTAssertTrue(tab.waitForExistence(timeout: 15))
    select(app, ops, tabs: 2)

    drag(tab, onto: paneTabs(app)[1], dx: 0.8, hold: 0.8)

    XCTAssertTrue(waitFor { !tab.exists }, "the standalone tab goes")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 3 }, "Ops has its terminal")
  }

  /// Value: protects=a group's title bar dropped on another group's title-bar tab merges into it;
  /// fails_when=the title bar only splits or moves the window; why_new=#652 unify; seam=the real
  /// title bar drag; no_claim=order
  func testAGroupsTitleBarDroppedOnAnotherGroupsTabMerges() {
    let app = launchedApp()
    let opsTab = element(app, "workroom.tab.\(ops)")
    XCTAssertTrue(opsTab.waitForExistence(timeout: 15))
    select(app, dev, tabs: 1)
    let bar = element(app, "workroom.pane.titlebar")
    XCTAssertTrue(bar.waitForExistence(timeout: 5))

    drag(bar, onto: opsTab, hold: 0.8)

    XCTAssertTrue(waitFor { !self.element(app, "workroom.tab.\(self.dev)").exists }, "Dev goes")
    XCTAssertTrue(waitFor { self.groupRows(app) == 1 })
  }

  // MARK: The title bar's empty space

  /// The title bar's tabs, left to right, by identifier.
  private func titleBarTabs(_ app: XCUIApplication) -> [String] {
    var seen = Set<String>()
    return app.descendants(matching: .any).matching(
      NSPredicate(
        format:
          "identifier BEGINSWITH 'workroom.tab.' AND NOT (identifier BEGINSWITH 'workroom.tab.splitBracket')"
      )
    ).allElementsBoundByIndex.filter { $0.frame.width > 0 }
      .sorted { $0.frame.minX < $1.frame.minX }
      .map(\.identifier).filter { seen.insert($0).inserted }
  }

  /// Drags `handle`, one of Ops's two terminals, into the title bar's empty space past its last
  /// tab, and checks it becomes a standalone terminal whose tab is last.
  private func assertLetGoPastTheLastTitleBarTabBecomesStandalone(
    _ app: XCUIApplication, handle: XCUIElement
  ) {
    let before = titleBarTabs(app)
    guard let lastID = before.last else { return XCTFail("no title-bar tabs") }
    let standalones = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.standalone.'"))
    XCTAssertEqual(Set(standalones.allElementsBoundByIndex.map(\.identifier)).count, 1)

    drag(handle, onto: element(app, lastID), dx: 1.4, hold: 0.8)

    XCTAssertTrue(
      waitFor { Set(standalones.allElementsBoundByIndex.map(\.identifier)).count == 2 },
      "a new standalone terminal")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 1 }, "it left Ops")
    XCTAssertTrue(
      waitFor {
        guard let tab = self.titleBarTabs(app).last else { return false }
        return tab.hasPrefix("workroom.tab.standalone:") && !before.contains(tab)
      }, "its tab is last: \(titleBarTabs(app))")
  }

  /// Value: protects=a pane tab let go in the title bar's empty space becomes a standalone
  /// terminal, its tab there (#652 owner request); fails_when=the drop is ignored, splits, or the
  /// tab lands elsewhere; why_new=#652; seam=the real pane tab drag; no_claim=sessions
  /// (TerminalDropTests)
  func testAPaneTabLetGoInTheTitleBarsEmptySpaceBecomesStandalone() {
    let app = launchedApp()
    select(app, ops, tabs: 2)
    assertLetGoPastTheLastTitleBarTabBecomesStandalone(app, handle: paneTabs(app)[1])
  }

  /// Value: protects=a pane's own title bar let go in the title bar's empty space does the same
  /// (#652 owner request); fails_when=it pops out of a split or does nothing; why_new=#652;
  /// seam=the real pane title bar drag; no_claim=sessions (TerminalDropTests)
  func testAPaneTitleBarLetGoInTheTitleBarsEmptySpaceBecomesStandalone() {
    let app = launchedApp()
    select(app, ops, tabs: 2)
    let bar = element(app, "terminal.pane.titlebar")
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    assertLetGoPastTheLastTitleBarTabBecomesStandalone(app, handle: bar)
  }

  /// Value: protects=a solo pane's own title bar drags like its tab: let go on another group's
  /// sidebar row, its terminal moves there (#652 owner request); fails_when=the bar only drags
  /// within a split, or does nothing alone; why_new=#652; seam=the real pane title bar drag;
  /// no_claim=sessions (TerminalDropTests)
  func testAPaneTitleBarDroppedOnAnotherGroupsRowMovesItsTerminalThere() {
    let app = launchedApp()
    let devRow = element(app, "sidebar.group.\(dev)")
    XCTAssertTrue(devRow.waitForExistence(timeout: 15))
    select(app, ops, tabs: 2)
    let bar = element(app, "terminal.pane.titlebar")
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    let terminalRows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.terminal.'"))
    let devTerminals = {
      Set(
        terminalRows.allElementsBoundByIndex.filter { $0.frame.midY > devRow.frame.maxY }
          .map(\.identifier)
      ).count
    }
    XCTAssertTrue(waitFor { devTerminals() == 1 }, "Dev has one")

    drag(bar, onto: devRow, hold: 0.8)

    XCTAssertTrue(waitFor { self.opsTerminals(app) == 1 }, "it left Ops")
    XCTAssertTrue(waitFor { devTerminals() == 2 }, "and is Dev's")
  }
}
