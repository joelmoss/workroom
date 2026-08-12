import XCTest

/// Regression cover for the IO-layer patch swap (`0002-host-managed-io.patch` →
/// `-modern`, see "Bump the libghostty pin" in TODOS.md) leaving a shell behind on quit.
///
/// **Why a marker, not a shell-name grep.** `QA-libghostty.md`'s manual "Orphan check" used to grep
/// `ps -ax` for `zsh|bash` — which always matches every unrelated shell already running on the
/// machine (a real CI/dev box has dozens). This test instead spawns a process tagged with a unique
/// token, so there is nothing else on the system it could collide with.
///
/// **Why a heartbeat FILE, not `ps`.** The obvious design — poll `ps` for the marker from the test
/// process — does not work in an XCUITest target: `Process()` spawning `/bin/ps` throws
/// `NSPOSIXErrorDomain Code=1 "Operation not permitted"` from inside the UI test runner (measured
/// while writing this test, not assumed). The runner (Xcode's auto-generated `XCTRunner` host) is
/// sandboxed against spawning subprocesses; adding an entitlements override to lift that would be a
/// project-wide signing change to unblock one test — the wrong trade for a dependency bump, and
/// `project.yml`'s own `get-task-allow` notes already document how sensitive that surface is. File
/// I/O, by contrast, DOES work from the runner (confirmed the same way; `SessionRestoreUITests`
/// already relies on this — it polls a session file's attributes from the runner process). So the
/// marked process is a stamper, not a sleeper: it touches a file in a loop, and liveness is "the
/// file's mtime is still advancing," read via `FileManager` instead of `ps`.
///
/// **Why quit via `XCUIApplication.terminate()`, not a force-quit or workroom-switch.** Those two
/// paths stay in the manual `QA-libghostty.md` checklist — this test covers specifically the normal
/// UI-quit teardown path (`WorkroomApp.applicationWillTerminate`'s documented no-mass-free
/// rationale: the process exits, the OS reclaims libghostty's memory and closes the PTYs, every
/// child shell gets SIGHUP exactly as a manual `ghostty_surface_free` would deliver). A bad IO patch
/// is exactly the kind of change that could make that SIGHUP never arrive, or arrive after libghostty
/// itself has already torn down the surface it came from.
///
/// **Proof this can actually go red, not just green** (design requirement — a test that was never
/// capable of failing is worse than no test) — partially achieved, and the honest state is worth
/// recording rather than overclaiming:
///
/// - **The detection mechanism itself IS proven.** The first fault-injection attempt backgrounded the
///   stamper (`&`, with or without `disown`) instead of `exec`ing it into the shell's own slot. A
///   background job sits in its own process group, and a terminal hangup's `SIGHUP` only reaches the
///   session's FOREGROUND process group — ordinary POSIX job control, nothing to do with libghostty —
///   so that version "leaked" on every run, healthy app or not. That was a bug in the test, but it
///   incidentally proved the READ side works: `stampIsAdvancing`/`pollUntilAdvancing` correctly
///   distinguished "still touching its file" from "stopped," every time, which is the actual
///   mechanism the real test's `XCTAssertFalse` depends on.
/// - **The fault-injection trick (`testStampDetectionCatchesAGenuineOrphan_designProof`) itself did
///   NOT reproduce reliably** after switching to the correct foreground-`exec` shape: `trap '' HUP`
///   on the marked process sometimes went red as intended, sometimes green (the process died on quit
///   anyway) across repeated runs — inconclusive, not a confirmed non-vacuity proof for THIS
///   mechanism. Time-boxed rather than chased further: this test is disabled and never runs in CI, so
///   its own flakiness doesn't threaten `make app-uitest`, and the detection mechanism it was meant to
///   re-verify is already proven by the point above. Whoever revisits this: a stronger fault
///   injection (e.g. actually holding the app's teardown open, per the plan's "debug flag or timing
///   hack" alternative) would need real app-code cooperation, which this session deliberately avoided
///   adding just to satisfy a proof.
///
/// It stays here, disabled, as the design record of what was tried.
///
/// **One typing gotcha found and fixed along the way, worth knowing for future edits to this file:**
/// `XCUIElement.typeText` garbled a bare `:` (as in the idiomatic `while :; do …`) into `;5u;`,
/// silently corrupting the shell syntax while the line still ECHOED as typed — the corruption was in
/// the synthesized keystrokes, not the rendering, so it was invisible without reading the terminal's
/// actual content. `stamperCommand` uses `while true` instead, deliberately.
final class GhosttyOrphanShellUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-WorkroomUITestNoRunCommand", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    return app
  }

  /// Same focus mechanism as `GhosttyActionDispatchUITests.focusTerminal` — click the tab CHIP, not
  /// the pane container, or the surface never becomes first responder and typed text is dropped.
  private func focusTerminal(_ app: XCUIApplication) {
    app.activate()
    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
      .firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 20), "the fixture workroom has a terminal tab")
    chip.click()
    RunLoop.current.run(until: Date().addingTimeInterval(1))
  }

  /// Types the line, then the Return **as its own `typeText` call**, not folded into one string.
  /// Measured while writing this test: `typeText(line + "\r")` reliably dropped the trailing Return
  /// specifically for lines containing shifted punctuation (`(`, `)`, `&`) — the line itself echoed
  /// correctly but the shell never received Enter, so nothing after it ever ran. Splitting the Return
  /// into its own call fixed it. `GhosttyActionDispatchUITests.run` gets away with the combined form
  /// only because its lines are plain lowercase words.
  private func run(_ app: XCUIApplication, _ line: String) {
    app.typeText(line)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    app.typeText("\r")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
  }

  /// `/tmp` (not `NSTemporaryDirectory()`), deliberately. The runner (`XCTRunner`) and the app under
  /// test are two DIFFERENT sandbox realms — the runner is a sandboxed helper app, the app under
  /// test is not (`project.yml`'s `get-task-allow` notes explain why) — so `NSTemporaryDirectory()`
  /// resolves to a different, container-private directory in each, and a path built in one is
  /// invisible or unwritable from the other (measured while writing this test: the runner's
  /// `NSTemporaryDirectory()` was a path under
  /// `~/Library/Containers/com.developwithstyle.workroom.uitests.xctrunner/`, which the shell running
  /// inside the unsandboxed app couldn't write into). `/tmp` is the traditional shared, world-writable
  /// scratch directory exempt from that per-container isolation — confirmed writable from both sides
  /// before relying on it here.
  private func stampPath(_ marker: String) -> String {
    "/tmp/qa-orphan-stamp-\(marker).txt"
  }

  /// Replaces the pane's interactive shell (`exec -a`, not a backgrounded `&` job) with a marked
  /// process that touches `stamp` every half second, forever. The marker names the PROCESS (for a
  /// human reading `ps` by hand later); the file is what this test can actually observe from the
  /// sandboxed runner.
  ///
  /// **Must be the FOREGROUND process, not a background job — this is not a style choice.** A
  /// background `&` job runs in its own process group, and a terminal hangup's `SIGHUP` is delivered
  /// to the session's FOREGROUND process group only (ordinary POSIX job-control semantics, nothing
  /// libghostty-specific) — so a backgrounded stamper is immune to the app quitting REGARDLESS of
  /// whether the app's teardown is healthy. Measured the hard way: an earlier version of this test
  /// backgrounded the stamper (with or without `disown`) and it "leaked" on every run, healthy app or
  /// not, because it was never attached to the PTY as the foreground process in the first place —
  /// nothing about libghostty was under test. `exec`ing the marked process INTO the shell's own slot
  /// is what makes it the thing that actually receives (or, for the proof test, is made to ignore)
  /// the hangup.
  ///
  /// `while true`, not the more idiomatic `while :`. Measured while writing this test:
  /// `XCUIElement.typeText` garbled the bare `:` into `;5u;`, corrupting the loop condition into
  /// invalid syntax and silently breaking the whole stamper — the line still ECHOED as typed (so a
  /// naive glance at the terminal looked fine) because the corruption happened in the synthesized
  /// keystrokes themselves, not in rendering. `true` avoids the character entirely.
  ///
  /// `hupImmune` makes the marked process ignore `SIGHUP` (`trap '' HUP`) before it starts looping —
  /// the design-proof's fault injection, applied directly to the process that will actually receive
  /// the hangup this time (unlike an earlier attempt that trapped on a process one level removed from
  /// the marked one and proved nothing). Simulates "survives regardless of teardown health" without
  /// touching a single line of app or engine code.
  private func stamperCommand(marker: String, stamp: String, hupImmune: Bool) -> String {
    let trap = hupImmune ? "trap '' HUP; " : ""
    return "exec -a \(marker) sh -c '\(trap)while true; do touch \(stamp); sleep 0.5; done'"
  }

  private func modificationDate(_ path: String) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  }

  /// Waits `window` seconds, then reports whether `stamp`'s mtime advanced during that window —
  /// i.e., whether whatever is touching it is still alive right now, not just whether it once
  /// existed.
  private func stampIsAdvancing(_ stamp: String, window: TimeInterval) -> Bool {
    let before = modificationDate(stamp)
    RunLoop.current.run(until: Date().addingTimeInterval(window))
    let after = modificationDate(stamp)
    guard let before, let after else { return false }
    return after > before
  }

  /// Polls (rather than a single fixed-length wait) so setup isn't flaky on a slow launch: retries
  /// `stampIsAdvancing` in short windows until it sees the file moving, up to `timeout`.
  private func pollUntilAdvancing(_ stamp: String, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if stampIsAdvancing(stamp, window: 0.7) { return true }
    }
    return false
  }

  /// The real regression gate: quit through the normal UI path, the marked stamper (representing a
  /// live TUI pane, same scenario as the manual `QA-libghostty.md` item) must stop touching its file
  /// afterward.
  func testNormalQuitLeavesNoOrphanedShell() {
    let marker = "qa_orphan_uitest_\(UUID().uuidString.prefix(8))"
    let stamp = stampPath(marker)
    addTeardownBlock { try? FileManager.default.removeItem(atPath: stamp) }

    let app = launchedApp()
    focusTerminal(app)
    run(app, stamperCommand(marker: marker, stamp: stamp, hupImmune: false))

    // Sanity-check the setup itself before trusting the teardown assertion: if the stamper never
    // started, "it stopped after quit" would trivially — and meaninglessly — pass.
    XCTAssertTrue(
      pollUntilAdvancing(stamp),
      "setup failed: the marked stamper (\(marker)) never started touching \(stamp)")

    app.terminate()
    // Give the teardown path a moment to actually run before the first read.
    RunLoop.current.run(until: Date().addingTimeInterval(1))

    XCTAssertFalse(
      stampIsAdvancing(stamp, window: 2),
      "a process tagged \(marker) kept touching \(stamp) after the app quit — the IO-layer teardown "
        + "path leaked it")
  }

  /// Design-time-only proof, kept as a record of what was tried — see the class doc's honest account
  /// of the result. NOT run by `make app-uitest` (disabled). Flipping `disabled` to `false` and
  /// running it standalone was RED sometimes and GREEN other times across repeated attempts in this
  /// session, not consistently RED — so treat a single run either way as inconclusive, not as new
  /// evidence about the app.
  ///
  /// **Manual cleanup required after running this.** It deliberately leaves a `SIGHUP`-immune
  /// infinite loop running as the pane's former foreground process, and — the same restriction this
  /// whole file exists to work around — the runner cannot spawn `Process()` to kill it itself. Run
  /// `pkill -f qa_orphan_uitest_proof` yourself afterward.
  func testStampDetectionCatchesAGenuineOrphan_designProof() throws {
    let disabled = true
    try XCTSkipIf(
      disabled, "design-time proof only — see the class doc for why this isn't a CI test")

    let marker = "qa_orphan_uitest_proof_\(UUID().uuidString.prefix(8))"
    let stamp = stampPath(marker)
    addTeardownBlock { try? FileManager.default.removeItem(atPath: stamp) }

    let app = launchedApp()
    focusTerminal(app)
    // `trap '' HUP` makes the marked process ignore the hangup a normal quit sends it — enough to
    // simulate "survives the app quitting" without touching a single line of app or engine code.
    run(app, stamperCommand(marker: marker, stamp: stamp, hupImmune: true))

    XCTAssertTrue(
      pollUntilAdvancing(stamp),
      "setup failed: the marked stamper (\(marker)) never started touching \(stamp)")

    app.terminate()
    RunLoop.current.run(until: Date().addingTimeInterval(1))

    // The EXACT assertion `testNormalQuitLeavesNoOrphanedShell` makes, applied to a scenario known to
    // leak — this must fail (go red) for the real test's assertion to be trusted at all.
    XCTAssertFalse(
      stampIsAdvancing(stamp, window: 2),
      "expected this to FAIL: a HUP-immune stamper should still be touching its file after quit — if "
        + "this assertion passes instead, the detection mechanism itself is broken, not just "
        + "insensitive to a real leak")
  }
}
