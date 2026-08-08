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

  /// Proves the fixture seam isolates every other UI test: with no session path, the app writes
  /// nothing at all — so the 30-odd existing tests cannot touch the developer's own session.
  func testWithoutASessionPathNothingIsWritten() throws {
    let app = launchedApp(withSessionFile: false)
    waitForFirstPane(app)
    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    app.terminate()

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: sessionFile.path),
      "fixture mode must not write a session unless a test asked for one")
  }
}
