import XCTest

/// Isolation tripwires, extracted so they stay in the ROUTINE `make app-uitest` sweep even though
/// `AgentResumeUITests`/`SessionRestoreUITests` (their original homes) are skipped by default via
/// `APP_UITEST_FLAGS` (see the `Makefile`).
///
/// Both guard a production no-op-unless-seeded rule that the REST of the UI suite silently depends
/// on: without it, every other test would read or write the developer's own `~/.claude`/session
/// file. If a future change breaks either guard, this file is what still catches it in the default
/// sweep — the two full test classes these came from no longer run there.
final class AgentSessionIsolationTripwireUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  // MARK: `AgentResumeUITests.testWithNoSeededRootDiscoveryIsANoOp`

  private var agentRoot: URL!

  private func launchedAppWithNoAgentRoot(sessionFile: URL) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestSessionFile", sessionFile.path]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func resumeButton(_ app: XCUIApplication, _ agent: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "terminal.statusBar.resume.\(agent)")
      .firstMatch
  }

  private func paneCwd(_ app: XCUIApplication) -> String {
    let segment = app.descendants(matching: .any)
      .matching(identifier: "terminal.statusBar.cwd").firstMatch
    XCTAssertTrue(
      segment.waitForExistence(timeout: 60),
      "the pane's status bar should report a cwd once the shell reports one")
    let prefix = "Working directory "
    XCTAssertTrue(segment.label.hasPrefix(prefix), "unexpected cwd label: \(segment.label)")
    return String(segment.label.dropFirst(prefix.count))
  }

  private func quitAndWaitForSave(_ app: XCUIApplication, sessionFile: URL) {
    app.terminate()
    let exists = NSPredicate { _, _ in
      guard
        let size = try? FileManager.default.attributesOfItem(atPath: sessionFile.path)[.size]
          as? Int
      else { return false }
      return size > 0
    }
    _ = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: exists, object: nil)], timeout: 10)
  }

  private func claudeSlug(for path: String) -> String {
    String(path.map { $0 == "/" || $0 == "." ? "-" : $0 })
  }

  private func seedClaude(cwd: String) throws {
    let url = agentRoot.appendingPathComponent(
      ".claude/projects/\(claudeSlug(for: cwd))/session.jsonl")
    let lines = [
      #"{"leafUuid":"abc","sessionId":"s1","type":"summary"}"#,
      #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user"}}"#,
    ]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  /// **The default-off rule.** With no seeded root, discovery does nothing at all — which is what
  /// stops every other UI test reading the developer's real `~/.claude`.
  func testWithNoSeededRootDiscoveryIsANoOp() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "workroom-uitest-resume-tripwire-\(UUID().uuidString)", isDirectory: true)
    let sessionFile = base.appendingPathComponent("session.json")
    agentRoot = base.appendingPathComponent("home", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let first = launchedAppWithNoAgentRoot(sessionFile: sessionFile)
    XCTAssertTrue(panes(first).firstMatch.waitForExistence(timeout: 20))
    let cwd = paneCwd(first)
    quitAndWaitForSave(first, sessionFile: sessionFile)
    try seedClaude(cwd: cwd)

    let app = launchedAppWithNoAgentRoot(sessionFile: sessionFile)
    XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 20))
    _ = paneCwd(app)
    XCTAssertFalse(
      resumeButton(app, "claude").exists, "no seeded root means discovery never runs")
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
