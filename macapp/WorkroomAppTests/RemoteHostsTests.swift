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
      startHost: { _ in }, now: { connects.now })
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

  /// Only a host whose workroom the user opened has its container started before connecting: the
  /// status sweep connects to every remote workroom, and must not start them all (#309).
  func testOnlyAnOpenedHostIsStartedBeforeItsConnect() async throws {
    let connects = Connects()
    connects.hold(false)
    let started = Swept()
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { host in
        guard case .remote(let id) = host else { return }
        started.add(nil, [id])
      })
    let (probed, opened) = (UUID(), UUID())

    try await remote.ensureConnected(.remote(probed))
    XCTAssertTrue(started.calls.isEmpty, "a probe of an unopened host started it")

    remote.activate(.remote(opened))
    try await remote.ensureConnected(.remote(opened))
    XCTAssertEqual(started.calls.map(\.known), [[opened]])
    XCTAssertEqual(connects.calls, 2)
  }

  /// Opening a workroom whose host just failed a probe tries it again at once, starting it: the
  /// probe's failure was the container being stopped, which opening is about to fix.
  func testOpeningAHostLiftsItsRetryWindow() async throws {
    let connects = Connects()
    connects.hold(false)
    connects.fail(true)
    let remote = hosts(connects)
    let host = HostID.remote(UUID())
    do { try await remote.ensureConnected(host) } catch {}
    connects.fail(false)
    remote.activate(host)
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

  /// A container workroom's create is off while its project is busy: a second create would build a second
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

  /// The New Workroom menu says why its entries are off while a create holds the project, or a
  /// delete is taking it (#309).
  @MainActor
  func testACreateBlockedProjectSaysWhy() {
    let store = AppStore()
    let project = Project(path: "/proj", vcs: "git", workrooms: [])
    XCTAssertNil(store.createBlockedReason(in: project))
    store.busyProjects["/proj"] = 1
    XCTAssertEqual(store.createBlockedReason(in: project), "a workroom is already being created")
    store.deletingProjects.insert("/proj")
    XCTAssertEqual(store.createBlockedReason(in: project), "the project is being deleted")
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

  private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [Double] = []
    var all: [Double] { lock.withLock { heard } }
    func add(_ fraction: Double) { lock.withLock { heard.append(fraction) } }
  }

  /// A pull's progress reaches the create that asked for it as it goes, rising to the whole (#309).
  func testAPullsProgressReachesItsCreate() async throws {
    let (runtime, _) = try scriptedRuntime(
      """
      "image inspect --format {{.Id}} workroom-host") exit 1 ;;
      "pull workroom-host")
        printf 'aaaaaaaaaaaa: Pulling fs layer\nbbbbbbbbbbbb: Pulling fs layer\n'
        sleep 0.2; printf 'aaaaaaaaaaaa: Pull complete\n'
        sleep 0.2; printf 'bbbbbbbbbbbb: Pull complete\n' ;;
      run*) exit 1 ;;
      """)
    let heard = Fractions()
    let report: @Sendable (Double) -> Void = { heard.add($0) }
    try? await ContainerHostDriver.$pullProgress.withValue(report) {
      _ = try await Self.driver(runtime: runtime, context: nil).create()
    }
    XCTAssertEqual(heard.all, [0, 0.5, 1])
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

  private static func driver(
    runtime: URL, context: String?, dialect: ContainerHostDriver.Dialect = .docker
  ) -> ContainerHostDriver {
    ContainerHostDriver(
      hosts: [:], directory: FileManager.default.temporaryDirectory,
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "workroom-host", user: RemoteWorkrooms.user,
        identityFile: "/dev/null", publicKey: "ssh-ed25519 AAAA",
        agentSocket: RemoteWorkrooms.agentSocket, labels: ["workroom.provisioner=test"],
        context: context, dialect: dialect))
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

    // Written back with no `context` key at all, so an old record's bytes don't change.
    let written = try JSONSerialization.jsonObject(
      with: try JSONEncoder().encode(Self.record(context: nil)))
    XCTAssertNil((written as? [String: Any])?["context"])

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

  /// A new Docker workroom wants the context the CLI uses now, except `default`, which is whatever
  /// `DOCKER_HOST` says and so pins nothing. Apple's runtime has no contexts and asks nothing.
  func testANewWorkroomWantsTheCurrentDockerContext() async throws {
    for (current, expected) in [("orbstack", "orbstack"), ("default", nil)] as [(String, String?)] {
      let (runtime, log) = try stubRuntime(output: current + "\n")
      let remote = RemoteHosts(makeDriver: { Self.driver(runtime: runtime, context: $0.context) })
      let key = try await remote.key(for: .docker)
      XCTAssertEqual(key, RemoteHosts.DriverKey(runtime: .docker, context: expected), current)
      XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "context show\n")
    }
    let remote = RemoteHosts(makeDriver: { _ in
      XCTFail("Apple's key asked a runtime")
      throw RemoteWorkrooms.Failure.noDocker
    })
    let apple = try await remote.key(for: .apple)
    XCTAssertEqual(apple, RemoteHosts.DriverKey(runtime: .apple))
  }

  /// A project keeps a base per runtime and Docker context (#309): a workroom derives from the one
  /// where it is asked for, a base made before #309 (no context) still serves Docker, and recording
  /// or removing one keeps the others.
  func testAProjectKeepsABasePerRuntimeAndContext() throws {
    let base = { (runtime: RemoteWorkrooms.Runtime, context: String?) in
      HostDescriptor(
        driver: runtime.rawValue, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: context))
    }
    let old = base(.docker, nil)
    let key = { (runtime: RemoteWorkrooms.Runtime, context: String?) in
      RemoteHosts.DriverKey(runtime: runtime, context: context)
    }
    // The one-base form a project before #309 has serves Docker on any context, and not Apple.
    XCTAssertEqual(RemoteWorkrooms.base(in: old, for: key(.docker, "orbstack"))?.id, old.id)
    XCTAssertNil(RemoteWorkrooms.base(in: old, for: key(.apple, nil)))

    let apple = base(.apple, nil)
    let both = RemoteWorkrooms.recording(apple, in: old)
    XCTAssertEqual(both.allBases.map(\.id), [old.id, apple.id])
    XCTAssertEqual(RemoteWorkrooms.base(in: both, for: key(.apple, nil))?.id, apple.id)
    // An exact match wins over the context-less one.
    let pinned = base(.docker, "orbstack")
    let three = RemoteWorkrooms.recording(pinned, in: both)
    XCTAssertEqual(RemoteWorkrooms.base(in: three, for: key(.docker, "orbstack"))?.id, pinned.id)
    XCTAssertEqual(RemoteWorkrooms.base(in: three, for: key(.docker, "desktop-linux"))?.id, old.id)
    // Round-trips through config, and comes apart again base by base.
    let decoded = try JSONDecoder().decode(
      HostDescriptor.self, from: try JSONEncoder().encode(three))
    XCTAssertEqual(decoded, three)
    let fewer = RemoteWorkrooms.removing(try XCTUnwrap(old.id), from: three)
    XCTAssertEqual(fewer?.allBases.map(\.id), [apple.id, pinned.id])
    let one = RemoteWorkrooms.removing(try XCTUnwrap(apple.id), from: fewer)
    XCTAssertEqual(one, pinned, "one base left goes back to the one-base form")
    XCTAssertNil(RemoteWorkrooms.removing(try XCTUnwrap(pinned.id), from: one))
  }

  /// Each recorded host is adopted into its own context's driver, and every driver's sweep keeps
  /// every recorded host: two contexts can name one daemon, and a sweep that kept only its own
  /// driver's hosts would remove the other's.
  func testHostsAreAdoptedByContextAndEverySweepKeepsThemAll() async throws {
    let (runtime, _) = try stubRuntime()
    let swept = Swept()
    let remote = RemoteHosts(
      makeDriver: { Self.driver(runtime: runtime, context: $0.context) },
      sweepDriver: { driver, known, _ in
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

  /// A sweep keeps an image another context's host was run from: both contexts can name one daemon,
  /// where that image is labelled as this build's and old enough to go.
  func testASweepKeepsImagesOtherContextsHostsRunFrom() async throws {
    let image = "sha256:" + String(repeating: "b", count: 64)
    for kept in [true, false] {
      let (runtime, log) = try stubRuntime()
      let script = try String(contentsOf: runtime, encoding: .utf8)
      try
        (script + """

          case "$1 $2" in "images -aq") echo \(image.dropFirst(7).prefix(12)) ;; "image inspect") echo 0 ;; esac
          """).write(to: runtime, atomically: true, encoding: .utf8)
      _ = await Self.driver(runtime: runtime, context: nil).sweep(
        keeping: [], images: kept ? [image] : [])
      let removed = try String(contentsOf: log, encoding: .utf8).contains("rmi ")
      XCTAssertEqual(removed, !kept, kept ? "a recorded image was removed" : "the control kept it")
    }
  }

  // MARK: Apple's container runtime (#309)

  /// A stand-in CLI that answers each command by the shell `cases` given (a `case "$*" in` body),
  /// and logs every call.
  private func scriptedRuntime(_ cases: String) throws -> (runtime: URL, log: URL) {
    let (runtime, log) = try stubRuntime()
    let script = try String(contentsOf: runtime, encoding: .utf8)
    try (script + "\ncase \"$*\" in\n\(cases)\nesac\n").write(
      to: runtime, atomically: true, encoding: .utf8)
    return (runtime, log)
  }

  private func calls(_ log: URL) throws -> [String] {
    try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  /// Apple's runtime has no `--restart` or `--pull`, and pulls every platform of an image unless
  /// told its architecture: a missing image is pulled for arm64, and run with neither flag.
  func testAppleRunsAndPullsInItsOwnDialect() async throws {
    let (runtime, log) = try scriptedRuntime(
      """
      "image inspect workroom-host") exit 1 ;;
      run*) exit 1 ;;
      """)
    do {
      _ = try await Self.driver(runtime: runtime, context: nil, dialect: .apple).create()
      XCTFail("run was meant to fail")
    } catch {}
    let made = try calls(log)
    XCTAssertEqual(
      Array(made.prefix(2)),
      ["image inspect workroom-host", "image pull --arch arm64 workroom-host"])
    let run = try XCTUnwrap(made.first { $0.hasPrefix("run ") })
    XCTAssertTrue(run.hasPrefix("run --detach --init --arch arm64 --name workroom-"), run)
    XCTAssertFalse(run.contains("--restart") || run.contains("--pull"), run)
    XCTAssertTrue(made.contains { $0.hasPrefix("delete --force workroom-") }, "\(made)")
  }

  /// Apple's sweep: containers and images labelled as this build's and old enough go, unless a
  /// recorded host is theirs; an image any container was run from stays, since Apple removes an
  /// image that is in use where Docker refuses.
  func testAppleSweepsByJSONAndKeepsImagesInUse() async throws {
    let (kept, swept) = (UUID(), UUID())
    func container(_ id: String, labels: [String: String], image: String) -> [String: Any] {
      [
        "id": id, "status": ["state": "running"],
        "configuration": ["labels": labels, "image": ["reference": image]],
      ]
    }
    func image(_ name: String, labels: [String: String]) -> [String: Any] {
      [
        "configuration": ["name": name],
        "variants": [
          ["platform": ["architecture": "arm64"], "config": ["config": ["Labels": labels]]]
        ],
      ]
    }
    let ours = ["workroom.provisioner": "test", "workroom.created": "1"]
    let list = [
      container(ContainerHostDriver.containerName(kept), labels: ours, image: "in-use:1"),
      container(ContainerHostDriver.containerName(swept), labels: ours, image: "other:1"),
      container(
        "theirs", labels: ["workroom.provisioner": "other", "workroom.created": "1"], image: "x"),
      container(
        "fresh",
        labels: [
          "workroom.provisioner": "test",
          "workroom.created": "\(Int(Date().timeIntervalSince1970))",
        ], image: "y"),
    ]
    let images = [
      image("in-use:1", labels: ours), image("leftover:1", labels: ours),
      image("recorded:1", labels: ours), image("user:1", labels: [:]),
    ]
    let json = { (o: Any) in
      String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    let (runtime, log) = try scriptedRuntime(
      """
      "list --all --format json") printf '%s' \(ContainerHostDriver.shellQuoted(try json(list))) ;;
      "image list --format json") printf '%s' \(ContainerHostDriver.shellQuoted(try json(images))) ;;
      """)
    let failures = await Self.driver(runtime: runtime, context: nil, dialect: .apple).sweep(
      keeping: [kept], images: ["recorded:1"])
    XCTAssertEqual(failures, [])
    let removed = try calls(log).filter { $0.hasPrefix("delete ") || $0.hasPrefix("image delete ") }
    XCTAssertEqual(
      removed,
      ["delete --force \(ContainerHostDriver.containerName(swept))", "image delete leftover:1"])
  }

  /// A derived image is rebuilt from the exported disk with the host image's own process: its
  /// entrypoint, command and environment, not the run-time ones a container carries.
  func testAppleDerivesWithTheImagesOwnProcess() throws {
    let image: [String: Any] = [
      "variants": [
        [
          "platform": ["architecture": "amd64"],
          "config": ["config": ["Entrypoint": ["/wrong"]]],
        ],
        [
          "platform": ["architecture": "arm64"],
          "config": [
            "config": [
              "Entrypoint": ["/usr/local/bin/entrypoint.sh"], "Cmd": ["serve", "a b"],
              "Env": ["PATH=/usr/bin:/bin", #"QUOTED=say "hi" \ $HOME"#], "WorkingDir": "/srv/$x",
              "User": "",
            ]
          ],
        ],
      ]
    ]
    let process = try XCTUnwrap(
      AppleContainerCLI.processConfig(ofImage: image, architecture: "arm64"))
    XCTAssertEqual(
      try AppleContainerCLI.dockerfile(process),
      """
      FROM scratch
      ADD rootfs.tar /
      ENV PATH="/usr/bin:/bin"
      ENV QUOTED="say \\"hi\\" \\\\ \\$HOME"
      WORKDIR /srv/\\$x
      ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
      CMD ["serve","a b"]

      """)
    var broken = process
    broken.env.append("BAD=line\nbreak")
    XCTAssertThrowsError(try AppleContainerCLI.dockerfile(broken))
  }

  /// What each container gets: Apple's own default is a 1 GB VM, too small for a compiler or an
  /// agent, so it gets half the cores and a quarter of the memory, between 2 and 8 GB, unless set.
  /// Docker's containers share Docker's VM and get nothing unless set.
  func testContainerResourcesDefaultForAppleOnly() {
    let gb: UInt64 = 1_073_741_824
    let apple = { (cores: Int, memory: UInt64) in
      RemoteHosts.resources(
        for: .apple, cpus: nil, memory: nil, cores: cores, physicalMemory: memory)
    }
    XCTAssertTrue(apple(10, 32 * gb) == (5, "8G"))
    XCTAssertTrue(apple(8, 16 * gb) == (4, "4G"))
    XCTAssertTrue(apple(2, 4 * gb) == (2, "2G"))
    XCTAssertTrue(
      RemoteHosts.resources(
        for: .apple, cpus: 6, memory: "12G", cores: 8, physicalMemory: 16 * gb) == (6, "12G"))
    XCTAssertTrue(
      RemoteHosts.resources(for: .docker, cpus: nil, memory: nil, cores: 8, physicalMemory: 16 * gb)
        == (nil, nil))
  }

  /// A derive a crash cut short leaves its staged disk in the temporary folder; the sweep removes
  /// one gone quiet, and leaves one still being written.
  func testAppleSweepRemovesStaleDeriveFolders() async throws {
    let temp = FileManager.default.temporaryDirectory
    let stale = temp.appendingPathComponent(
      ContainerHostDriver.deriveDirectoryPrefix + "stale-\(UUID())")
    let live = temp.appendingPathComponent(
      ContainerHostDriver.deriveDirectoryPrefix + "live-\(UUID())")
    for directory in [stale, live] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("disk".utf8).write(to: directory.appendingPathComponent("rootfs.tar"))
    }
    defer { for d in [stale, live] { try? FileManager.default.removeItem(at: d) } }
    let old = Date(timeIntervalSinceNow: -3600)
    for url in [stale, stale.appendingPathComponent("rootfs.tar"), live] {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let (runtime, _) = try scriptedRuntime(
      """
      "list --all --format json") printf '[]' ;;
      "image list --format json") printf '[]' ;;
      """)
    _ = await Self.driver(runtime: runtime, context: nil, dialect: .apple).sweep(keeping: [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a stale folder stayed")
    XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live derive's was taken")
  }

  /// Only a base is derived from. An Apple instance records no image, as a base doesn't, so a
  /// host is a base only when its adopter says so; deriving from an instance would copy its
  /// enrolment.
  func testAnAppleInstanceIsNeverDerivedFrom() async throws {
    let (runtime, log) = try stubRuntime()
    let driver = Self.driver(runtime: runtime, context: nil, dialect: .apple)
    let instance = UUID()
    try driver.adopt(instance, Self.record(context: nil), isBase: false)
    do {
      _ = try await driver.deriveFromBase(.remote(instance))
      XCTFail("derived from an instance")
    } catch HostDriverError.invalidConfiguration {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the instance was touched")
  }

  /// A recorded Apple host is adopted into Apple's driver, and a Docker one beside it into
  /// Docker's, by the descriptor's `driver`.
  func testHostsAreAdoptedIntoTheirRuntimesDrivers() throws {
    let (runtime, _) = try stubRuntime()
    let remote = RemoteHosts(
      makeDriver: { key in
        Self.driver(
          runtime: runtime, context: key.context, dialect: key.runtime == .apple ? .apple : .docker)
      }, sweepDriver: { _, _, _ in [] })
    let (docker, apple) = (UUID(), UUID())
    let host = { (id: UUID, runtime: RemoteWorkrooms.Runtime) in
      HostDescriptor(
        driver: runtime.rawValue, provisioner: RemoteWorkrooms.provisioner, id: id,
        container: Self.record(context: nil))
    }
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
          host: host(apple, .apple))
      ], host: host(docker, .docker))
    remote.adopt([project])
    XCTAssertEqual(remote.existingDriver(holding: docker)?.provisioning?.dialect, .docker)
    XCTAssertEqual(remote.existingDriver(holding: apple)?.provisioning?.dialect, .apple)
  }

  /// A project's workrooms are derived from its base, so they go on the base's runtime: asking
  /// for another is refused before anything is made.
  func testAWorkroomOnAnotherRuntimeThanItsBaseIsRefused() async throws {
    let (runtime, _) = try stubRuntime()
    let driver = Self.driver(runtime: runtime, context: nil, dialect: .apple)
    let environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r")),
        cloneURL: "https://github.com/o/r.git",
        base: HostDescriptor(
          driver: RemoteWorkrooms.Runtime.docker.rawValue, provisioner: RemoteWorkrooms.provisioner,
          id: UUID(), repository: "o/r", cloneURL: "https://github.com/o/r.git",
          path: "/home/workroom/r"),
        runtime: .apple, driver: driver, environment: environment,
        recorder: RemoteWorkrooms.Recorder(
          reserve: { _, _ in "x" }, record: { _, _ in XCTFail("recorded") },
          forget: { _ in }))
      XCTFail("a workroom went on another runtime than its base")
    } catch RemoteWorkrooms.Failure.baseOnOtherRuntime(let runtime) {
      XCTAssertEqual(runtime, "Docker")
    }
  }

  /// Why a container runtime's New Workroom entry is off, in the order a user has to fix it:
  /// Apple's needs Apple silicon and macOS 26 before installing it means anything (#309).
  func testARuntimeEntrySaysWhyItIsOff() {
    let ready = { (runtime: RemoteWorkrooms.Runtime) in
      RemoteWorkrooms.unavailability(
        of: runtime, installed: true, appleSilicon: true, macOS26: true, signedIn: true)
    }
    XCTAssertNil(ready(.docker))
    XCTAssertNil(ready(.apple))
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(
        of: .apple, installed: false, appleSilicon: false, macOS26: false, signedIn: false),
      "needs Apple silicon")
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(
        of: .apple, installed: false, appleSilicon: true, macOS26: false, signedIn: true),
      "needs macOS 26")
    // Docker runs on an Intel Mac and on macOS 15.
    XCTAssertNil(
      RemoteWorkrooms.unavailability(
        of: .docker, installed: true, appleSilicon: false, macOS26: false, signedIn: true))
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(
        of: .docker, installed: false, appleSilicon: true, macOS26: true, signedIn: true),
      "not installed")
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(
        of: .docker, installed: true, appleSilicon: true, macOS26: true, signedIn: false),
      "sign in to Codaset or run gh auth login")
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

  /// A delete takes each host down with the environment of its own runtime and context (#309).
  func testADeleteRoutesEachHostToItsRuntimesEnvironment() throws {
    let (runtime, _) = try stubRuntime()
    let environment = { (key: RemoteHosts.DriverKey) in
      RemoteProvisioning.Environment(
        driver: Self.driver(
          runtime: runtime, context: key.context, dialect: key.runtime == .apple ? .apple : .docker),
        agentSocket: RemoteWorkrooms.agentSocket,
        client: BrokerClient(
          baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    }
    let keys = [
      RemoteHosts.DriverKey(runtime: .docker),
      RemoteHosts.DriverKey(runtime: .docker, context: "orbstack"),
      RemoteHosts.DriverKey(runtime: .apple),
    ]
    let deletion = RemoteHosts.Deletion(
      environments: Dictionary(uniqueKeysWithValues: keys.map { ($0, environment($0)) }))
    for key in keys {
      let host = HostDescriptor(
        driver: key.runtime.rawValue, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: key.context))
      let driver = try XCTUnwrap(deletion.environment(for: host)?.driver as? ContainerHostDriver)
      XCTAssertEqual(driver.provisioning?.context, key.context)
      XCTAssertEqual(driver.provisioning?.dialect, key.runtime == .apple ? .apple : .docker)
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
