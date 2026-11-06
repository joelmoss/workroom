import XCTest

@testable import Workroom

/// The Quick Terminal runs a workroom's own `TerminalSessions`, with three differences: its shells
/// are ended at quit rather than kept, its panes never move to a window of their own, and each pane
/// reads its own folder's branch, since no workroom knows it.
@MainActor
final class QuickTerminalSessionsTests: XCTestCase {
  private let target = TerminalTarget(
    id: .quickTerminal, title: "Quick Terminal", path: "/a", unavailability: nil)

  private func makeSessions(
    quickTerminal: Bool = true, backend: SessionBackendAvailability = .notBundled
  ) -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.recency = SwitcherRecency()
    sessions.resolveBranch = { "branch\($0)" }
    // No real background helper: a test surface never attaches, so no session is ever opened.
    sessions.sessionService = PersistentSessionService(
      probe: { _ in backend }, ownership: { _ in .notOwned })
    if quickTerminal {
      sessions.readsPaneBranches = true
      sessions.allowsDetach = false
    }
    return sessions
  }

  private func state(_ id: TerminalTab.ID, in sessions: TerminalSessions) -> TerminalState? {
    guard case .terminal(let state) = sessions.tab(id, for: target)?.content else { return nil }
    return state
  }

  /// Value: protects=a Quick Terminal pane running in a background session like a workroom's, so it
  /// gets "needs you" and "finished" alerts (ADR 0064); fails_when=its sessions are switched off
  /// again; why_new=the old test pinned the opposite; seam=none; no_claim=a real attach.
  func testAQuickTerminalPaneRunsInABackgroundSession() throws {
    let sessions = makeSessions(backend: .ready(version: "test"))
    let tab = sessions.addTab(for: target)
    XCTAssertNotNil(try XCTUnwrap(state(tab.id, in: sessions)).sessionID)
  }

  /// Value: protects=its shells ending at quit while its panes stay open, since a quit must not free
  /// surfaces (ADR 0064); fails_when=a session is missed or the tabs are closed; why_new=new path;
  /// seam=none; no_claim=the daemon actually ending the session (no helper in a unit test).
  func testAtQuitItsSessionsEndAndItsPanesStay() throws {
    let sessions = makeSessions(backend: .ready(version: "test"))
    let first = sessions.addTab(for: target)
    let second = sessions.addTab(for: target)
    let ids = [first, second].compactMap { state($0.id, in: sessions)?.sessionID }
    XCTAssertEqual(ids.count, 2)

    XCTAssertEqual(Set(sessions.endSessionsAtQuit(for: target)), Set(ids))
    XCTAssertEqual(sessions.tabs(for: target).count, 2, "no tab closed, no surface freed")
  }

  func testAQuickTerminalPaneNeverMovesToAWindow() {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    XCTAssertEqual(
      tab.surface?.offersWindowToggle, false, "no Move to New Window in its right-click menu")
    sessions.detachPane(tab.id, for: target, at: .zero)
    XCTAssertTrue(sessions.detachedTabIDs.isEmpty, "a drag out of the window leaves it put")

    let workroom = makeSessions(quickTerminal: false)
    XCTAssertEqual(
      workroom.addTab(for: target).surface?.offersWindowToggle, true, "workroom panes still can")
  }

  func testEachPaneReadsItsOwnFoldersBranch() async throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    await sessions.liveBranchRead(forTab: tab.id)
    XCTAssertEqual(state(tab.id, in: sessions)?.liveBranch, "branch/a")

    try XCTUnwrap(tab.surface).handlePwd("/b")
    await sessions.liveBranchRead(forTab: tab.id)
    XCTAssertEqual(state(tab.id, in: sessions)?.liveBranch, "branch/b", "follows a cd")
  }

  func testAWorkroomPaneTakesItsBranchFromTheWorkroom() async {
    let sessions = makeSessions(quickTerminal: false)
    let tab = sessions.addTab(for: target)
    await sessions.liveBranchRead(forTab: tab.id)
    XCTAssertNil(state(tab.id, in: sessions)?.liveBranch)
  }

  func testALocalClaudeNamesItsAccountOnlyWhenConfirmedByProcess() {
    let claude = GhosttySurfaceView(workingDirectory: "/", command: nil, spawnsSurface: false)
    claude.foregroundProcessNameForTesting = "claude"
    // No live process in a test surface, so no environment: the default login, as workroomd says
    // for an unreadable one.
    XCTAssertEqual(TerminalSessions.localClaudeProfile(of: claude), .reported(""))

    let shell = GhosttySurfaceView(workingDirectory: "/", command: nil, spawnsSurface: false)
    shell.foregroundProcessNameForTesting = "zsh"
    XCTAssertEqual(
      TerminalSessions.localClaudeProfile(of: shell), .notReported, "a title alone names no account"
    )
  }
}
