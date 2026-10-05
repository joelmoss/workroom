import Defaults
import XCTest

@testable import Workroom

/// A reachable remote workroom's Changes, History, Files, diffs and PR/CI status route by its
/// location on its host, never by its path, which one project's remote workrooms share (#253).
final class RemoteWorkroomRoutingTests: XCTestCase {
  private let path = "/home/workroom/r"

  override func setUp() {
    super.setUp()
    RemoteWorkrooms.enabledForTesting = true
  }

  override func tearDown() {
    RemoteWorkrooms.enabledForTesting = nil
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
