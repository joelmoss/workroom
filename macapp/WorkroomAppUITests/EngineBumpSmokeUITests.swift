import XCTest

/// The automatable part of `QA-libghostty.md` §N, "Engine bump smoke": run this class on the current
/// libghostty pin, bump, and run it again. Most of §N has no absolute right answer, only "the same as
/// before the bump", so a failure here after a bump that passed before it is the signal.
///
///     make app-uitest-vm APP_UITEST_FLAGS="-only-testing:WorkroomAppUITests/EngineBumpSmokeUITests"
///
/// The RSS and leak figures are printed as `EngineBumpSmoke:` lines in the test log, so the two runs
/// can be compared; only the leak check asserts on them.
///
/// **How a test reads what the app's process does.** The runner cannot spawn `ps`, `kill` or `leaks`
/// (`GhosttyOrphanShellUITests` measured it), and it can read `/tmp` but not create anything there
/// (measured on the first run of this class). A pane's shell can do both. So a pane runs
/// `testdata/engine-bump-smoke/engine-bump-smoke.sh`, copied into this bundle, and it leaves its
/// answers in a `/tmp` folder of the test's own that the runner reads. The script finds the app by
/// walking up from the pane's shell to the first ancestor whose executable is named Workroom.
/// Those folders stay behind: the runner cannot delete them, and a VM guest is thrown away anyway.
///
/// Typing rules from the neighbouring terminal tests apply: no `:` in typed text (XCUITest sends it as
/// a garbled escape), and the Return goes in its own `typeText` call after shifted punctuation.
///
/// Left to the manual checklist: the scrollbar overlay, ⌘-clicking a relative path, ssh, the shell
/// matrix, the busy indicator's animation (its state is checked here, not
/// how it looks), and which screen row a Find Next lands on (the counter is checked here, the
/// highlight's position is not).
final class EngineBumpSmokeUITests: XCTestCase {
  /// The test's `/tmp` folder, made by the pane on the first `helper` call.
  private var scratch = ""
  private var scratchReady = false

  override func setUpWithError() throws {
    continueAfterFailure = false
    scratch = "/tmp/wr-qa-\(UUID().uuidString.prefix(8))"
    scratchReady = false
  }

  // MARK: IO layer

  /// Open and close twenty terminals in one workroom: no crash, no hang, and the last pane still runs
  /// commands. RSS before and after is logged for comparison across bumps.
  func testSurfaceChurnKeepsTheAppUp() throws {
    let app = launchedApp()
    focusTerminal(app)
    let before = try appRSS(app, "churn-before")
    for round in 1...20 {
      app.typeKey("t", modifierFlags: .command)
      assertCount(tabs(app), reaches: 2, "round \(round): ⌘T opened a second terminal")
      // Long enough for the new tab's surface to be created, which is what this churns.
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      app.typeKey("w", modifierFlags: .command)
      assertCount(tabs(app), reaches: 1, "round \(round): ⌘W closed it")
    }
    XCTAssertEqual(app.state, .runningForeground, "the app survived the churn")
    focusTerminal(app)
    let after = try appRSS(app, "churn-after")
    log("surface churn RSS KB before=\(before) after=\(after) delta=\(after - before)")
    assertAnswers(app)
  }

  /// Split and close, ten times, alternating Split Right and Split Down and alternating which pane is
  /// closed: the survivor stays mounted at the full pane size, never blank or shrunk.
  func testSplitChurnKeepsTheSurvivorFullSize() {
    let app = launchedApp()
    focusTerminal(app)
    let full = panes(app).firstMatch.frame
    XCTAssertFalse(full.isEmpty, "the fixture pane has a frame")
    for round in 1...10 {
      let down = round.isMultiple(of: 2)
      app.typeKey("d", modifierFlags: down ? [.command, .shift] : .command)
      assertCount(panes(app), reaches: 2, "round \(round): the split opened")
      if round % 4 >= 2 {
        // Focus the original pane, so ⌘W closes it and the new one survives.
        tabs(app).element(boundBy: 0).click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      }
      app.typeKey("w", modifierFlags: .command)
      assertCount(panes(app), reaches: 1, "round \(round): the split closed")
      let survivor = panes(app).firstMatch.frame
      XCTAssertEqual(survivor.width, full.width, accuracy: 2, "round \(round): survivor width")
      XCTAssertEqual(survivor.height, full.height, accuracy: 2, "round \(round): survivor height")
    }
    focusTerminal(app)
    assertAnswers(app)
  }

  /// Cycle three workrooms ten times: each comes back to its own live pane, never another's content.
  func testWorkroomSwitchReturnsEachWorkroomsOwnPane() {
    let app = launchedApp(["-WorkroomUITestWorkroomCount", "3"])
    let names = ["uitest-room", "uitest-room-2", "uitest-room-3"]
    for (index, name) in names.enumerated() {
      select(app, workroom: name)
      focusTerminal(app)
      // `$((…))` so the marker is only in the output, never in the typed line.
      run(app, "echo WRSW$((10+\(index)))")
      XCTAssertTrue(
        waitForScreen(app, containing: "WRSW\(10 + index)").found, "\(name) answered its echo")
    }
    for round in 1...10 {
      for (index, name) in names.enumerated() {
        select(app, workroom: name)
        let result = waitForScreen(app, containing: "WRSW\(10 + index)", timeout: 10)
        XCTAssertTrue(
          result.found, "round \(round): \(name) lost its pane. Screen was:\n\(result.screen)")
        for other in names.indices where other != index {
          XCTAssertFalse(
            result.screen.contains("WRSW\(10 + other)"),
            "round \(round): \(name) shows \(names[other])'s content. Screen was:\n\(result.screen)"
          )
        }
      }
    }
  }

  /// Delete a workroom while one of its terminals runs a loop and another floods output: its panes
  /// tear down, their processes end, and the app and the other workroom carry on. Fixture workrooms
  /// are not registered with the CLI, so the teardown that follows fails and the workroom comes back
  /// (`AppStoreDeleteRaceTests.testFailedTeardownRestoresWorkroom`); the panes are reaped before it.
  func testDeletingAWorkroomWithLivePanesTearsThemDown() throws {
    let stamp = "\(scratch)/stamp"
    let marker = "qa_delete_\(UUID().uuidString.prefix(8))"
    let app = launchedApp(["-WorkroomUITestWorkroomCount", "2"])
    select(app, workroom: "uitest-room")
    focusTerminal(app)
    try prepareScratch(app)
    select(app, workroom: "uitest-room-2")
    focusTerminal(app)
    run(app, "exec -a \(marker) sh -c 'while true; do touch \(stamp); sleep 0.5; done'")
    XCTAssertTrue(pollUntilAdvancing(stamp), "setup: the stamper never started")
    app.typeKey("t", modifierFlags: .command)
    assertCount(tabs(app), reaches: 2, "⌘T opened a second terminal")
    focusTab(app, 1)
    run(app, "yes WRDELETE")
    RunLoop.current.run(until: Date().addingTimeInterval(1))

    clickMenu(app, "Room", "Delete Workroom…")
    let confirm = app.buttons["Delete"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the delete confirmation appeared")
    confirm.click()

    XCTAssertTrue(
      poll(timeout: 20) { !self.stampIsAdvancing(stamp, window: 1.5) },
      "\(marker) kept touching \(stamp): the deleted workroom's panes were not torn down")
    XCTAssertEqual(app.state, .runningForeground, "the app survived the delete")
    dismissErrorSheet(app)
    select(app, workroom: "uitest-room")
    focusTerminal(app)
    assertAnswers(app)
  }

  /// `GhosttyOrphanShellUITests` covers a normal quit. This is the force-quit: the app is killed with
  /// SIGKILL from its own second terminal, and the first terminal's process must still end.
  func testForceQuitLeavesNoOrphanedShell() throws {
    let stamp = "\(scratch)/stamp"
    let marker = "qa_orphan_kill_\(UUID().uuidString.prefix(8))"
    let app = launchedApp(["-WorkroomUITestTerminalTabs", "2"])
    focusTab(app, 0)
    try prepareScratch(app)
    run(app, "exec -a \(marker) sh -c 'while true; do touch \(stamp); sleep 0.5; done'")
    XCTAssertTrue(pollUntilAdvancing(stamp), "setup: the stamper never started")
    focusTab(app, 1)
    XCTAssertTrue(pollUntilAdvancing(stamp), "setup: the stamper stopped when its tab was hidden")
    try helper(app, "kill")
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "kill -9 ended the app")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    XCTAssertFalse(
      stampIsAdvancing(stamp, window: 2),
      "\(marker) kept touching \(stamp) after the app was killed: its shell was orphaned")
  }

  /// Quit with vim in one terminal and less in another: the app exits and macOS writes no crash
  /// report for it. A watcher started in the background before vim, so it outlives the app, checks
  /// `~/Library/Logs/DiagnosticReports` once the app's process is gone.
  ///
  /// §N names `top`; `testTopRuns` covers it on its own, and `less` keeps this test independent of
  /// the terminal type.
  func testQuitWithLiveTUIsExitsCleanly() throws {
    let result = "\(scratch)/quit-result"
    let app = launchedApp(["-WorkroomUITestTerminalTabs", "2"])
    focusTab(app, 0)
    try prepareScratch(app)
    run(app, "nohup sh '\(try helperPath())' crashwatch \(scratch) >/dev/null 2>&1 &")
    XCTAssertTrue(
      waitForFile("\(scratch)/quit-start") != nil, "setup: the crash watcher found the app")
    run(app, "vim")
    XCTAssertTrue(waitForScreen(app, containing: "Vi IMproved").found, "vim opened")
    focusTab(app, 1)
    run(app, "less /etc/shells")
    let less = waitForScreen(app, containing: "acceptable shells")
    XCTAssertTrue(less.found, "less opened. Screen was:\n\(less.screen)")

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "⌘Q ended the app")
    let verdict = waitForFile(result, timeout: 30)
    XCTAssertEqual(
      verdict, "clean", "quitting with TUIs open: \(verdict ?? "the watcher never reported")")
  }

  /// Start, let it fail, start again; then start, stop and start a long one: each start runs, the
  /// exit code still reads as a failure, and nothing says a server is already running.
  func testRunTabRestartsCleanly() {
    let app = launchedRunApp(runCommand: "sleep 2; exit 7")
    for attempt in 1...2 {
      clickMenu(app, "Room", "Run")
      XCTAssertTrue(waitForRunState(app, "running"), "attempt \(attempt): the run started")
      XCTAssertTrue(waitForRunState(app, "failed"), "attempt \(attempt): exit 7 reads as failed")
    }
    assertNoAlreadyRunning(app)
  }

  func testRunTabStopsAndStartsAgain() {
    let app = launchedRunApp(runCommand: "sleep 30")
    clickMenu(app, "Room", "Run")
    XCTAssertTrue(waitForRunState(app, "running"), "the run started")
    clickMenu(app, "Room", "Stop")
    XCTAssertTrue(waitForRunState(app, "stopped"), "Stop stopped it")
    clickMenu(app, "Room", "Run")
    XCTAssertTrue(waitForRunState(app, "running"), "it started again")
    clickMenu(app, "Room", "Restart")
    XCTAssertTrue(waitForRunState(app, "running", timeout: 20), "Restart left it running")
    assertNoAlreadyRunning(app)
  }

  /// Click and drag-select over a pane while `yes` floods its scrollback: no crash, and the pane
  /// answers afterwards. RSS before and after is logged.
  func testClickingDuringScrollbackOutputDoesNotCrash() throws {
    let app = launchedApp()
    focusTerminal(app)
    let before = try appRSS(app, "flood-before")
    run(app, "yes WRYES")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let surface = self.surface(app)
    for round in 0..<15 {
      let x = 0.2 + 0.6 * Double(round % 5) / 4
      let y = 0.2 + 0.6 * Double(round % 3) / 2
      surface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
      if round.isMultiple(of: 5) {
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3))
          .click(
            forDuration: 0.1,
            thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
      }
    }
    app.typeKey("c", modifierFlags: .control)
    XCTAssertEqual(app.state, .runningForeground, "the app survived clicks during output")
    let after = try appRSS(app, "flood-after")
    log("scrollback-click RSS KB before=\(before) after=\(after) delta=\(after - before)")
    assertAnswers(app)
  }

  /// Read the surface's text three hundred times through the accessibility path, which copies it out
  /// with `ghostty_surface_read_text` and releases it with `ghostty_surface_free_text`: `leaks` must
  /// not find the copies. A `free_text` that freed nothing would leak every read.
  func testReadingTheSurfaceTextDoesNotLeak() throws {
    let app = launchedApp()
    focusTerminal(app)
    run(app, "seq 1 200")
    XCTAssertTrue(waitForScreen(app, containing: "200").found, "the viewport filled")
    let before = try leakedBytes(app, "before")
    let surface = self.surface(app)
    var characters = 0
    for _ in 0..<300 { characters += ((surface.value as? String) ?? "").count }
    XCTAssertGreaterThan(characters, 300 * 100, "each read returned the viewport")
    let after = try leakedBytes(app, "after")
    log(
      "free_text leak bytes before=\(before) after=\(after) over 300 reads of \(characters) chars")
    XCTAssertLessThan(
      after - before, 64 * 1024,
      "300 surface reads leaked \(after - before) bytes: ghostty_surface_free_text frees nothing")
  }

  // MARK: Behaviour keyed to engine internals

  /// ⌘G walks the matches with a counter that counts up and wraps from the last to the first; ⇧⌘G
  /// counts down and wraps the other way. `TerminalSearch.navigationPlan` inverts the engine's
  /// direction and synthesizes the wrap, so if the engine's order or wrap changes this goes red.
  func testFindNextCountsUpAndWraps() {
    let app = launchedApp(["-WorkroomUITestSearchNeedle", "WRFIND"])
    focusTerminal(app)
    // `WRF""IND` so the typed line itself is not a match.
    run(app, "for i in 1 2 3 4 5; do echo WRF\"\"IND$i; done")
    XCTAssertTrue(waitForScreen(app, containing: "WRFIND5").found, "the matches are on screen")
    clickMenu(app, "Edit", "Find…")
    let summary = app.staticTexts.matching(identifier: "terminal.search.summary").firstMatch
    XCTAssertTrue(
      poll(timeout: 10) { self.matchPosition(summary)?.total == 5 },
      "the engine found the five matches; summary was \(summaryText(summary))")

    var positions: [Int] = []
    for _ in 0..<7 {
      let previous = summaryText(summary)
      clickMenu(app, "Edit", "Find Next")
      _ = poll(timeout: 5) { self.summaryText(summary) != previous }
      positions.append(matchPosition(summary)?.index ?? -1)
    }
    log("find next positions \(positions)")
    for (from, to) in zip(positions, positions.dropFirst()) {
      XCTAssertEqual(to, from % 5 + 1, "Find Next counts up and wraps 5 → 1: \(positions)")
    }

    var backwards: [Int] = [positions.last ?? -1]
    for _ in 0..<6 {
      let previous = summaryText(summary)
      clickMenu(app, "Edit", "Find Previous")
      _ = poll(timeout: 5) { self.summaryText(summary) != previous }
      backwards.append(matchPosition(summary)?.index ?? -1)
    }
    log("find previous positions \(backwards)")
    for (from, to) in zip(backwards, backwards.dropFirst()) {
      XCTAssertEqual(
        to, from == 1 ? 5 : from - 1, "Find Previous counts down and wraps: \(backwards)")
    }
  }

  /// Backspace erases exactly one character.
  func testBackspaceErasesOneCharacter() {
    let app = launchedApp()
    focusTerminal(app)
    app.typeText("echo WRBS")
    app.typeText("x")
    app.typeKey(.delete, modifierFlags: [])
    app.typeText("Q")
    app.typeText("\r")
    let result = waitForScreen(app, containing: "WRBSQ")
    let lines = screenLines(result.screen)
    XCTAssertTrue(lines.contains("WRBSQ"), "the echo printed WRBSQ. Screen was:\n\(result.screen)")
    XCTAssertFalse(
      result.screen.contains("WRBSx") || lines.contains("WRBQ"),
      "Backspace erased none or two characters. Screen was:\n\(result.screen)")
  }

  /// ⌃Tab reaches nothing in a TUI in a single-pane workroom: Ghostty's default `next_tab` binding
  /// consumes it and Workroom ignores that action (#555). `cat -v` would print any bytes it sent.
  func testCtrlTabSendsNothingToATUI() {
    let app = launchedApp()
    focusTerminal(app)
    run(app, "cat -v")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    app.typeKey("\t", modifierFlags: .control)
    app.typeText("WRCT")
    app.typeText("\r")
    let result = waitForScreen(app, containing: "WRCT")
    app.typeKey("c", modifierFlags: .control)
    XCTAssertTrue(result.found, "cat echoed the line. Screen was:\n\(result.screen)")
    XCTAssertFalse(
      result.screen.contains("^["),
      "⌃Tab reached the TUI as an escape sequence. Screen was:\n\(result.screen)")
  }

  // MARK: Resource contract

  /// OSC 133 still lands. Shell integration retitles the tab to a running command and back, and the
  /// end-of-command mark (133;D, `GHOSTTY_ACTION_COMMAND_FINISHED`) clears the busy state. The second
  /// command sets busy with OSC 9;4 and never clears it, so only 133;D can: the 30 s stale-progress
  /// timeout in `GhosttySurfaceView` falls after this test's deadline.
  func testShellIntegrationTracksAndEndsACommand() {
    let app = launchedApp()
    focusTerminal(app)
    run(app, "sleep 4")
    let titled = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab.sleep")).firstMatch
    XCTAssertTrue(titled.waitForExistence(timeout: 20), "the tab took the running command's title")
    XCTAssertTrue(poll(timeout: 20) { !titled.exists }, "the title moved on when it finished")

    let chip = anyTab(app)
    let typed = Date()
    run(app, #"printf '\033]9;4;1;50\007'; sleep 6"#)
    XCTAssertTrue(poll(timeout: 5) { (chip.value as? String) == "Busy" }, "OSC 9;4 marked it busy")
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    XCTAssertEqual(chip.value as? String, "Busy", "still busy while the command runs")
    XCTAssertTrue(
      poll(timeout: 20) { (chip.value as? String) == "Idle" },
      "the command's end (OSC 133;D) cleared the busy state; value is \(chip.value ?? "nil")")
    let elapsed = Date().timeIntervalSince(typed)
    log("busy cleared \(Int(elapsed)) s after the command was typed")
    XCTAssertLessThan(elapsed, 25, "cleared by the command's end, not the 30 s progress timeout")
  }

  /// bash's exit status reaches the app (#465). With Homebrew bash as the shell, a failing command
  /// raises the coding agent's diagnosis and a passing one clears it. Before ghostty#14250, bash's
  /// OSC 133;D reported 0 for every bash 4.4+ command, so nothing ever failed. macOS's `/bin/bash`
  /// (3.2) never loads the integration, so this needs Homebrew's: the VM base image has it
  /// (`docs/designs/parallel-workroom-testing.md`), and a Mac without it skips.
  func testBashExitStatusReachesTheApp() throws {
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/bash"),
      "needs Homebrew bash at /opt/homebrew/bin/bash (brew install bash)")
    let app = launchedApp([
      "-WorkroomUITestShell", "bash", "-WorkroomUITestCodingAgentStub", "1",
    ])
    focusTerminal(app)
    // `$((…))` so the marker is only in the output: bash 4+ (1), with Ghostty's integration loaded.
    run(app, "echo WRB$((2+3))-$((BASH_VERSINFO[0] >= 4))-$(type -t __ghostty_precmd)")
    let shell = waitForScreen(app, containing: "WRB5-")
    XCTAssertTrue(
      shell.screen.contains("WRB5-1-function"),
      "the pane runs Homebrew bash with Ghostty's integration. Screen was:\n\(shell.screen)")

    run(app, "( exit 7 )")
    let diagnosis = app.buttons["terminal.statusBar.diagnosis"]
    XCTAssertTrue(
      diagnosis.waitForExistence(timeout: 20),
      "exit 7 reached the app and raised the diagnosis: bash reported a non-zero status")
    run(app, "true")
    XCTAssertTrue(
      poll(timeout: 15) { !diagnosis.exists },
      "a passing command cleared the diagnosis: bash reported 0 for `true`")
  }

  /// `$TERM` is `xterm-256color` by default, and the bundled `xterm-ghostty` entry (from
  /// `Resources/ghostty`) still resolves for anyone who turns on Report terminal as Ghostty.
  func testTermIsXterm256ColorAndTheGhosttyEntryResolves() {
    let app = launchedApp()
    focusTerminal(app)
    run(app, "echo WRT-$TERM; infocmp xterm-ghostty >/dev/null; echo WRI-$?")
    let result = waitForScreen(app, containing: "WRI-0")
    XCTAssertTrue(
      result.screen.contains("WRT-xterm-256color"), "$TERM. Screen was:\n\(result.screen)")
    XCTAssertTrue(result.found, "infocmp xterm-ghostty failed. Screen was:\n\(result.screen)")
  }

  /// macOS's `top` runs. It is setuid root, so ncurses ignores `TERMINFO` and reads only the
  /// system's entries: with `TERM=xterm-ghostty` it stopped at "Error opening terminal".
  func testTopRuns() {
    let app = launchedApp()
    focusTerminal(app)
    run(app, "top")
    let result = waitForScreen(app, containing: "PID")
    XCTAssertTrue(result.found, "top did not start. Screen was:\n\(result.screen)")
    XCTAssertFalse(
      result.screen.contains("Error opening terminal"), "Screen was:\n\(result.screen)")
    app.typeText("q")
    assertAnswers(app)
  }

  // MARK: Helpers

  /// `engine-bump-smoke.sh` in this bundle (`macapp/project.yml` copies it in).
  private func helperPath() throws -> String {
    try XCTUnwrap(
      Bundle(for: Self.self).path(forResource: "engine-bump-smoke", ofType: "sh"),
      "engine-bump-smoke.sh is missing from the UI-test bundle (macapp/project.yml)")
  }

  /// Runs `engine-bump-smoke.sh <command> <scratch> <arguments…>` in the focused pane.
  private func helper(_ app: XCUIApplication, _ command: String, _ arguments: String...) throws {
    let line = ["sh", "'\(try helperPath())'", command, scratch] + arguments
    run(app, line.joined(separator: " "))
  }

  /// Has the focused pane make the test's `/tmp` folder, once.
  private func prepareScratch(_ app: XCUIApplication) throws {
    guard !scratchReady else { return }
    try helper(app, "init")
    XCTAssertEqual(waitForFile("\(scratch)/ready"), "ok", "the pane made \(scratch)")
    scratchReady = true
  }

  private func log(_ line: String) {
    print("EngineBumpSmoke: \(name) \(line)")
    let attachment = XCTAttachment(string: line)
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func launchedApp(_ arguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchArguments += arguments
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  private func launchedRunApp(runCommand: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestRunCommand", runCommand]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    _ = app.useScratchDaemon()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    XCTAssertTrue(app.buttons["runCommand.run"].waitForExistence(timeout: 15), "Run is available")
    return app
  }

  private func tabs(_ app: XCUIApplication) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  private func surfaces(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.surface")
  }

  private func surface(_ app: XCUIApplication) -> XCUIElement {
    surfaces(app).firstMatch
  }

  /// Click the tab chip, not the pane, or the surface never becomes first responder (see
  /// `GhosttyOrphanShellUITests.focusTerminal`).
  private func focusTerminal(_ app: XCUIApplication) {
    app.activate()
    XCTAssertTrue(tabs(app).firstMatch.waitForExistence(timeout: 20), "a terminal tab exists")
    tabs(app).firstMatch.click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  private func focusTab(_ app: XCUIApplication, _ index: Int) {
    app.activate()
    XCTAssertTrue(poll(timeout: 20) { self.tabs(app).count > index }, "tab \(index) exists")
    tabs(app).element(boundBy: index).click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  /// A workroom's chip; its identifier ends with `|<name>` (see `SplitPaneUITests.workroomChip`).
  private func select(_ app: XCUIApplication, workroom name: String) {
    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier ENDSWITH %@", "|\(name)")).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 10), "\(name) has a workroom chip")
    chip.click()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
  }

  /// The first terminal tab, whatever its title (it changes as commands run).
  private func anyTab(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab.")).firstMatch
  }

  /// Closes the error sheet a fixture workroom's failed teardown raises, if it comes up.
  private func dismissErrorSheet(_ app: XCUIApplication) {
    let sheet = app.sheets.firstMatch
    guard sheet.waitForExistence(timeout: 15) else { return }
    if sheet.buttons["OK"].exists {
      sheet.buttons["OK"].click()
    } else {
      sheet.buttons["Cancel"].click()
    }
    XCTAssertTrue(poll(timeout: 5) { !sheet.exists }, "the teardown error sheet closed")
  }

  /// Clicks `item` in the menu bar's `menu` (Room ▸ Run, Edit ▸ Find Next).
  private func clickMenu(_ app: XCUIApplication, _ menu: String, _ item: String) {
    app.menuBars.menuBarItems[menu].menuItems[item].click()
  }

  /// Types the line, then the Return in its own call (see `GhosttyOrphanShellUITests.run`).
  private func run(_ app: XCUIApplication, _ line: String) {
    app.typeText(line)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    app.typeText("\r")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
  }

  /// The focused pane still runs commands: an echo whose output is not in the typed line comes back.
  private func assertAnswers(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    run(app, "echo WRALIVE$((40+2))")
    let result = waitForScreen(app, containing: "WRALIVE42")
    XCTAssertTrue(
      result.found, "the pane stopped answering. Screen was:\n\(result.screen)", file: file,
      line: line)
  }

  private func waitForScreen(
    _ app: XCUIApplication, containing needle: String, timeout: TimeInterval = 30
  ) -> (found: Bool, screen: String) {
    let surface = self.surface(app)
    var screen = ""
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      screen = (surface.value as? String) ?? ""
      if screen.contains(needle) { return (true, screen) }
      usleep(250_000)
    }
    return (false, screen)
  }

  private func screenLines(_ screen: String) -> [String] {
    screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  private func assertCount(
    _ query: XCUIElementQuery, reaches count: Int, _ message: String, timeout: TimeInterval = 8
  ) {
    XCTAssertTrue(poll(timeout: timeout) { query.count == count }, message)
  }

  private func waitForFile(_ path: String, timeout: TimeInterval = 30) -> String? {
    var contents: String?
    _ = poll(timeout: timeout) {
      contents = try? String(contentsOfFile: path, encoding: .utf8)
      return contents != nil
    }
    return contents?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func appRSS(_ app: XCUIApplication, _ label: String) throws -> Int {
    try prepareScratch(app)
    try helper(app, "rss", label)
    return try XCTUnwrap(
      waitForFile("\(scratch)/rss-\(label)").flatMap(Int.init), "measured the app's RSS (\(label))")
  }

  /// Total leaked bytes `leaks` reports for the app. Skips, saying why, when `leaks` gives no total
  /// (it cannot inspect the app on this machine), so the gap shows as a skip rather than a pass.
  private func leakedBytes(_ app: XCUIApplication, _ label: String) throws -> Int {
    try prepareScratch(app)
    try helper(app, "leaks", label)
    let total = waitForFile("\(scratch)/leaks-\(label)", timeout: 90)
    guard let total, let bytes = Int(total) else {
      let output = (try? String(contentsOfFile: "\(scratch)/leaks-\(label).txt", encoding: .utf8))
      throw XCTSkip("leaks gave no total for the app: \(output?.prefix(400) ?? "no output")")
    }
    return bytes
  }

  private func modificationDate(_ path: String) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  }

  private func stampIsAdvancing(_ stamp: String, window: TimeInterval) -> Bool {
    let before = modificationDate(stamp)
    RunLoop.current.run(until: Date().addingTimeInterval(window))
    guard let before, let after = modificationDate(stamp) else { return false }
    return after > before
  }

  private func pollUntilAdvancing(_ stamp: String, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if stampIsAdvancing(stamp, window: 0.7) { return true }
    }
    return false
  }

  private func waitForRunState(
    _ app: XCUIApplication, _ state: String, timeout: TimeInterval = 15
  ) -> Bool {
    let chip = app.descendants(matching: .any).matching(identifier: "terminal.tab.Run").firstMatch
    return poll(timeout: timeout) { (chip.value as? String) == state }
  }

  private func assertNoAlreadyRunning(_ app: XCUIApplication) {
    let warning = app.staticTexts.matching(
      NSPredicate(
        format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "already running",
        "already running"))
    XCTAssertEqual(warning.count, 0, "something says a server is already running")
  }

  private func summaryText(_ summary: XCUIElement) -> String {
    guard summary.exists else { return "" }
    return (summary.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? summary.label
  }

  /// The find bar's "n/total".
  private func matchPosition(_ summary: XCUIElement) -> (index: Int, total: Int)? {
    let parts = summaryText(summary).split(separator: "/").compactMap { Int($0) }
    return parts.count == 2 ? (parts[0], parts[1]) : nil
  }
}
