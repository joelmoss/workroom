import XCTest

/// End-to-end resume offers for restored panes (issue #145).
///
/// The chain no unit test reaches: a real restore produces a real pane, a real filesystem scan finds
/// a seeded conversation, the button appears, and clicking it puts a command into a live shell **and
/// submits it**.
///
/// Two isolation rules, both load-bearing:
///
/// - `-WorkroomUITestAgentSessionRoot` points discovery at a throwaway `$HOME`. **Without it,
///   discovery is a no-op in fixture mode** — otherwise these tests, and the 30-odd others, would
///   read the developer's real `~/.claude` and pass or fail depending on which directories they had
///   talked to an agent in that day.
/// - Every seeded conversation is a file, never a process. Nothing here runs a real agent, and the
///   one test that clicks Resume asserts on the terminal's own output rather than on an agent
///   starting — an agent session costs money.
///
/// Run on a GUI login session: `make app-uitest`, or scoped via `xcodebuild -only-testing`.
final class AgentResumeUITests: XCTestCase {
  private var sessionFile: URL!
  private var agentRoot: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("workroom-uitest-resume-\(UUID().uuidString)", isDirectory: true)
    sessionFile = base.appendingPathComponent("session.json")
    agentRoot = base.appendingPathComponent("home", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: sessionFile.deletingLastPathComponent())
  }

  // MARK: Launching

  private func launchedApp(withAgentRoot: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestSessionFile", sessionFile.path]
    if withAgentRoot {
      app.launchArguments += ["-WorkroomUITestAgentSessionRoot", agentRoot.path]
    }
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

  /// The pane's real working directory, read off the status bar's accessibility label. The fixture
  /// workroom lives under the app's own temp directory, so asking the app beats reconstructing it.
  private func paneCwd(_ app: XCUIApplication) -> String {
    let segment = app.descendants(matching: .any)
      .matching(identifier: "terminal.statusBar.cwd").firstMatch
    // Generous: the cwd only appears once the shell has reported it via OSC 7, and the FIRST launch
    // of a run pays for the app's cold start on top of that.
    XCTAssertTrue(
      segment.waitForExistence(timeout: 60),
      "the pane's status bar should report a cwd once the shell reports one")
    let prefix = "Working directory "
    XCTAssertTrue(segment.label.hasPrefix(prefix), "unexpected cwd label: \(segment.label)")
    return String(segment.label.dropFirst(prefix.count))
  }

  /// Quit, then wait for the artefact rather than trusting `terminate()`'s timing.
  private func quitAndWaitForSave(_ app: XCUIApplication) {
    app.terminate()
    let exists = NSPredicate { [sessionFile] _, _ in
      guard let sessionFile,
        let size = try? FileManager.default.attributesOfItem(atPath: sessionFile.path)[.size]
          as? Int
      else { return false }
      return size > 0
    }
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: exists, object: nil)], timeout: 10),
      .completed, "quitting should have written the session")
  }

  // MARK: Seeding

  /// Claude's slug, as the app hints it: `/` and `.` both become `-`.
  private func claudeSlug(for path: String) -> String {
    String(path.map { $0 == "/" || $0 == "." ? "-" : $0 })
  }

  /// A transcript whose FIRST line is the `{leafUuid, sessionId, type}` summary that carries no cwd —
  /// the shape the real store writes, and the reason extraction has to scan forward.
  private func seedClaude(cwd: String) throws {
    let url = agentRoot.appendingPathComponent(
      ".claude/projects/\(claudeSlug(for: cwd))/session.jsonl")
    let lines = [
      #"{"leafUuid":"abc","sessionId":"s1","type":"summary"}"#,
      #"{"type":"user","cwd":"\#(cwd)","message":{"role":"user"}}"#,
    ]
    try write(lines, to: url)
  }

  private func seedCodex(cwd: String) throws {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd"
    let day = formatter.string(from: Date())
    let url = agentRoot.appendingPathComponent(".codex/sessions/\(day)/rollout-a.jsonl")
    try write(
      [#"{"type":"session_meta","timestamp":"t","payload":{"cwd":"\#(cwd)","id":"x"}}"#], to: url)
  }

  private func write(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  /// Run once, quit, and come back with `seed` applied to the pane's own directory.
  ///
  /// The seed has to happen between the runs: discovery fires during the restore, so a conversation
  /// written afterwards would be looked for before it existed.
  private func relaunchRestored(seeding seed: (String) throws -> Void) throws -> XCUIApplication {
    let first = launchedApp()
    XCTAssertTrue(panes(first).firstMatch.waitForExistence(timeout: 20))
    let cwd = paneCwd(first)
    quitAndWaitForSave(first)

    try seed(cwd)
    return launchedApp()
  }

  // MARK: The offer

  func testARestoredPaneWithClaudeHistoryOffersResume() throws {
    let app = try relaunchRestored(seeding: seedClaude)

    XCTAssertTrue(
      resumeButton(app, "claude").waitForExistence(timeout: 25),
      "a restored pane whose directory has recent Claude history offers Resume Claude")
    XCTAssertFalse(resumeButton(app, "codex").exists, "Codex was not seeded")
  }

  func testARestoredPaneWithCodexHistoryOffersResume() throws {
    let app = try relaunchRestored(seeding: seedCodex)

    XCTAssertTrue(resumeButton(app, "codex").waitForExistence(timeout: 25))
    XCTAssertFalse(resumeButton(app, "claude").exists, "Claude was not seeded")
  }

  /// Both qualifying yields BOTH actions. One button cannot pick for you: the app has no way to know
  /// which agent a pane was running, and guessing is the failure this design exists to avoid.
  func testBothAgentsQualifyingOffersTwoIndependentActions() throws {
    let app = try relaunchRestored { cwd in
      try seedClaude(cwd: cwd)
      try seedCodex(cwd: cwd)
    }

    XCTAssertTrue(resumeButton(app, "claude").waitForExistence(timeout: 25))
    XCTAssertTrue(resumeButton(app, "codex").waitForExistence(timeout: 10))
  }

  func testARestoredPaneWithNoHistoryOffersNothing() throws {
    let app = try relaunchRestored { _ in }

    XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 20))
    _ = paneCwd(app)  // the status bar has rendered, so an offer would have had time to appear
    XCTAssertFalse(resumeButton(app, "claude").exists)
    XCTAssertFalse(resumeButton(app, "codex").exists)
  }

  /// **The default-off rule.** With no seeded root, discovery does nothing at all — which is what
  /// stops every other UI test reading the developer's real `~/.claude`.
  func testWithNoSeededRootDiscoveryIsANoOp() throws {
    let first = launchedApp(withAgentRoot: false)
    XCTAssertTrue(panes(first).firstMatch.waitForExistence(timeout: 20))
    let cwd = paneCwd(first)
    quitAndWaitForSave(first)
    try seedClaude(cwd: cwd)

    let app = launchedApp(withAgentRoot: false)
    XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 20))
    _ = paneCwd(app)
    XCTAssertFalse(
      resumeButton(app, "claude").exists, "no seeded root means discovery never runs")
  }

  // MARK: Acting on it

  /// **The behaviour the whole feature is.** Clicking types the picker command into the pane AND
  /// submits it, and the button is spent.
  ///
  /// Submission is asserted through the fixture-only accessibility value on the surface, because a
  /// libghostty pane renders through Metal and is otherwise invisible to XCUITest. The check is that
  /// the terminal moved PAST the line the command was typed on: if `\r` were filtered out of the text
  /// path the command would sit on the input line forever, typed and never run — a silent failure
  /// with no unit test able to see it, since the behaviour belongs to the engine.
  func testClickingResumeTypesAndSubmitsTheCommandExactlyOnce() throws {
    let app = try relaunchRestored(seeding: seedClaude)
    let button = resumeButton(app, "claude")
    XCTAssertTrue(button.waitForExistence(timeout: 25))

    button.click()

    let surface = app.descendants(matching: .any).matching(identifier: "terminal.surface")
      .firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 10))

    // Submitted means the shell moved PAST the line the command was typed on — so there is
    // non-whitespace content after it, whether that is the agent's own UI or a `command not found`
    // from a machine with no `claude` installed. Typed-but-not-submitted is the case that leaves the
    // command sitting alone at the end of the prompt line.
    //
    // Polled by hand rather than through `XCTNSPredicateExpectation`: that re-evaluates against a
    // cached element snapshot and never observed the surface's value changing here, which cost a
    // debugging round trip on a test whose subject was already working.
    var screen = ""
    let deadline = Date().addingTimeInterval(30)
    var submitted = false
    while Date() < deadline, !submitted {
      screen = (surface.value as? String) ?? ""
      if let range = screen.range(of: "claude --resume") {
        submitted = !screen[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      }
      if !submitted { usleep(250_000) }
    }

    XCTAssertTrue(
      submitted,
      """
      the command should have been typed AND submitted, but nothing followed it on screen — \
      libghostty drops `\\r` from the TEXT path, so Return must go through `ghostty_surface_key`. \
      Screen was:
      \(screen)
      """)

    // Spent: `consume` removes the offer before returning the command, so a second click cannot
    // start a second (billed) agent session.
    XCTAssertFalse(button.exists, "the offer is consumed by the click")
  }

  /// **REGRESSION.** Discovery is async, so an offer can land after the user has started typing.
  /// Appending the command to a half-typed line would run something nobody asked for, so the first
  /// keystroke drops the offer.
  func testTypingInThePaneRemovesTheOffer() throws {
    let app = try relaunchRestored(seeding: seedClaude)
    let button = resumeButton(app, "claude")
    XCTAssertTrue(button.waitForExistence(timeout: 25))

    panes(app).firstMatch.click()
    app.typeText("ec")

    let gone = NSPredicate(format: "exists == false")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: gone, object: button)], timeout: 10),
      .completed, "a pane that is no longer pristine must not be typed into")
  }
}
