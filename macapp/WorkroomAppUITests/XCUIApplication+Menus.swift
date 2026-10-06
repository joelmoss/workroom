import XCTest

extension XCUIApplication {
  /// The ON-SCREEN menu item with this exact title, or nil. Hittable only, because the menu bar keeps
  /// collapsed copies of its items in the tree with a zero frame ("Split Right" is one): a plain
  /// title match can be satisfied, or clicked, there instead of on the context menu that is open.
  func hittableMenuItem(titled title: String) -> XCUIElement? {
    menuItems.matching(NSPredicate(format: "title == %@", title))
      .allElementsBoundByIndex.first { $0.isHittable }
  }

  /// Wait for an on-screen menu item to appear (a menu opens a beat after the right-click), and
  /// return it, or nil if it never did.
  func waitForHittableMenuItem(titled title: String, timeout: TimeInterval = 3) -> XCUIElement? {
    let shown = NSPredicate { _, _ in self.hittableMenuItem(titled: title) != nil }
    _ = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: timeout)
    return hittableMenuItem(titled: title)
  }

  /// Wait until no on-screen menu item has this title, i.e. the menu holding it has closed. Name an
  /// item only that menu has, so the next menu's checks can't be satisfied by this one.
  func waitForNoHittableMenuItem(titled title: String, timeout: TimeInterval = 4) -> Bool {
    let closed = NSPredicate { _, _ in self.hittableMenuItem(titled: title) == nil }
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: timeout)
      == .completed
  }
}
