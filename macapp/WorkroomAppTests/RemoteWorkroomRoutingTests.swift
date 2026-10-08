import Defaults
import XCTest

@testable import Workroom

/// A reachable remote workroom's Changes, History, Files, diffs and PR/CI status route by its
/// location on its host, never by its path, which one project's remote workrooms share (#253).
final class RemoteWorkroomRoutingTests: XCTestCase {
  private let path = "/home/workroom/r"

  override func tearDown() {
    RepositoryRouter.shared.replaceRemote([])
    super.tearDown()
  }

  private func remote(
    _ name: String, host: UUID, state: String? = nil,
    provisioner: String = RemoteWorkrooms.provisioner
  ) -> Workroom {
    Workroom(
      name: name, path: path, vcsName: "workroom/\(name)", warnings: [],
      host: HostDescriptor(state: state, provisioner: provisioner, id: host))
  }

  private func project(_ workrooms: [Workroom], repository: String? = "o/r") -> Project {
    Project(
      path: "/proj", vcs: "git", workrooms: workrooms,
      host: HostDescriptor(
        provisioner: RemoteWorkrooms.provisioner, id: UUID(), repository: repository))
  }

  /// Two remote workrooms at one path on two hosts are two repositories. Each is its own shared
  /// root and carries the base's GitHub identity; one this app can't reach (being created, or
  /// another build's) is not registered at all.
  func testReachableRemoteWorkroomsRegisterOnTheirOwnHosts() throws {
    let a = UUID()
    let b = UUID()
    let registrations = RemoteWorkrooms.registrations([
      project([
        remote("a", host: a), remote("b", host: b), remote("c", host: UUID(), state: "creating"),
        remote("d", host: UUID(), provisioner: "another.build"),
      ])
    ])

    XCTAssertEqual(
      registrations.map(\.location),
      [try .remote(host: a, path: path), try .remote(host: b, path: path)])
    for registration in registrations {
      XCTAssertEqual(registration.entry.sharedLocation, registration.location)
      XCTAssertEqual(registration.entry.github?.flag, "github.com/o/r")
    }
  }

  /// A workroom carries its own base's GitHub identity: a base on another runtime, made after the
  /// project's origin changed, is a clone of another repository (#309).
  func testEachWorkroomCarriesItsOwnBasesRepository() throws {
    let (docker, apple) = (UUID(), UUID())
    let workroom = { (name: String, host: UUID, driver: String) in
      Workroom(
        name: name, path: self.path, vcsName: "workroom/\(name)", warnings: [],
        host: HostDescriptor(driver: driver, provisioner: RemoteWorkrooms.provisioner, id: host))
    }
    let registrations = RemoteWorkrooms.registrations([
      Project(
        path: "/proj", vcs: "git",
        workrooms: [workroom("d", docker, "container"), workroom("a", apple, "apple-container")],
        host: HostDescriptor(bases: [
          HostDescriptor(
            driver: "container", provisioner: RemoteWorkrooms.provisioner, id: UUID(),
            repository: "o/old"),
          HostDescriptor(
            driver: "apple-container", provisioner: RemoteWorkrooms.provisioner, id: UUID(),
            repository: "o/new"),
        ]))
    ])
    let github = Dictionary(
      uniqueKeysWithValues: registrations.map { ($0.location, $0.entry.github?.flag) })
    XCTAssertEqual(github[try .remote(host: docker, path: path)], "github.com/o/old")
    XCTAssertEqual(github[try .remote(host: apple, path: path)], "github.com/o/new")
  }

  /// No base identity, no GitHub identity: its PR and CI stay off rather than guess.
  func testAProjectWithoutABaseRepositoryRegistersNoGitHubIdentity() {
    let registrations = RemoteWorkrooms.registrations([
      project([remote("a", host: UUID())], repository: nil)
    ])
    XCTAssertEqual(registrations.count, 1)
    XCTAssertNil(registrations.first?.entry.github)
  }

  /// The listing owns remote registrations: a reload replaces them all, and neither replacement
  /// touches the other host's half.
  func testRemoteAndLocalReplacementsLeaveEachOther() async throws {
    let router = RepositoryRouter()
    let local = try await RepositoryLocation.local("/tmp")
    let gone = try RepositoryLocation.remote(host: UUID(), path: path)
    let kept = try RepositoryLocation.remote(host: UUID(), path: path)
    router.replaceLocal([try .init(location: local, sharedLocation: local)])
    router.replaceRemote([try .init(location: gone, sharedLocation: gone)])

    router.replaceRemote([try .init(location: kept, sharedLocation: kept)])

    XCTAssertNil(router.entry(for: gone))
    XCTAssertNotNil(router.entry(for: kept))
    XCTAssertNotNil(router.entry(for: local))
    router.replaceLocal([])
    XCTAssertNotNil(router.entry(for: kept))
  }

  /// The router connects a remote host itself before every read, listing and write on it, and never
  /// for a local repository; what the connect throws is what the caller gets.
  func testTheRouterConnectsARemoteHostBeforeUsingIt() async throws {
    actor Connects {
      var hosts: [HostID] = []
      func add(_ host: HostID) { hosts.append(host) }
    }
    let connects = Connects()
    let router = RepositoryRouter(connectRemote: { host in
      await connects.add(host)
      throw RepositoryRoutingError.unavailable(host)
    })
    let remote = try RepositoryLocation.remote(host: UUID(), path: path)
    let local = try await RepositoryLocation.local("/tmp")
    router.replaceRemote([try .init(location: remote, sharedLocation: remote)])
    router.replaceLocal([try .init(location: local, sharedLocation: local)])

    let attempts: [@Sendable () async throws -> Void] = [
      { _ = try await router.reader(for: remote) },
      { _ = try await router.files(for: remote) },
      { _ = try await router.writer(for: remote) },
    ]
    for attempt in attempts {
      do {
        try await attempt()
        XCTFail("a remote service was handed out without connecting its host")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(remote.host))
      }
    }
    _ = try await router.files(for: local)
    let hosts = await connects.hosts
    XCTAssertEqual(hosts, [remote.host, remote.host, remote.host])
  }

  // Value: protects=an asleep boxd box reads as asleep (moon, no alarm), not as a broken repository;
  // fails_when=the resolver's .asleep catch goes or .asleep joins the weighted failures;
  // why_new=RemoteHostsTests stops at the thrown error and nothing maps it to the badge; seam=none
  /// A boxd box left asleep (#356) is not a failure: the sidebar says asleep and neither the dot nor
  /// the project row's aggregate raises an alarm, where "unavailable" is a question mark that does.
  func testAnAsleepBoxReadsAsAsleepNotUnavailable() async throws {
    let router = RepositoryRouter(connectRemote: { throw RepositoryRoutingError.asleep($0) })
    let remote = try RepositoryLocation.remote(host: UUID(), path: path)
    router.replaceRemote([try .init(location: remote, sharedLocation: remote)])

    let status = await WorkroomStatusResolver().resolve(location: remote, router: router)

    XCTAssertEqual(status.failure, .asleep)
    XCTAssertNil(status.dirty)
    let dot = try XCTUnwrap(VCSStatusPresentation.dot(status))
    XCTAssertEqual(dot.accessibility, "asleep")
    XCTAssertEqual(dot.semantic, .neutral)
    XCTAssertEqual(status.aggregateWeight, 0, "an asleep box must not mark its project")
  }

  // Value: protects=a box its agent let go of reads as idle, not asleep, as boxd hasn't slept it yet;
  // fails_when=the resolver folds .idle into .asleep or into the weighted failures;
  // why_new=the idle state is new and only RemoteHostsTests see it thrown; seam=none
  /// A box its agent let go of as idle (#380) may still be awake: the dot says so, without an alarm.
  func testABoxLetGoOfReadsAsIdleNotAsleep() async throws {
    let router = RepositoryRouter(connectRemote: { throw RepositoryRoutingError.idle($0) })
    let remote = try RepositoryLocation.remote(host: UUID(), path: path)
    router.replaceRemote([try .init(location: remote, sharedLocation: remote)])

    let status = await WorkroomStatusResolver().resolve(location: remote, router: router)

    XCTAssertEqual(status.failure, .idle)
    let dot = try XCTUnwrap(VCSStatusPresentation.dot(status))
    XCTAssertEqual(dot.accessibility, "idle, not connected")
    XCTAssertEqual(dot.semantic, .neutral)
    XCTAssertEqual(status.aggregateWeight, 0, "an idle box must not mark its project")
  }

  // Value: protects=a deleted or other-account boxd machine raises an alarm on its row, never the quiet asleep moon;
  // fails_when=the resolver folds .gone into its .asleep catch, or drops it from the failures that mark a project;
  // why_new=RemoteHostsTests stop at the thrown .gone and nothing maps it to the sidebar; seam=none
  /// A machine boxd says is gone (#356) is a failure the user must act on, not a box asleep.
  func testAGoneBoxdMachineReadsAsAFailureNotAsleep() async throws {
    let router = RepositoryRouter(connectRemote: { throw RepositoryRoutingError.gone($0) })
    let remote = try RepositoryLocation.remote(host: UUID(), path: path)
    router.replaceRemote([try .init(location: remote, sharedLocation: remote)])

    let status = await WorkroomStatusResolver().resolve(location: remote, router: router)

    XCTAssertNotEqual(status.failure, .asleep)
    XCTAssertNotNil(status.failure)
    XCTAssertNotEqual(VCSStatusPresentation.dot(status)?.accessibility, "asleep")
    XCTAssertEqual(status.aggregateWeight, 1, "a gone machine must mark its project")
  }

  // Value: protects=selecting a boxd workroom whose agent let go of its box reconnects it;
  // fails_when=AppStore stops telling RemoteHosts which host is selected;
  // why_new=RemoteHostsTests call select() directly; nothing drives it from the app's selection; seam=none
  /// Selecting a boxd workroom whose agent let go of its box (#380) forgets the release, so its
  /// reads reconnect it.
  @MainActor
  func testSelectingABoxdWorkroomForgetsItsRelease() async throws {
    let host = boxdHostReleased()
    guard case .remote(let id) = host else { return XCTFail("not a remote host") }
    let box = Workroom(
      name: "w", path: "/home/boxd/r", vcsName: "workroom/w", warnings: [],
      host: HostDescriptor(
        driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner, id: id))
    let store = AppStore()
    store.projects = [Project(path: "/proj", vcs: "git", workrooms: [box])]
    // The store selects under its own window key, which its deinit clears.
    store.selectedTargetID = .workroom(project: "/proj", name: "w")
    XCTAssertFalse(RemoteHosts.shared.isReleased(host), "selecting its workroom left it released")
  }

  /// A boxd host the app has adopted and whose agent let go of it (#380), on the shared
  /// `RemoteHosts` the click call sites below use.
  @MainActor
  private func boxdHostReleased() -> HostID {
    let id = UUID()
    RemoteHosts.shared.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "w", path: "/home/boxd/r", vcsName: "workroom/w", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
                id: id))
          ])
      ], sweep: false)
    RemoteHosts.shared.released(.remote(id))
    return .remote(id)
  }

  // Value: protects=closing a pane on a boxd box its agent let go of wakes it to end the session, rather
  // than leaving the session running; fails_when=endSession's remote kill drops wake: true; why_new=
  // RemoteHostsTests pass wake: true by hand and nothing drives this call site; seam=none
  /// As above: the kill fails here, so the session stays registered, which is the right outcome
  /// for a host that can't be reached; the click still reached the box.
  @MainActor
  func testClosingAPaneOnABoxLetGoOfIsAClickNotABackgroundRead() async throws {
    let host = boxdHostReleased()
    let session = UUID()
    let sessions = PersistentSessionService.shared
    sessions.registerRemoteSession(
      session, on: host,
      via: BoxdHostDriver(
        configuration: .init(cli: URL(fileURLWithPath: "/usr/bin/false")),
        directory: FileManager.default.temporaryDirectory),
      workingDirectory: "/home/boxd/r")
    defer { sessions.forgetRemoteSession(session) }

    let ended = await sessions.endSession(sessionID: session)

    XCTAssertFalse(ended, "a session on an unreachable host was reported ended")
    XCTAssertTrue(sessions.isRemote(session), "the failed kill dropped the session's registration")
    XCTAssertFalse(RemoteHosts.shared.isReleased(host), "closing the pane was refused as a read")
  }

  // Value: protects=a pane attaching to a host with no service connection reconnects it, so its
  // badge is heard and a container's credential relay is there for the pane's git; fails_when=
  // attachCommand stops reconnecting the host; why_new=no test attaches a pane to a released host;
  // seam=none
  /// A pane attaching (a reconnect after a dropped link, a window reopened) is the user at the box,
  /// as a click is: a host its agent let go of is reconnected (#380).
  @MainActor
  func testAPaneAttachingToABoxLetGoOfTakesItBack() async throws {
    let host = boxdHostReleased()
    guard case .remote(let id) = host else { return XCTFail("not a remote host") }
    let session = UUID()
    let sessions = PersistentSessionService.shared
    sessions.registerRemoteSession(
      session, on: host,
      via: ContainerHostDriver(
        hosts: [
          id: .init(
            address: "127.0.0.1", port: 1, user: "boxd", identityFile: "/keys/id",
            hostKey: "ssh-ed25519 AAAA", agentSocket: "/s")
        ], directory: FileManager.default.temporaryDirectory),
      workingDirectory: "/home/boxd/r")
    defer { sessions.forgetRemoteSession(session) }

    // An attach whose ssh is gone before the take-back runs holds nothing, so takes nothing back.
    let pane = UUID()
    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: pane))
    sessions.paneDetached(session, by: pane)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(
      RemoteHosts.shared.isReleased(host), "a pane gone before the take-back took it back")

    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: pane))
    // The take-back runs in its own task.
    for _ in 0..<100 where RemoteHosts.shared.isReleased(host) {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(
      RemoteHosts.shared.isReleased(host), "a pane attached to a box its agent let go of left it so"
    )
  }

  /// A target names its repository by host: a reachable remote one by its host's location, and one
  /// it can't reach by none, so a viewer never reads its path on this Mac.
  func testATargetResolvesItsRemoteLocationFromItsHost() throws {
    let host = UUID()
    let target = remote("a", host: host).target(inProject: "/proj")
    XCTAssertEqual(target.remoteLocation, try .remote(host: host, path: path))

    let creating = remote("b", host: host, state: "creating").target(inProject: "/proj")
    XCTAssertNil(creating.remoteLocation)
  }

  /// A session is tagged with what every Mac calls its workroom: a remote workroom's own id, never
  /// `target.id`, which holds this Mac's project path; a local one keeps `target.id`, which its
  /// own Mac's sweep and delete match against (#255).
  func testASessionsWorkroomTagIsTheRemoteWorkroomsOwnIdAndTheTargetIdLocally() {
    let workroomID = UUID()
    let tagged = Workroom(
      name: "a", path: path, vcsName: "workroom/a", warnings: [],
      host: HostDescriptor(
        provisioner: RemoteWorkrooms.provisioner, id: UUID(), workroomID: workroomID)
    ).target(inProject: "/proj")
    XCTAssertEqual(tagged.sessionWorkroomKey, workroomID.uuidString)

    let local = TerminalTarget(id: "wr|/proj|b", title: "b", path: "/proj/b", isMissing: false)
    XCTAssertEqual(local.sessionWorkroomKey, "wr|/proj|b")
    // A remote workroom recorded before workroom ids (#251) has none, and keeps its target id.
    XCTAssertEqual(
      remote("c", host: UUID()).target(inProject: "/proj").sessionWorkroomKey, "wr|/proj|c")
  }

  /// A reachable remote workroom has a status item on its host, read as git, which may read its
  /// GitHub status once registered; one this app can't reach has none.
  @MainActor
  func testARemoteWorkroomHasAStatusItemOnItsHost() throws {
    let host = UUID()
    let store = AppStore()
    store.projects = [
      project([remote("a", host: host), remote("b", host: UUID(), state: "failed")])
    ]
    RepositoryRouter.shared.replaceRemote(RemoteWorkrooms.registrations(store.projects))

    let item = try XCTUnwrap(
      store.selectedStatusWorkItem(for: .workroom(project: "/proj", name: "a")))
    XCTAssertEqual(item.location, try .remote(host: host, path: path))
    XCTAssertEqual(item.vcs, "git")
    XCTAssertFalse(item.permitsLocalAccess)
    XCTAssertTrue(item.permitsGitHubAccess)
    XCTAssertEqual(item.sharedLocation, item.location)
    XCTAssertNil(store.selectedStatusWorkItem(for: .workroom(project: "/proj", name: "b")))
    XCTAssertEqual(
      store.statusWorkItems().map(\.sid),
      [.root(project: "/proj"), .workroom(project: "/proj", name: "a")])
  }
}
