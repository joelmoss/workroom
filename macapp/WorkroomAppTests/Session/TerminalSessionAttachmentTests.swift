import DaemonConnection
import WorkroomDomain
import XCTest

@testable import Workroom

/// Detached sessions > Active tab (`TerminalSessionAttachment`): the one place besides a tab's
/// making that points a terminal at a session. The tab's session id is what every reader reads
/// (saved layout, program status, host cwd, Claude profile), the surface's attach included, which
/// reads it from the tab; a refused attach moves nothing.
@MainActor
final class TerminalSessionAttachmentTests: XCTestCase {
  private let target = TerminalTarget(
    id: .workroom(project: "/p", name: "foo"), title: "foo", path: "/tmp", isMissing: false)

  /// No helper (so a new pane gets no session of its own) and an inert surface (so a reattach
  /// spawns nothing).
  private func makeSessions() -> TerminalPanes { makeIsolatedPanes() }

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

  // Value: protects=a pane pointed at another session stops holding the old one's remote host,
  // and only its own mark goes (#356); fails_when=the swap no longer clears the old attach, or
  // clears another pane's; why_new=the swap used to clear it from the surface's own copy of the
  // id, which is gone; seam=none
  func testAPanePointedAtAnotherSessionLetsOnlyItsOwnHoldOnTheOldHostGo() throws {
    let service = isolatedPaneSessionService()
    let sessions = makeIsolatedPanes(service: service)
    let old = try registerRemoteSession(on: service, log: "").session
    let host = try XCTUnwrap(service.remoteHost(of: old))
    let tab = sessions.addTab(for: target)
    sessions.giveSession(old, toTab: tab.id, in: target)
    let surface = try XCTUnwrap(sessions.surface(tab))
    XCTAssertNotNil(
      surface.attachment.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    let bystander = UUID()
    XCTAssertNotNil(service.attachCommand(forSession: old, by: bystander))

    XCTAssertTrue(
      TerminalSessionAttachment.attachToActivePane(
        sessionID: UUID(), target: target, sessions: sessions))

    XCTAssertTrue(service.hasAttachedPane(on: host), "another pane's ssh still holds the host")
    service.paneDetached(old, by: bystander)
    XCTAssertFalse(service.hasAttachedPane(on: host), "the swapped pane still holds the old host")
  }

  // Value: protects=a UI-test fixture pane with seeded program status stays a plain shell, as it
  // was when the seeded id lived only on the tab; fails_when=the surface attaches with the status
  // key; why_new=the surface now reads the tab; seam=the fixture's program-status seam and the
  // attachment's plain-fixture flag (a hosted test is no fixture launch)
  func testAFixturePanesSeededStatusNamesNoSessionToAttach() throws {
    let service = isolatedPaneSessionService()
    let sessions = makeIsolatedPanes(service: service)
    let tab = sessions.addTab(for: target)
    let surface = try XCTUnwrap(sessions.surface(tab))
    surface.attachment.isPlainFixturePane = true
    sessions.seedProgramStatusForFixture(
      tab: tab.id, target: target.id, records: [ProgramStatusRecord(id: "", state: .working)])
    let seeded = try XCTUnwrap(sessions.sessionID(forTab: tab.id, inTarget: target.id))
    XCTAssertNotNil(sessions.tab(tab.id, for: target)?.terminal?.programStatus, "its status")
    XCTAssertEqual(surface.attachment.sessionID, seeded, "the surface reads the tab's")
    // Something that would answer an attach for it, as a fixture's bundled daemon might.
    service.registerRemoteSession(
      seeded, on: .remote(UUID()), via: HostDriverRegistry.unreachable, workingDirectory: "/w")

    XCTAssertNil(
      surface.attachment.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false),
      "it launches a login shell")

    // Negative control: pointed at that session, the same pane is restored and attaches.
    XCTAssertTrue(
      TerminalSessionAttachment.attachToActivePane(
        sessionID: seeded, target: target, sessions: sessions))
    XCTAssertNotNil(
      surface.attachment.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
  }

  // Value: protects=a surface keeps its tab's session while the tab moves between windows, and
  // a pane whose tab has gone (a window closing frees its surfaces after its tabs) still lets its
  // host go (#356); fails_when=the surface reads its session through one window's layout, or
  // clears its attach by the tab's session; why_new=the surface used to keep its own copy;
  // seam=none
  func testASurfaceReadsItsTabsSessionInTransitAndLetsItsHostGoOnceTheTabHasGone() throws {
    let service = isolatedPaneSessionService()
    let from = makeIsolatedPanes(service: service)
    let to = makeIsolatedPanes(service: service)
    let session = try registerRemoteSession(on: service, log: "").session
    let host = try XCTUnwrap(service.remoteHost(of: session))
    let tab = from.addTab(for: target)
    from.giveSession(session, toTab: tab.id, in: target)
    let surface = try XCTUnwrap(from.surface(tab))
    addTeardownBlock { surface.tearDown() }
    XCTAssertNotNil(
      surface.attachment.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))

    let handOff = try XCTUnwrap(from.handOff(target))
    XCTAssertEqual(surface.attachment.sessionID, session, "in transit, held by no window")
    to.adopt(handOff)
    XCTAssertEqual(surface.attachment.sessionID, session, "in the window that took it")
    XCTAssertEqual(to.sessionID(forTab: tab.id, inTarget: target.id), session)
    XCTAssertNil(from.sessionID(forTab: tab.id, inTarget: target.id), "not the old one's")

    // As a window closing does: its tabs go, and its surfaces are freed after, untorn-down.
    _ = to.handOff(target)
    TerminalTabs.shared.remove(tab.id)
    XCTAssertNil(surface.attachment.sessionID, "its tab has gone")
    XCTAssertTrue(service.hasAttachedPane(on: host), "fixture: its ssh still holds the host")
    surface.attachment.surfaceGone()
    XCTAssertFalse(service.hasAttachedPane(on: host), "a freed pane whose tab went holds its host")
  }
}
