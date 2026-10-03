import CryptoKit
import Defaults
import XCTest

@testable import Workroom

/// Guards on remote workrooms that need no Docker (#253): connecting a host once for every caller,
/// backing off a dead one, the image IDs `destroy` removes with `--force`, a base reused only for
/// its own repository, the client key's repair, the create guard, and re-reading a remote tree.
final class RemoteHostsTests: XCTestCase {
  /// Counts connects, fails them or not, and holds each until released, for
  /// `RemoteHosts.ensureConnected`.
  private final class Connects: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failing = false
    private var held = true
    private var asked = 0
    private var instant = ContinuousClock.now
    var calls: Int { lock.withLock { count } }
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func fail(_ on: Bool) { lock.withLock { failing = on } }
    func advance(_ by: Duration) { lock.withLock { instant += by } }
    func hold(_ on: Bool) { lock.withLock { held = on } }
    /// Callers that have reached `ensureConnected`'s connected check.
    var arrived: Int { lock.withLock { asked } }
    func ask() { lock.withLock { asked += 1 } }

    func connect(_ host: HostID) async throws {
      lock.withLock { count += 1 }
      while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(1)) }
      if lock.withLock({ failing }) { throw HostDriverError.unknownHost(host) }
    }
  }

  private func hosts(_ connects: Connects) -> RemoteHosts {
    RemoteHosts(
      connectHost: { try await connects.connect($0) },
      isConnected: { _ in
        connects.ask()
        return false
      },
      now: { connects.now })
  }

  /// The inspector's panels ask together when a remote workroom is selected: one connect serves
  /// them all, where a second would be refused while the first is running.
  func testCallersAtOnceShareOneConnect() async throws {
    let connects = Connects()
    let remote = hosts(connects)
    let host = HostID.remote(UUID())

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<5 { group.addTask { try await remote.ensureConnected(host) } }
      // Every caller is in before the one connect finishes: it is held until all five have asked
      // whether the host is up, past which each joins the running connect without suspending.
      while connects.arrived < 5 { try await Task.sleep(for: .milliseconds(1)) }
      try await Task.sleep(for: .milliseconds(20))
      connects.hold(false)
      try await group.waitForAll()
    }
    XCTAssertEqual(connects.calls, 1)
  }

  /// A host that is down answers for `retryAfter` without another connect, each of which would wait
  /// out ssh's timeout, and is tried again after it.
  func testADeadHostIsRetriedOnlyAfterItsWindow() async throws {
    let connects = Connects()
    let remote = hosts(connects)
    let host = HostID.remote(UUID())
    connects.fail(true)
    connects.hold(false)

    for _ in 0..<2 {
      do {
        try await remote.ensureConnected(host)
        XCTFail("a dead host connected")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(host))
      }
    }
    XCTAssertEqual(connects.calls, 1, "a dead host was tried again inside its window")

    connects.fail(false)
    connects.advance(RemoteHosts.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 2)
  }

  /// `destroy` removes a host's image with `--force`, so a record's image must be a commit's ID.
  func testOnlyAWholeLowercaseSHA256IsAnImageID() {
    let hex = String(repeating: "a1", count: 32)
    XCTAssertTrue(ContainerHostDriver.isImageID("sha256:" + hex))
    for bad in [
      "", "debian:bookworm", hex, "sha256:" + hex.uppercased(), "sha256:" + hex.dropLast(),
      "sha256:" + hex + "a", "sha256:" + String(repeating: "g", count: 64),
    ] {
      XCTAssertFalse(ContainerHostDriver.isImageID(bad), bad)
    }
  }

  /// A project whose origin changed since its base was cloned is refused before anything is made:
  /// reusing the base would give it workrooms of the old repository, with credentials for that.
  func testABaseOfAnotherRepositoryIsNotReused() async throws {
    let driver = ContainerHostDriver(hosts: [:], directory: FileManager.default.temporaryDirectory)
    let environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, _ in
        XCTFail("a name was taken")
        return "x"
      },
      record: { _, _ in XCTFail("something was recorded") },
      forget: { _ in XCTFail("something was forgotten") })

    do {
      _ = try await RemoteWorkrooms.create(
        repository: try XCTUnwrap(GitHubRepository(host: "github.com", owner: "fork", name: "r")),
        cloneURL: "https://github.com/fork/r.git",
        base: HostDescriptor(
          provisioner: RemoteWorkrooms.provisioner, id: UUID(), repository: "upstream/r",
          cloneURL: "https://github.com/upstream/r.git", path: "/home/workroom/r"),
        driver: driver, environment: environment, recorder: recorder)
      XCTFail("a base of another repository was reused")
    } catch RemoteWorkrooms.Failure.baseRepositoryChanged(let base, let origin) {
      XCTAssertEqual(base, "upstream/r")
      XCTAssertEqual(origin, "fork/r")
    }
  }

  /// A keygen cut short leaves the private half alone: the public half is derived from it again,
  /// rather than every later create failing to read it. A private half that isn't a key says so.
  func testAMissingPublicKeyIsDerivedFromThePrivateOne() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-key-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try RemoteHosts.clientKey(in: directory)
    let pub = key.appendingPathExtension("pub")
    let original = try String(contentsOf: pub, encoding: .utf8)
    XCTAssertTrue(original.hasPrefix("ssh-ed25519 "), original)

    try FileManager.default.removeItem(at: pub)
    XCTAssertEqual(try RemoteHosts.clientKey(in: directory), key)
    // `-y` prints no comment, so compare the key itself.
    XCTAssertEqual(
      try String(contentsOf: pub, encoding: .utf8).split(separator: " ").prefix(2),
      original.split(separator: " ").prefix(2))

    try FileManager.default.removeItem(at: pub)
    try Data("not a key".utf8).write(to: key)
    XCTAssertThrowsError(try RemoteHosts.clientKey(in: directory))
  }

  /// The launch's one sweep waits out a delete (#296): a call that isn't allowed leaves it for the
  /// next, and only one call ever runs it.
  func testTheSweepIsHeldUntilAllowedThenRunsOnce() {
    let remote = RemoteHosts()
    XCTAssertFalse(remote.claimSweep(allowed: false))
    XCTAssertTrue(remote.claimSweep(allowed: true))
    XCTAssertFalse(remote.claimSweep(allowed: true))
  }

  /// New Remote Workroom is off while its project is busy: a second create would build a second
  /// base.
  @MainActor
  func testARemoteCreateIsOffWhileItsProjectIsBusy() {
    RemoteWorkrooms.enabledForTesting = true
    defer { RemoteWorkrooms.enabledForTesting = nil }
    let store = AppStore()
    let project = Project(path: "/proj", vcs: "git", workrooms: [])
    XCTAssertTrue(store.canCreateRemoteWorkroom(in: project))
    store.busyProjects["/proj"] = 1
    XCTAssertFalse(store.canCreateRemoteWorkroom(in: project))
  }

  /// No watcher refreshes a remote tree, so coming back to it reads it again; the same local path
  /// would be a no-op.
  @MainActor
  func testReactivatingARemoteTreeListsItAgain() async throws {
    RemoteWorkrooms.enabledForTesting = true
    defer { RemoteWorkrooms.enabledForTesting = nil }
    let lists = Connects()
    lists.fail(true)
    lists.hold(false)
    // Counts each listing at the connect it starts with, and connects nothing.
    let router = RepositoryRouter(connectRemote: { try await lists.connect($0) })
    let model = FileTreeModel(router: router)
    let target = Workroom(
      name: "r", path: "/home/workroom/r", vcsName: "workroom/r", warnings: [],
      host: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID())
    ).target(inProject: "/proj")

    for expected in 1...2 {
      model.activate(target: target)
      for _ in 0..<500 where lists.calls < expected { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(lists.calls, expected)
    }
  }

  /// A remote workroom this app can't reach (previews off, here) reads nothing on this Mac: its
  /// path names a directory on its host, not here.
  @MainActor
  func testAnUnreachableRemoteWorkroomReadsNothingHere() {
    RemoteWorkrooms.enabledForTesting = false
    defer { RemoteWorkrooms.enabledForTesting = nil }
    let target = Workroom(
      name: "r", path: NSTemporaryDirectory(), vcsName: "workroom/r", warnings: [],
      host: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID())
    ).target(inProject: "/proj")
    XCTAssertNil(target.remoteHost)

    let history = HistoryModel()
    history.focus(target: target)
    XCTAssertNil(history.root, "History read the remote path on this Mac")
    XCTAssertEqual(history.state, .idle)

    let files = FileTreeModel(router: RepositoryRouter())
    files.activate(target: target)
    XCTAssertEqual(files.state, .idle, "Files listed the remote path on this Mac")
  }

  /// A base record that names a host but not enough to derive from is refused: building another
  /// would leave the recorded one running with nothing pointing at it.
  func testAnIncompleteBaseIsNotReplaced() async throws {
    let driver = ContainerHostDriver(hosts: [:], directory: FileManager.default.temporaryDirectory)
    let environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, _ in
        XCTFail("a name was taken")
        return "x"
      },
      record: { _, _ in XCTFail("something was recorded") },
      forget: { _ in XCTFail("something was forgotten") })

    do {
      _ = try await RemoteWorkrooms.create(
        repository: try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r")),
        cloneURL: "https://github.com/o/r.git",
        base: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID()),
        driver: driver, environment: environment, recorder: recorder)
      XCTFail("an incomplete base was replaced")
    } catch RemoteWorkrooms.Failure.incompleteBase {}
  }
}
