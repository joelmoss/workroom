import XCTest

/// UI tests for the Pull Request section's unusable-`gh` warning.
///
/// Until now nothing — unit test or UI test — touched this copy, and it was a chain of
/// `status == .notInstalled` ternaries, so every state that wasn't "not found" printed "not signed
/// in". A version problem would have inherited a sign-in message that cannot fix it.
/// `PullRequestPanelCopyTests` pins the mapping; this pins that the panel actually renders the right
/// one, through the real gate in `PullRequestPanel.body`.
///
/// Driven by the `-WorkroomUITestGHStatus` seam, which had to be added: `refreshGitHubCLI` returns
/// immediately in fixture mode — it must, or a UI test would ask `gh` about the developer's own
/// machine — so before this there was no way to reach any warning state from a test.
///
/// Asserted on ACCESSIBILITY IDENTIFIERS, not text. Measured: every `staticTexts` element in this
/// inspector's tree reports `label == ""`, so a label-matching test can see that *some* warning exists
/// but never which one — useless for the bug in question. `pr.ghWarning.<state>` makes the state
/// itself observable.
///
/// Run with `make app-uitest` on a real GUI login session, or scoped:
/// `xcodebuild ... -only-testing:WorkroomAppUITests/PullRequestWarningUITests/<method>`.
final class PullRequestWarningUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp(ghStatus: String?) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    if let ghStatus { app.launchArguments += ["-WorkroomUITestGHStatus", ghStatus] }
    app.launch()
    app.activate()
    return app
  }

  private func warning(_ app: XCUIApplication, _ state: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "pr.ghWarning.\(state)").firstMatch
  }

  private func prSectionHeader(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "inspector.header.Pull Request").firstMatch
  }

  /// Bring the Pull Request section into view.
  ///
  /// The section is collapsible (`⌥⌘P`, bound to `store.prSectionCollapsed`) and its collapsed state
  /// PERSISTS across launches through Defaults, so this must not assume either state. Clicking the
  /// header rather than sending the shortcut: a focused terminal swallows key equivalents, and
  /// synthetic keystrokes are the least reliable way to drive this app.
  private func revealPullRequestSection(_ app: XCUIApplication, expecting state: String) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let header = prSectionHeader(app)
    XCTAssertTrue(
      header.waitForExistence(timeout: 10), "the Pull Request inspector section should exist")
    if !warning(app, state).waitForExistence(timeout: 3), header.isHittable {
      header.click()
    }
  }

  /// An old gh must say so, and must NOT offer the "Install gh…" link — it is already installed, and
  /// the link buries the one-line upgrade that actually fixes it.
  func testTooOldRendersAnUpgradeWarningWithoutTheInstallLink() throws {
    let app = launchedApp(ghStatus: "tooOld")
    revealPullRequestSection(app, expecting: "tooOld")

    XCTAssertTrue(
      warning(app, "tooOld").waitForExistence(timeout: 10),
      "the tooOld state should render its own warning, not the sign-in one")
    XCTAssertFalse(
      warning(app, "notAuthenticated").exists, "an old gh was described as a sign-in problem")
    XCTAssertFalse(
      warning(app, "installLink").exists, "gh is installed — the install link misdirects")
  }

  /// The state the reported bug produced falsely. Seeded here it SHOULD appear.
  func testNotAuthenticatedRendersTheSignInWarning() throws {
    let app = launchedApp(ghStatus: "notAuthenticated")
    revealPullRequestSection(app, expecting: "notAuthenticated")

    XCTAssertTrue(
      warning(app, "notAuthenticated").waitForExistence(timeout: 10),
      "a genuinely signed-out gh should still warn")
    XCTAssertFalse(warning(app, "tooOld").exists)
    XCTAssertFalse(warning(app, "installLink").exists)
  }

  /// Missing gh is the one state where a download link is the fix.
  func testNotInstalledRendersTheInstallLink() throws {
    let app = launchedApp(ghStatus: "notInstalled")
    revealPullRequestSection(app, expecting: "notInstalled")

    XCTAssertTrue(
      warning(app, "notInstalled").waitForExistence(timeout: 10), "a missing gh should say so")
    XCTAssertTrue(
      warning(app, "installLink").waitForExistence(timeout: 4),
      "the install link is the fix for a missing gh")
  }

  /// The default fixture launch (no seam argument) must warn about NOTHING — the optimistic
  /// `.available` default plus a fixture that never probes should leave the panel quiet. This is the
  /// reported bug's shape at the UI layer: a warning appearing when nothing is actually wrong.
  func testNoWarningWhenGHStatusIsNotSeeded() throws {
    let app = launchedApp(ghStatus: nil)
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(prSectionHeader(app).waitForExistence(timeout: 10))

    for state in ["notInstalled", "notAuthenticated", "tooOld"] {
      XCTAssertFalse(warning(app, state).exists, "warned about \(state) with nothing wrong")
    }
  }
}
