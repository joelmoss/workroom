import XCTest

/// Railway's host options in Settings › Remote Hosts (#633), with the provider read stubbed by the
/// fixture (`-WorkroomUITestHostOptions ok`: this Mac's environment holds `uitest-checkpoint`, on
/// a Hobby plan). Nothing is chosen, so the run saves no setting.
///
/// Run in the VM: `make app-uitest-vm APP_UITEST_FLAGS="-only-testing:WorkroomAppUITests/RailwayHostOptionsUITests"`.
final class RailwayHostOptionsUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// Value: protects=a Railway host's region, size up to the plan's maximum, and this Mac's
  /// checkpoints are offered where other providers' host options are (stories 19, 20, 23);
  /// fails_when=Railway has no options section, a region is missing, the CPU goes past the
  /// plan's 8 vCPU, or the checkpoint menu doesn't list this environment's checkpoint;
  /// why_new=#633; seam=-WorkroomUITestHostOptions ok; no_claim=the create that sends them
  /// (RailwayHostOptionsTests)
  func testRemoteHostsOffersRailwaysRegionsSizesAndCheckpoints() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1", "-ApplePersistenceIgnoreState", "YES",
      "-WorkroomUITestHostOptions", "ok",
    ]
    app.launch()
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let appMenu = app.menuBarItems.element(boundBy: 1)
    XCTAssertTrue(appMenu.waitForExistence(timeout: 10))
    appMenu.click()
    let settings = app.menuItems["Settings…"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.click()
    let pane = element(app, "settingsPane.remoteHosts")
    XCTAssertTrue(pane.waitForExistence(timeout: 10))
    pane.click()

    // The pop-up itself: a Form row gives its label the picker's identifier too, and clicking the
    // label doesn't open the menu.
    let region = app.popUpButtons["hostOptions.railway.region"]
    XCTAssertTrue(region.waitForExistence(timeout: 10), "Railway has no host options")
    region.scrollIntoView(in: app, maxScrolls: 30)
    region.click()
    for name in [
      "US West (California) (default)", "US East (Virginia)", "EU West (Amsterdam)",
      "Southeast Asia (Singapore)",
    ] {
      XCTAssertTrue(app.menuItems[name].waitForExistence(timeout: 5), "no region \(name)")
    }
    app.typeKey(.escape, modifierFlags: [])

    let cpu = app.popUpButtons["hostOptions.railway.cpu"]
    XCTAssertTrue(cpu.waitForExistence(timeout: 5), "no Railway CPU picker")
    cpu.scrollIntoView(in: app, maxScrolls: 30)
    cpu.click()
    XCTAssertTrue(app.menuItems["8 vCPU"].waitForExistence(timeout: 5), "the plan's maximum")
    XCTAssertFalse(app.menuItems["9 vCPU"].exists, "a CPU past the Hobby plan's maximum")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(element(app, "hostOptions.railway.memory").exists, "no Railway memory picker")

    let checkpoints = element(app, "hostOptions.choices.Checkpoint")
    XCTAssertTrue(checkpoints.waitForExistence(timeout: 5), "no checkpoint menu")
    checkpoints.scrollIntoView(in: app, maxScrolls: 30)
    checkpoints.click()
    XCTAssertTrue(
      app.menuItems["uitest-checkpoint"].waitForExistence(timeout: 5),
      "this Mac's checkpoint isn't offered")
    app.typeKey(.escape, modifierFlags: [])
  }
}
