import XCTest

/// The sidebar's Open Tabs view (#819, ADR 0082, ADR 0083), through the real window: a window opens on
/// it, with no Terminals heading, its rows select the targets and tabs they stand for and reorder
/// by drag, and the switcher's "+" makes a terminal or a group from it.
/// Wiring only; the rows' content, order, fold and drag rules are `OpenTabsTests`' and the
/// store's. Fixture only, never a real project or config. Run in the VM: `make app-uitest-vm`.
final class OpenTabsUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// The fixture's fixed ids (`UITestFixture.standaloneTerminalIDs`, `.terminalGroupID`).
  private let standalone = [
    "standalone:00000000-0000-0000-0000-000000000651",
    "standalone:00000000-0000-0000-0000-000000000652",
  ]
  private let group = "group:00000000-0000-0000-0000-000000000658"

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1",
      "-WorkroomUITestStandaloneTerminals", "2",
      "-WorkroomUITestTerminalGroup", "1",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    app.activate()
    addTeardownBlock { app.terminate() }
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func elements(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", prefix))
  }

  private func poll(timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  /// The strip chips (`terminal.tab.<title>`), not its split brackets or waiting edges.
  private func selectedChipIDs(_ app: XCUIApplication) -> Set<String> {
    Set(
      elements(app, prefix: "terminal.tab.").allElementsBoundByIndex.filter {
        $0.isSelected && !$0.identifier.hasPrefix("terminal.tab.splitBracket")
          && !$0.identifier.hasPrefix("terminal.tab.waitingEdge")
      }.map(\.identifier))
  }

  /// A window opens on the Open Tabs view, with its rows, and there is no Terminals heading any more.
  func testAWindowOpensOnTheOpenView() {
    let app = launchedApp()

    XCTAssertTrue(
      element(app, "sidebar.view.open").waitForExistence(timeout: 15), "the switcher's Open tab")
    XCTAssertTrue(element(app, "sidebar.view.projects").exists, "and its Projects tab")
    XCTAssertTrue(
      element(app, "sidebar.open.workroom.\(standalone[0])").waitForExistence(timeout: 5),
      "the Open Tabs view's rows")
    XCTAssertFalse(element(app, "sidebar.terminals").exists, "no Terminals heading")
  }

  /// A workroom's row selects its target: its title-bar tab is the selected one.
  func testClickingAWorkroomRowSelectsItsTarget() {
    let app = launchedApp()
    let first = element(app, "sidebar.open.workroom.\(standalone[0])")
    let second = element(app, "sidebar.open.workroom.\(standalone[1])")
    XCTAssertTrue(first.waitForExistence(timeout: 15), "an Open row for each target")
    XCTAssertTrue(second.waitForExistence(timeout: 5))

    first.click()
    XCTAssertTrue(poll { self.element(app, "workroom.tab.\(self.standalone[0])").isSelected })
    second.click()
    XCTAssertTrue(
      poll { self.element(app, "workroom.tab.\(self.standalone[1])").isSelected },
      "the clicked row's title-bar tab is selected")
    XCTAssertFalse(element(app, "workroom.tab.\(standalone[0])").isSelected)
  }

  /// A tab's row selects that tab in the strip.
  func testClickingATabRowSelectsThatTabInTheStrip() {
    let app = launchedApp()
    let groupRow = element(app, "sidebar.open.workroom.\(group)")
    XCTAssertTrue(groupRow.waitForExistence(timeout: 15), "the group's row")
    groupRow.click()  // selecting a row unfolds it
    let tabs = elements(app, prefix: "sidebar.open.tab.")
    XCTAssertTrue(
      poll { Set(tabs.allElementsBoundByIndex.map(\.identifier)).count == 2 },
      "the group's two tabs under it")
    let rows = Array(Set(tabs.allElementsBoundByIndex.map(\.identifier))).sorted()

    var chips: [Set<String>] = []
    for id in rows {
      element(app, id).click()
      XCTAssertTrue(poll { self.selectedChipIDs(app).count == 1 }, "one chip selected for \(id)")
      chips.append(selectedChipIDs(app))
    }
    XCTAssertNotEqual(chips[0], chips[1], "each row selected its own tab in the strip")
  }

  /// The workroom rows' ids, top to bottom.
  private func workroomRowOrder(_ app: XCUIApplication) -> [String] {
    elements(app, prefix: "sidebar.open.workroom.").allElementsBoundByIndex
      .filter { $0.exists && $0.frame.height > 0 }
      .sorted { $0.frame.minY < $1.frame.minY }
      .map(\.identifier)
  }

  /// The title-bar tab of the workroom whose Open row is `rowID`.
  private func chip(_ app: XCUIApplication, ofRow rowID: String) -> XCUIElement {
    element(
      app, "workroom.tab." + rowID.replacingOccurrences(of: "sidebar.open.workroom.", with: ""))
  }

  /// The first workroom row, dragged down to the lower edge of the second's row (between rows,
  /// never onto it), lifts out of the list and, let go there, lands second: the list and the title
  /// bar both show the new order (#819). The ghost and the gap are what it looks like on the way,
  /// not asserted here (`OpenRowReflowTests`).
  func testDraggingAWorkroomRowPastTheNextReordersThem() {
    let app = launchedApp()
    XCTAssertTrue(
      element(app, "sidebar.open.workroom.\(group)").waitForExistence(timeout: 15),
      "the Open Tabs view's rows")
    XCTAssertTrue(
      poll { self.workroomRowOrder(app).count >= 3 }, "the fixture's terminals, group and more")
    let before = workroomRowOrder(app)
    let first = element(app, before[0])
    let second = element(app, before[1])

    first.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click(
      forDuration: 0.6,
      thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.9)),
      withVelocity: .slow, thenHoldForDuration: 0.4)

    var expected = before
    expected.swapAt(0, 1)
    XCTAssertTrue(
      poll(timeout: 8) { self.workroomRowOrder(app) == expected },
      "it lands second: \(workroomRowOrder(app))")
    let moved = chip(app, ofRow: before[0])
    let passed = chip(app, ofRow: before[1])
    XCTAssertTrue(
      poll { passed.frame.minX < moved.frame.minX }, "and its title-bar tab follows the other's")
  }

  /// A group's terminal row, dragged out of the group to the upper quarter of another top-level
  /// row (between rows, never onto it) and let go, becomes a standalone terminal with a row of its
  /// own there, just above that row, and the named group stays (#819 owner report). Where the gap
  /// goes on the way is `OpenRowReflowTests`'; the store's move is `OpenTabsDropTests`'.
  func testDraggingAGroupsTerminalRowBetweenRowsMakesAStandaloneThere() {
    let app = launchedApp()
    let groupRowID = "sidebar.open.workroom.\(group)"
    let groupRow = element(app, groupRowID)
    XCTAssertTrue(groupRow.waitForExistence(timeout: 15), "the group's row")
    XCTAssertTrue(
      poll { self.workroomRowOrder(app).count >= 3 }, "the fixture's terminals, group and more")
    groupRow.click()  // selecting a row unfolds it
    let tabs = elements(app, prefix: "sidebar.open.tab.")
    XCTAssertTrue(
      poll { Set(tabs.allElementsBoundByIndex.map(\.identifier)).count == 2 },
      "the group's two tabs under it")
    let before = workroomRowOrder(app)
    let groupIndex = before.firstIndex(of: groupRowID) ?? 0
    // Between two other rows: up to just above the row above the group when a row is above that
    // one too, else down to just above the row below the group (just below the group).
    let landsAt = groupIndex >= 2 ? groupIndex - 1 : groupIndex + 1
    let target = element(app, before[landsAt])
    let dragged = tabs.allElementsBoundByIndex.filter(\.exists).max {
      $0.frame.minY < $1.frame.minY
    }
    guard let dragged else { return XCTFail("no tab row") }

    dragged.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click(
      forDuration: 0.6,
      thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)),
      withVelocity: .slow, thenHoldForDuration: 0.4)

    // A new standalone terminal's row, just above the row it was let go on, the group still there.
    let landed = poll(timeout: 8) {
      let after = self.workroomRowOrder(app)
      guard after.count == before.count + 1, after.indices.contains(landsAt) else { return false }
      var rest = after
      let made = rest.remove(at: landsAt)
      return made.hasPrefix("sidebar.open.workroom.standalone:") && !before.contains(made)
        && rest == before
    }
    XCTAssertTrue(landed, "a standalone row at \(landsAt) of \(before): \(workroomRowOrder(app))")
  }

  /// The switcher's "+" menu makes a terminal or a group, in the Open Tabs view; opening a workroom is
  /// ⌘O's.
  func testThePlusMenuOffersNewTerminalAndNewGroup() {
    let app = launchedApp()
    let plus = element(app, "sidebar.add")
    XCTAssertTrue(plus.waitForExistence(timeout: 15), "the switcher's \"+\"")

    plus.click()
    for title in ["New Terminal", "New Terminal Group…"] {
      XCTAssertNotNil(app.waitForHittableMenuItem(titled: title), "its menu offers \(title)")
    }
    XCTAssertFalse(element(app, "sidebar.open.add.openWorkroom").exists, "not Open Workroom…")
    app.typeKey(.escape, modifierFlags: [])
  }
}
