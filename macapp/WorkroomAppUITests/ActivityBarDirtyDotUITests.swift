import XCTest

/// UI test for the activity bar's **Changes dirty dot**. The fixture (`-WorkroomUITestFixture 1`)
/// auto-selects the jj fixture workroom, whose seeded `WorkroomStatus` is `dirty: true`
/// (`UITestFixture.workroomStatus`), so on launch the Changes icon must signal the uncommitted
/// working tree. The dot itself is decorative (a11y-hidden); the state is announced on the icon
/// button's accessibility **value** ("has changes"), which is what this test reads.
///
/// Also guards that the dot is scoped to Changes only — no peer icon inherits the dirty value even
/// though the selected workroom is dirty.
///
/// The peer icons are **discovered from the accessibility tree**, not named. This test used to probe
/// `activitySection.history` by name, which stopped existing when History moved out of the activity bar
/// and into the Changes stack (`0fc3b97a`): reading `.value` on a element that isn't there throws
/// "Failed to get matching snapshot", so the test failed for 16 days while saying nothing about the dot.
/// Enumerating whatever sections the bar renders keeps the assertion honest through the next such move.
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run, so
/// this is excluded from `make app-test` (the unit gate) via a separate scheme.
final class ActivityBarDirtyDotUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.activate()
    return app
  }

  /// A bar icon by its accessibility id (`activitySection.<rawValue>`).
  private func icon(_ app: XCUIApplication, _ raw: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "activitySection.\(raw)").firstMatch
  }

  /// Every activity-bar icon currently in the tree, by identifier — whatever sections the bar renders.
  private func barIcons(_ app: XCUIApplication) -> [(id: String, value: String)] {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "activitySection."))
      .allElementsBoundByIndex
      .map { (id: $0.identifier, value: $0.value as? String ?? "") }
  }

  /// Wait until `el`'s accessibility value contains `text`. The dirty state rides the icon button's
  /// value ("has changes"), so this asserts the dot's wiring directly.
  @discardableResult
  private func waitValue(_ el: XCUIElement, contains text: String, _ timeout: TimeInterval = 6)
    -> Bool
  {
    let p = NSPredicate(format: "value CONTAINS %@", text)
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// The dirty fixture workroom is selected on launch, so the Changes icon reports "has changes" and
  /// the other sections don't — the dot is Changes-scoped, driven by the selected target's status.
  func testChangesIconShowsDirtyForDirtyWorkroom() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let changes = icon(app, "changes")
    XCTAssertTrue(changes.waitForExistence(timeout: 10), "activity bar should render")

    // The seeded workroom is dirty → the Changes icon announces it on its accessibility value.
    XCTAssertTrue(
      waitValue(changes, contains: "has changes"),
      "Changes icon should report the dirty working tree")

    // The dot is scoped to Changes: no peer section inherits the dirty value. Peers are read off the
    // tree rather than named, so a section leaving the bar can't turn this into a query for an element
    // that doesn't exist (which is how it broke before — see the type doc).
    let peers = barIcons(app).filter { $0.id != "activitySection.changes" }
    XCTAssertFalse(
      peers.isEmpty,
      "the bar must render at least one peer section, or this assertion proves nothing")
    for peer in peers {
      XCTAssertFalse(
        peer.value.contains("has changes"),
        "\(peer.id) must not carry the dirty dot — it is scoped to Changes")
    }
  }
}
