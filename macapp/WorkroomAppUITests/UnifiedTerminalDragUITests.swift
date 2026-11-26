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

  /// How many tab rows Ops lists under its Open row, unfolding it first (`openTabRows(of:)`). The
  /// sidebar, not the strip: a hovered pane tab hides its title under its close button.
  private func opsTerminals(_ app: XCUIApplication) -> Int { app.openTabRows(of: ops) }

  private func groupRows(_ app: XCUIApplication) -> Int {
    [ops, dev].filter { element(app, "sidebar.open.workroom.\($0)").exists }.count
  }

  // MARK: Sidebar rows

  private func assertStandaloneRowJoinsAGroupsTitleBarTab(hold: TimeInterval) {
    let app = launchedApp()
    let row = element(app, "sidebar.open.workroom.\(standalone)")
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
    let row = element(app, "sidebar.open.workroom.\(standalone)")
    let opsRow = element(app, "sidebar.open.workroom.\(ops)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 2 })

    drag(row, onto: opsRow, hold: 0.8)

    XCTAssertTrue(waitFor { !row.exists }, "the standalone row goes")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 3 }, "Ops has its terminal")
  }

  private func assertGroupRowMergesIntoAnother(hold: TimeInterval) {
    let app = launchedApp()
    let opsRow = element(app, "sidebar.open.workroom.\(ops)")
    let devRow = element(app, "sidebar.open.workroom.\(dev)")
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
    let row = element(app, "sidebar.open.workroom.\(standalone)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    select(app, ops, tabs: 2)
    let second = paneTabs(app)[1]

    drag(row, onto: second, dx: 0.2, hold: 1.5)

    XCTAssertTrue(waitFor { !row.exists }, "the standalone row goes")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 3 }, "Ops has its terminal")
  }

  /// Value: protects=an Open tab row dropped on another group's row moves that terminal there;
  /// fails_when=the List's table takes the row's drag and it never ends (#819 review A1);
  /// why_new=#819; seam=the real sidebar drag; no_claim=the position (TerminalDropTests)
  func testAnOpenTabRowDroppedOnAnotherGroupsRowMovesThere() {
    let app = launchedApp()
    let devRow = element(app, "sidebar.open.workroom.\(dev)")
    XCTAssertTrue(devRow.waitForExistence(timeout: 15))
    select(app, ops, tabs: 2)
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 2 })
    let opsRow = element(app, "sidebar.open.workroom.\(ops)")
    let tabRow = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.open.tab.'")
    ).allElementsBoundByIndex.filter { $0.frame.midY > opsRow.frame.maxY }
      .min { $0.frame.minY < $1.frame.minY }
    guard let tabRow else { return XCTFail("Ops's first tab row") }

    drag(tabRow, onto: devRow, hold: 0.8)

    XCTAssertTrue(waitFor { app.openTabRows(of: self.dev) == 2 }, "Dev has it")
    XCTAssertTrue(waitFor { self.opsTerminals(app) == 1 }, "it left Ops")
  }

  // MARK: Tabs

  /// Value: protects=a pane tab dropped on another group's sidebar row moves into that group;
  /// fails_when=the drop is refused; why_new=#652 unify; seam=the real pane tab drag;
  /// no_claim=the position (TerminalDropTests)
  func testAPaneTabDroppedOnAGroupsRowMovesThere() {
    let app = launchedApp()
    let opsRow = element(app, "sidebar.open.workroom.\(ops)")
    XCTAssertTrue(opsRow.waitForExistence(timeout: 15))
    select(app, dev, tabs: 1)

    // Over the Open list the tab lifts its row (#819): coming down from the strip, past the row
    // above Ops, its gap opens above Ops, which slides down a row. Ops's middle is then a row
    // lower than where it was as the drag started.
    drag(paneTabs(app)[0], onto: opsRow, dy: 1.5, hold: 0.8)

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
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.open.workroom.standalone:'"))
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
    let devRow = element(app, "sidebar.open.workroom.\(dev)")
    XCTAssertTrue(devRow.waitForExistence(timeout: 15))
    let devTerminals = { app.openTabRows(of: self.dev) }
    XCTAssertTrue(waitFor { devTerminals() == 1 }, "Dev has one")
    select(app, ops, tabs: 2)
    let bar = element(app, "terminal.pane.titlebar")
    XCTAssertTrue(bar.waitForExistence(timeout: 5))

    drag(bar, onto: devRow, hold: 0.8)

    XCTAssertTrue(waitFor { self.opsTerminals(app) == 1 }, "it left Ops")
    XCTAssertTrue(waitFor { devTerminals() == 2 }, "and is Dev's")
  }

  // MARK: Into another group's place in the Open view (#819)

  /// The ids of the tab rows `sid`'s Open row lists under it, top to bottom.
  private func tabRowIDs(_ app: XCUIApplication, of sid: String) -> [String] {
    let row = element(app, "sidebar.open.workroom.\(sid)")
    guard row.exists else { return [] }
    let top = row.frame.maxY
    let bottom =
      app.descendants(matching: .any).matching(
        NSPredicate(format: "identifier BEGINSWITH 'sidebar.open.workroom.'")
      ).allElementsBoundByIndex.map(\.frame.minY).filter { $0 >= top - 0.5 }.min()
      ?? .greatestFiniteMagnitude
    var seen = Set<String>()
    return app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.open.tab.'")
    ).allElementsBoundByIndex.filter { $0.frame.midY > top && $0.frame.midY < bottom }
      .sorted { $0.frame.minY < $1.frame.minY }.map(\.identifier)
      .filter { seen.insert($0).inserted }
  }

  /// Dev selected (its one terminal's row under it) and Ops unfolded by its menu's Expand, its two
  /// terminals' rows under it. Returns Ops's tab rows and Dev's.
  private func showBothGroupsTerminals(_ app: XCUIApplication) -> (ops: [String], dev: [String]) {
    select(app, dev, tabs: 1)
    let opsRow = element(app, "sidebar.open.workroom.\(ops)")
    XCTAssertTrue(opsRow.waitForExistence(timeout: 5))
    opsRow.rightClick()
    let expand = app.menuItems["Expand"]
    XCTAssertTrue(expand.waitForExistence(timeout: 5), "Ops's row offers Expand")
    expand.click()
    XCTAssertTrue(waitFor { self.tabRowIDs(app, of: self.ops).count == 2 }, "Ops unfolds")
    XCTAssertTrue(waitFor { self.tabRowIDs(app, of: self.dev).count == 1 }, "Dev shows its own")
    return (tabRowIDs(app, of: ops), tabRowIDs(app, of: dev))
  }

  /// Value: protects=a group's terminal row dragged over another group's terminal rows opens a gap
  /// there and, let go between two of them, lands in that group in that place, not at its end
  /// (#819 owner report: the blue line showed); fails_when=it lands at the end, stays, or the drop
  /// is refused; why_new=#819; seam=the real Open row drag; no_claim=the gap's look
  /// (OpenRowReflowTests)
  func testAnOpenTabRowLetGoBetweenAnotherGroupsTerminalsLandsThere() {
    let app = launchedApp()
    let (opsTabs, devTabs) = showBothGroupsTerminals(app)
    guard opsTabs.count == 2, let moving = devTabs.first else { return XCTFail("rows") }

    drag(element(app, moving), onto: element(app, opsTabs[1]), dy: 0.3, hold: 0.5)

    XCTAssertTrue(
      waitFor { self.tabRowIDs(app, of: self.ops) == [opsTabs[0], moving, opsTabs[1]] },
      "between Ops's two: \(tabRowIDs(app, of: ops))")
  }

  /// Value: protects=a pane tab dragged from the strip into the Open view lifts its own Open row
  /// and, let go between another group's terminals, lands there as that row's drag would (#819
  /// owner request); fails_when=a strip drag shows the line, or lands at the group's end;
  /// why_new=#819; seam=the real strip drag over the Open list; no_claim=the ghost's look
  func testAPaneTabDraggedIntoTheOpenViewLandsBetweenAnotherGroupsTerminals() {
    let app = launchedApp()
    let (opsTabs, devTabs) = showBothGroupsTerminals(app)
    guard opsTabs.count == 2, let moving = devTabs.first else { return XCTFail("rows") }

    drag(paneTabs(app)[0], onto: element(app, opsTabs[1]), dy: 0.3, hold: 0.5)

    XCTAssertTrue(
      waitFor { self.tabRowIDs(app, of: self.ops) == [opsTabs[0], moving, opsTabs[1]] },
      "between Ops's two: \(tabRowIDs(app, of: ops))")
  }

  /// The workroom rows of the Open view, top to bottom.
  private func openRowOrder(_ app: XCUIApplication) -> [String] {
    var seen = Set<String>()
    return app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.open.workroom.'")
    ).allElementsBoundByIndex.filter { $0.exists && $0.frame.height > 0 }
      .sorted { $0.frame.minY < $1.frame.minY }.map(\.identifier)
      .filter { seen.insert($0).inserted }
  }

  /// Value: protects=a title-bar tab dragged into the Open view lifts its Open row and, let go
  /// between two rows (the last row's lower edge, never onto it), reorders there, the title bar
  /// following (#819 owner request); fails_when=it joins the row, does nothing, or only the title
  /// bar's own reorder runs; why_new=#819; seam=the real title-bar drag over the Open list;
  /// no_claim=the ghost's look
  func testATitleBarTabDraggedIntoTheOpenViewReordersItsRow() {
    let app = launchedApp()
    let row = "sidebar.open.workroom.\(standalone)"
    XCTAssertTrue(element(app, row).waitForExistence(timeout: 15))
    XCTAssertTrue(waitFor { self.openRowOrder(app).count >= 3 }, "a standalone and two groups")
    let before = openRowOrder(app)
    guard let last = before.last, last != row else { return XCTFail("order \(before)") }

    drag(element(app, "workroom.tab.\(standalone)"), onto: element(app, last), dy: 0.9, hold: 0.5)

    let expected = before.filter { $0 != row } + [row]
    XCTAssertTrue(
      waitFor { self.openRowOrder(app) == expected }, "it lands last: \(openRowOrder(app))")
    XCTAssertTrue(
      waitFor { self.titleBarTabs(app).last == "workroom.tab.\(self.standalone)" },
      "its title-bar tab follows: \(titleBarTabs(app))")
  }
}
