import XCTest

extension XCUIApplication {
  /// How many tab rows the Open Tabs view lists under `sid`'s workroom row (#819), 0 while the row
  /// is gone. Only the selected row unfolds by default, so a row showing none has its title-bar
  /// tab clicked to select, and so unfold, it: poll this (`XCTNSPredicateExpectation`) and the
  /// next poll counts its rows. Counted between the row and the next workroom row below it.
  func openTabRows(of sid: String) -> Int {
    let row = descendants(matching: .any).matching(identifier: "sidebar.open.workroom.\(sid)")
      .firstMatch
    guard row.exists else { return 0 }
    let top = row.frame.maxY
    let below = descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.open.workroom.'")
    ).allElementsBoundByIndex.map(\.frame.minY).filter { $0 >= top - 0.5 }
    let bottom = below.min() ?? .greatestFiniteMagnitude
    let tabs = descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'sidebar.open.tab.'")
    ).allElementsBoundByIndex.filter { $0.frame.midY > top && $0.frame.midY < bottom }
    let count = Set(tabs.map(\.identifier)).count
    if count == 0 {
      let tab = descendants(matching: .any).matching(identifier: "workroom.tab.\(sid)").firstMatch
      if tab.exists, tab.isHittable {
        tab.click()
        // Not a second click soon after, which would be a double-click.
        Thread.sleep(forTimeInterval: 0.6)
      }
    }
    return count
  }

  /// Shows the sidebar's Projects view through its switcher's tab (ADR 0083), as a click does: a
  /// window opens on the Open Tabs view, and the project tree's rows are in the Projects view.
  func showProjectsView(file: StaticString = #filePath, line: UInt = #line) {
    showSidebarView("projects", file: file, line: line)
  }

  /// Shows the sidebar's Open Tabs view through its switcher's tab.
  func showOpenView(file: StaticString = #filePath, line: UInt = #line) {
    showSidebarView("open", file: file, line: line)
  }

  /// Answers the name prompt a drop that makes a terminal group shows (`AppStore.askGroupName`):
  /// types `name` and chooses Create, or Cancel when `name` is nil.
  func answerNewGroupName(_ name: String?, file: StaticString = #filePath, line: UInt = #line) {
    let field = textFields["terminalGroup.name.field"]
    XCTAssertTrue(
      field.waitForExistence(timeout: 10), "the drop asks for the group's name", file: file,
      line: line)
    guard let name else {
      buttons["Cancel"].firstMatch.click()
      return
    }
    field.typeText(name)
    buttons["Create"].firstMatch.click()
  }

  private func showSidebarView(_ view: String, file: StaticString, line: UInt) {
    let tab = descendants(matching: .any).matching(identifier: "sidebar.view.\(view)").firstMatch
    XCTAssertTrue(
      tab.waitForExistence(timeout: 15), "the sidebar's \(view) tab", file: file, line: line)
    // Clicking the view already shown does nothing.
    tab.click()
  }
}
