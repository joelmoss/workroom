import XCTest

extension XCUIApplication {
  /// How many tab rows the Open section lists under `sid`'s workroom row (#819), 0 while the row
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
}
