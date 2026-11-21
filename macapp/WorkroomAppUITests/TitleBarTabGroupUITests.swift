import XCTest

/// Grouping title-bar tabs by dropping one on another (#652): a standalone terminal's tab let go
/// over the middle of another's makes an unnamed group, and at its edge only reorders; on a
/// group's tab it joins that group; a group's tab on another group's moves its terminals there.
/// Seeded by the fixture's standalone terminals and groups, never a real project or config.
final class TitleBarTabGroupUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private let standalone = (1...3).map { "standalone:00000000-0000-0000-0000-00000000065\($0)" }
  private let ops = "group:00000000-0000-0000-0000-000000000658"
  private let dev = "group:00000000-0000-0000-0000-000000006520"
  /// The Quick Terminal's group (#661), always listed: never one of the groups made here.
  private let quickTerminal = "51C10A7E-0D4F-4E6A-9B2C-000000000001"

  private func launchedApp(_ arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += arguments
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Elements whose identifier starts with `prefix`, leaving out the Quick Terminal's.
  private func elements(_ app: XCUIApplication, prefix: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND NOT (identifier CONTAINS[c] %@)", prefix,
        quickTerminal))
  }

  /// Waits for `query` to match `n` distinct identifiers (a List row can show up more than once).
  private func waitForCount(_ query: XCUIElementQuery, _ n: Int, timeout: TimeInterval = 10)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if Set(query.allElementsBoundByIndex.map(\.identifier)).count == n { return true }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return false
  }

  private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 6) -> Bool {
    let met = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter().wait(for: [met], timeout: timeout) == .completed
  }

  /// A slow mouse drag of tab `from` to `dx` (0–1) across tab `to`, held there before the button
  /// comes up, so the bar's drag sees the pointer settle. `click…`, the mouse drag: on macOS 27
  /// `press` posts no mouse events (#269).
  private func drag(_ from: XCUIElement, onto to: XCUIElement, dx: CGFloat = 0.5) {
    let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.click(
      forDuration: 0.3, thenDragTo: to.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0.6)
  }

  /// Value: protects=case 1 in the real window: a standalone terminal's tab let go over the middle
  /// of another's makes one group tab of the two, and let go at a tab's leading edge it only
  /// reorders; fails_when=a middle drop reorders instead, or an edge drop groups;
  /// why_new=#652; seam=the real title-bar drag; no_claim=sessions (TitleBarTabGroupDropTests)
  func testAStandaloneTabOnAnotherGroupsThemAndAtItsEdgeReorders() {
    let app = launchedApp(["-WorkroomUITestStandaloneTerminals", "3"])
    let first = element(app, "workroom.tab.\(standalone[0])")
    let second = element(app, "workroom.tab.\(standalone[1])")
    let third = element(app, "workroom.tab.\(standalone[2])")
    XCTAssertTrue(first.waitForExistence(timeout: 15))
    XCTAssertTrue(third.waitForExistence(timeout: 5))
    XCTAssertLessThan(first.frame.minX, third.frame.minX)

    // At the leading edge of the first: the third goes before it, and nothing groups.
    drag(third, onto: first, dx: 0.1)
    XCTAssertTrue(waitFor { third.frame.minX < first.frame.minX }, "it reorders")
    let groupTabs = elements(app, prefix: "workroom.tab.group:")
    XCTAssertTrue(waitForCount(groupTabs, 0, timeout: 1), "and groups nothing")

    // Over the middle of the first: a group tab of the two, and the third left alone. A
    // screenshot, taken while the drag hovers, shows the target's highlight.
    let hovering = ScreenshotBox()
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
      hovering.set(XCUIScreen.main.screenshot())
    }
    drag(second, onto: first)
    if let hovering = hovering.get() {
      let shot = XCTAttachment(screenshot: hovering)
      shot.name = "title-bar group drop highlight"
      shot.lifetime = .keepAlways
      add(shot)
    }
    XCTAssertTrue(waitForCount(groupTabs, 1), "the two become a group's tab")
    XCTAssertTrue(
      waitForCount(elements(app, prefix: "workroom.tab.standalone:"), 1), "one is left")
    XCTAssertTrue(third.exists, "the third is the one left")
  }

  /// Value: protects=case 2 in the real window: a standalone terminal's tab let go on a group's
  /// tab joins that group, and its own tab goes; fails_when=it reorders instead, or a new group is
  /// made; why_new=#652; seam=the real title-bar drag; no_claim=its place in the group
  /// (TitleBarTabGroupDropTests)
  func testAStandaloneTabOnAGroupsTabJoinsIt() {
    let app = launchedApp([
      "-WorkroomUITestStandaloneTerminals", "1", "-WorkroomUITestTerminalGroup", "1",
    ])
    let tab = element(app, "workroom.tab.\(standalone[0])")
    let group = element(app, "workroom.tab.\(ops)")
    XCTAssertTrue(tab.waitForExistence(timeout: 15))
    XCTAssertTrue(group.waitForExistence(timeout: 5))
    let terminals = elements(app, prefix: "sidebar.terminal.")
    XCTAssertTrue(waitForCount(terminals, 2), "Ops starts with two")

    drag(tab, onto: group)

    XCTAssertTrue(waitForCount(elements(app, prefix: "workroom.tab.standalone:"), 0))
    XCTAssertTrue(waitForCount(elements(app, prefix: "workroom.tab.group:"), 1), "only Ops")
    XCTAssertTrue(group.exists)
    XCTAssertTrue(waitForCount(terminals, 3), "Ops has three")
  }

  /// Value: protects=case 3 in the real window: a group's tab let go on another group's moves
  /// every terminal there, and the emptied group's tab and row go; fails_when=it reorders, a
  /// terminal is lost, or the dragged group stays; why_new=#652; seam=the real title-bar drag;
  /// no_claim=their order and sessions (TitleBarTabGroupDropTests)
  func testAGroupsTabOnAnotherGroupsTabMovesItsTerminalsThere() {
    let app = launchedApp([
      "-WorkroomUITestTerminalGroup", "1", "-WorkroomUITestSecondTerminalGroup", "1",
    ])
    let opsTab = element(app, "workroom.tab.\(ops)")
    let devTab = element(app, "workroom.tab.\(dev)")
    XCTAssertTrue(opsTab.waitForExistence(timeout: 15))
    XCTAssertTrue(devTab.waitForExistence(timeout: 5))
    let terminals = elements(app, prefix: "sidebar.terminal.")
    XCTAssertTrue(waitForCount(terminals, 3))

    drag(opsTab, onto: devTab)

    XCTAssertTrue(waitForCount(elements(app, prefix: "workroom.tab.group:"), 1), "only Dev")
    XCTAssertTrue(devTab.exists)
    XCTAssertTrue(waitFor { !self.element(app, "sidebar.group.\(self.ops)").exists }, "Ops goes")
    XCTAssertTrue(waitForCount(terminals, 3), "every terminal kept")
  }
}

/// A screenshot taken off the test's thread, while a drag holds it.
private final class ScreenshotBox: @unchecked Sendable {
  private let lock = NSLock()
  private var shot: XCUIScreenshot?
  func set(_ shot: XCUIScreenshot) { lock.withLock { self.shot = shot } }
  func get() -> XCUIScreenshot? { lock.withLock { shot } }
}
