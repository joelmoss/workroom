import XCTest

/// The sidebar's Open view (#819, ADR 0082, ADR 0083), through the real window: a window opens on
/// it, with no Terminals heading, its rows select the targets and tabs they stand for, and the
/// switcher's "+" opens anything from it.
/// Wiring only; the rows' content, order, fold and drag rules are `OpenSectionTests`' and the
/// store's. Fixture only, never a real project or config. Run in the VM: `make app-uitest-vm`.
final class OpenSectionUITests: XCTestCase {
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

  /// A window opens on the Open view, with its rows, and there is no Terminals heading any more.
  func testAWindowOpensOnTheOpenView() {
    let app = launchedApp()

    XCTAssertTrue(
      element(app, "sidebar.view.open").waitForExistence(timeout: 15), "the switcher's Open tab")
    XCTAssertTrue(element(app, "sidebar.view.projects").exists, "and its Projects tab")
    XCTAssertTrue(
      element(app, "sidebar.open.workroom.\(standalone[0])").waitForExistence(timeout: 5),
      "the Open view's rows")
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

  /// The switcher's "+" menu makes a terminal or a group, in the Open view; opening a workroom is
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
