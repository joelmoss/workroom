import XCTest

/// End-to-end session restore (issue #46): quit, relaunch, and assert the panes came back.
///
/// This is the layer that proves the whole chain — the save actually reaching disk on quit, and the
/// restore landing before `ensureInitialTerminal` can add a stray terminal. No unit test can cover
/// that ordering, because the race is between a write on the quit path and a SwiftUI view `.task`.
///
/// Each test drives its own session file via `-WorkroomUITestSessionFile`. **In fixture mode the
/// session store is a no-op unless that path is given** — without it, every one of the other UI tests
/// would write over the developer's own `Workroom Dev` session, and the fixture's temp-directory
/// workrooms would then be restored into a real launch.
///
/// Run on a GUI login session: `make app-uitest`, or scoped via `xcodebuild -only-testing`.
final class SessionRestoreUITests: XCTestCase {
  private var sessionFile: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    sessionFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-uitest-session-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("session.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: sessionFile.deletingLastPathComponent())
  }

  private func launchedApp(withSessionFile: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    if withSessionFile {
      app.launchArguments += ["-WorkroomUITestSessionFile", sessionFile.path]
    }
    // Ignore AppKit's own persisted window state, so what comes back is ours and only ours.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func tabs(_ app: XCUIApplication) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 8) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  private func waitForFirstPane(_ app: XCUIApplication) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      panes(app).firstMatch.waitForExistence(timeout: 10),
      "the fixture workroom should render a terminal pane on launch")
  }

  /// Quit, then wait for the session file rather than for `terminate()`'s timing.
  ///
  /// `XCUIApplication.terminate()` signals the app and force-kills it if it lingers, so asserting on
  /// the artefact is what makes this deterministic — the alternative is trusting that the SIGTERM
  /// handler finished, which is exactly the sort of assumption that produces a flaky suite.
  private func quitAndWaitForSave(_ app: XCUIApplication) {
    app.terminate()
    let exists = NSPredicate { [sessionFile] _, _ in
      guard let sessionFile,
        let size = try? FileManager.default.attributesOfItem(atPath: sessionFile.path)[.size]
          as? Int
      else { return false }
      return size > 0
    }
    let exp = XCTNSPredicateExpectation(predicate: exists, object: nil)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: 10), .completed,
      "quitting should have written the session to \(sessionFile.path)")
  }

  // MARK: Restore

  /// The headline: a split survives a relaunch with no ⌘D.
  func testSplitSurvivesRelaunch() throws {
    let app = launchedApp()
    waitForFirstPane(app)
    assertCount(panes(app), reaches: 1)

    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    quitAndWaitForSave(app)

    let relaunched = launchedApp()
    XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 10))
    assertCount(panes(relaunched), reaches: 2)
  }

  /// The stray-terminal regression: the restored strip must hold exactly what was saved, with nothing
  /// added by `ensureInitialTerminal` racing the restore.
  func testTabCountSurvivesRelaunchWithNoStrayTerminal() throws {
    let app = launchedApp()
    waitForFirstPane(app)
    assertCount(tabs(app), reaches: 1)

    app.typeKey("t", modifierFlags: .command)
    app.typeKey("t", modifierFlags: .command)
    assertCount(tabs(app), reaches: 3)
    quitAndWaitForSave(app)

    let relaunched = launchedApp()
    XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 10))
    assertCount(tabs(relaunched), reaches: 3)
  }

  // MARK: Multi-window

  /// Poll the window count, which settles asynchronously.
  private func waitForWindowCount(_ app: XCUIApplication, _ target: Int, timeout: TimeInterval = 10)
    -> Bool
  {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", target), object: app.windows)
    return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
  }

  /// New Window is **menu-only** — ⌘N belongs to New Workroom (issue #81), so typing it here would
  /// open a dialog instead of a window.
  private func openSecondWindow(_ app: XCUIApplication) {
    app.menuBars.menuBarItems["File"].menuItems["New Window"].click()
  }

  /// Every window that was open at quit comes back. The one assertion covering the whole multi-window
  /// chain end to end: claiming by key, the sibling fan-out, and the save gate that stops the launch
  /// window overwriting the file before its siblings exist.
  func testEveryWindowSurvivesRelaunch() throws {
    let app = launchedApp()
    waitForFirstPane(app)
    let before = app.windows.count

    openSecondWindow(app)
    XCTAssertTrue(
      waitForWindowCount(app, before + 1), "File ▸ New Window should add exactly one window")
    quitAndWaitForSave(app)

    let relaunched = launchedApp()
    XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 10))
    waitForFirstPane(relaunched)
    XCTAssertTrue(
      waitForWindowCount(relaunched, before + 1),
      "both windows should be reopened from the saved session, without a second ⌘N")
  }

  /// **CRITICAL REGRESSION.** A restored sibling window comes back with its panes VISIBLE.
  ///
  /// `testEveryWindowSurvivesRelaunch` asserts only the window count, and that is exactly how this
  /// shipped broken: `bootstrap` gates on an app-wide one-shot the launch window consumes, so every
  /// sibling cleared the selection its own session had just supplied. The panes were restored into
  /// `TerminalSessions` and then rendered by nothing — window 2 came back empty.
  ///
  /// The second window is made by duplicating what the app itself wrote, rather than by driving the
  /// sidebar: it needs a window with a real selection, and the app's own ids are the only ones
  /// guaranteed to resolve.
  func testARestoredSiblingWindowShowsItsPanes() throws {
    let app = launchedApp()
    waitForFirstPane(app)
    assertCount(panes(app), reaches: 1)
    quitAndWaitForSave(app)

    // Duplicate window 0 under a fresh key, so the next launch has two windows to restore.
    let data = try Data(contentsOf: sessionFile)
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    var windows = try XCTUnwrap(document["windows"] as? [[String: Any]])
    var sibling = try XCTUnwrap(windows.first)
    XCTAssertNotNil(
      sibling["selectedTargetID"], "the saved window must carry a selection to restore")
    sibling["windowKey"] = UUID().uuidString
    sibling["isKey"] = false
    windows.append(sibling)
    document["windows"] = windows
    try JSONSerialization.data(withJSONObject: document).write(to: sessionFile)

    let relaunched = launchedApp()
    XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(waitForWindowCount(relaunched, 2), "both saved windows should reopen")
    // Two panes across two windows: the sibling must RENDER its restored pane, not open blank.
    assertCount(panes(relaunched), reaches: 2)
  }

  // MARK: Scrollback (issue #144)

  /// The headline for #144: what you were reading is still there after a relaunch, above a divider.
  ///
  /// Asserted through the session directory rather than the terminal's a11y tree — the libghostty
  /// Metal surface contributes no text to it, which is why every other terminal assertion in this
  /// suite counts panes and chips instead of reading content.
  func testScrollbackIsCapturedOnQuitAndReplayed() throws {
    let app = launchedApp()
    waitForFirstPane(app)

    let marker = "SCROLLBACK-UITEST-\(UUID().uuidString.prefix(8))"
    app.typeText("echo \(marker)\n")
    // Let the command run and the output render before quitting.
    _ = XCTWaiter().wait(for: [expectation(description: "settle")], timeout: 3)
    quitAndWaitForSave(app)

    let scrollbackDir = sessionFile.deletingLastPathComponent()
      .appendingPathComponent("scrollback")
    let sidecars =
      (try? FileManager.default.contentsOfDirectory(
        at: scrollbackDir, includingPropertiesForKeys: nil))
      ?? []
    XCTAssertFalse(sidecars.isEmpty, "quitting should have written a scrollback sidecar")

    let captured = sidecars.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    XCTAssertTrue(
      captured.contains { $0.contains(marker) },
      "the pane's output should be in its sidecar")

    // Relaunching must consume it without crashing, and leave exactly the restored pane.
    let relaunched = launchedApp()
    XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 10))
    waitForFirstPane(relaunched)
    assertCount(panes(relaunched), reaches: 1)
  }

  /// A corrupt sidecar must cost the history, never the launch.
  func testCorruptScrollbackSidecarStillLaunches() throws {
    let app = launchedApp()
    waitForFirstPane(app)
    quitAndWaitForSave(app)

    let scrollbackDir = sessionFile.deletingLastPathComponent()
      .appendingPathComponent("scrollback")
    try FileManager.default.createDirectory(at: scrollbackDir, withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0xFF]).write(to: scrollbackDir.appendingPathComponent("garbage.txt"))

    let relaunched = launchedApp()
    XCTAssertTrue(relaunched.wait(for: .runningForeground, timeout: 10))
    waitForFirstPane(relaunched)
    assertCount(panes(relaunched), reaches: 1)
  }

  // MARK: Degradation

  /// Corrupt input on the launch path must never cost more than the restore itself.
  func testCorruptSessionFileStillLaunchesCleanly() throws {
    try FileManager.default.createDirectory(
      at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("this is not json".utf8).write(to: sessionFile)

    let app = launchedApp()
    waitForFirstPane(app)
    assertCount(panes(app), reaches: 1)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: sessionFile.deletingLastPathComponent()
          .appendingPathComponent("session.corrupt.json").path),
      "the unreadable file should be quarantined, not silently deleted")
  }

  /// The fresh-install path is unchanged: one workroom, one terminal.
  func testNoSessionFileOpensExactlyOneTerminal() throws {
    let app = launchedApp()
    waitForFirstPane(app)
    assertCount(panes(app), reaches: 1)
    assertCount(tabs(app), reaches: 1)
  }

  // `testWithoutASessionPathNothingIsWritten` moved to
  // `AgentSessionIsolationTripwireUITests.swift` — it's an isolation tripwire the routine sweep
  // must keep running even though this file is skipped by default via `APP_UITEST_FLAGS`.
}
