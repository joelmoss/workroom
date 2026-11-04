import XCTest

@testable import Workroom

/// The Quick Terminal runs a workroom's own `TerminalSessions`, with three differences: its shells
/// are never kept, its panes never move to a window of their own, and each pane reads its own
/// folder's branch, since no workroom knows it.
@MainActor
final class QuickTerminalSessionsTests: XCTestCase {
  private let target = TerminalTarget(
    id: "workroom.quickTerminal", title: "Quick Terminal", path: "/a", unavailability: nil)

  private func makeSessions(quickTerminal: Bool = true) -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    sessions.recordUnrecognizedTool = { _ in }
    sessions.recency = SwitcherRecency()
    sessions.resolveBranch = { "branch\($0)" }
    // No real background helper: a workroom pane here must not open a session on this Mac's.
    sessions.sessionService = PersistentSessionService(
      probe: { _ in .notBundled }, ownership: { _ in .notOwned })
    if quickTerminal {
      sessions.persistsSessions = false
      sessions.allowsDetach = false
    }
    return sessions
  }

  private func state(_ id: TerminalTab.ID, in sessions: TerminalSessions) -> TerminalState? {
    guard case .terminal(let state) = sessions.tab(id, for: target)?.content else { return nil }
    return state
  }

  func testPolicyKeepsNoSessionWhereSessionsDontPersist() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        isAvailable: true, inProcessCommand: false, hasExistingSession: true, persists: false,
        isFixture: false))
  }

  func testAQuickTerminalPaneHasNoSessionEvenWhenHandedOne() throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target, sessionID: UUID())
    let state = try XCTUnwrap(state(tab.id, in: sessions))
    XCTAssertNil(state.sessionID, "never a background session, so never kept")
    XCTAssertNil(state.view.persistentSessionID)
  }

  func testAQuickTerminalPaneNeverMovesToAWindow() {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    XCTAssertNil(tab.surface?.onToggleWindow, "no Move to New Window in its right-click menu")
    sessions.detachPane(tab.id, for: target, at: .zero)
    XCTAssertTrue(sessions.detachedTabIDs.isEmpty, "a drag out of the window leaves it put")

    let workroom = makeSessions(quickTerminal: false)
    XCTAssertNotNil(
      workroom.addTab(for: target).surface?.onToggleWindow, "workroom panes still can")
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
