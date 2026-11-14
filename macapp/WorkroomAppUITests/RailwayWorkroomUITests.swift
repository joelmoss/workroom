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

  /// Value: protects=a create whose reply was lost shows "A Railway create may have left a
  /// sandbox" with the unrecorded sandbox it may have made and not the recorded one; Destroy asks
  /// first, and confirmed, destroys it and resolves the notice (review 5 of #623, D1);
  /// fails_when=the notice is missing, offers the workroom's own sandbox, destroys without asking,
  /// or stays after the destroy; seam=the app through the UI test fixture, Railway stubbed
  /// (`-WorkroomUITestRailwayLostCreate 1`); no_claim=Dismiss and the candidate rules
  /// (RailwayLostCreatesModelTests, RailwaySweepTests)
  func testALostRailwayCreateOffersItsCandidateToDestroy() {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += ["-WorkroomUITestRailway", "signedIn"]
    app.launchArguments += ["-WorkroomUITestRailwayWorkroom", "1"]
    app.launchArguments += ["-WorkroomUITestRailwayLostCreate", "1"]
    app.launch()
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let row = element(app, "sidebar.workroom.uitest-railway")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the Railway workroom isn't listed")
    row.click()
    let details = element(app, "activitySection.details")
    XCTAssertTrue(details.waitForExistence(timeout: 5))
    details.click()

    XCTAssertTrue(
      element(app, "railway.lostCreate.title").waitForExistence(timeout: 10),
      "no notice of the lost create")
    let destroy = element(app, "railway.lostCreate.destroy.sbx-lost-uitest")
    XCTAssertTrue(destroy.waitForExistence(timeout: 10), "the candidate isn't offered")
    XCTAssertFalse(
      element(app, "railway.lostCreate.destroy.sbx-uitest").exists,
      "the workroom's own sandbox is offered")
    XCTAssertTrue(element(app, "railway.lostCreate.dismiss").exists)

    destroy.click()
    let confirm = app.buttons["Destroy Sandbox"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Destroy didn't ask first")
    confirm.click()

    let resolved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == NO"),
      object: element(app, "railway.lostCreate.title"))
    XCTAssertEqual(
      XCTWaiter().wait(for: [resolved], timeout: 15), .completed, "the notice stayed")
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
