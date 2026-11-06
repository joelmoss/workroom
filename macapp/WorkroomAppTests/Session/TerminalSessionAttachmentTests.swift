import WorkroomDomain
import XCTest

@testable import Workroom

/// Detached sessions > Active tab (`TerminalSessionAttachment`): the one place besides a tab's
/// making that points a terminal at a session. The tab's session id is what every reader reads
/// (saved layout, program status, host cwd, Claude profile), and the surface's attach id is what it
/// reattaches with, so the two must move together, and a refused attach must move neither.
@MainActor
final class TerminalSessionAttachmentTests: XCTestCase {
  private let target = TerminalTarget(
    id: .workroom(project: "/p", name: "foo"), title: "foo", path: "/tmp", isMissing: false)

  /// No helper (so a new pane gets no session of its own) and an inert surface (so a reattach
  /// spawns nothing).
  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
    }
    sessions.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned })
    sessions.programStatus = ProgramStatusMonitor()
    sessions.recordUnrecognizedTool = { _ in }
    sessions.recency = SwitcherRecency()
    return sessions
  }

  func testTheFocusedPaneTakesTheSessionOnItsTabAndItsSurface() throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    let session = UUID()
    XCTAssertNil(sessions.sessionID(forTab: tab.id, inTarget: target.id), "fixture: none yet")

    XCTAssertTrue(
      TerminalSessionAttachment.attachToActivePane(
        sessionID: session, target: target, sessions: sessions))

    XCTAssertEqual(sessions.sessionID(forTab: tab.id, inTarget: target.id), session)
    let surface = try XCTUnwrap(sessions.surface(tab))
    XCTAssertEqual(surface.attachment.sessionID, session, "the surface reattaches to it")
    XCTAssertTrue(surface.attachment.isRestored, "it names a session that already exists")
    let saved = try XCTUnwrap(sessions.tab(tab.id, for: target)).content
    guard case .terminal(let state) = saved else { return XCTFail("not a terminal") }
    XCTAssertEqual(
      TabSession(key: "t", tab: TerminalTab(content: .terminal(state)))?.terminal?.sessionID,
      session.uuidString, "and a saved layout keeps it")
  }

  /// Negative control: a session another tab shows is refused, and the focused pane keeps what it
  /// had, on its tab and its surface alike.
  func testASessionAnotherTabShowsIsRefusedAndMovesNothing() throws {
    let sessions = makeSessions()
    let owner = sessions.addTab(for: target)
    let session = UUID()
    XCTAssertTrue(
      TerminalSessionAttachment.attachToActivePane(
        sessionID: session, target: target, sessions: sessions))
    let other = sessions.addTab(for: target)
    XCTAssertEqual(
      sessions.focusedTab(for: target)?.id, other.id, "fixture: the new tab is focused")

    XCTAssertFalse(
      TerminalSessionAttachment.attachToActivePane(
        sessionID: session, target: target, sessions: sessions))

    XCTAssertNil(sessions.sessionID(forTab: other.id, inTarget: target.id))
    XCTAssertNil(try XCTUnwrap(sessions.surface(other)).attachment.sessionID)
    XCTAssertEqual(sessions.owner(of: session, in: target), owner.id, "the owner keeps it")
  }

  /// A content pane has no session to point anywhere.
  func testAFocusedContentPaneTakesNoSession() {
    let sessions = makeSessions()
    sessions.addTab(for: target)
    let diff = sessions.openDiffPreview(
      DiffDescriptor(path: "a.swift", change: .modified, source: .gitWorktree, isPreview: true),
      for: target)
    XCTAssertEqual(sessions.focusedTab(for: target)?.id, diff, "fixture: the diff is focused")

    XCTAssertFalse(
      TerminalSessionAttachment.attachToActivePane(
        sessionID: UUID(), target: target, sessions: sessions))
    XCTAssertTrue(sessions.ownedSessionIDs(for: target).isEmpty)
  }
}
