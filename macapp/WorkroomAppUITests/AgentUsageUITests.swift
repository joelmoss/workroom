import XCTest

final class AgentUsageUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp(
    agent: String? = nil, terminalTabs: Int? = nil, usageUnavailable: Bool = false,
    zeroUsage: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1", "-ApplePersistenceIgnoreState", "YES"]
    if let agent { app.launchArguments += ["-WorkroomUITestUsageAgent", agent] }
    if let terminalTabs {
      app.launchArguments += ["-WorkroomUITestTerminalTabs", String(terminalTabs)]
    }
    if usageUnavailable {
      app.launchArguments += ["-WorkroomUITestUsageUnavailable", "1"]
    }
    if zeroUsage { app.launchArguments += ["-WorkroomUITestUsageZero", "1"] }
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  func testOrdinaryTerminalHidesQuotaUsage() {
    let app = launchedApp()
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.descendants(matching: .any)["terminal.statusBar.agentUsage"].exists)
  }

  func testCodexShowsBothQuotaWindowsAndAccessibilityDetail() {
    let app = launchedApp(agent: "codex")
    let usage = app.descendants(matching: .any)["terminal.statusBar.agentUsage"]
    XCTAssertTrue(usage.waitForExistence(timeout: 15))
    XCTAssertTrue(usage.label.contains("Codex quota"))
    XCTAssertTrue(usage.label.contains("5h quota 42% used"), usage.label)
    XCTAssertTrue(usage.label.contains("wk quota 61% used"), usage.label)
    XCTAssertTrue(usage.label.contains("resets in"))
    XCTAssertFalse(usage.label.contains("second"))
  }

  func testClaudeOffersOptInWithoutChangingDeveloperSettings() {
    let app = launchedApp(agent: "claude")
    let enable = app.descendants(matching: .any)[
      "terminal.statusBar.agentUsage.enableClaude"]
    XCTAssertTrue(enable.waitForExistence(timeout: 15))
    enable.click()
    XCTAssertTrue(app.buttons["Enable"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Cancel"].exists)
  }

  func testDetectedAgentWithoutSnapshotExplainsWhyAndOffersARefresh() {
    let app = launchedApp(agent: "codex", usageUnavailable: true)
    let unavailable = app.descendants(matching: .any)[
      "terminal.statusBar.agentUsage.unavailable"]
    XCTAssertTrue(unavailable.waitForExistence(timeout: 15))
    XCTAssertTrue(unavailable.label.contains("has been read yet"), unavailable.label)
    XCTAssertTrue(unavailable.label.contains("Click to refresh"), unavailable.label)
    XCTAssertTrue(unavailable.isHittable)
    unavailable.click()
    XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
  }

  func testZeroUsageOmitsPace() {
    let app = launchedApp(agent: "codex", zeroUsage: true)
    let usage = app.descendants(matching: .any)["terminal.statusBar.agentUsage"]
    XCTAssertTrue(usage.waitForExistence(timeout: 15))
    XCTAssertTrue(usage.label.contains("5h quota 0% used"), usage.label)
    XCTAssertTrue(usage.label.contains("wk quota 0% used"), usage.label)
    XCTAssertFalse(usage.label.contains("in deficit"), usage.label)
    XCTAssertFalse(usage.label.contains("in reserve"), usage.label)
    XCTAssertFalse(usage.label.contains("pace"), usage.label)
  }

  func testNarrowSplitKeepsBothPercentages() {
    let app = launchedApp(agent: "codex")
    app.menuBars.menuBarItems["View"].menuItems["Split Right"].click()
    let usage = app.descendants(matching: .any).matching(
      identifier: "terminal.statusBar.agentUsage"
    )
    .firstMatch
    XCTAssertTrue(usage.waitForExistence(timeout: 10))
    XCTAssertTrue(usage.label.contains("42%"), usage.label)
    XCTAssertTrue(usage.label.contains("61%"), usage.label)
  }

  func testNonAgentTabHasNoQuotaSegment() {
    let app = launchedApp(agent: "codex", terminalTabs: 2)
    app.descendants(matching: .any).matching(identifier: "terminal.tab.Codex").firstMatch
      .click()
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar.agentUsage"].waitForExistence(timeout: 15)
    )
    app.descendants(matching: .any).matching(identifier: "terminal.tab.Terminal 2").firstMatch
      .click()
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar.agentUsage"].waitForNonExistence(
        timeout: 5))
  }
}
