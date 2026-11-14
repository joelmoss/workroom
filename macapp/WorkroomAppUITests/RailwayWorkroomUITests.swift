import XCTest

/// A Railway workroom (#629) whose Railway sign-in has ended: the fixture lists one
/// (`-WorkroomUITestRailwayWorkroom 1`) with Railway stubbed signed out (`RailwayStub`), and its
/// relay a name that never resolves, so nothing reaches Railway.
///
/// Run in the VM: `make app-uitest-vm APP_UITEST_FLAGS="-only-testing:WorkroomAppUITests/RailwayWorkroomUITests"`.
final class RailwayWorkroomUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Value: protects=a Railway workroom whose sandbox was destroyed outside Workroom shows gone,
  /// with Remove Workroom as its only action, and no pane retrying it (#623 story 26, #629);
  /// fails_when=its pane, Details or context menu still offers anything else; seam=the app
  /// through the UI test fixture, Railway stubbed with no sandboxes
  func testAGoneRailwayWorkroomOffersOnlyRemove() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += ["-WorkroomUITestRailway", "gone"]
    app.launchArguments += ["-WorkroomUITestRailwayWorkroom", "1"]
    app.launch()
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let row = element(app, "sidebar.workroom.uitest-railway")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the Railway workroom isn't listed")
    row.click()

    // The pane: the gone notice and Remove Workroom, not a terminal retrying the host.
    XCTAssertTrue(
      element(app, "terminal.removeGoneWorkroom").waitForExistence(timeout: 30),
      "the pane doesn't say the host is gone")

    let details = element(app, "activitySection.details")
    XCTAssertTrue(details.waitForExistence(timeout: 5))
    details.click()
    XCTAssertTrue(element(app, "details.hostGone").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "details.removeGoneWorkroom").exists)

    // The row's menu: Remove Workroom… and nothing else.
    row.rightClick()
    let remove = app.menuItems["Remove Workroom…"]
    XCTAssertTrue(remove.waitForExistence(timeout: 5), "the menu has no Remove Workroom…")
    for other in ["Run", "Set Label…", "Delete Workroom…", "Open (split right)"] {
      XCTAssertFalse(app.menuItems[other].exists, "a gone workroom's menu offers \(other)")
    }
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Value: protects=a revoked or expired Railway sign-in shows the workroom signed out, with Sign
  /// In, and signing in clears it; fails_when=the Details pane says nothing, or the button doesn't
  /// sign in; seam=the app through the UI test fixture, Railway stubbed
  func testASignedOutRailwayWorkroomOffersSignIn() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += ["-WorkroomUITestRailway", "signedOut"]
    app.launchArguments += ["-WorkroomUITestRailwayWorkroom", "1"]
    app.launch()
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let row = element(app, "sidebar.workroom.uitest-railway")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the Railway workroom isn't listed")
    row.click()
    let details = element(app, "activitySection.details")
    XCTAssertTrue(details.waitForExistence(timeout: 5))
    details.click()

    let signIn = element(app, "details.railwaySignIn")
    XCTAssertTrue(
      signIn.waitForExistence(timeout: 10), "a signed-out Railway workroom has no Sign In")
    XCTAssertTrue(element(app, "details.railwaySignedOut").exists)
    signIn.click()

    // The fixture's browser approves on Railway's page.
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == NO"), object: signIn)
    XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 15), .completed, "still signed out")
  }
}
