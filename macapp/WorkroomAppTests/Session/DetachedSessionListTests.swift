import DaemonConnection
import Synchronization
import WorkroomDomain
import WorkroomVCS
import WorkroomWire
import XCTest

@testable import Workroom

/// The pane footer's detached-sessions list (#584): a remote workroom's comes from its host's
/// daemon, tagged with the workroom's own id (`TerminalTarget.sessionWorkroomKey`), and a local
/// workroom's from this Mac's helpers, as before.
@MainActor
final class DetachedSessionListTests: XCTestCase {
  private let hostID = UUID()
  private let workroomID = UUID()

  private var remote: TerminalTarget {
    TerminalTarget(
      id: .workroom(project: "/p", name: "far"), title: "far", path: "/home/workroom/far",
      unavailability: .remote, remoteHost: hostID, remoteWorkroomID: workroomID)
  }

  private let local = TerminalTarget(
    id: .workroom(project: "/p", name: "near"), title: "near", path: "/tmp", isMissing: false)

  private func session(workroom: String, title: String = "Terminal") -> SessionDescriptor {
    SessionDescriptor(
      identifier: SessionIdentifier(UUID()), shellProcessID: 1, ttyDevice: 0,
      workingDirectory: "/home/workroom/far", isAttached: false,
      metadata: [
        SessionEnvironmentEntry(key: SessionMetadataKey.workroom, value: workroom),
        SessionEnvironmentEntry(key: SessionMetadataKey.title, value: title),
      ])
  }

  /// A list over `connections`, whose local helpers hold `local` and whose sessions end in
  /// `service`.
  private func makeList(
    connections: HostConnectionManager = HostConnectionManager(),
    local: [SessionDescriptor] = [],
    service: PersistentSessionService = isolatedPaneSessionService()
  ) -> DetachedSessionList {
    DetachedSessionList(service: service, connections: connections, localSessions: { local })
  }

  private func connected(_ fixture: SessionsConnection) async throws -> HostConnectionManager {
    let manager = HostConnectionManager()
    _ = try await manager.connect(host: .remote(hostID)) { fixture }
    return manager
  }

  // Value: protects=a remote workroom's footer lists what its host holds and no tab shows (#584);
  // fails_when=the list asks only this Mac's helpers, or matches the host's sessions against
  // `target.id` rather than the workroom's own id; why_new=it never listed a remote session;
  // seam=a stub host connection
  func testARemoteWorkroomListsItsHostsSessionsThatNoTabOwns() async throws {
    let mine = session(workroom: workroomID.uuidString, title: "mine")
    let owned = session(workroom: workroomID.uuidString, title: "owned")
    let underTargetID = session(workroom: remote.id.encoded, title: "under the path's key")
    let another = session(workroom: UUID().uuidString, title: "another workroom's")
    let fixture = SessionsConnection(sessions: [another, owned, mine, underTargetID])
    let list = makeList(
      connections: try await connected(fixture),
      local: [session(workroom: workroomID.uuidString, title: "on this Mac")])

    await list.refresh(remote, ownedSessionIDs: [try XCTUnwrap(owned.identifier.uuid)])

    XCTAssertEqual(list.detached(for: remote).map(\.identifier), [mine.identifier])
    XCTAssertEqual(
      list.detachedByWorkroom.keys.sorted(), [workroomID.uuidString],
      "kept under the workroom's own id, which the footer reads")
  }

  // Value: protects=a host the app has no connection to (unreachable, asleep, stopped, still
  // connecting) lists nothing, and is never connected or woken for a footer; fails_when=the list
  // connects, throws, or keeps an earlier answer; why_new=no remote read existed; seam=a manager
  // with no connection
  func testAHostWithNoConnectionListsNothingAndIsNotConnected() async throws {
    let manager = HostConnectionManager()
    let list = makeList(connections: manager)

    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertTrue(list.detached(for: remote).isEmpty)
    let status = await manager.snapshot(for: .remote(hostID)).status
    XCTAssertEqual(status, .disconnected, "a footer is no reason to reach a host")
  }

  // Value: protects=a host whose daemon fails the list (an older one, a link that drops mid-call)
  // reads as empty, and drops what it listed before; fails_when=the error escapes or a stale list
  // stays; why_new=no remote read existed; seam=a stub host connection
  func testAHostWhoseListFailsListsNothing() async throws {
    let fixture = SessionsConnection(sessions: [session(workroom: workroomID.uuidString)])
    let list = makeList(connections: try await connected(fixture))
    await list.refresh(remote, ownedSessionIDs: [])
    XCTAssertEqual(list.detached(for: remote).count, 1, "fixture: listed while it answers")

    fixture.fails = true
    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertTrue(list.detached(for: remote).isEmpty)
  }

  // Value: protects=the footer lists a remote workroom's sessions once its host connects, which a
  // pane mounting before its own attach brought the host up would otherwise never see;
  // fails_when=the list is read only at mount; why_new=no remote read existed; seam=a manager
  // connected after the follow starts
  func testFollowingARemoteWorkroomListsOnceItsHostConnects() async throws {
    let manager = HostConnectionManager()
    let list = makeList(connections: manager)
    let mine = session(workroom: workroomID.uuidString)
    let fixture = SessionsConnection(sessions: [mine])
    let target = remote
    let follow = Task { await list.follow(target, ownedSessionIDs: { [] }) }
    defer { follow.cancel() }
    XCTAssertTrue(list.detached(for: remote).isEmpty, "fixture: nothing before it connects")

    // Whether the follow subscribes before or after this, it is given the connected snapshot.
    _ = try await manager.connect(host: .remote(hostID)) { fixture }

    try await waitUntil { await MainActor.run { !list.detached(for: target).isEmpty } }
    XCTAssertEqual(list.detached(for: remote).map(\.identifier), [mine.identifier])
    XCTAssertEqual(fixture.listed, 1, "one list per connection, not one per publish")
  }

  // Value: protects=a local workroom's list is what it was: this Mac's helpers, under `target.id`,
  // less its tabs' sessions; fails_when=a local target asks a host, or its key changes;
  // why_new=negative control for the place-aware read; seam=the local source
  func testALocalWorkroomStillListsThisMacsSessions() async throws {
    let mine = session(workroom: local.id.encoded)
    let owned = session(workroom: local.id.encoded)
    let another = session(workroom: "wr|/p|other")
    let fixture = SessionsConnection(sessions: [session(workroom: local.id.encoded)])
    let list = makeList(
      connections: try await connected(fixture), local: [mine, owned, another])

    await list.refresh(local, ownedSessionIDs: [try XCTUnwrap(owned.identifier.uuid)])

    XCTAssertEqual(list.detached(for: local).map(\.identifier), [mine.identifier])
    XCTAssertEqual(list.detachedByWorkroom.keys.sorted(), [local.id.encoded])
    XCTAssertEqual(fixture.listed, 0, "no host is asked")
  }

  // Value: protects=Stop on a remote workroom's detached session ends it on its host, never on
  // this Mac's helpers, which never held it (#584); fails_when=Stop goes to the local service;
  // why_new=the list never held a remote session; seam=a stub host connection
  func testStoppingARemoteSessionEndsItOnItsHost() async throws {
    let mine = session(workroom: workroomID.uuidString)
    let fixture = SessionsConnection(sessions: [mine])
    let list = makeList(connections: try await connected(fixture))
    await list.refresh(remote, ownedSessionIDs: [])
    let id = try XCTUnwrap(mine.identifier.uuid)

    await list.stop(id, in: remote, ownedSessionIDs: [])

    XCTAssertEqual(fixture.ended, [id])
    XCTAssertTrue(list.detached(for: remote).isEmpty, "listed again after the stop")
  }

  // Value: protects=Stop on a remote session a pane here attached to (the one an Active tab swap
  // left running) goes through the service, whose registration keeps its kill retry;
  // fails_when=every remote Stop bypasses the service; why_new=negative control for the branch
  // Stop takes; seam=a stub host connection and a service the test holds
  func testStoppingARegisteredRemoteSessionGoesThroughTheService() async throws {
    let mine = session(workroom: workroomID.uuidString)
    let id = try XCTUnwrap(mine.identifier.uuid)
    let endedByService = Mutex<[UUID]>([])
    let service = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      endRemote: { session, _ in
        endedByService.withLock { $0.append(session) }
        return true
      })
    service.registerRemoteSession(
      id, on: .remote(hostID), via: HostDriverRegistry.unreachable,
      workingDirectory: "/home/workroom/far")
    let fixture = SessionsConnection(sessions: [mine])
    let list = makeList(connections: try await connected(fixture), service: service)

    await list.stop(id, in: remote, ownedSessionIDs: [])

    XCTAssertEqual(endedByService.withLock { $0 }, [id], "ended through its registration")
    XCTAssertTrue(fixture.ended.isEmpty, "not by this list's own call to the host")
    XCTAssertFalse(service.isRemote(id), "and its registration goes with it")
  }

  private func waitUntil(
    timeout: Duration = .seconds(5), _ condition: @escaping () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

/// A host's daemon that lists `sessions` and ends the ones it is asked to, or fails both.
private final class SessionsConnection: HostServiceConnection, Sendable {
  let disconnection = AsyncStream<Void> { _ in }
  private let state: Mutex<(sessions: [SessionDescriptor], fails: Bool, listed: Int, ended: [UUID])>

  init(sessions: [SessionDescriptor]) { state = Mutex((sessions, false, 0, [])) }

  var fails: Bool {
    get { state.withLock { $0.fails } }
    set { state.withLock { $0.fails = newValue } }
  }
  var listed: Int { state.withLock { $0.listed } }
  var ended: [UUID] { state.withLock { $0.ended } }

  func sessions() async throws -> [SessionDescriptor] {
    try state.withLock {
      if $0.fails { throw HostConnectionError.connectionLost }
      $0.listed += 1
      return $0.sessions
    }
  }

  func endSession(_ session: UUID) async throws -> Bool {
    try state.withLock {
      if $0.fails { throw HostConnectionError.connectionLost }
      $0.ended.append(session)
      $0.sessions.removeAll { $0.identifier.uuid == session }
      return true
    }
  }

  func reader(context: RepositoryContext) throws -> VCSProviding { throw VCSError.io("unused") }
  func writer(context: RepositoryContext, reader: VCSProviding) throws -> VCSWriting {
    throw VCSError.io("unused")
  }
  func close() async {}
}
