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

  private func session(
    workroom: String, title: String = "Terminal", id: UUID = UUID(), attached: Bool = false
  ) -> SessionDescriptor {
    SessionDescriptor(
      identifier: SessionIdentifier(id), shellProcessID: 1, ttyDevice: 0,
      workingDirectory: "/home/workroom/far", isAttached: attached,
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
    // A daemon connection answers for this Mac's own host id too, so a local read sent over the
    // host connections instead of the helpers would be counted.
    let fixture = SessionsConnection(sessions: [session(workroom: local.id.encoded)])
    let manager = try await connected(fixture)
    _ = try await manager.connect(host: .local) { fixture }
    let list = makeList(connections: manager, local: [mine, owned, another])

    await list.refresh(local, ownedSessionIDs: [try XCTUnwrap(owned.identifier.uuid)])

    XCTAssertEqual(list.detached(for: local).map(\.identifier), [mine.identifier])
    XCTAssertEqual(list.detachedByWorkroom.keys.sorted(), [local.id.encoded])
    XCTAssertEqual(fixture.listed, 0, "no daemon connection is asked, local or remote")
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

  // MARK: Attached sessions (#584 follow-up)

  // Value: protects=a remote session a client is attached to (another Mac's pane) is not offered
  // as detached, so two Macs never fight over its size; fails_when=the list ignores the daemon's
  // attached flag; why_new=the owner's decision on #584; seam=a stub host connection
  func testARemoteSessionAClientIsAttachedToIsHidden() async throws {
    let detached = session(workroom: workroomID.uuidString, title: "detached")
    let shown = session(workroom: workroomID.uuidString, title: "another Mac's", attached: true)
    let fixture = SessionsConnection(sessions: [shown, detached])
    let list = makeList(connections: try await connected(fixture))

    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertEqual(list.detached(for: remote).map(\.identifier), [detached.identifier])
  }

  // Value: protects=a local session a client is attached to (a pane in another window, an
  // external attach) is not offered as detached, as Stop Detached Terminals already judges it;
  // fails_when=the local list ignores the attached flag; why_new=the owner's decision on #584;
  // seam=the local source
  func testALocalSessionAClientIsAttachedToIsHidden() async throws {
    let detached = session(workroom: local.id.encoded)
    let shown = session(workroom: local.id.encoded, attached: true)
    let list = makeList(local: [shown, detached])

    await list.refresh(local, ownedSessionIDs: [])

    XCTAssertEqual(list.detached(for: local).map(\.identifier), [detached.identifier])
  }

  // Value: protects=the remote session this Mac's pane just let go (an Active tab swap) is listed
  // though its old ssh still counts as attached on the host, as it does until the host notices
  // that ssh is gone; fails_when=every attached remote session is hidden; why_new=the attached
  // filter; seam=a registered session no pane here attaches to
  func testARemoteSessionThisMacLetGoIsListedThoughItsOldAttachLingers() async throws {
    let service = isolatedPaneSessionService()
    let id = try registerRemoteSession(on: service, log: "").session
    service.sessionReleased(id)
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let list = makeList(connections: try await connected(fixture), service: service)

    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertEqual(list.detached(for: remote).map(\.identifier.uuid), [id])
  }

  // Value: protects=a pane in another window here that lost its link and is waiting out its
  // reconnect backoff keeps its session out of this window's list, though no pane mark is held
  // meanwhile; fails_when=the leftover exception admits every session this Mac registered;
  // why_new=the second review of #584; seam=a pane's attach marked, then dropped as an exit does
  func testARemoteSessionWhosePaneHereIsReconnectingIsHidden() async throws {
    let service = isolatedPaneSessionService()
    let id = try registerRemoteSession(on: service, log: "").session
    let pane = UUID()
    XCTAssertNotNil(service.attachCommand(forSession: id, by: pane))
    service.paneDetached(by: pane)  // its ssh exited; the reattach waits out the backoff
    XCTAssertFalse(service.hasAttachedPane(to: id), "fixture: no pane mark held")
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let list = makeList(connections: try await connected(fixture), service: service)

    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertTrue(list.detached(for: remote).isEmpty)
  }

  // Value: protects=a lazily restored hidden tab in another window here (registered, never
  // attached) whose session another Mac is attached to stays out of the list; fails_when=the
  // exception admits a registered session another client holds; why_new=the second review of
  // #584; seam=a registration with no attach
  func testARemoteSessionAHiddenTabHereRegisteredAndAnotherMacHoldsIsHidden() async throws {
    let service = isolatedPaneSessionService()
    let id = try registerRemoteSession(on: service, log: "").session
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let list = makeList(connections: try await connected(fixture), service: service)

    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertTrue(list.detached(for: remote).isEmpty)
  }

  // Value: protects=Stop never ends a session another Mac attached to after this Mac let it go,
  // though the leftover exception still lists it (PR #594 Codex P1); fails_when=Stop's re-read
  // admits an attached session through the exception; why_new=the exception outranked the
  // attached flag at Stop; seam=a released registration and a host that says it is attached
  func testStopNeverEndsASessionAttachedElsewhereAfterThisMacLetItGo() async throws {
    let id = UUID()
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
    service.sessionReleased(id)  // an Active tab swap on this Mac
    // Then another Mac attaches to it.
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let list = makeList(connections: try await connected(fixture), service: service)
    await list.refresh(remote, ownedSessionIDs: [])
    XCTAssertEqual(list.detached(for: remote).count, 1, "fixture: listed as this Mac's leftover")

    await list.stop(id, in: remote, ownedSessionIDs: [])

    XCTAssertTrue(endedByService.withLock { $0 }.isEmpty, "not ended through the service")
    XCTAssertTrue(fixture.ended.isEmpty, "nor on the host")
    XCTAssertTrue(service.isRemote(id), "its registration stays")
    XCTAssertTrue(list.detached(for: remote).isEmpty, "its row goes quietly")
  }

  // Value: protects=the leftover exception covers only the old ssh draining just after a swap,
  // never a client still attached later, which may be another Mac's (PR #594 Codex P1);
  // fails_when=a release lasts until this Mac attaches it again; why_new=the release never
  // expired; seam=the service's clock
  func testTheLeftoverExceptionExpiresAfterTheDrainWindow() async throws {
    let clock = Mutex(100.0)
    let service = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      now: { clock.withLock { $0 } })
    let id = try registerRemoteSession(on: service, log: "").session
    service.sessionReleased(id)
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let list = makeList(connections: try await connected(fixture), service: service)
    await list.refresh(remote, ownedSessionIDs: [])
    XCTAssertEqual(list.detached(for: remote).count, 1, "fixture: listed while it drains")

    clock.withLock { $0 += PersistentSessionService.releaseDrain + 1 }
    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertTrue(list.detached(for: remote).isEmpty)
    XCTAssertFalse(service.wasReleasedHere(id))
  }

  // Value: protects=a footer whose list was empty (another Mac held every session) picks up a
  // session that Mac lets go, while the connection stays up (PR #594 Codex P2); fails_when=a
  // remote list is read only per connection; why_new=nothing re-read an empty list, and an empty
  // list has no button to open; seam=a stub host whose answer changes, a short re-read interval
  func testAnEmptyListPicksUpASessionLetGoElsewhere() async throws {
    let id = UUID()
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let manager = try await connected(fixture)
    let list = makeList(connections: manager)
    let target = remote
    let follow = Task {
      await list.follow(target, ownedSessionIDs: { [] }, rereadEvery: .milliseconds(10))
    }
    defer { follow.cancel() }
    try await waitUntil { fixture.listed >= 1 }
    XCTAssertTrue(list.detached(for: remote).isEmpty, "fixture: another Mac holds it")

    fixture.answer = [session(workroom: workroomID.uuidString, id: id)]

    try await waitUntil {
      await MainActor.run { list.detached(for: target).map(\.identifier.uuid) == [id] }
    }
  }

  /// Negative control: the re-read never reaches a host with no connection.
  func testTheRereadAsksNothingOfAHostWithNoConnection() async throws {
    let manager = HostConnectionManager()
    let list = makeList(connections: manager)
    let target = remote
    let follow = Task {
      await list.follow(target, ownedSessionIDs: { [] }, rereadEvery: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(50))
    follow.cancel()
    await follow.value

    let status = await manager.snapshot(for: .remote(hostID)).status
    XCTAssertEqual(status, .disconnected)
    XCTAssertTrue(list.detached(for: remote).isEmpty)
  }

  /// Negative control: a session this Mac let go and a pane here attached again is no longer the
  /// leftover the exception admits.
  func testASessionLetGoThenAttachedAgainHereIsNoLongerALeftover() throws {
    let service = isolatedPaneSessionService()
    let id = try registerRemoteSession(on: service, log: "").session
    service.sessionReleased(id)
    XCTAssertTrue(service.wasReleasedHere(id), "fixture: let go")

    let pane = UUID()
    XCTAssertNotNil(service.attachCommand(forSession: id, by: pane))
    service.paneDetached(by: pane)

    XCTAssertFalse(service.wasReleasedHere(id))
  }

  // Value: protects=Stop never ends a session that someone attached to after the list was read
  // (another Mac picked it up); fails_when=Stop trusts the list it was clicked from;
  // why_new=the second review of #584; seam=a stub host connection whose answer changes
  func testStoppingASessionAttachedSinceTheListWasReadEndsNothing() async throws {
    let id = UUID()
    let fixture = SessionsConnection(sessions: [session(workroom: workroomID.uuidString, id: id)])
    let list = makeList(connections: try await connected(fixture))
    await list.refresh(remote, ownedSessionIDs: [])
    XCTAssertEqual(list.detached(for: remote).count, 1, "fixture: listed")
    fixture.answer = [session(workroom: workroomID.uuidString, id: id, attached: true)]

    await list.stop(id, in: remote, ownedSessionIDs: [])

    XCTAssertTrue(fixture.ended.isEmpty, "a session in use is never ended")
    XCTAssertTrue(list.detached(for: remote).isEmpty, "its row goes")
  }

  /// The same for a local workroom: a session attached since the read is left running.
  func testStoppingALocalSessionAttachedSinceTheListWasReadEndsNothing() async throws {
    let id = UUID()
    let answer = Mutex([session(workroom: local.id.encoded, id: id)])
    // A local end resolves the session's owner first, so being asked is how an end shows here.
    let askedToEnd = Mutex<[UUID]>([])
    let service = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") },
      ownership: { asked in
        askedToEnd.withLock { $0.append(asked) }
        return .notOwned
      })
    let list = DetachedSessionList(
      service: service, connections: HostConnectionManager(),
      localSessions: { answer.withLock { $0 } })
    await list.refresh(local, ownedSessionIDs: [])
    XCTAssertEqual(list.detached(for: local).count, 1, "fixture: listed")
    answer.withLock { $0 = [self.session(workroom: self.local.id.encoded, id: id, attached: true)] }

    await list.stop(id, in: local, ownedSessionIDs: [])

    XCTAssertTrue(askedToEnd.withLock { $0 }.isEmpty, "a session in use is never ended")
    XCTAssertTrue(list.detached(for: local).isEmpty, "its row goes")

    // Negative control: one still detached at the click is ended.
    answer.withLock { $0 = [self.session(workroom: self.local.id.encoded, id: id)] }
    await list.stop(id, in: local, ownedSessionIDs: [])
    XCTAssertEqual(askedToEnd.withLock { $0 }, [id])
  }

  // Value: protects=the session a local Active tab swap lets go shows in the list once its old
  // attach has exited, the case the re-read exists for; fails_when=the list is read once after
  // the swap; why_new=the second review of #584 (the loop was tested only on a remote id);
  // seam=the local source, whose answer changes after the first read
  func testALocalSessionLetGoIsListedOnceItsDepartingAttachHasGone() async throws {
    let id = UUID()
    let reads = Mutex(0)
    let target = local
    let sourced = DetachedSessionList(
      service: isolatedPaneSessionService(), connections: HostConnectionManager(),
      localSessions: {
        let read = reads.withLock {
          $0 += 1
          return $0
        }
        return [self.session(workroom: target.id.encoded, id: id, attached: read < 3)]
      })

    await sourced.refreshAfterReleasing(
      id, in: target, ownedSessionIDs: { [] }, interval: .milliseconds(1))

    XCTAssertEqual(sourced.detached(for: target).map(\.identifier.uuid), [id])
    XCTAssertEqual(reads.withLock { $0 }, 3, "read until it was let go, then no more")
  }

  // Value: protects=a remote session a pane in another window on this Mac shows is hidden, though
  // this Mac registered it and that window's tab is not in this window's owned set (#255);
  // fails_when=a registered session is listed whatever holds it; why_new=the attached filter;
  // seam=a pane's attach recorded on the service
  func testARemoteSessionAnotherWindowHereShowsIsHidden() async throws {
    let service = isolatedPaneSessionService()
    let id = try registerRemoteSession(on: service, log: "").session
    XCTAssertNotNil(
      service.attachCommand(forSession: id, by: UUID()), "fixture: a pane here attaches to it")
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let list = makeList(connections: try await connected(fixture), service: service)

    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertTrue(list.detached(for: remote).isEmpty)
  }

  // Value: protects=a remote workroom's run session (another Mac's, D7) is not offered as a plain
  // terminal, which a later Run click would then adopt a second time; fails_when=the remote list
  // keeps run sessions; why_new=the review of #584; seam=a stub host connection
  func testARemoteRunSessionIsNotListed() async throws {
    let shell = session(workroom: workroomID.uuidString)
    let run = SessionDescriptor(
      identifier: SessionIdentifier(UUID()), shellProcessID: 1, ttyDevice: 0,
      workingDirectory: "/home/workroom/far", isAttached: false,
      metadata: [
        SessionEnvironmentEntry(key: SessionMetadataKey.workroom, value: workroomID.uuidString),
        SessionEnvironmentEntry(key: RunSessionKey.kind, value: RunSessionKey.run),
      ])
    let fixture = SessionsConnection(sessions: [run, shell])
    let list = makeList(connections: try await connected(fixture))

    await list.refresh(remote, ownedSessionIDs: [])

    XCTAssertEqual(list.detached(for: remote).map(\.identifier), [shell.identifier])
  }

  // Value: protects=a host whose link drops shows nothing, and lists again on the next
  // connection; fails_when=a disconnect keeps the old list, or a new lease is not listed;
  // why_new=the review of #584 (claimed, untested); seam=a manager the test disconnects
  func testADisconnectClearsTheListAndAReconnectListsAgain() async throws {
    let manager = HostConnectionManager()
    let list = makeList(connections: manager)
    let first = session(workroom: workroomID.uuidString, title: "first")
    let second = session(workroom: workroomID.uuidString, title: "second")
    let target = remote
    let follow = Task { await list.follow(target, ownedSessionIDs: { [] }) }
    defer { follow.cancel() }
    let lease = try await manager.connect(host: .remote(hostID)) {
      SessionsConnection(sessions: [first])
    }
    try await waitUntil { await MainActor.run { !list.detached(for: target).isEmpty } }

    await manager.disconnect(lease)
    try await waitUntil { await MainActor.run { list.detached(for: target).isEmpty } }

    _ = try await manager.connect(host: .remote(hostID)) { SessionsConnection(sessions: [second]) }
    try await waitUntil {
      await MainActor.run { list.detached(for: target).map(\.identifier) == [second.identifier] }
    }
  }

  // Value: protects=a footer that goes away stops watching its host; fails_when=a cancelled
  // follow keeps its subscription; why_new=the review of #584; seam=the manager's observer count
  func testCancellingAFollowEndsItsSubscription() async throws {
    let manager = HostConnectionManager()
    let list = makeList(connections: manager)
    let target = remote
    let follow = Task { await list.follow(target, ownedSessionIDs: { [] }) }
    try await waitUntil { await manager.observerCount(for: .remote(self.hostID)) == 1 }

    follow.cancel()
    await follow.value

    try await waitUntil { await manager.observerCount(for: .remote(self.hostID)) == 0 }
  }

  // Value: protects=the session an Active tab swap lets go shows in the list once its departing
  // attach has let go, though the read right after the swap still finds it attached;
  // fails_when=the list is read once after the swap; why_new=hiding attached sessions made the
  // swap race its own departing client; seam=a stub host connection whose answer changes
  func testASessionLetGoIsListedOnceItsDepartingAttachHasGone() async throws {
    let id = UUID()
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let list = makeList(connections: try await connected(fixture))
    let target = remote
    let reading = Task {
      await list.refreshAfterReleasing(
        id, in: target, ownedSessionIDs: { [] }, interval: .milliseconds(10))
    }
    try await waitUntil { fixture.listed >= 1 }
    XCTAssertTrue(list.detached(for: remote).isEmpty, "fixture: still attached at first")

    fixture.answer = [session(workroom: workroomID.uuidString, id: id)]
    await reading.value

    XCTAssertEqual(list.detached(for: remote).map(\.identifier.uuid), [id])
  }

  // Value: protects=a session let go that stays attached (another client holds it) is read a
  // bounded number of times, never polled for good; fails_when=the re-read has no bound;
  // why_new=the re-read is new; seam=a stub host connection
  func testASessionLetGoThatStaysAttachedIsReadABoundedNumberOfTimes() async throws {
    let id = UUID()
    let fixture = SessionsConnection(
      sessions: [session(workroom: workroomID.uuidString, id: id, attached: true)])
    let list = makeList(connections: try await connected(fixture))

    await list.refreshAfterReleasing(
      id, in: remote, ownedSessionIDs: { [] }, attempts: 3, interval: .milliseconds(1))

    XCTAssertEqual(fixture.listed, 3)
    XCTAssertTrue(list.detached(for: remote).isEmpty)
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
  /// What the next list answers.
  var answer: [SessionDescriptor] {
    get { state.withLock { $0.sessions } }
    set { state.withLock { $0.sessions = newValue } }
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
