import XCTest

/// Isolation tripwire, extracted so it stays in the ROUTINE `make app-uitest` sweep even though
/// `SessionRestoreUITests` (its original home) is skipped by default via `APP_UITEST_FLAGS` (see
/// the `Makefile`).
///
/// Guards a production no-op-unless-seeded rule that the REST of the UI suite silently depends on:
/// without it, every other test would read or write the developer's own session file. If a future
/// change breaks this guard, this file is what still catches it in the default sweep — the full
/// test class this came from no longer runs there.
final class AgentSessionIsolationTripwireUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  // MARK: `SessionRestoreUITests.testWithoutASessionPathNothingIsWritten`

  private func launchedAppWithNoSessionFile() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    return app
  }

  private func waitForFirstPane(_ app: XCUIApplication) {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      panes(app).firstMatch.waitForExistence(timeout: 10),
      "the fixture workroom should render a terminal pane on launch")
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 8) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// Proves the fixture seam isolates every other UI test: with no session path, the app writes
  /// nothing at all — so the 30-odd existing tests cannot touch the developer's own session.
  func testWithoutASessionPathNothingIsWritten() throws {
    let sessionFile = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "workroom-uitest-session-tripwire-\(UUID().uuidString)", isDirectory: true
      )
      .appendingPathComponent("session.json")
    defer { try? FileManager.default.removeItem(at: sessionFile.deletingLastPathComponent()) }

    let app = launchedAppWithNoSessionFile()
    waitForFirstPane(app)
    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    app.terminate()

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: sessionFile.path),
      "fixture mode must not write a session unless a test asked for one")
  }
}
