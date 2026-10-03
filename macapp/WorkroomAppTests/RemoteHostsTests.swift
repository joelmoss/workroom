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
    XCTAssertFalse(remote.sweepHeld, "nothing has reached the sweep, so nothing is owed")
    XCTAssertFalse(remote.claimSweep(allowed: false))
    XCTAssertTrue(remote.sweepHeld, "a held sweep is still owed")
    XCTAssertTrue(remote.claimSweep(allowed: true))
    XCTAssertFalse(remote.sweepHeld)
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

  // MARK: Docker contexts (#309)

  /// A stand-in runtime CLI: a script that appends its arguments to `log`, one call per line, and
  /// prints `output`.
  private func stubRuntime(output: String = "") throws -> (runtime: URL, log: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-runtime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let runtime = directory.appendingPathComponent("docker")
    let log = directory.appendingPathComponent("calls")
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> \(ContainerHostDriver.shellQuoted(log.path))
    printf '%s' \(ContainerHostDriver.shellQuoted(output))
    """.write(to: runtime, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    return (runtime, log)
  }

  /// A stand-in runtime CLI that logs every call and fails `image inspect` (the image is missing),
  /// `run`, and `pull` when `pullFails`, so `create` stops at its first container.
  private func failingRuntime(pullFails: Bool) throws -> (runtime: URL, log: URL) {
    let (runtime, log) = try stubRuntime()
    let script = try String(contentsOf: runtime, encoding: .utf8)
    try
      (script + """

        case "$1 $2" in "image inspect") exit 1 ;; esac
        case "$1" in run) exit 1 ;; pull) \(pullFails ? "echo 'denied' >&2; exit 1" : "exit 0") ;; esac
        """).write(to: runtime, atomically: true, encoding: .utf8)
    return (runtime, log)
  }

  /// A missing host image is pulled, by itself, before the base's container runs, and `run` never
  /// pulls: left to it, a missing image was looked for on Docker Hub (#309).
  func testAMissingHostImageIsPulledBeforeRunAndRunNeverPulls() async throws {
    let (runtime, log) = try failingRuntime(pullFails: false)
    do {
      _ = try await Self.driver(runtime: runtime, context: nil).create()
      XCTFail("run was meant to fail")
    } catch {}
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
      $0.split(separator: " ").prefix(2).joined(separator: " ")
    }
    XCTAssertEqual(
      Array(calls.prefix(3)), ["image inspect", "pull workroom-host", "run --pull=never"])
  }

  /// A pull that fails says the host image couldn't be downloaded, and runs nothing.
  func testAFailedPullSaysTheImageCouldNotBeDownloaded() async throws {
    let (runtime, log) = try failingRuntime(pullFails: true)
    do {
      _ = try await Self.driver(runtime: runtime, context: nil).create()
      XCTFail("a failed pull created a host")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains("couldn't download the workroom host image"),
        error.localizedDescription)
    }
    XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("run "))
  }

  /// The image a new base runs: the hidden override, else the build's pinned digest, else a local
  /// `workroom-host`. Empty values, as an unset build setting leaves `WorkroomHostImage`, don't count.
  func testTheHostImageIsTheOverrideThenThePinThenLocal() {
    let pinned = "ghcr.io/joelmoss/workroom-host@sha256:" + String(repeating: "a", count: 64)
    XCTAssertEqual(RemoteWorkrooms.hostImage(override: "mine", pinned: pinned), "mine")
    XCTAssertEqual(RemoteWorkrooms.hostImage(override: nil, pinned: pinned), pinned)
    XCTAssertEqual(RemoteWorkrooms.hostImage(override: " ", pinned: ""), "workroom-host")
    XCTAssertEqual(RemoteWorkrooms.hostImage(override: nil, pinned: nil), "workroom-host")
  }

  private static func driver(runtime: URL, context: String?) -> ContainerHostDriver {
    ContainerHostDriver(
      hosts: [:], directory: FileManager.default.temporaryDirectory,
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "workroom-host", user: RemoteWorkrooms.user,
        identityFile: "/dev/null", publicKey: "ssh-ed25519 AAAA",
        agentSocket: RemoteWorkrooms.agentSocket, labels: ["workroom.provisioner=test"],
        context: context))
  }

  private static func record(context: String?) -> ContainerHostDriver.Record {
    ContainerHostDriver.Record(
      address: "127.0.0.1", port: 2222, user: RemoteWorkrooms.user, hostKey: "ssh-ed25519 AAAA",
      image: nil, context: context)
  }

  /// A record written before #309 has no context: it reads as nil, which names no context on any
  /// command, as every command did then. A pinned one keeps its context through config.
  func testARecordWithoutAContextReadsAsTheUnpinnedOne() throws {
    let old = Data(
      #"{"address":"127.0.0.1","port":2222,"user":"workroom","host_key":"ssh-ed25519 AAAA"}"#.utf8)
    let decoded = try JSONDecoder().decode(ContainerHostDriver.Record.self, from: old)
    XCTAssertNil(decoded.context)
    XCTAssertEqual(decoded, Self.record(context: nil))

    let pinned = Self.record(context: "orbstack")
    XCTAssertEqual(
      try JSONDecoder().decode(
        ContainerHostDriver.Record.self, from: try JSONEncoder().encode(pinned)), pinned)
  }

  /// Every runtime command names a pinned context, ahead of the command (Docker refuses it after),
  /// and an unpinned driver's commands are exactly what they were before #309.
  func testRuntimeCommandsNameTheContextAheadOfTheCommand() async throws {
    for context in [nil, "orbstack"] as [String?] {
      let (runtime, log) = try stubRuntime()
      _ = await Self.driver(runtime: runtime, context: context).sweep(keeping: [])
      let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
      let prefix = context.map { "--context \($0) " } ?? ""
      XCTAssertEqual(
        calls,
        [
          "\(prefix)ps -a --filter label=workroom.provisioner=test --format "
            + "{{.Names}}\t{{.Label \"workroom.created\"}}",
          "\(prefix)images -aq --filter label=workroom.provisioner=test",
        ], "context \(context ?? "nil")")
    }
  }

  /// A new base is pinned to the context the CLI uses now, except `default`, which is whatever
  /// `DOCKER_HOST` says and so pins nothing. A project with a base stays on the base's context.
  func testANewWorkroomGoesInItsBasesContextOrTheCurrentOne() async throws {
    for (current, expected) in [("orbstack", "orbstack"), ("default", nil)] as [(String, String?)] {
      let (runtime, log) = try stubRuntime(output: current + "\n")
      let remote = RemoteHosts(makeDriver: { Self.driver(runtime: runtime, context: $0) })
      let context = try await remote.context(forBase: nil)
      XCTAssertEqual(context, expected, current)
      XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "context show\n")
    }

    let remote = RemoteHosts(makeDriver: { _ in
      XCTFail("a project with a base asked Docker")
      throw RemoteWorkrooms.Failure.noDocker
    })
    for context in [nil, "desktop-linux"] as [String?] {
      let base = HostDescriptor(
        provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: context))
      let found = try await remote.context(forBase: base)
      XCTAssertEqual(found, context)
    }
  }

  /// Each recorded host is adopted into its own context's driver, and every driver's sweep keeps
  /// every recorded host: two contexts can name one daemon, and a sweep that kept only its own
  /// driver's hosts would remove the other's.
  func testHostsAreAdoptedByContextAndEverySweepKeepsThemAll() async throws {
    let (runtime, _) = try stubRuntime()
    let swept = Swept()
    let remote = RemoteHosts(
      makeDriver: { Self.driver(runtime: runtime, context: $0) },
      sweepDriver: { driver, known in
        swept.add(driver.provisioning?.context, known)
        return []
      })
    let (base, pinned) = (UUID(), UUID())
    let descriptor = { (id: UUID, context: String?) in
      HostDescriptor(
        driver: RemoteWorkrooms.containerDriver, provisioner: RemoteWorkrooms.provisioner, id: id,
        container: Self.record(context: context))
    }
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
          host: descriptor(pinned, "orbstack"))
      ], host: descriptor(base, nil))

    remote.adopt([project])

    XCTAssertNil(try XCTUnwrap(remote.existingDriver(holding: base)).provisioning?.context)
    XCTAssertEqual(remote.existingDriver(holding: pinned)?.provisioning?.context, "orbstack")
    for _ in 0..<500 where swept.calls.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(Set(swept.calls.map(\.context)), [nil, "orbstack"])
    for call in swept.calls { XCTAssertEqual(call.known, [base, pinned], call.context ?? "nil") }
  }

  private final class Swept: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [(context: String?, known: Set<UUID>)] = []
    var calls: [(context: String?, known: Set<UUID>)] { lock.withLock { made } }
    func add(_ context: String?, _ known: Set<UUID>) {
      lock.withLock { made.append((context, known)) }
    }
  }

  /// A driver takes on only a host of its own context: its commands would not reach another's.
  func testADriverRefusesAHostOfAnotherContext() throws {
    let (runtime, _) = try stubRuntime()
    XCTAssertThrowsError(
      try Self.driver(runtime: runtime, context: "orbstack").adopt(
        UUID(), Self.record(context: nil)))
    XCTAssertNoThrow(
      try Self.driver(runtime: runtime, context: "orbstack").adopt(
        UUID(), Self.record(context: "orbstack")))
  }

  /// One delete runs one driver, so hosts in two contexts are refused before anything is removed.
  @MainActor
  func testADeleteAcrossContextsIsRefused() throws {
    let live = { (context: String?) in
      HostDescriptor(
        driver: RemoteWorkrooms.containerDriver, provisioner: RemoteWorkrooms.provisioner,
        id: UUID(), container: Self.record(context: context))
    }
    XCTAssertThrowsError(
      try RemoteHosts().environment(toDelete: [live(nil), live("orbstack")])
    ) { error in
      guard case HostDriverError.invalidConfiguration = error else {
        return XCTFail("\(error)")
      }
    }
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
