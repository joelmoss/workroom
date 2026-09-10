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

  /// Both windows survive a narrow split, AND the `ViewThatFits` bar-width ladder actually engages.
  ///
  /// The label half is deliberately not named "keeps both percentages": the percentages come off the
  /// accessibility label, which is identical whichever variant rendered and would still carry them
  /// if the segment drew nothing. The width half is what has teeth. The ladder shipped DEAD once
  /// (issue #168): a `.fixedSize(horizontal: true)` on the `ViewThatFits` proposed an unspecified
  /// width, so the first variant always "fit" and every later rung was unreachable — with the whole
  /// suite green, because nothing looked at geometry. The bars are rigid `Capsule().frame(width:)`,
  /// so a dead ladder does not shrink: it keeps its widest ideal width and overflows.
  ///
  /// Measured under this fixture window: 116pt unsplit (the 44pt rung), 92pt after one split (the
  /// 32pt rung). Further splits divide the OTHER pane, so one split is what crosses a rung here.
  /// Asserted as an inequality rather than the literal numbers so spacing tweaks don't false-fail;
  /// re-adding `.fixedSize` pins it at 116 and trips this.
  func testNarrowSplitKeepsBothWindowsAndShrinksTheBars() {
    let app = launchedApp(agent: "codex")
    let usage = app.descendants(matching: .any)["terminal.statusBar.agentUsage"]
    XCTAssertTrue(usage.waitForExistence(timeout: 15))
    let wideWidth = usage.frame.width

    app.menuBars.menuBarItems["View"].menuItems["Split Right"].click()
    let split = app.descendants(matching: .any).matching(
      identifier: "terminal.statusBar.agentUsage"
    )
    .firstMatch
    XCTAssertTrue(split.waitForExistence(timeout: 10))
    XCTAssertTrue(split.label.contains("42%"), split.label)
    XCTAssertTrue(split.label.contains("61%"), split.label)

    XCTAssertLessThan(
      split.frame.width, wideWidth,
      "the bar-width ladder did not engage in a split pane — a dead ladder keeps its widest variant"
    )
    XCTAssertTrue(
      app.windows.firstMatch.frame.contains(split.frame),
      "the usage segment overflowed its window instead of stepping down a rung")
  }

  /// The detail popover, which had no coverage at all before issue #168 — its identifier had zero
  /// references outside its own definition. It matters more now: the shared `QuotaBar` renders in
  /// both places, and with the footer showing bars alone this popover is where the numbers live.
  func testClickingUsageOpensTheDetailPopover() {
    let app = launchedApp(agent: "codex")
    let usage = app.descendants(matching: .any)["terminal.statusBar.agentUsage"]
    XCTAssertTrue(usage.waitForExistence(timeout: 15))
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

    // A second click unpins it, which is the documented dismissal alongside clicking away.
    usage.click()
    XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
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
