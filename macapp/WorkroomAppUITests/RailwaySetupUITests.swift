import XCTest

/// The Railway setup sheet (#627), opened from Settings › Remote Hosts, with Railway stubbed by the
/// fixture (`-WorkroomUITestRailway`, `RailwayStub`): no Railway, browser or Keychain is touched.
/// Covers signing in, the workspaces the user granted, Trial and Free refused with the reason, the
/// project's workspace missing from the grant, and signing out after its warning.
///
/// Run in the VM: `make app-uitest-vm APP_UITEST_FLAGS="-only-testing:WorkroomAppUITests/RailwaySetupUITests"`.
final class RailwaySetupUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launch(_ scenario: String, neededWorkspace: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += ["-WorkroomUITestRailway", scenario]
    if let neededWorkspace {
      app.launchArguments += ["-WorkroomUITestRailwayNeededWorkspace", neededWorkspace]
    }
    app.launch()
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    return app
  }

  /// Settings › Remote Hosts › Set Up Railway….
  private func openRailwaySetup(_ app: XCUIApplication) {
    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10))
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.click()
    let pane = element(app, "settingsPane.remoteHosts")
    XCTAssertTrue(pane.waitForExistence(timeout: 10))
    pane.click()
    let setUp = element(app, "settings.control.railwaySetup")
    XCTAssertTrue(setUp.waitForExistence(timeout: 5))
    // Below the providers' host options.
    setUp.scrollIntoView(in: app, maxScrolls: 30)
    setUp.click()
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func text(_ app: XCUIApplication, containing words: String) -> XCUIElement {
    app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", words)).firstMatch
  }

  private func radio(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.radioButtons[label].firstMatch
  }

  /// Signed out: Sign In with Railway opens Railway's page (the fixture approves), and the sheet
  /// lists the granted workspaces with their plans. Picking the Free one, then the Trial one,
  /// says why each is refused; a paid one clears it.
  func testSigningInListsWorkspacesAndRefusesTrialAndFree() {
    let app = launch("signedOut")
    openRailwaySetup(app)

    let signIn = element(app, "railwaySetup.signIn")
    XCTAssertTrue(signIn.waitForExistence(timeout: 10), "a signed-out user is offered sign-in")
    signIn.click()

    XCTAssertTrue(
      element(app, "railwaySetup.signedIn").waitForExistence(timeout: 15), "signed in")
    XCTAssertTrue(radio(app, "Personal (Hobby)").waitForExistence(timeout: 5))
    XCTAssertTrue(radio(app, "Codaset (Pro)").exists)
    XCTAssertTrue(radio(app, "Side projects (Free)").exists)
    XCTAssertTrue(radio(app, "New team (Trial)").exists)
    XCTAssertFalse(element(app, "railwaySetup.planRefused").exists, "Personal is allowed")

    radio(app, "Side projects (Free)").click()
    XCTAssertTrue(element(app, "railwaySetup.planRefused").waitForExistence(timeout: 5))
    XCTAssertTrue(text(app, containing: "the Free plan").exists)

    radio(app, "New team (Trial)").click()
    XCTAssertTrue(text(app, containing: "on a Trial").waitForExistence(timeout: 5))

    radio(app, "Codaset (Pro)").click()
    let refused = element(app, "railwaySetup.planRefused")
    XCTAssertTrue(
      XCTWaiter().wait(
        for: [
          XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"), object: refused)
        ],
        timeout: 5) == .completed, "a Pro workspace isn't refused")
  }

  /// The Project step offers the workspace's projects and a new `Workroom` one; Use This Project
  /// makes this Mac's environment there (#629, story 14).
  func testTheProjectStepOffersExistingProjectsOrANewWorkroomOne() {
    let app = launch("signedIn")
    openRailwaySetup(app)

    XCTAssertTrue(radio(app, "my-app").waitForExistence(timeout: 10), "an existing project")
    let new = radio(app, "New project named Workroom")
    XCTAssertTrue(new.exists, "a new Workroom project")
    XCTAssertEqual(new.value as? Int, 1, "the new Workroom project isn't the default")

    let use = element(app, "railwaySetup.useProject")
    XCTAssertTrue(use.waitForExistence(timeout: 5))
    use.click()

    XCTAssertTrue(element(app, "railwaySetup.placed").waitForExistence(timeout: 10))
    XCTAssertTrue(radio(app, "Workroom").exists, "the made project isn't listed")
    XCTAssertFalse(radio(app, "New project named Workroom").exists, "a second is offered")
  }

  /// The `Workroom` project's workspace isn't among those granted: the sheet says so and offers
  /// to sign in again.
  func testAnUngrantedWorkspaceIsSaidWithSignInAgain() {
    let app = launch("signedIn", neededWorkspace: "ws-elsewhere")
    openRailwaySetup(app)

    XCTAssertTrue(element(app, "railwaySetup.workspaceMissing").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "railwaySetup.signInAgain").exists)
  }

  /// Sign Out… warns that Railway sandboxes keep running and billing; confirming signs out and
  /// offers Sign In with Railway again.
  func testSigningOutWarnsThenSignsOut() {
    let app = launch("signedIn")
    openRailwaySetup(app)

    let signOut = element(app, "railwaySetup.signOut")
    XCTAssertTrue(signOut.waitForExistence(timeout: 10))
    signOut.click()

    XCTAssertTrue(text(app, containing: "keep running").waitForExistence(timeout: 5))
    let confirm = element(app, "railwaySetup.confirmSignOut")
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.click()

    XCTAssertTrue(element(app, "railwaySetup.signIn").waitForExistence(timeout: 10))
  }
}
