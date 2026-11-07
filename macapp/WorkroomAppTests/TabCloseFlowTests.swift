import AppKit
import XCTest

@testable import Workroom

/// A host's terminal-tab close, driven over a bare `TerminalPanes` and `RunCommandController` with
/// no `AppStore`, as a host other than a workroom window (the Quick Terminal) owns one. The confirm
/// state is pinned per flow (`confirmOnCloseOverride`), never by writing the shared key, and the
/// confirm is shown through `presentConfirmForTesting`: a test host has no window, so the real one
/// would be a blocking `runModal()`.
@MainActor
final class TabCloseFlowTests: XCTestCase {
  private let target = TerminalTarget(
    id: .workroom(project: "/p", name: "foo"), title: "foo", path: "/tmp", isMissing: false)

  private var terminals: TerminalPanes!
  private var runCommand: RunCommandController!

  override func setUp() {
    super.setUp()
    terminals = TerminalPanes()
    // A test surface never spawns, so it has no process and reads as live (`processHasExited`
    // is false before a surface exists), which is what a confirm needs to be asked for.
    terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    terminals.recordUnrecognizedTool = { _ in }
    terminals.sessionService = PersistentSessionService(
      probe: { _ in .notBundled }, ownership: { _ in .notOwned })
    runCommand = RunCommandController(terminals: terminals)
  }

  override func tearDown() {
    terminals = nil
    runCommand = nil
    super.tearDown()
  }

  private func makeFlow(confirmOnClose: Bool) -> TabCloseFlow {
    let flow = TabCloseFlow(terminals: terminals, runCommand: runCommand)
    flow.confirmOnCloseOverride = confirmOnClose
    flow.presentConfirmForTesting = { _, _ in XCTFail("this close must not ask") }
    return flow
  }

  private func persistentDiff(_ path: String) -> DiffDescriptor {
    DiffDescriptor(path: path, change: .modified, source: .gitWorktree, isPreview: false)
  }

  /// Let one main-queue turn run, so a confirm deferred by a turn has had its chance to show.
  private func drainMainQueue() {
    let drained = expectation(description: "main queue turn")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  /// Value: protects=a close with the confirm off tearing tabs down at once, for one tab, others and all;
  /// fails_when=the flow stops reaching `closeTab`, or needs an AppStore to; why_new=the flow is new and
  /// AppStoreCloseTabsTests drives it only through the store; seam=confirmOnCloseOverride.
  func testWithTheConfirmOffEachCloseClosesAtOnce() {
    let flow = makeFlow(confirmOnClose: false)
    let first = terminals.addTab(for: target).id
    let keep = terminals.addTab(for: target).id
    terminals.addTab(for: target)

    flow.requestClose(first, for: target)
    XCTAssertNil(terminals.tab(first, for: target))

    flow.requestCloseOthers(keeping: keep, for: target)
    XCTAssertEqual(terminals.tabs(for: target).map(\.id), [keep])
    XCTAssertEqual(terminals.activeTab(for: target)?.id, keep, "focus lands on the kept tab")

    flow.requestCloseAll(for: target)
    XCTAssertTrue(terminals.tabs(for: target).isEmpty)
  }

  /// Value: protects=a batch of only content tabs and exited terminals never prompting, even with the
  /// confirm on (issue #7); fails_when=`closeNeedsConfirm` counts a tab with no surface or an exited
  /// process as live; why_new=AppStoreCloseTabsTests covers content tabs only, never an exited one;
  /// seam=processExitedOverrideForTesting.
  func testContentAndExitedTabsNeverPrompt() throws {
    let flow = makeFlow(confirmOnClose: true)
    terminals.openDiffPersistent(persistentDiff("a.swift"), for: target)
    let exited = terminals.addTab(for: target).id
    try XCTUnwrap(terminals.surface(of: exited)).processExitedOverrideForTesting = true

    flow.requestCloseAll(for: target)

    XCTAssertTrue(terminals.allTabs(for: target).isEmpty, "closed synchronously, no confirm")
    drainMainQueue()
  }

  /// Value: protects=an Investigate tab closing at once rather than through a run's graceful stop;
  /// fails_when=`performClose` treats every run-command tab as the target's run; why_new=only the
  /// surface's close prompt (RunCommandTests) checked it; seam=confirmOnCloseOverride.
  func testAnInvestigateTabClosesAtOnce() {
    let flow = makeFlow(confirmOnClose: false)
    let tab = terminals.addRunTab(for: target, command: "claude", cwd: "/tmp")
    runCommand.investigateTabs[tab.id] = target.id

    flow.requestClose(tab.id, for: target)

    XCTAssertNil(terminals.tab(tab.id, for: target))
    XCTAssertNil(runCommand.investigateTabs[tab.id])
  }

  /// Value: protects=the confirm waiting a turn, showing once however often a close fires while it is
  /// pending, and asking again once answered; fails_when=the re-entrancy guard goes, is not cleared
  /// on an answer, or Cancel still closes; why_new=no test reached the confirm itself, which needed
  /// a window; seam=presentConfirmForTesting.
  func testASecondRequestWhileAConfirmIsPendingDoesNothing() throws {
    let flow = makeFlow(confirmOnClose: true)
    let live = terminals.addTab(for: target).id
    var presented: [(alert: NSAlert, resolve: (NSApplication.ModalResponse) -> Void)] = []
    flow.presentConfirmForTesting = { presented.append(($0, $1)) }

    flow.requestClose(live, for: target)
    XCTAssertTrue(presented.isEmpty, "the confirm waits a turn for the triggering event")
    XCTAssertTrue(flow.isPresentingCloseConfirm)
    flow.requestCloseAll(for: target)
    drainMainQueue()
    flow.requestClose(live, for: target)
    drainMainQueue()

    XCTAssertEqual(presented.count, 1, "one confirm, however often the close fired")
    let title = try XCTUnwrap(terminals.tab(live, for: target)).title
    XCTAssertEqual(presented.first?.alert.messageText, "Close ‘\(title)’?")
    XCTAssertNotNil(terminals.tab(live, for: target), "nothing closes before the answer")

    try XCTUnwrap(presented.first).resolve(.alertSecondButtonReturn)
    XCTAssertFalse(flow.isPresentingCloseConfirm, "an answer clears the guard")
    XCTAssertNotNil(terminals.tab(live, for: target), "Cancel keeps the tab")

    flow.requestClose(live, for: target)
    drainMainQueue()
    XCTAssertEqual(presented.count, 2, "a close after the answer asks again")
    try XCTUnwrap(presented.last).resolve(.alertFirstButtonReturn)
    XCTAssertNil(terminals.tab(live, for: target), "Close closes it")
  }
}
