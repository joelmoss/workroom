import WorkroomSessionProtocol
import XCTest

@testable import Workroom

final class TerminalPersistentSessionPolicyTests: XCTestCase {
  func testOnWhenAvailable() {
    XCTAssertTrue(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        isAvailable: true,
        isRunCommand: false,
        hasExistingSession: false,
        isFixture: false))
  }

  func testRunCommandAndFixtureAreExcluded() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        isAvailable: true, isRunCommand: true,
        hasExistingSession: false, isFixture: false))
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        isAvailable: true, isRunCommand: false,
        hasExistingSession: false, isFixture: true))
  }

  /// No backend can take a NEW session, so a fresh pane gets none.
  func testUnavailableHelperGivesANewPaneNoSession() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        isAvailable: false,
        isRunCommand: false,
        hasExistingSession: false,
        isFixture: false))
  }

  /// REGRESSION, and the reason `hasExistingSession` exists.
  ///
  /// `isAvailable` answers for the backend a NEW session would go to. A RESTORED pane already has
  /// an id naming a session some helper may still be holding, and running that id through the same
  /// gate discarded it before anything could ask who owned it — so an unhealthy agent silently
  /// stranded every session the Swift daemon was still holding, one layer above the fix that was
  /// supposed to prevent exactly that. Keeping the id is safe: if nothing can attach to it,
  /// `attachCommand` returns nil and the pane opens a plain shell anyway.
  func testARestoredSessionSurvivesAnUnavailableHelper() {
    XCTAssertTrue(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        isAvailable: false,
        isRunCommand: false,
        hasExistingSession: true,
        isFixture: false),
      "a pane restoring a session it already had must keep its id so the owner can be resolved")
  }

  /// A run command is still excluded even when restoring, so the bypass cannot widen past its case.
  func testARestoredRunCommandIsStillExcluded() {
    XCTAssertFalse(
      TerminalPersistentSessionPolicy.usesPersistentSession(
        isAvailable: false,
        isRunCommand: true,
        hasExistingSession: true,
        isFixture: false))
  }

}

final class TerminalPayloadSessionIDTests: XCTestCase {
  func testAbsentSessionIDStillDecodes() throws {
    let json = """
      {"defaultTitle":"Terminal 1","cwd":"/tmp"}
      """.data(using: .utf8)!
    let payload = try JSONDecoder().decode(TerminalPayload.self, from: json)
    XCTAssertEqual(payload.defaultTitle, "Terminal 1")
    XCTAssertNil(payload.sessionID)
  }

  func testSessionIDRoundTrips() throws {
    let payload = TerminalPayload(
      defaultTitle: "Terminal 1", cwd: "/tmp", sessionID: UUID().uuidString)
    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(TerminalPayload.self, from: data)
    XCTAssertEqual(decoded.sessionID, payload.sessionID)
  }
}

final class OrphanedSessionTests: XCTestCase {
  /// "Stop Detached Terminals" spares every session a window will reattach to, not just open tabs:
  /// a remote target held back until its host is reachable keeps its saved session ids, and those
  /// shells look detached until it comes back.
  @MainActor
  func testHeldSessionsIncludeADeferredTarget() {
    let store = AppStore()
    let held = UUID()
    store.deferredTargetSessions["wr|/p|remote"] = TargetSession(
      targetID: "wr|/p|remote",
      tabs: [
        TabSession(
          key: "t1", kind: TabSession.terminalKind,
          terminal: TerminalPayload(
            defaultTitle: "Terminal 1", cwd: nil, sessionID: held.uuidString))
      ])
    XCTAssertTrue(store.heldSessionIDs.contains(held))
  }

  private func session(workroom: String?) -> SessionDescriptor {
    SessionDescriptor(
      identifier: SessionIdentifier(UUID()), shellProcessID: 1,
      ttyDevice: 0, workingDirectory: "/tmp", isAttached: false,
      metadata: workroom.map {
        [SessionEnvironmentEntry(key: SessionMetadataKey.workroom, value: $0)]
      }
        ?? [])
  }

  /// Only a session tagged with a workroom that no longer resolves is orphaned. An untagged one
  /// proves nothing about where it belonged, so it is kept.
  func testOnlyUnresolvedWorkroomsAreOrphaned() {
    let live = session(workroom: "wr|/p|live")
    let gone = session(workroom: "wr|/p|gone")
    let untagged = session(workroom: nil)
    let orphans = PersistentSessionService.orphanedSessionIDs(
      [live, gone, untagged], resolves: { $0 == "wr|/p|live" })
    XCTAssertEqual(orphans, [gone.identifier.uuid!])
  }

  /// REGRESSION GUARD. A test launch lists only fixture projects while the helpers it would ask
  /// belong to the developer's own Workroom Dev, so the sweep must never run from one, and must
  /// not use up the once-per-process flag either.
  @MainActor
  func testATestLaunchNeverSweeps() {
    let projects = UITestFixture.projects()
    XCTAssertFalse(projects.isEmpty, "the empty-listing guard would make this pass vacuously")
    let before = AppStore.sweptOrphanedSessions
    AppStore().endOrphanedSessionsOnce(in: projects, isTestProcess: true)
    XCTAssertEqual(AppStore.sweptOrphanedSessions, before)
  }
}
