import XCTest

/// A named terminal group in the real window (#658, ADR 0077): its row in the Terminals section,
/// its terminals' rows under it, which fold away, and its one title-bar tab. Seeded by the fixture's
/// `-WorkroomUITestTerminalGroup`, never a real project or config.
final class TerminalGroupUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The fixture's fixed group (`UITestFixture.terminalGroupID`).
  private let group = "group:00000000-0000-0000-0000-000000000658"

  /// `group: false` leaves the fixture's group out, so the only terminal rows are a workroom's.
  private func launchedApp(group: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if group { app.launchArguments += ["-WorkroomUITestTerminalGroup", "1"] }
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func elements(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", prefix))
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Waits for `query` to match `n` distinct rows: a List row's element shows up more than once in
  /// the tree, under the same identifier, and a terminal's row is identified by its title.
  private func waitForRows(_ query: XCUIElementQuery, _ n: Int, timeout: TimeInterval = 10)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if Set(query.allElementsBoundByIndex.map(\.identifier)).count == n { return true }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return false
  }

  func testAGroupHasARowThatFoldsItsTerminalsAndOneTitleBarTab() {
    let app = launchedApp()

    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "the group's row")
    let tab = element(app, "workroom.tab.\(group)")
    XCTAssertTrue(tab.waitForExistence(timeout: 5), "its one title-bar tab")
    XCTAssertEqual(elements(app, prefix: "workroom.tab.\(group)").count, 1)
    let spoken = [tab.label, tab.title, tab.value as? String ?? ""]
    XCTAssertTrue(spoken.contains { $0.contains("Ops") }, "named for the group: \(spoken)")
    XCTAssertTrue(
      element(app, "sidebar.group.new.\(group)").exists, "New Terminal in Group on its row")

    // Unfolded, the row lists the group's two terminals; folded, none. Its fold chevron is in its
    // leading column at rest, as a project row's always shows.
    let terminals = elements(app, prefix: "sidebar.terminal.")
    XCTAssertTrue(waitForRows(terminals, 2), "its terminals under it")
    let fold = element(app, "sidebar.group.fold.\(group)")
    XCTAssertTrue(fold.waitForExistence(timeout: 5), "at rest, its chevron")
    XCTAssertLessThan(fold.frame.maxX, row.frame.minX + 30, "in the rows' leading glyph column")
    fold.click()
    XCTAssertTrue(waitForRows(terminals, 0), "folding hides them")
    XCTAssertTrue(row.exists, "and keeps the row")
    row.hover()
    XCTAssertTrue(fold.waitForExistence(timeout: 5))
    fold.click()
    XCTAssertTrue(waitForRows(terminals, 2), "unfolding shows them again")
    // A click anywhere on the row folds and unfolds it too, as on a project's row.
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(waitForRows(terminals, 0), "a click on the row folds it")
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(waitForRows(terminals, 2), "and another unfolds it")

    // Clicking its title-bar tab shows the group: ⌘T then opens a third terminal in it.
    tab.click()
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(waitForRows(terminals, 3), "⌘T opens a terminal in the group")
  }

  /// The group's menu folds it as its hover chevron does, with no pointer over the row: Collapse
  /// while its terminals show, Expand while they're hidden.
  func testTheGroupsMenuCollapsesAndExpandsIt() {
    let app = launchedApp()
    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "the group's row")
    let terminals = elements(app, prefix: "sidebar.terminal.")
    XCTAssertTrue(waitForRows(terminals, 2), "its terminals under it")

    row.rightClick()
    XCTAssertNil(app.waitForHittableMenuItem(titled: "Expand", timeout: 1), "not while expanded")
    let collapse = app.waitForHittableMenuItem(titled: "Collapse")
    XCTAssertNotNil(collapse, "the group's menu offers Collapse")
    collapse?.click()
    XCTAssertTrue(waitForRows(terminals, 0), "Collapse hides its terminals")
    XCTAssertTrue(row.exists, "and keeps the row")

    row.rightClick()
    let expand = app.waitForHittableMenuItem(titled: "Expand")
    XCTAssertNotNil(expand, "folded, the menu offers Expand")
    expand?.click()
    XCTAssertTrue(waitForRows(terminals, 2), "Expand shows them again")
  }

  /// A workroom's menu folds its terminals as its hover chevron does, once it has two of them.
  func testAWorkroomsMenuCollapsesAndExpandsItsTerminals() {
    let app = launchedApp(group: false)
    let row = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier == %@ AND label == %@", "sidebar.workroom.uitest-room", "uitest-room")
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15), "the fixture's workroom row")
    XCTAssertTrue(
      element(app, "terminal.pane").waitForExistence(timeout: 10), "its terminal, selected")
    let terminals = elements(app, prefix: "sidebar.terminal.")

    // One terminal has nothing to fold.
    row.rightClick()
    XCTAssertNil(app.waitForHittableMenuItem(titled: "Expand", timeout: 1), "one terminal")
    app.typeKey(.escape, modifierFlags: [])

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(waitForRows(terminals, 0), "a workroom's terminals start folded")
    row.rightClick()
    let expand = app.waitForHittableMenuItem(titled: "Expand")
    XCTAssertNotNil(expand, "with two terminals, the menu offers Expand")
    expand?.click()
    XCTAssertTrue(waitForRows(terminals, 2), "Expand lists its two terminals")

    row.rightClick()
    let collapse = app.waitForHittableMenuItem(titled: "Collapse")
    XCTAssertNotNil(collapse, "expanded, the menu offers Collapse")
    collapse?.click()
    XCTAssertTrue(waitForRows(terminals, 0), "Collapse hides them")
  }

  /// Every "+" in the sidebar sits in one trailing column: the Terminals heading's, the Quick
  /// Terminal's and a group's rows', and the Projects heading's Add Project. (A project row's "+" is a menu,
  /// which exposes no element to query; it draws the same `SidebarIconGlyph` in the same column.)
  func testEverySidebarPlusSharesOneColumn() {
    let app = launchedApp()
    XCTAssertTrue(element(app, "sidebar.group.\(group)").waitForExistence(timeout: 15))
    var pluses = [element(app, "sidebar.terminals.new"), element(app, "AddProject")]
    pluses += elements(app, prefix: "sidebar.group.new.").allElementsBoundByIndex
    XCTAssertGreaterThanOrEqual(
      pluses.count, 4, "the Terminals heading's, two groups', the Projects heading's")
    let centres = pluses.map { $0.exists ? $0.frame.midX : -1 }
    let first = centres[0]
    for (plus, x) in zip(pluses, centres) {
      XCTAssertEqual(x, first, accuracy: 0.5, "\(plus.identifier) is out of the column: \(centres)")
    }
  }

  /// Closing a named group's last terminal deletes the group, silently: its row and its title-bar
  /// tab go, and nothing asks about the group itself.
  func testClosingTheGroupsLastTerminalDeletesIt() {
    let app = launchedApp()
    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "the group's row")
    let tab = element(app, "workroom.tab.\(group)")
    XCTAssertTrue(tab.waitForExistence(timeout: 5))
    let terminals = elements(app, prefix: "sidebar.terminal.")
    XCTAssertTrue(waitForRows(terminals, 2), "its two terminals")

    tab.click()
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(waitForRows(terminals, 1), "one closed")
    XCTAssertTrue(row.exists, "a named group with a terminal left stays")
    app.typeKey("w", modifierFlags: .command)

    let gone = NSPredicate(format: "exists == false")
    let expectations = [
      XCTNSPredicateExpectation(predicate: gone, object: row),
      XCTNSPredicateExpectation(predicate: gone, object: tab),
    ]
    XCTAssertEqual(
      XCTWaiter().wait(for: expectations, timeout: 8), .completed,
      "the group goes with its last terminal")
    XCTAssertFalse(app.sheets.firstMatch.exists, "nothing asks about the group")
    XCTAssertFalse(app.dialogs.firstMatch.exists, "nothing asks about the group")
  }

  /// Rename… on the group's row edits its name in place; Return keeps it, on the row and the
  /// title-bar tab.
  func testRenameEditsTheGroupsNameInPlace() {
    let app = launchedApp()
    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))

    row.rightClick()
    let rename = app.waitForHittableMenuItem(titled: "Rename…")
    XCTAssertNotNil(rename, "the group's menu offers Rename…")
    rename?.click()
    let field = element(app, "sidebar.group.rename.\(group)")
    XCTAssertTrue(field.waitForExistence(timeout: 6), "an inline name field")
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Servers\r")

    // The tab is a StaticText, whose name arrives as its `value`, not its `label`; the row is a
    // button, named by its label. Accept either on both rather than depend on which.
    let named = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Servers", "Servers")
    let tab = element(app, "workroom.tab.\(group)")
    let renamed = [
      XCTNSPredicateExpectation(predicate: named, object: tab),
      XCTNSPredicateExpectation(predicate: named, object: row),
    ]
    XCTAssertEqual(
      XCTWaiter().wait(for: renamed, timeout: 6), .completed,
      "tab: \(tab.label) / \(tab.value ?? "-"); row: \(row.label) / \(row.value ?? "-")")
    XCTAssertFalse(field.exists, "the field closes")
  }

  /// A group's terminal row offers Rename… and Move to… as its tab does (stories 28, 41).
  /// Renaming from the row edits the name in place, as the group's row does, and an empty name
  /// gives the default back.
  func testATerminalsRowRenamesItInPlaceAndOffersMoveTo() {
    let app = launchedApp()
    let terminals = elements(app, prefix: "sidebar.terminal.")
    XCTAssertTrue(waitForRows(terminals, 2, timeout: 15), "the group's terminals under its row")
    let first = terminals.element(boundBy: 0)
    let defaultID = first.identifier

    first.rightClick()
    XCTAssertNotNil(app.waitForHittableMenuItem(titled: "Move to…"), "its row offers Move to…")
    let rename = app.waitForHittableMenuItem(titled: "Rename…")
    XCTAssertNotNil(rename, "its row offers Rename…")
    rename?.click()

    let field = elements(app, prefix: "sidebar.terminal.rename.").firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 6), "an inline name field, not a sheet")
    XCTAssertFalse(app.sheets.firstMatch.exists, "no sheet")
    field.typeText("Build box\r")
    // The row keeps its identifier (its tab's); its label is the title it shows.
    let row = element(app, defaultID)
    XCTAssertTrue(
      waitForLabel(row, containing: "Build box"), "the row shows the name the user gave it")
    XCTAssertFalse(field.exists, "the field closes")

    row.rightClick()
    app.waitForHittableMenuItem(titled: "Rename…")?.click()
    XCTAssertTrue(field.waitForExistence(timeout: 6))
    field.typeKey("a", modifierFlags: .command)
    field.typeKey(.delete, modifierFlags: [])
    field.typeText("\r")
    XCTAssertTrue(
      waitForLabel(row, containing: "zsh "), "an empty name gives the default back: \(row.label)")
    XCTAssertFalse(row.label.contains("Build box"))
  }

  private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", text)
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 8)
      == .completed
  }

  /// The group's title-bar tab menu offers its row's items and no Run, Restart or Stop (a project's
  /// run command); its Rename… edits the name in the sidebar row.
  func testTheGroupsTabMenuOffersItsRowsItemsAndRenamesInTheRow() {
    let app = launchedApp()
    let tab = element(app, "workroom.tab.\(group)")
    XCTAssertTrue(tab.waitForExistence(timeout: 15), "the group's title-bar tab")

    tab.rightClick()
    for title in ["New Terminal in Ops", "Set Starting Folder…", "Rename…"] {
      XCTAssertNotNil(app.waitForHittableMenuItem(titled: title), "its tab offers \(title)")
    }
    // The menu bar's Room menu has its own Run, Restart and Stop, closed and so not hittable.
    for title in ["Run", "Restart", "Stop"] {
      XCTAssertFalse(
        app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex
          .contains { $0.isHittable }, "no \(title) on a group's tab")
    }
    app.waitForHittableMenuItem(titled: "Rename…")?.click()

    let field = element(app, "sidebar.group.rename.\(group)")
    XCTAssertTrue(field.waitForExistence(timeout: 6), "the row's inline name field")
    XCTAssertFalse(app.sheets.firstMatch.exists, "no sheet while the row is in view")
    field.typeKey("a", modifierFlags: .command)
    field.typeText("Servers\r")
    let named = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Servers", "Servers")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: named, object: tab)], timeout: 6),
      .completed, "tab: \(tab.label) / \(tab.value ?? "-")")
  }

  /// The group's row menu names it in New Terminal, and its pane header shows its name where a
  /// workroom's shows "project / workroom" (#652 critique).
  func testTheGroupsMenuAndPaneHeaderNameIt() {
    let app = launchedApp()
    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))

    row.rightClick()
    XCTAssertNotNil(
      app.waitForHittableMenuItem(titled: "New Terminal in Ops"), "New Terminal names the group")
    XCTAssertNil(app.hittableMenuItem(titled: "New Terminal in Terminal Group"))
    app.typeKey(.escape, modifierFlags: [])

    element(app, "workroom.tab.\(group)").click()
    let header = element(app, "workroom.pane.titlebar")
    XCTAssertTrue(header.waitForExistence(timeout: 6), "the pane header")
    let named = NSPredicate(format: "label == %@", "Ops")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: named, object: header)], timeout: 6),
      .completed, "the header names the group: \(header.label)")
  }

  /// A group terminal's Move to… lists Standalone Terminal and the group it is in, its own place
  /// disabled (and checked), and the workroom as "project / workroom" (#652 critique).
  func testMoveToNamesPlacesAsTheAppDoes() {
    let app = launchedApp()
    let terminals = elements(app, prefix: "sidebar.terminal.")
    XCTAssertTrue(waitForRows(terminals, 2, timeout: 15))

    terminals.element(boundBy: 0).rightClick()
    guard let move = app.waitForHittableMenuItem(titled: "Move to…") else {
      return XCTFail("its row offers Move to…")
    }
    move.hover()
    XCTAssertNotNil(
      app.waitForHittableMenuItem(titled: "Standalone Terminal"),
      "Standalone Terminal, not Standalone")
    let own = app.waitForHittableMenuItem(titled: "Ops")
    XCTAssertEqual(own?.isEnabled, false, "its own place, disabled")
    XCTAssertNotNil(
      app.waitForHittableMenuItem(titled: "UITestProject / uitest-room"),
      "the workroom as \"project / workroom\"")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Dragging a row within the Terminals section reorders it.
  func testDraggingARowReordersTheSection() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestStandaloneTerminals", "1"]
    app.launchArguments += ["-WorkroomUITestTerminalGroup", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    let standalone = element(
      app, "sidebar.standalone.standalone:00000000-0000-0000-0000-000000000651")
    let row = element(app, "sidebar.group.\(group)")
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(standalone.waitForExistence(timeout: 5))
    XCTAssertLessThan(standalone.frame.minY, row.frame.minY, "seeded above the group")

    // `click(forDuration:thenDragTo:)`, the mouse drag: on macOS 27 `press` posts no mouse
    // events from an element, so nothing drags (#269).
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click(
      forDuration: 0.6,
      thenDragTo: standalone.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)))

    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in row.frame.minY < standalone.frame.minY }, object: nil)
    XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 6), .completed, "the group is first")
  }
}
