import XCTest

final class AgentUsageUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp(
    agent: String? = nil, terminalTabs: Int? = nil, usageUnavailable: Bool = false
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
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  /// An ordinary terminal (no usage agent) must not show quota usage, and the sidebar's settings
  /// button must open Settings. The read-only footer checks run first; opening Settings is last.
  func testOrdinaryTerminalHidesQuotaUsageAndSettingsButtonOpensSettings() {
    let app = launchedApp()
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.descendants(matching: .any)["window.footer"].exists)
    XCTAssertTrue(app.buttons["activityBar.settings"].exists)
    XCTAssertTrue(app.buttons["activityBar.notifications"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["terminal.statusBar.agentUsage"].exists)

    let settingsButton = app.buttons["activityBar.settings"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
    settingsButton.click()
    let settings = app.windows.matching(NSPredicate(format: "title CONTAINS %@", "Settings"))
    XCTAssertTrue(settings.firstMatch.waitForExistence(timeout: 8))
  }

  /// One launch with `-WorkroomUITestUsageAgent codex`, as an ordered chain: the footer's label and
  /// accessibility detail, the detail popover (opened, then closed), a split (which must neither
  /// duplicate nor resize the window's provider quota controls), and last a second window, which
  /// shows the running agent from the first. New Window is last because it makes
  /// `app.windows.firstMatch` ambiguous.
  func testCodexQuotaLabelPopoverSplitAndSecondWindow() {
    let app = launchedApp(agent: "codex")
    let usage = app.descendants(matching: .any)["terminal.statusBar.agentUsage"]
    let usageSegments = app.descendants(matching: .any).matching(
      identifier: "terminal.statusBar.agentUsage")
    XCTAssertTrue(usage.waitForExistence(timeout: 15))

    // Step 1: both quota windows and the accessibility detail.
    XCTAssertTrue(usage.label.contains("Codex quota"))
    XCTAssertTrue(usage.label.contains("5h quota 42% used"), usage.label)
    XCTAssertTrue(usage.label.contains("wk quota 61% used"), usage.label)
    XCTAssertTrue(usage.label.contains("resets in"))
    XCTAssertFalse(usage.label.contains("second"))
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = "Window footer"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    // Step 2: the detail popover, which had no coverage at all before issue #168 — its identifier
    // had zero references outside its own definition. It matters more now: the shared `QuotaBar`
    // renders in both places, and with the footer showing bars alone this popover is where the
    // numbers live.
    usage.click()

    let detail = app.descendants(matching: .any)["terminal.statusBar.agentUsage.detail"]
    XCTAssertTrue(detail.waitForExistence(timeout: 5))

    // Assert on the ROWS, and on their `value` rather than their `label` — two separate XCUITest
    // quirks stack here. The container is `.accessibilityElement(children: .contain)`, which keeps
    // its children queryable but does NOT fold them into its own label, so `detail.label` is empty
    // (unlike the footer segment, which is `.ignore` + an explicit label). And each `windowRow` is
    // `.combine`d, which surfaces as a `StaticText` carrying the row's whole sentence in `value`,
    // with an empty `label` — the same shape `PlainFileViewer`'s content assertions hit.
    for expected in ["Session 42% used", "Weekly 61% used"] {
      let row = detail.descendants(matching: .staticText).matching(
        NSPredicate(format: "value CONTAINS %@", expected)
      ).firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 5), "no popover row for '\(expected)'")
    }

    // A second click unpins it, which is the documented dismissal alongside clicking away. The
    // popover must be gone before the split, so it cannot affect the measured width.
    usage.click()
    XCTAssertTrue(detail.waitForNonExistence(timeout: 5))

    // Step 3: splitting a pane must neither duplicate nor resize the window's provider quota
    // controls.
    XCTAssertEqual(usageSegments.count, 1)
    let wideWidth = usage.frame.width

    app.menuBars.menuBarItems["View"].menuItems["Split Right"].click()
    // Wait for the split to render: the segment already existed before it, so without this the
    // width and count checks below could read the unsplit window and pass for nothing.
    let panes = app.descendants(matching: .any).matching(identifier: "terminal.pane")
    let twoPanes = NSPredicate(format: "count == 2")
    expectation(for: twoPanes, evaluatedWith: panes)
    waitForExpectations(timeout: 10)
    let split = usageSegments.firstMatch
    XCTAssertTrue(split.waitForExistence(timeout: 10))
    XCTAssertTrue(split.label.contains("42%"), split.label)
    XCTAssertTrue(split.label.contains("61%"), split.label)

    XCTAssertEqual(split.frame.width, wideWidth, accuracy: 1)
    XCTAssertEqual(usageSegments.count, 1)
    XCTAssertTrue(
      app.windows.firstMatch.frame.contains(split.frame),
      "the usage segment overflowed its window instead of stepping down a rung")

    // Step 4 (last): an empty second window shows the running agent from the first window.
    app.menuBars.menuBarItems["Window"].menuItems["New Window"].click()
    let twoSegments = NSPredicate(format: "count == 2")
    expectation(for: twoSegments, evaluatedWith: usageSegments)
    waitForExpectations(timeout: 10)
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "window.footer").count, 2)
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

  func testNonAgentTabKeepsRunningAgentQuotaSegment() {
    let app = launchedApp(agent: "codex", terminalTabs: 2)
    app.descendants(matching: .any).matching(identifier: "terminal.tab.Codex").firstMatch
      .click()
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar.agentUsage"].waitForExistence(timeout: 15)
    )
    app.descendants(matching: .any).matching(identifier: "terminal.tab.Terminal 2").firstMatch
      .click()
    XCTAssertTrue(
      app.descendants(matching: .any)["terminal.statusBar.agentUsage"].waitForExistence(
        timeout: 5))
  }
}
