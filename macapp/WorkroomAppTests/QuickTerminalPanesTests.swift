import XCTest

@testable import Workroom

/// The Quick Terminal runs a workroom's own `TerminalPanes`, with one difference: each pane reads
/// its own folder's branch, since no workroom knows it. Its shells are kept across a quit and its
/// panes pop out, as any group's do (ADR 0077).
@MainActor
final class QuickTerminalPanesTests: XCTestCase {
  private let target = TerminalTarget(
    id: .quickTerminal, title: "Quick Terminal", path: "/a", unavailability: nil)

  private func makeSessions(
    quickTerminal: Bool = true, backend: SessionBackendAvailability = .notBundled
  ) -> TerminalPanes {
    let sessions = TerminalPanes()
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
    }
    return sessions
  }

  private func state(_ id: TerminalTab.ID, in sessions: TerminalPanes) -> TerminalState? {
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

  /// Value: protects=a Quick Terminal pane popping out into a window of its own, as any pane does
  /// (ADR 0077, story 39); fails_when=its panes are kept from detaching again; why_new=the Quick
  /// Terminal is an ordinary group now (#661); seam=none; no_claim=the window itself
  /// (QuickTerminalControllerTests).
  func testAQuickTerminalPaneCanPopOut() {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    XCTAssertEqual(sessions.surface(tab)?.offersWindowToggle, true, "Move to New Window offered")
    sessions.detachPane(tab.id, for: target, at: .zero)
    XCTAssertEqual(sessions.detachedTabIDs, [tab.id])
  }

  func testEachPaneReadsItsOwnFoldersBranch() async throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    await sessions.liveBranchRead(forTab: tab.id)
    XCTAssertEqual(state(tab.id, in: sessions)?.liveBranch, "branch/a")

    try XCTUnwrap(sessions.surface(tab)).handlePwd("/b")
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
    XCTAssertEqual(PaneLiveState.localClaudeProfile(of: claude), .reported(""))

    let shell = GhosttySurfaceView(workingDirectory: "/", command: nil, spawnsSurface: false)
    shell.foregroundProcessNameForTesting = "zsh"
    XCTAssertEqual(
      PaneLiveState.localClaudeProfile(of: shell), .notReported, "a title alone names no account"
    )
  }
}
