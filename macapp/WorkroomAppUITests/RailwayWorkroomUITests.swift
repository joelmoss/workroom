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
  /// through the UI test fixture, its host marked gone (`-WorkroomUITestRailway gone`);
  /// no_claim=the presence read that marks it (HostReachabilityTests)
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
      app.staticTexts["Host gone"].waitForExistence(timeout: 10),
      "the pane doesn't say the host is gone")
    XCTAssertTrue(app.buttons["Remove Workroom…"].exists)
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "terminal.surface").firstMatch.exists,
      "a terminal is mounted over the gone host")

    // The row's menu: Remove Workroom… and nothing else.
    row.rightClick()
    // The menu holding Remove Workroom…: the row's, not one of the menu bar's.
    let menu = app.menus.containing(
      NSPredicate(format: "title == %@", "Remove Workroom…")
    ).firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5), "no context menu")
    XCTAssertTrue(menu.menuItems["Remove Workroom…"].exists, "the menu has no Remove Workroom…")
    XCTAssertEqual(
      menu.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty },
      ["Remove Workroom…"], "a gone workroom's menu offers more")
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
