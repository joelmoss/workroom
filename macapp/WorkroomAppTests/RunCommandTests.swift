import AppKit
import Defaults
import XCTest

@testable import Workroom

/// Store-level tests for the per-project "Run command" feature (issue #7). They drive a real,
/// non-singleton `AppStore` with the terminal factory seam overridden (so no live PTY) and capture
/// the command string handed to `makeView` to assert the shell wrap. Run-state lives on the store
/// (OV-A), so it's all inspectable here; the libghostty `command`/child-exit behaviour itself is
/// verified live (T1), and the toolbar/menu/sidebar wiring via XCUITest (T13).
@MainActor
final class RunCommandTests: XCTestCase {
  private var captured: [String?] = []
  private var signals: [(TerminalTarget.ID, Int32)] = []
  /// Windows registered on `WindowRegistry.shared` by the owner-focus test below — unlike every
  /// other test here, that one exercises the real singleton (not an injectable instance), so
  /// registrations must be unwound in `tearDown` (not just at the end of the test body) or a failed
  /// assertion could leak a stale registration into a later test (issue #127).
  private var registeredWindows: [NSWindow] = []

  override func setUp() {
    super.setUp()
    captured = []
    signals = []
    Defaults[.runCommands] = [:]
  }

  override func tearDown() {
    Defaults[.runCommands] = [:]
    for window in registeredWindows { WindowRegistry.shared.unregister(window: window) }
    registeredWindows = []
    super.tearDown()
  }

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    // No close-confirm modal in a unit test. Per store, NOT via `Defaults[.confirmOnCloseTerminal]`:
    // parallel workers share one UserDefaults domain, so writing that key reached into the other
    // close-behaviour classes mid-body (see `AppStore.confirmOnCloseOverrideForTesting`).
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { [weak self] _, cwd, command in
      self?.captured.append(command)
      return GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.signalSupervisorForTesting = { [weak self] sig, id in
      self?.signals.append((id, sig))
      return true
    }
    store.projects = projects
    return store
  }

  /// A `makeStore` variant whose supervisor seam always returns `false` (dead supervisor), forcing
  /// `restartRunCommand` to take the respawn path rather than the signal path.
  private func makeStoreDeadSupervisor(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    store.confirmOnCloseOverrideForTesting = false  // as in `makeStore`: never a modal
    store.terminals.makeView = { [weak self] _, cwd, command in
      self?.captured.append(command)
      return GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.signalSupervisorForTesting = { [weak self] sig, id in
      self?.signals.append((id, sig))
      return false
    }
    store.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  private func target(_ store: AppStore, _ project: String, _ name: String) -> TerminalTarget {
    store.target(for: .workroom(project: project, name: name))!
  }

  /// The run terminal's surface view (so a test can simulate supervisor exit via `handleChildExited`).
  private func runView(_ store: AppStore, _ target: TerminalTarget) -> GhosttySurfaceView? {
    store.runTabID(for: target.id).flatMap { store.terminals.tab($0, for: target)?.surface }
  }

  // MARK: Storage

  func testRunConfigRoundTripAndRemoval() {
    let store = makeStore([])
    let config = RunConfig(command: "npm run dev", autoRun: true)
    store.setRunConfig(config, forProject: "/a")
    XCTAssertEqual(store.runConfig(forProject: "/a"), config)
    XCTAssertTrue(store.hasRunCommand(forProject: "/a"))

    // A blank command with auto-run off removes the entry (no dead keys).
    store.setRunConfig(.empty, forProject: "/a")
    XCTAssertEqual(store.runConfig(forProject: "/a"), .empty)
    XCTAssertNil(Defaults[.runCommands]["/a"])
    XCTAssertFalse(store.hasRunCommand(forProject: "/a"))
  }

  func testSetRunConfigTrimsCommand() {
    let store = makeStore([])
    store.setRunConfig(RunConfig(command: "  bin/dev  ", autoRun: false), forProject: "/a")
    XCTAssertEqual(store.runConfig(forProject: "/a").command, "bin/dev")
  }

  // MARK: Start

  func testStartRunCommandSpawnsTracksAndWraps() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)

    XCTAssertNotNil(store.runTabID(for: t.id))
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    // The surface command is the supervisor invocation: /bin/sh <supervisor.sh> <ctl> <status> …
    let cmd = try! XCTUnwrap(captured.last as? String)
    XCTAssertTrue(cmd.contains("supervisor.sh"), "command must invoke the supervisor: \(cmd)")
    XCTAssertTrue(cmd.contains("echo hi"), "user command must be present: \(cmd)")
    // The supervisor runs the user command under an interactive login shell (A3); `-lic` is the
    // proof that `-i` (interactive) is included alongside `-l` and `-c` (issue #15).
    XCTAssertTrue(cmd.contains("-lic"), "not an interactive login shell: \(cmd)")
    // The status file path is included so the supervisor can write its state transitions.
    XCTAssertTrue(cmd.contains(".status"), "no status file path in command: \(cmd)")
  }

  /// Regression guard for moving `runCommandLine`'s shell-dialect decision into the shared
  /// `ShellEnvironment.loginShellInvocation` (which the environment probe also uses, so the two
  /// can't drift). The dialect branch itself — POSIX `$SHELL` gets `-lic`, fish/nu/csh fall back to
  /// a login `/bin/sh -lc` — is covered per-shell in `ShellEnvironmentTests`; that fallback had no
  /// test at all before, and this refactor made it load-bearing for the run command too. What can
  /// only be checked here is the composition: that the wrap the supervisor receives is byte-for-byte
  /// what the shared helper produces, rather than a second hand-rolled copy that happens to agree
  /// on this machine's shell.
  func testRunWrapComesFromTheSharedLoginShellHelper() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)

    let cmd = try! XCTUnwrap(captured.last as? String)
    let q = CommandLineInstaller.shellQuoted
    let inner = "exec \(q(ShellEnvironment.loginShellExecutable())) -c \(q("echo hi"))"
    let expected = ShellEnvironment.loginShellInvocation(script: inner).commandString
    XCTAssertTrue(cmd.hasSuffix(expected), "wrap is not the shared helper's output: \(cmd)")
  }

  func testStartIsNoOpWithoutCommand() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    XCTAssertNil(store.runTabID(for: t.id))
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  /// Issue #127: ⌘R/toolbar Run on a target with no run command configured must not silently
  /// no-op — it should surface the Project Settings sheet with a warning. This is the mandatory
  /// regression test for `runOrFocusRunCommand`'s `.armed/.none` branch: none of this file's other
  /// `runOrFocusRunCommand()` calls exercise the no-command case (they all pre-configure a command).
  func testRunOrFocusPresentsProjectSettingsWithWarningWhenNoCommand() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.runOrFocusRunCommand()

    XCTAssertNil(store.runTabID(for: t.id), "must not start anything without a configured command")
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
    let pending = try! XCTUnwrap(store.pendingProjectSettings)
    XCTAssertEqual(pending.project.path, "/a")
    XCTAssertTrue(pending.showsRunWarning)
  }

  func testPendingProjectSettingsDefaultsNoWarning() {
    let p = project("/a", workrooms: [])
    XCTAssertFalse(PendingProjectSettings(project: p).showsRunWarning)
  }

  /// Found by the review's Testing + Maintainability specialists (independently, same root cause):
  /// the `pendingProjectSettings == nil` guard added in eng review (issue #127-eng-4) — so a second
  /// ⌘R for a DIFFERENT no-command target can't silently overwrite an already-open settings sheet —
  /// had no test proving it actually works.
  func testRunOrFocusDoesNotClobberAnAlreadyOpenSettingsSheet() {
    let store = makeStore([project("/a", workrooms: []), project("/b", workrooms: ["main"])])
    store.pendingProjectSettings = PendingProjectSettings(project: project("/a", workrooms: []))
    let tB = target(store, "/b", "main")
    store.selectedTargetID = .workroom(project: "/b", name: "main")

    store.runOrFocusRunCommand()

    XCTAssertEqual(
      store.pendingProjectSettings?.project.path, "/a",
      "must not clobber the already-open sheet with a different project")
    XCTAssertNil(store.runTabID(for: tB.id))
  }

  /// Found by the Testing specialist: every other test here stops at "the sheet opens" or "no
  /// warning shown" — none confirmed the fix's actual payoff, that configuring a command from the
  /// warned sheet lets a subsequent ⌘R really run it.
  func testRunOrFocusStartsAfterConfiguringCommandFromTheWarnedSheet() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.runOrFocusRunCommand()
    XCTAssertNotNil(store.pendingProjectSettings)

    // Simulates `ProjectSettingsSheet`'s Save button: persist the command, then dismiss.
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    store.pendingProjectSettings = nil

    store.runOrFocusRunCommand()

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
  }

  /// Issue #127-eng-4 (outside-voice review): the owner-elsewhere branch takes precedence over the
  /// new no-command branch, and unlike every other test in this file, it exercises the real
  /// `WindowRegistry.shared` singleton `runOrFocusRunCommand` hardcodes — registrations are unwound
  /// in `tearDown` via `registeredWindows`.
  func testRunOrFocusFocusesOwnerWindowInsteadOfStartingDuplicate() {
    let ownerStore = makeStore([project("/a", workrooms: ["main"])])
    ownerStore.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let ownerTarget = target(ownerStore, "/a", "main")
    ownerStore.startRunCommand(for: ownerTarget)  // owner is now actually running this target

    let selectingStore = makeStore([project("/a", workrooms: ["main"])])
    let selectingTarget = target(selectingStore, "/a", "main")
    selectingStore.selectedTargetID = .workroom(project: "/a", name: "main")

    let winOwner = NSWindow()
    let winSelecting = NSWindow()
    WindowRegistry.shared.register(window: winOwner, store: ownerStore)
    WindowRegistry.shared.register(window: winSelecting, store: selectingStore)
    registeredWindows = [winOwner, winSelecting]

    selectingStore.runOrFocusRunCommand()

    XCTAssertNil(
      selectingStore.runTabID(for: selectingTarget.id),
      "must not start a duplicate run — the owner window already runs it (issue #70)")
    XCTAssertNil(
      selectingStore.pendingProjectSettings,
      "owner-elsewhere takes precedence over the no-command branch — no settings sheet either")
  }

  // MARK: Per-target Run (issue #139)

  /// The whole reason `runOrFocusRunCommand(for:)` exists. Each workroom pane now owns a Run button, so
  /// pressing one on a co-displayed but non-selected split member must run THAT workroom's command —
  /// the selection-scoped door would silently have run the selected one instead.
  func testRunOrFocusForTargetActsOnThePassedTargetNotTheSelection() {
    let store = makeStore([project("/a", workrooms: ["main", "other"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let selected = target(store, "/a", "main")
    let pressed = target(store, "/a", "other")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.runOrFocusRunCommand(for: pressed)

    XCTAssertTrue(
      store.isRunCommandRunning(for: pressed.id), "the pressed workroom should be running")
    XCTAssertNil(
      store.runTabID(for: selected.id),
      "the SELECTED workroom must be untouched — that was the bug this overload fixes")
  }

  /// Pressing Run on a non-selected member also raises it. Without this, `.running`'s focus branch
  /// switches a tab inside a dimmed, non-focused pane and the click looks like it did nothing.
  func testRunOrFocusForTargetRaisesThePressedPane() {
    let store = makeStore([project("/a", workrooms: ["main", "other"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.runOrFocusRunCommand(for: target(store, "/a", "other"))

    XCTAssertEqual(store.selectedTargetID, .workroom(project: "/a", name: "other"))
    XCTAssertEqual(store.selectedProjectID, "/a")
  }

  /// `isEditingTextField` guards the AMBIENT ⌘R — it must not reach a deliberate button click. The
  /// guard lives on the selection-scoped overload only, so the per-target one runs regardless of what
  /// holds first responder. Proven here by driving the overload directly (a unit test can't make a real
  /// field editor first responder, which is exactly why this seam has to be structural, not conditional).
  func testRunOrFocusForTargetIgnoresTheTextFieldGuard() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = nil  // no selection at all: the ⌘R path would bail here

    store.runOrFocusRunCommand(for: t)

    XCTAssertTrue(
      store.isRunCommandRunning(for: t.id),
      "a button press carries its own target and must not depend on the selection")
  }

  /// The selection-scoped door still works — it just delegates now.
  func testRunOrFocusSelectionOverloadDelegatesToThePerTargetOne() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.runOrFocusRunCommand()

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
  }

  /// A missing directory is refused on the per-target path too, not just via the selection.
  func testRunOrFocusForTargetRefusesAMissingWorkroom() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let live = target(store, "/a", "main")
    let missing = TerminalTarget(
      id: live.id, title: live.title, path: live.path, isMissing: true)

    store.runOrFocusRunCommand(for: missing)

    XCTAssertNil(store.runTabID(for: missing.id))
  }

  /// The single-owner-across-windows hop keys on the PASSED target. Same scenario as
  /// `testRunOrFocusFocusesOwnerWindowInsteadOfStartingDuplicate`, but pressed on a workroom that isn't
  /// the selection — the branch reads `runStates[target.id]`, so a regression that reverted it to the
  /// selection would fork a second dev server on the same port.
  func testRunOrFocusForTargetChecksOwnerForThePassedTarget() {
    let ownerStore = makeStore([project("/a", workrooms: ["main", "other"])])
    ownerStore.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    ownerStore.startRunCommand(for: target(ownerStore, "/a", "other"))

    let pressingStore = makeStore([project("/a", workrooms: ["main", "other"])])
    let pressed = target(pressingStore, "/a", "other")
    pressingStore.selectedTargetID = .workroom(project: "/a", name: "main")

    let winOwner = NSWindow()
    let winPressing = NSWindow()
    WindowRegistry.shared.register(window: winOwner, store: ownerStore)
    WindowRegistry.shared.register(window: winPressing, store: pressingStore)
    registeredWindows = [winOwner, winPressing]

    pressingStore.runOrFocusRunCommand(for: pressed)

    XCTAssertNil(
      pressingStore.runTabID(for: pressed.id),
      "the other window already runs THIS workroom — no duplicate (issue #70)")
  }

  func testStartSingleQuoteEscaping() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo 'x'", autoRun: false), forProject: "/a")
    store.startRunCommand(for: target(store, "/a", "main"))
    let cmd = try! XCTUnwrap(captured.last as? String)
    XCTAssertTrue(cmd.contains("'\\''"), "single quotes not POSIX-escaped: \(cmd)")
  }

  func testStartDoesNotDuplicateRunTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let first = store.runTabID(for: t.id)
    store.startRunCommand(for: t)  // already exists → no-op (issue #67: no re-focus)
    XCTAssertEqual(store.runTabID(for: t.id), first)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 1)
  }

  // MARK: Child-exit / stop / restart

  func testChildExitFlipsToStoppedButKeepsPane() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tabID = store.runTabID(for: t.id)

    store.applyRunStatus("exited 0", for: t)

    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(store.runTabID(for: t.id), tabID, "pane should stay open after exit")
  }

  func testRunOrFocusReRunsAStoppedTab() {
    // Stopped-but-open pane: the supervisor exited, so `restartRunCommand` takes the respawn path
    // (signalSupervisor returns false → respawnRunCommand) → fresh tab.
    let store = makeStoreDeadSupervisor([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.startRunCommand(for: t)
    let first = store.runTabID(for: t.id)
    store.applyRunStatus("exited 0", for: t)  // now stopped-but-open
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))

    store.runOrFocusRunCommand()  // ensure-running: stopped → re-run (OV-B)
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertNotEqual(
      store.runTabID(for: t.id), first, "re-run spawns a fresh tab (dead supervisor)")
  }

  /// TODOS.md ("Stopped run-tab silently closes instead of warning when its command is cleared"):
  /// a run stops (pane stays open), the command is cleared via Project Settings, and the next ⌘R
  /// used to hit `respawnRunCommand`'s `hasRunCommand` guard and just close the pane — no warning,
  /// indistinguishable from ⌘R doing nothing at all. It must now surface the same warning sheet the
  /// `.armed`/`.none` no-command branch already shows, and leave the stopped pane alone.
  func testRestartWithClearedCommandWarnsInsteadOfClosing() {
    let store = makeStoreDeadSupervisor([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.startRunCommand(for: t)
    let tabID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.applyRunStatus("exited 0", for: t)  // now stopped-but-open
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))

    store.setRunConfig(RunConfig(command: "", autoRun: false), forProject: "/a")  // cleared
    store.runOrFocusRunCommand()  // ⌘R again — dead supervisor → respawnRunCommand's guard

    XCTAssertEqual(
      store.pendingProjectSettings?.project.path, "/a",
      "clearing the command must surface the same warning sheet as the no-command case")
    XCTAssertEqual(store.pendingProjectSettings?.showsRunWarning, true)
    XCTAssertEqual(
      store.runTabID(for: t.id), tabID,
      "the stopped pane must stay open — the fix is to warn, not to silently destroy it")
  }

  /// The other entry state `respawnRunCommand`'s no-command guard has to handle: `restartRunCommand`
  /// reaches it from `.running`/`.restarting`/`.stopped` alike (its shared branch when
  /// `signalSupervisor` reports the supervisor gone), not only `.stopped`. Restarting while the store
  /// still says `.running` — a dead supervisor that never got the chance to report its exit — must
  /// not leave that stale "running" state behind once the warning sheet takes over; otherwise the
  /// toast/sidebar dot keeps claiming a pid that's already confirmed gone.
  func testRestartFromRunningWithClearedCommandStopsReportingAsRunning() {
    let store = makeStoreDeadSupervisor([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.startRunCommand(for: t)
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))  // still .running — no exit reported yet

    store.setRunConfig(RunConfig(command: "", autoRun: false), forProject: "/a")  // cleared
    store.restartRunCommand(for: t)  // dead supervisor → respawnRunCommand's no-command guard

    XCTAssertFalse(
      store.isRunCommandRunning(for: t.id),
      "a confirmed-dead supervisor must not leave the state reporting .running")
    XCTAssertEqual(store.pendingProjectSettings?.project.path, "/a")
  }

  func testClosingRunTabClearsState() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tabID = try! XCTUnwrap(store.runTabID(for: t.id))

    store.terminals.closeTab(tabID, for: t)

    XCTAssertNil(store.runTabID(for: t.id))
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  func testGracefulRestartReplacesTabAfterExit() {
    // Under the supervisor model, restart signals SIGUSR1 and the SAME tab stays —  no surface
    // free/respawn. Drive completion with `applyRunStatus("running 1")`.
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let first = try! XCTUnwrap(store.runTabID(for: t.id))

    store.restartRunCommand(for: t)  // running → SIGUSR1 → .restarting (same tab)
    XCTAssertTrue(signals.contains { $0.1 == SIGUSR1 }, "restart must send SIGUSR1")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(
      store.runTabID(for: t.id), first, "tab stays put — supervisor handles the restart")

    store.applyRunStatus("running 1", for: t)  // supervisor relaunched the child

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(store.runTabID(for: t.id), first, "same tab throughout the restart")
  }

  /// Put the run tab in a split (run tab + one sibling), then restart it. The split must survive
  /// unchanged — the supervisor restarts the child in place, so no tab replacement occurs (issue #40).
  func testGracefulRestartKeepsRunTabInSplit() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    let sibling = store.terminals.addTab(for: t).id  // a second pane to split against
    // Split: [sibling, run].
    store.terminals.moveTabIntoSplit(runID, ontoEdge: .right, of: sibling, for: t)
    XCTAssertEqual(store.terminals.split(for: t)?.tabIDs, [sibling, runID])

    store.restartRunCommand(for: t)  // SIGUSR1 → .restarting, tab unchanged
    XCTAssertTrue(signals.contains { $0.1 == SIGUSR1 }, "restart must send SIGUSR1")

    store.applyRunStatus("running 1", for: t)  // child relaunched by supervisor

    XCTAssertEqual(store.runTabID(for: t.id), runID, "same run tab — no surface respawn")
    let split = try! XCTUnwrap(store.terminals.split(for: t), "split must survive the restart")
    XCTAssertEqual(split.tabIDs, [sibling, runID], "split layout unchanged")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
  }

  /// The stopped-but-open re-run path (⌘R on an exited run tab): with a dead supervisor the app
  /// respawns a fresh surface and the new tab takes the old one's slot in the split (issue #40).
  func testStoppedReRunKeepsRunTabInSplit() {
    // Supervisor is gone after the run exited, so restartRunCommand takes the respawn path.
    let store = makeStoreDeadSupervisor([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    let sibling = store.terminals.addTab(for: t).id
    store.terminals.moveTabIntoSplit(runID, ontoEdge: .left, of: sibling, for: t)  // [run, sibling]
    store.applyRunStatus("exited 0", for: t)  // run tab now stopped-but-open
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))

    store.runOrFocusRunCommand()  // stopped → re-run in place (dead supervisor → respawn)

    let newRun = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertNotEqual(newRun, runID, "re-run spawns a fresh tab")
    let split = try! XCTUnwrap(store.terminals.split(for: t), "split must survive the re-run")
    XCTAssertEqual(split.tabIDs, [newRun, sibling], "new run tab takes the old one's slot")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
  }

  func testArmedAutoRunBackgroundsRunAndOpensShell() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: true), forProject: "/a")
    let t = target(store, "/a", "main")

    // Armed auto-run + the always-on "open a terminal in new workrooms": the run starts as a
    // BACKGROUNDED tab #1 (running, not focused) and a plain shell opens as the focused tab #2 the user
    // lands on (issue #67 / Arch #5).
    store.armAutoRun(forWorkroom: t.id)
    store.ensureInitialTerminal(for: t)  // the terminal pane mounting

    XCTAssertNotNil(store.runTabID(for: t.id), "armed auto-run should start the command on mount")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id), "run still starts, just in the background")
    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 2, "run tab + shell tab")
    let active = store.terminals.activeTab(for: t)?.id
    XCTAssertNotNil(active)
    XCTAssertNotEqual(
      active, store.runTabID(for: t.id), "the shell is focused, the run is backgrounded")
  }

  func testInitialTerminalOpensShellWhenNotArmed() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    // Not armed (auto-run off) → mounting a pane with no terminals always opens a single plain shell,
    // no run tab: a newly created workroom and an existing workroom/root selected with none open both
    // land the user in a terminal. A configured-but-not-auto run command must not start here.
    store.ensureInitialTerminal(for: t)

    XCTAssertNil(store.runTabID(for: t.id), "no auto-run → no run tab")
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 1, "one shell terminal opened")
  }

  func testInitialTerminalIdempotentAcrossRemounts() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")

    store.ensureInitialTerminal(for: t)
    store.ensureInitialTerminal(for: t)  // a re-mount (navigate away and back) must not re-open

    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 1, "no duplicate shell on re-mount")
  }

  func testInitialTerminalLeavesExistingTerminalsAlone() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")

    // A target that already has a terminal open gets no extra one — "open one if there are none open".
    store.terminals.addTab(for: t)
    store.ensureInitialTerminal(for: t)

    XCTAssertEqual(
      store.terminals.tabCount(forTargetID: t.id), 1, "existing terminal → no extra tab")
  }

  func testToggleStartsWhenNotRunning() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))

    store.toggleRunCommand(for: t)  // sidebar run button: not running → start

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertNotNil(store.runTabID(for: t.id))
  }

  func testReapClearsRunState() async {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))

    await store.terminals.reap(t.id)

    XCTAssertNil(store.runTabID(for: t.id))
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  /// Regression: closing the run tab mid-restart (before the supervisor completes the child restart)
  /// must clear state. A fresh run started afterwards must not be mistaken for a pending respawn.
  func testClosingTabMidRestartDoesNotRespawnTheNextRun() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)
    store.restartRunCommand(for: t)  // SIGUSR1 → .restarting
    let firstTab = try! XCTUnwrap(store.runTabID(for: t.id))

    store.terminals.closeTab(firstTab, for: t)  // user ⌘W before the supervisor restarts
    XCTAssertNil(store.runTabID(for: t.id))

    // A fresh run; its natural exit must NOT trigger a respawn (no stale pendingRestart).
    store.startRunCommand(for: t)
    let freshTab = try! XCTUnwrap(store.runTabID(for: t.id))
    store.applyRunStatus("exited 0", for: t)

    // Pump the main queue so any (buggy) deferred respawn would have run before we assert.
    let pumped = expectation(description: "no respawn")
    DispatchQueue.main.async { pumped.fulfill() }
    wait(for: [pumped], timeout: 1)

    XCTAssertFalse(store.isRunCommandRunning(for: t.id), "exited run stays stopped")
    XCTAssertEqual(store.runTabID(for: t.id), freshTab, "must not respawn a new tab")
  }

  /// Stop is one press: SIGUSR2 to the supervisor, which then SIGINTs the child and waits for it to
  /// exit (keeps the pane). `applyRunStatus("stopped")` drives the state to `.stopped`.
  func testStopEscalatesToCloseOnSecondPress() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))

    store.stopRunCommand(for: t)  // SIGUSR2 → .running(interrupted), pane stays
    XCTAssertTrue(signals.contains { $0.1 == SIGUSR2 }, "stop must send SIGUSR2")
    XCTAssertEqual(store.runTabID(for: t.id), tab, "stop keeps the pane open")
    XCTAssertTrue(
      store.isRunCommandRunning(for: t.id), "still running until supervisor confirms stop")

    // Supervisor confirms the stop via the status file.
    store.applyRunStatus("stopped", for: t)
    XCTAssertEqual(
      store.runTabID(for: t.id), tab, "pane stays open after stop (wait_after_command)")
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  /// Regression (#3): a Stop pressed right after a Restart must send SIGUSR2 (graceful),
  /// not hard-kill. The supervisor serializes this internally.
  func testStopAfterRestartIsGracefulNotImmediateHardKill() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))

    store.restartRunCommand(for: t)  // SIGUSR1 → .restarting
    XCTAssertTrue(signals.contains { $0.1 == SIGUSR1 }, "restart must send SIGUSR1")

    signals.removeAll()
    store.stopRunCommand(for: t)  // Stop after Restart → SIGUSR2, pane stays
    XCTAssertTrue(signals.contains { $0.1 == SIGUSR2 }, "stop after restart must send SIGUSR2")
    XCTAssertEqual(store.runTabID(for: t.id), tab, "pane must stay open on stop")

    store.applyRunStatus("stopped", for: t)
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  /// The gate the **sidebar** row buttons use: a present target whose project has a command — not a
  /// missing directory (where startRunCommand silently no-ops), and not a project without a command
  /// (review #9/#14).
  ///
  /// Note this is no longer the gate the workroom pane header uses. Its Run button is always shown for a
  /// present target (issue #139 follow-up) and a press with no command configured opens Project Settings
  /// with the warning, exactly as ⌘R does — a visible button that teaches you how to configure it beats
  /// no button at all. A sidebar *row* is a different case: it's a list of many workrooms, where a button
  /// per row that only opens a settings sheet would be noise.
  func testCanRunCommandGate() {
    let store = makeStore([])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let present = TerminalTarget(id: "x", title: "main", path: "/a/main", isMissing: false)
    let missing = TerminalTarget(id: "y", title: "gone", path: "/a/gone", isMissing: true)

    XCTAssertTrue(store.canRunCommand(for: present, inProject: "/a"))
    XCTAssertFalse(store.canRunCommand(for: missing, inProject: "/a"), "missing → no run controls")
    XCTAssertFalse(
      store.canRunCommand(for: present, inProject: "/b"), "no command → no run controls")
  }

  // MARK: Graceful teardown (issue #7, Option B) — a live run command (e.g. Puma) gets a SIGTERM
  // to the supervisor and a wait for it to actually exit before its surface is freed, so it isn't
  // orphaned by the bare PTY hangup (SIGHUP, which Puma ignores) → "A server is already running"
  // on the next start. Tests run without a real PTY, so `liveProcessOverrideForTesting` stands in
  // for a live child process.

  /// A small async settle so a scheduled `pollUntilExited` tick (asyncAfter 0.1s) runs before asserting.
  /// Only for asserting something has NOT happened — a dwell is the only way to show that. For the
  /// positive direction use `waitUntil`.
  private func settle(_ seconds: TimeInterval = 0.25) {
    let done = expectation(description: "settle")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
    wait(for: [done], timeout: seconds + 1)
  }

  /// Pump the main runloop in short slices until `condition` holds, then assert it did.
  ///
  /// `pollUntilExited` notices an exit on a 0.1s main-queue timer, so every "…once the process has
  /// exited" assertion here is really waiting on a timer tick. Sleeping a flat interval instead makes
  /// the test a race against machine load: under the parallel suite a 0.1s tick can slip past a 0.2s
  /// sleep, which is exactly how this suite flaked (a one-off failure of the graceful-stop-all test
  /// that then passed 60/60 in isolation). Waiting on the OUTCOME is load-proof — a generous ceiling
  /// can absorb any delay, and the wait still returns the moment the tick lands, so it costs no time
  /// in the common case.
  private func waitUntil(
    timeout: TimeInterval = 5, _ message: String, _ condition: () -> Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      settle(0.02)
    }
    XCTAssertTrue(condition(), message, file: file, line: line)
  }

  func testSecondStopWaitsForLiveProcessThenCloses() {
    // Under the supervisor model, closing the run tab (requestCloseTerminalTab) when a live process
    // is present sends SIGTERM via gracefullyStopRuns and waits before freeing. Simulated here by
    // stopping the command and then requesting a close.
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))
    let view = try! XCTUnwrap(runView(store, t))
    view.liveProcessOverrideForTesting = true  // a dev server still running

    // Request close while the process is alive — must wait, not close immediately. (`makeStore` has
    // already pinned the confirm off for this store.)
    store.requestCloseTerminalTab(tab, for: t)
    XCTAssertEqual(
      store.runTabID(for: t.id), tab, "close must wait while the process is alive")
    XCTAssertTrue(signals.contains { $0.1 == SIGTERM }, "close must send SIGTERM to supervisor")

    view.liveProcessOverrideForTesting = false  // process exits
    waitUntil("tab closes once the process has exited") { store.runTabID(for: t.id) == nil }
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  func testRequestCloseWaitsForLiveRunCommand() {
    let store = makeStore([project("/a", workrooms: ["main"])])  // confirm pinned off in makeStore
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))
    let view = try! XCTUnwrap(runView(store, t))
    view.liveProcessOverrideForTesting = true

    store.requestCloseTerminalTab(tab, for: t)
    XCTAssertEqual(store.runTabID(for: t.id), tab, "closing waits for the live run process to exit")
    XCTAssertTrue(signals.contains { $0.1 == SIGTERM }, "close must send SIGTERM to supervisor")

    view.liveProcessOverrideForTesting = false
    waitUntil("tab closes once the process has exited") { store.runTabID(for: t.id) == nil }
  }

  func testGracefullyStopAllWaitsForEveryLiveCommandThenCompletes() {
    let store = makeStore([project("/a", workrooms: ["main", "two"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t1 = target(store, "/a", "main")
    let t2 = target(store, "/a", "two")
    store.startRunCommand(for: t1)
    store.startRunCommand(for: t2)
    let v1 = try! XCTUnwrap(runView(store, t1))
    let v2 = try! XCTUnwrap(runView(store, t2))
    v1.liveProcessOverrideForTesting = true
    v2.liveProcessOverrideForTesting = true
    XCTAssertTrue(store.hasLiveRunCommand)

    var completed = false
    // A deliberately unreachable timeout: this test is about the wait ENDING because both processes
    // exited, so the fallback firing on a slow machine would be a false pass on the last assertion —
    // and a false failure on the two "still waiting" ones. The timeout path has its own test below.
    store.gracefullyStopAllRunCommands(timeout: 300) { completed = true }
    XCTAssertFalse(completed, "waits while processes are alive")
    // SIGTERM must be sent to both supervisors.
    XCTAssertTrue(
      signals.filter { $0.1 == SIGTERM }.count >= 2,
      "SIGTERM must be sent to each live supervisor")

    v1.liveProcessOverrideForTesting = false  // only one exited
    settle(0.2)  // a dwell, not a race: several poll ticks pass and must NOT complete
    XCTAssertFalse(completed, "still waiting on the second run command")

    v2.liveProcessOverrideForTesting = false  // both exited
    waitUntil("completes once every run command has exited") { completed }
  }

  func testGracefullyStopAllCompletesImmediatelyWhenNothingLive() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    store.startRunCommand(for: target(store, "/a", "main"))  // no override → no live PTY
    XCTAssertFalse(store.hasLiveRunCommand)

    var completed = false
    store.gracefullyStopAllRunCommands(timeout: 2) { completed = true }
    XCTAssertTrue(completed, "no live process → completes synchronously")
  }

  func testGracefullyStopAllFallsBackAfterTimeout() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let v = try! XCTUnwrap(runView(store, t))
    v.liveProcessOverrideForTesting = true  // a wedged server that never exits

    var completed = false
    store.gracefullyStopAllRunCommands(timeout: 0.2) { completed = true }
    XCTAssertFalse(completed)
    waitUntil("a wedged process still proceeds after the timeout (SIGHUP fallback)") { completed }
  }

  // MARK: Investigate (issue #146)

  private func investigateBanner(_ target: TerminalTarget) -> AgentBannerState {
    .awaitingDiagnose(
      FailedCommand(
        command: "npm test", cwd: target.path, exitCode: 1, shell: nil, output: "",
        isRunTab: false, isRemote: false))
  }

  func testStartInvestigateBuildsCommandAndTracksTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    let bannerState = investigateBanner(t)

    let tab = store.startInvestigate(bannerState: bannerState, target: t, surface: nil)

    XCTAssertEqual(captured.last, AgentPrompt.investigateCommandLine(for: bannerState))
    XCTAssertEqual(store.investigateTabs[tab.id], t.id)
  }

  func testInvestigateLivenessClearsViaChildExitAndViaTabRemoval() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    let bannerState = investigateBanner(t)
    XCTAssertFalse(store.hasLiveRunCommand)

    let tab1 = store.startInvestigate(bannerState: bannerState, target: t, surface: nil)
    let surface1 = try! XCTUnwrap(tab1.surface)
    surface1.liveProcessOverrideForTesting = true
    XCTAssertTrue(store.hasLiveRunCommand)

    // Cleanup path 1: the process exits (`onChildExited`) — independent of the tab closing.
    surface1.handleChildExited(exitCode: 0)
    XCTAssertNil(store.investigateTabs[tab1.id])
    XCTAssertFalse(store.hasLiveRunCommand)

    // Cleanup path 2: the tab is closed/reaped (`onTabsRemoved`) — independent of `onChildExited`
    // ever firing (it isn't guaranteed to, per libghostty exit-reporting flakiness).
    let tab2 = store.startInvestigate(bannerState: bannerState, target: t, surface: nil)
    let surface2 = try! XCTUnwrap(tab2.surface)
    surface2.liveProcessOverrideForTesting = true
    XCTAssertTrue(store.hasLiveRunCommand)

    store.terminals.closeTab(tab2.id, for: t)
    XCTAssertNil(store.investigateTabs[tab2.id])
    XCTAssertFalse(store.hasLiveRunCommand)
  }

  func testGracefullyStopAllCompletesImmediatelyWithOnlyInvestigateTabLive() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    let tab = store.startInvestigate(bannerState: investigateBanner(t), target: t, surface: nil)
    let surface = try! XCTUnwrap(tab.surface)
    surface.liveProcessOverrideForTesting = true
    XCTAssertTrue(store.hasLiveRunCommand)

    // `runStates` is empty — an Investigate-only session has no supervisor to SIGTERM, so this must
    // resolve immediately rather than wait on a `runStates` entry that will never appear (issue #146).
    var completed = false
    store.gracefullyStopAllRunCommands(timeout: 2) { completed = true }
    XCTAssertTrue(completed, "no runStates entries to iterate → completes synchronously")
  }

  /// `WindowRegistry.hasLiveInvestigateSession` (issue #146) — used to warn before
  /// deleteWorkroom/deleteProject reap a target's surfaces, since neither goes through
  /// `hasLiveRunCommand`. Must see a live session registered in ANY window, and must not match an
  /// unrelated target id.
  func testHasLiveInvestigateSessionAcrossWindows() {
    let registry = WindowRegistry()
    let store = makeStore([project("/a", workrooms: ["main", "other"])])
    registry.register(window: NSWindow(), store: store)
    let t = target(store, "/a", "main")
    let other = target(store, "/a", "other")

    XCTAssertFalse(registry.hasLiveInvestigateSession(for: [t.id]))

    let tab = store.startInvestigate(bannerState: investigateBanner(t), target: t, surface: nil)
    try! XCTUnwrap(tab.surface).liveProcessOverrideForTesting = true

    XCTAssertTrue(registry.hasLiveInvestigateSession(for: [t.id]))
    XCTAssertFalse(
      registry.hasLiveInvestigateSession(for: [other.id]), "must not match an unrelated target id")
  }

  /// A third teardown path, distinct from `closeTab`/quit: deleting a workroom/project reaps the
  /// target directly (`reapTargetLocally`), which must also purge `investigateTabs` via the same
  /// `onTabsRemoved` route — this exercises that specific caller, not just `closeTab`.
  func testInvestigateTabsClearedWhenTargetReapedWithLiveInvestigateTab() async {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    let tab = store.startInvestigate(bannerState: investigateBanner(t), target: t, surface: nil)
    try! XCTUnwrap(tab.surface).liveProcessOverrideForTesting = true
    XCTAssertTrue(store.hasLiveRunCommand)

    await store.reapTargetLocally(t.id)

    XCTAssertNil(store.investigateTabs[tab.id])
    XCTAssertFalse(store.hasLiveRunCommand)
  }

  /// `investigateTabs` allows many tabs per target (unlike the one-slot-per-target `runStates`) —
  /// a second live Investigate session on the same target must not be shadowed by the first one's
  /// (possibly already-dead) liveness, and closing just the live one must drop `hasLiveRunCommand`.
  func testHasLiveRunCommandTrueWithMultipleConcurrentInvestigateTabsOnSameTarget() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    let bannerState = investigateBanner(t)
    let tab1 = store.startInvestigate(bannerState: bannerState, target: t, surface: nil)
    let tab2 = store.startInvestigate(bannerState: bannerState, target: t, surface: nil)
    try! XCTUnwrap(tab1.surface).liveProcessOverrideForTesting = false
    try! XCTUnwrap(tab2.surface).liveProcessOverrideForTesting = true

    XCTAssertTrue(
      store.hasLiveRunCommand, "a second live Investigate tab on the same target must still count")

    store.terminals.closeTab(tab2.id, for: t)
    XCTAssertFalse(store.hasLiveRunCommand, "closing the only live tab drops liveness")
  }

  // Note: a direct `WindowCloseGuard.windowShouldClose` test for the "defer, then gracefully stop"
  // branch was attempted here and dropped — that branch calls `sender.close()` on the passed
  // `NSWindow`, and a bare `NSWindow()` with no real window-server backing crashes XCTest's
  // post-test memory checker (SIGSEGV in `objc_release` during
  // `XCTMemoryChecker._assertInvalidObjectsDeallocatedAfterScope:`), not the app itself. The
  // underlying logic this branch depends on (`hasLiveRunCommand`, `gracefullyStopAllRunCommands`
  // resolving immediately with no `runStates` entries) is already covered above; this specific
  // AppKit-glue path is verified manually (see the plan's Verification section) — matching the
  // existing precedent in `MultiWindowTests.swift` for a similarly NSWindow-bound case ("isn't
  // cleanly unit-testable; it's verified live").

  // MARK: Background run, status outcomes, run toast (issue #67)

  func testStartRunsInBackgroundWithoutStealingFocus() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    let shell = store.terminals.addTab(for: t).id  // a tab the user is on (addTab focuses it)

    store.startRunCommand(for: t)  // issue #67: starts in the background

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(
      store.terminals.activeTab(for: t)?.id, shell, "a background start must not steal focus")
    XCTAssertNotEqual(store.terminals.activeTab(for: t)?.id, store.runTabID(for: t.id))
  }

  func testToggleStartDoesNotNavigate() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = nil  // unrelated selection state

    store.toggleRunCommand(for: t)  // sidebar ▶ → start

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertNil(store.selectedTargetID, "issue #67: starting from the sidebar must not navigate")
  }

  func testCleanExitMapsToExitedOutcome() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.applyRunStatus("exited 0", for: t)

    XCTAssertEqual(store.runOutcomes[t.id], .exited(code: 0))
  }

  func testNonZeroExitMapsToFailedOutcome() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.applyRunStatus("exited 137", for: t)

    XCTAssertEqual(
      store.runOutcomes[t.id], .exited(code: 137), "a non-zero exit is recorded as such")
  }

  func testUserStopThenExitMapsToStopped() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.stopRunCommand(for: t)  // SIGUSR2 → .running(interrupted: true)
    store.applyRunStatus("stopped", for: t)  // supervisor confirms the stop

    XCTAssertEqual(store.runOutcomes[t.id], .stoppedByUser, "a user Stop is not a failure")
  }

  func testRunToastShownWhenBackgroundedHiddenWhenViewing() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)  // a focused shell, so the run isn't the visible tab

    store.startRunCommand(for: t)  // background
    XCTAssertEqual(store.runToastItems.map(\.targetID), [t.id], "a backgrounded run shows a toast")
    XCTAssertEqual(store.runToastItems.first?.status, .running)

    // Open the run terminal → it becomes the visible tab → the toast hides (not dismissed).
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.terminals.focus(runID, for: t)
    XCTAssertTrue(store.runToastItems.isEmpty, "no toast for the run you're looking at")
  }

  func testLiveRunToastOnlyForSelectedWorkroom() {
    // issue #73: two workrooms running in the background must not pop a live toast each — only the
    // selected workroom's backgrounded run shows a "running" toast; the other's stays silent.
    let store = makeStore([project("/a", workrooms: ["main", "two"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t1 = target(store, "/a", "main")
    let t2 = target(store, "/a", "two")

    // main selected, both runs backgrounded (a focused shell on each, so neither run is visible).
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t1)
    _ = store.terminals.addTab(for: t2)
    store.startRunCommand(for: t2)  // the other workroom's run, started first
    store.startRunCommand(for: t1)  // the selected workroom's run

    XCTAssertEqual(
      store.runToastItems.map(\.targetID), [t1.id],
      "only the selected workroom's live run toasts — not every open workroom (issue #73)")

    // Switch selection → the toast follows the selected workroom, still just one.
    store.selectedTargetID = .workroom(project: "/a", name: "two")
    XCTAssertEqual(
      store.runToastItems.map(\.targetID), [t2.id],
      "the live toast tracks the selected workroom, never both at once")
  }

  func testDismissRunToastHidesItWithoutStoppingTheRun() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)
    store.startRunCommand(for: t)
    XCTAssertFalse(store.runToastItems.isEmpty)

    store.dismissRunToast(for: t.id)

    XCTAssertTrue(store.runToastItems.isEmpty, "✕ dismisses the toast")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id), "but the run keeps running")
  }

  func testRunOrFocusFocusesAnAlreadyRunningBackgroundRun() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    let shell = store.terminals.addTab(for: t).id
    store.startRunCommand(for: t)  // background; the shell stays focused
    XCTAssertEqual(store.terminals.activeTab(for: t)?.id, shell)

    store.runOrFocusRunCommand()  // ⌘R while running → "show me the run"

    XCTAssertEqual(
      store.terminals.activeTab(for: t)?.id, store.runTabID(for: t.id),
      "⌘R on a running background run focuses it")
  }

  /// Regression (issue #7): ⌘R / toolbar Run pressed right after a Stop (a Ctrl-C is in flight,
  /// `.running(interrupted: true)`) must RESTART the run — wait out the stop and respawn — not
  /// silently focus a dying server. Before the fix this start was swallowed (the pane just focused)
  /// and the user was left with nothing running after a quick Stop → Run.
  func testRunOrFocusAfterStopRestartsRatherThanSwallowing() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))

    store.stopRunCommand(for: t)  // SIGUSR2 → .running(interrupted: true), stop in flight
    signals.removeAll()

    store.runOrFocusRunCommand()  // ⌘R during the stop → must restart, not swallow

    XCTAssertTrue(
      signals.contains { $0.1 == SIGUSR1 },
      "⌘R during a stop must restart (SIGUSR1), not silently focus a dying run")
    XCTAssertEqual(store.runTabID(for: t.id), tab, "restart keeps the same run tab")
  }

  func testRestartPreservesFocusWhenRunTabWasFocused() {
    // Under the supervisor model, restart signals SIGUSR1 and the same tab stays.
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.terminals.focus(runID, for: t)  // user opened the run terminal

    store.restartRunCommand(for: t)  // SIGUSR1 → .restarting (same tab)
    XCTAssertTrue(signals.contains { $0.1 == SIGUSR1 }, "restart must send SIGUSR1")

    store.applyRunStatus("running 1", for: t)  // supervisor relaunched the child

    XCTAssertEqual(store.runTabID(for: t.id), runID, "same tab throughout the restart")
    XCTAssertEqual(
      store.terminals.activeTab(for: t)?.id, runID,
      "restart keeps the run focused when it was focused (codex correction)")
  }

  func testBackgroundRestartStaysBackground() {
    // Under the supervisor model, restart signals SIGUSR1 and the same tab stays; focus is preserved.
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    let shell = store.terminals.addTab(for: t).id  // focused
    store.startRunCommand(for: t)  // background
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertEqual(store.terminals.activeTab(for: t)?.id, shell)

    store.restartRunCommand(for: t)  // SIGUSR1 → .restarting (same tab, no focus change)
    XCTAssertTrue(signals.contains { $0.1 == SIGUSR1 }, "restart must send SIGUSR1")

    store.applyRunStatus("running 1", for: t)  // child relaunched by supervisor

    XCTAssertEqual(store.runTabID(for: t.id), runID, "same tab throughout the restart")
    XCTAssertEqual(
      store.terminals.activeTab(for: t)?.id, shell,
      "a background restart stays backgrounded — focus stays on the shell")
  }

  func testRunVisibleInSplitHidesToastEvenWhenNotFocused() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)  // background
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    let sibling = store.terminals.addTab(for: t).id
    // Split [sibling, run] — both panes visible at once.
    store.terminals.moveTabIntoSplit(runID, ontoEdge: .right, of: sibling, for: t)
    store.terminals.focus(sibling, for: t)  // focus the sibling, not the run

    XCTAssertTrue(
      store.runToastItems.isEmpty,
      "a run visible in a split hides its toast even when the sibling is focused (split-aware)")
  }

  func testFailedToStartWhenSurfaceSpawnFails() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    // Simulate `ghostty_surface_new` returning nil for the backgrounded run surface.
    store.terminals.makeView = { _, cwd, command in
      let v = GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
      v.spawnFailOverrideForTesting = true
      return v
    }
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)  // background; spawn "fails"

    XCTAssertFalse(store.isRunCommandRunning(for: t.id), "a failed spawn is not 'running'")
    XCTAssertEqual(store.runOutcomes[t.id], .failedToStart)
    XCTAssertEqual(
      store.runToastItems.first?.status, .failedToStart, "the toast surfaces the failure, not a lie"
    )
  }

  func testRunToastAutoDismissesAfterTerminalState() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    var pending: [DispatchWorkItem] = []
    store.scheduleRunToastDismiss = { _, body in
      let work = DispatchWorkItem(block: body)
      pending.append(work)
      return work
    }
    // background (no selection → no live toast; terminal toast below)
    store.startRunCommand(for: t)

    store.applyRunStatus("exited 0", for: t)  // terminal → schedules the auto-dismiss
    XCTAssertEqual(pending.count, 1)
    XCTAssertFalse(store.runToastItems.isEmpty, "the toast lingers right after the run ends")

    pending[0].perform()  // the linger elapses
    XCTAssertTrue(store.runToastItems.isEmpty, "the toast auto-dismisses after the linger")
  }

  func testRestartCancelsStaleAutoDismissTimer() {
    // With a dead supervisor (seam returns false), restartRunCommand takes the respawn path
    // (respawnRunCommand), which calls resetRunToast → cancels the stale timer.
    let store = makeStoreDeadSupervisor([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    var pending: [DispatchWorkItem] = []
    store.scheduleRunToastDismiss = { _, body in
      let work = DispatchWorkItem(block: body)
      pending.append(work)
      return work
    }
    store.startRunCommand(for: t)
    store.applyRunStatus("exited 0", for: t)  // .stopped → schedules pending[0]
    XCTAssertEqual(pending.count, 1)

    store.restartRunCommand(for: t)  // .stopped + dead supervisor → respawn → resetRunToast

    XCTAssertTrue(pending[0].isCancelled, "restart cancels the stale auto-dismiss timer")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id), "and the fresh run is running")
  }

  func testRunningToastAutoHidesAfterLinger() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "npm run dev", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)  // focused shell → the run is backgrounded + toasted
    var pending: [DispatchWorkItem] = []
    store.scheduleRunToastDismiss = { _, body in
      let work = DispatchWorkItem(block: body)
      pending.append(work)
      return work
    }
    store.startRunCommand(for: t)
    store.applyRunStatus("running", for: t)  // live edge → schedules the running-toast auto-hide

    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(
      store.runToastItems.first?.status, .running, "the live toast shows while running")

    pending[0].perform()  // the running linger elapses

    XCTAssertTrue(store.runToastItems.isEmpty, "the live toast auto-hides after the linger")
    XCTAssertTrue(store.runningToastAutoHidden.contains(t.id))
    XCTAssertFalse(
      store.dismissedRunToasts.contains(t.id), "auto-hide isn't a permanent dismissal")
  }

  func testRunningToastAutoHideDoesNotSuppressLaterTerminalToast() {
    // Regression guard: a run that quietly auto-hid its "still running" toast must still surface a
    // failure toast if it later crashes — the two dismissal sets are independent.
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "npm run dev", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)
    var pending: [DispatchWorkItem] = []
    store.scheduleRunToastDismiss = { _, body in
      let work = DispatchWorkItem(block: body)
      pending.append(work)
      return work
    }
    store.startRunCommand(for: t)
    store.applyRunStatus("running", for: t)
    pending[0].perform()  // the running toast auto-hides
    XCTAssertTrue(store.runToastItems.isEmpty)

    store.applyRunStatus("exited 1", for: t)  // the run later crashes

    XCTAssertEqual(
      store.runToastItems.first?.status, .failed(code: 1),
      "a later failure toast isn't swallowed by the earlier running auto-hide")
  }

  func testRestartReArmsRunningToastAfterAutoHide() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "npm run dev", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)
    var pending: [DispatchWorkItem] = []
    store.scheduleRunToastDismiss = { _, body in
      let work = DispatchWorkItem(block: body)
      pending.append(work)
      return work
    }
    store.startRunCommand(for: t)
    store.applyRunStatus("running", for: t)
    pending[0].perform()  // auto-hidden
    XCTAssertTrue(store.runToastItems.isEmpty)

    store.restartRunCommand(for: t)  // alive supervisor → SIGUSR1 → .restarting, re-arms the toast

    XCTAssertFalse(
      store.runningToastAutoHidden.contains(t.id), "restarting clears the stale auto-hide flag")
    XCTAssertEqual(store.runToastItems.first?.status, .restarting)

    store.applyRunStatus("running", for: t)  // restart completes

    XCTAssertEqual(store.runToastItems.first?.status, .running)
  }

  func testRunOutcomeBannerWorthiness() {
    // A genuine failure warrants a banner; a clean exit or a user Stop does not (Arch #7).
    XCTAssertTrue(AppStore.runOutcomeIsBannerWorthy(.exited(code: 1)))
    XCTAssertTrue(AppStore.runOutcomeIsBannerWorthy(.exited(code: 137)))
    XCTAssertTrue(AppStore.runOutcomeIsBannerWorthy(.failedToStart))
    XCTAssertFalse(AppStore.runOutcomeIsBannerWorthy(.exited(code: 0)))
    XCTAssertFalse(AppStore.runOutcomeIsBannerWorthy(.stoppedByUser))
    XCTAssertFalse(AppStore.runOutcomeIsBannerWorthy(nil))
  }

  func testTappingRunToastOpensTheRunAndDismissesIt() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)  // focused shell → the run is backgrounded + toasted
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertFalse(store.runToastItems.isEmpty)

    // What a card tap fires (see ToastStack): open the run terminal AND dismiss the toast.
    store.openRunToast(for: t.id)
    store.dismissRunToast(for: t.id)

    XCTAssertEqual(store.terminals.activeTab(for: t)?.id, runID, "the tap opens the run terminal")
    XCTAssertTrue(store.dismissedRunToasts.contains(t.id), "the tap dismisses the toast for good")
    XCTAssertTrue(store.runToastItems.isEmpty)
  }

  // MARK: Success/failure detection (issue #79)

  func testRunOutcomeIsFailure() {
    XCTAssertFalse(AppStore.RunOutcome.exited(code: 0).isFailure, "a clean exit is not a failure")
    XCTAssertTrue(AppStore.RunOutcome.exited(code: 1).isFailure)
    XCTAssertTrue(AppStore.RunOutcome.exited(code: 137).isFailure)
    XCTAssertTrue(AppStore.RunOutcome.failedToStart.isFailure)
    XCTAssertFalse(AppStore.RunOutcome.stoppedByUser.isFailure, "a user stop is not a failure")
  }

  func testRunFailedTracksOutcome() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    XCTAssertFalse(store.runFailed(for: t.id), "no run yet → not failed")
    store.startRunCommand(for: t)
    XCTAssertFalse(store.runFailed(for: t.id), "running → not failed")
    store.applyRunStatus("exited 1", for: t)
    XCTAssertTrue(store.runFailed(for: t.id), "a non-zero self-exit → failed (drives the red icon)")
  }

  func testCleanExitIsNotFailed() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    store.applyRunStatus("exited 0", for: t)
    XCTAssertFalse(store.runFailed(for: t.id), "a clean exit shows no red icon")
  }

  func testFailureToastShowsEvenWhenViewingRunTab() {
    // #79: terminal-state toasts bypass the hide-when-visible rule (live toasts keep it).
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.terminals.focus(runID, for: t)  // viewing the run tab
    XCTAssertTrue(store.runToastItems.isEmpty, "no LIVE toast for the tab you're watching")

    store.applyRunStatus("exited 1", for: t)
    XCTAssertEqual(
      store.runToastItems.first?.status, .failed(code: 1),
      "a failure toast shows even on the focused run tab (#79 always-show)")
  }

  func testSuccessToastShowsEvenWhenViewingRunTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.terminals.focus(runID, for: t)

    store.applyRunStatus("exited 0", for: t)
    XCTAssertEqual(
      store.runToastItems.first?.status, .exited,
      "a success toast shows even on the focused run tab")
  }

  func testUserStopShowsNoToast() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.stopRunCommand(for: t)  // SIGUSR2 → interrupted
    store.applyRunStatus("stopped", for: t)  // supervisor confirms

    XCTAssertEqual(store.runOutcomes[t.id], .stoppedByUser)
    XCTAssertTrue(store.runToastItems.isEmpty, "a user-initiated stop shows no toast (#79)")
    XCTAssertFalse(store.runFailed(for: t.id), "and no red icon")
  }

  func testRestartShowsNoTerminalToast() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.restartRunCommand(for: t)  // SIGUSR1 → .restarting

    XCTAssertFalse(
      store.runToastItems.contains { $0.status.isTerminal },
      "a restart never surfaces a success/failure toast (#79)")
  }

  func testClosingRunTabClearsFailureOutcome() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.applyRunStatus("exited 1", for: t)
    XCTAssertTrue(store.runFailed(for: t.id))

    store.terminals.closeTab(runID, for: t)

    XCTAssertNil(store.runOutcomes[t.id], "closing the run tab clears the outcome (#79)")
    XCTAssertFalse(store.runFailed(for: t.id), "so the red icon resets")
  }

  // MARK: Phantom respawn after teardown (issue #7)

  /// The flaky "A server is already running" bug: a run tab's surface view can be re-mounted by
  /// SwiftUI/AppKit AFTER its tab closed (a `closeTab` teardown racing a still-pending view update).
  /// `viewDidMoveToWindow` → `createSurface` would then relaunch the run command on the dead view,
  /// spawning a SECOND, UNTRACKED supervisor + dev server the app can't stop — which orphans on the
  /// port and makes the next start fail with "A server is already running". `tearDown()` must make the
  /// view permanently unable to re-spawn. (The process-level half is covered by the supervisor PTY
  /// integration test, `Resources/run-supervisor/test_supervisor.py`.)
  func testTornDownRunViewNeverRespawns() {
    // spawnsSurface: true so the test exercises the real spawn-eligibility predicate (not the test
    // no-op seam) — `canSpawnSurface` is true for a fresh view and must flip to false after teardown.
    let view = GhosttySurfaceView(
      workingDirectory: "/tmp", command: "bin/rails s", spawnsSurface: true)
    XCTAssertTrue(view.canSpawnSurface, "a fresh run view is eligible to spawn its surface")
    XCTAssertFalse(view.isTornDown)

    view.tearDown()

    XCTAssertTrue(view.isTornDown, "tearDown marks the view dead")
    XCTAssertFalse(
      view.canSpawnSurface,
      "a torn-down view must NEVER re-spawn — a re-mount can't relaunch the command (phantom server)"
    )
  }

  /// A live (not-yet-torn-down) view stays spawn-eligible — guards against a fix that over-broadly
  /// blocks legitimate (re)spawns (e.g. the background-run off-window spawn or a normal window mount).
  func testLiveRunViewRemainsSpawnEligible() {
    let view = GhosttySurfaceView(
      workingDirectory: "/tmp", command: "bin/rails s", spawnsSurface: true)
    XCTAssertTrue(view.canSpawnSurface, "a live view must still be able to spawn its surface")
  }
}
