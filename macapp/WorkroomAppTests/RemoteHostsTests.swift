import DaemonConnection
import DaemonConnectionTestSupport
import Defaults
import HostDrivers
import Synchronization
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// Guards on remote workrooms that need no Docker (#253): which driver holds each recorded host
/// (`HostDriverRegistry`), adopting and sweeping, the image IDs `destroy` removes with `--force`, a
/// base reused only for its own repository, the client key's repair, the create guard, and
/// re-reading a remote tree. Reaching a host is `HostReachabilityTests`'.
final class RemoteHostsTests: XCTestCase {
  private typealias Connects = HostReachabilityTests.Connects

  // Value: protects=a container workroom made before #308 says to recreate it, and its delete still takes the container down;
  // fails_when=the connect's catch stops keeping olderContainer's words, or adopt stops taking such a record on for its destroy;
  // why_new=the driver test stops at adopt, and nothing covered what the workroom then says or that delete can do as it says; seam=stub runtime; no_claim=the Changes panel's text
  /// A container made before #308 (its record has an ssh host key) is taken on only to be taken
  /// down (Nightly rule: made again, never migrated): its connect, the backoff after it and a
  /// pane's attach all say to recreate the workroom, and the delete that asks for works.
  func testAContainerMadeBeforeExecSaysToRecreateTheWorkroom() async throws {
    let (runtime, log) = try stubRuntime()
    let remote = RemoteHosts(
      makeContainerDriver: { Self.driver(runtime: runtime, context: $0.context) },
      sweepDriver: { _, _, _, _ in [] })
    let id = UUID()
    let host = HostID.remote(id)
    remote.reachability.adopt([
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
            host: HostDescriptor(
              driver: HostKind.container(.docker).driver, provisioner: RemoteWorkrooms.provisioner,
              id: id, container: Self.sshRecord(context: nil)))
        ])
    ])

    for attempt in ["the connect", "a read inside the backoff"] {
      do {
        try await remote.reachability.ensureConnected(host)
        XCTFail("a container made before #308 connected (\(attempt))")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .olderLayout(host), attempt)
        XCTAssertEqual(
          (error as? LocalizedError)?.errorDescription, HostID.olderLayoutMessage, attempt)
      }
    }
    let driver = try XCTUnwrap(remote.registry.existingDriver(holding: id) as? ContainerHostDriver)
    XCTAssertThrowsError(
      try driver.attachCommand(
        to: host, session: UUID(), workingDirectory: "/w", restored: false, metadata: [],
        runCommand: nil)
    ) { XCTAssertEqual($0 as? HostDriverError, .olderContainer) }

    try await driver.destroy(host)
    let calls = try calls(log)
    XCTAssertTrue(
      calls.contains("rm --force --volumes \(ContainerHostDriver.containerName(id))"),
      calls.joined(separator: "\n"))
  }

  /// Value: protects=a pane on a host whose daemon the app couldn't update yet says why it waits
  /// when its attach drops (review #2); fails_when=the pane's command doesn't carry the app's
  /// notice, carries it for a probe, or carries one when there's nothing to say; seam=
  /// PersistentSessionService.attachCommand with the notice stubbed
  @MainActor
  func testAPaneOnAHostWithAnOlderDaemonCarriesWhyItWaits() throws {
    let id = UUID()
    let host = HostID.remote(id)
    let session = UUID()
    let sessions = PersistentSessionService.shared
    let notice = Mutex<String?>("This terminal's host runs an older Workroom daemon (busy).")
    sessions.waitingNotice = { $0 == host ? notice.withLock { $0 } : nil }
    defer {
      sessions.waitingNotice = { RemoteHosts.shared.reachability.waitingNotice(for: $0) }
      sessions.forgetRemoteSession(session)
    }
    sessions.registerRemoteSession(
      session, on: host, via: MachineDriver(made: id), workingDirectory: "/home/boxd/r")
    let pane = UUID()
    let waiting = try XCTUnwrap(sessions.attachCommand(forSession: session, by: pane))
    XCTAssertTrue(waiting.hasPrefix("/usr/bin/env 'WORKROOM_RETRY_NOTICE="), waiting)
    XCTAssertTrue(waiting.contains("older Workroom daemon (busy)"), waiting)
    let probe = try XCTUnwrap(sessions.attachCommand(forSession: session))
    XCTAssertFalse(probe.contains("WORKROOM_RETRY_NOTICE"), "a probe carried the pane's notice")
    notice.withLock { $0 = nil }
    let plain = try XCTUnwrap(sessions.attachCommand(forSession: session, by: pane))
    XCTAssertFalse(plain.contains("WORKROOM_RETRY_NOTICE"), plain)
    sessions.paneDetached(session, by: pane)
  }

  /// Which panes the app counts as attached to a host: a pane attaching reconnects its host
  /// (`attachCommand`, #380), so a registration alone, an attach no pane runs, or a pane on a host
  /// the driver can't reach must not count, and each pane clears only its own.
  @MainActor
  func testOnlyAPaneThatAttachedHoldsItsHost() {
    let boxd = UUID()
    let host = HostID.remote(boxd)
    let session = UUID()
    let sessions = PersistentSessionService.shared
    sessions.registerRemoteSession(
      session, on: host, via: MachineDriver(made: boxd), workingDirectory: "/home/boxd/r")
    // A restored pane registers its session but spawns nothing until it enters a window.
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "a pane that never attached holds the box")
    // An attach no pane runs (a probe, a test's own call) holds nothing.
    XCTAssertNotNil(sessions.attachCommand(forSession: session))
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "an attach no pane runs holds the box")
    let (first, second) = (UUID(), UUID())
    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: first))
    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: second))
    sessions.paneDetached(session, by: first)
    XCTAssertTrue(sessions.hasAttachedPane(on: host), "one pane's detach cleared another's attach")
    sessions.forgetRemoteSession(session)
    // A forgotten pane holds nothing, even if its id is registered again; nor does one whose host
    // the driver can't reach, whose pane only says why.
    sessions.registerRemoteSession(
      session, on: host, via: MachineDriver(made: boxd), workingDirectory: "/home/boxd/r")
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "a forgotten pane still holds the box")
    sessions.forgetRemoteSession(session)
    sessions.registerRemoteSession(
      session, on: host, via: HostDriverRegistry.unreachable, workingDirectory: "/home/boxd/r")
    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: UUID()))
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "a pane that can't reach its host holds it")
    sessions.forgetRemoteSession(session)
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

  /// The launch's one sweep waits out a delete (#296): a call that isn't allowed leaves it for the
  /// next, and only one call ever runs it. One whose runtime could not list is owed again (#284),
  /// and one still running is never claimed twice.
  func testTheSweepIsHeldUntilAllowedThenRunsOnce() {
    let remote = RemoteHosts().registry
    let (docker, apple) = (RemoteHosts.DriverKey(), RemoteHosts.DriverKey(runtime: .apple))
    XCTAssertFalse(remote.sweepHeld, "nothing has reached the sweep, so nothing is owed")
    XCTAssertEqual(remote.claimSweep([docker, apple], allowed: false), [])
    XCTAssertTrue(remote.sweepHeld, "a held sweep is still owed")
    XCTAssertEqual(remote.claimSweep([docker, apple], allowed: true), [docker, apple])
    XCTAssertFalse(remote.sweepHeld)
    XCTAssertEqual(remote.claimSweep([docker, apple], allowed: true), [], "claimed while running")
    remote.finishSweep(docker, ran: true)
    remote.finishSweep(apple, ran: false)
    XCTAssertEqual(remote.claimSweep([docker, apple], allowed: true), [apple])
    remote.finishSweep(apple, ran: true)
    XCTAssertEqual(remote.claimSweep([docker, apple], allowed: true), [])
  }

  /// REWRITTEN (#483, R3): a remote create stays on while another create runs in its project (each
  /// gets its own pane), and goes off only while the project is being deleted.
  /// Value: protects=concurrent creates in one project (spec section 7); fails_when=a running
  /// create still blocks the next, or a deleting project allows one; no_claim=the menu's drawing
  @MainActor
  func testARemoteCreateIsOffOnlyWhileItsProjectIsDeleted() {
    let store = AppStore()
    let project = Project(path: "/proj", vcs: "git", workrooms: [])
    store.lifecycle.creationRuns[UUID()] = CreationRun(
      project: project, kind: .boxd, splitAnchor: nil, previousSelection: nil)
    XCTAssertTrue(
      store.lifecycle.canCreateRemoteWorkroom(in: project), "a running create doesn't block")
    store.lifecycle.deletingProjects.insert("/proj")
    XCTAssertFalse(store.lifecycle.canCreateRemoteWorkroom(in: project))
  }

  /// A workroom in a container wears the network glyph on its tab and pane in place of the cube, and
  /// one on a remote provider the cloud, with what kind of host it is as the tooltip; one on this
  /// Mac keeps the cube (#309).
  func testAWorkroomOnAHostWearsItsPlacesGlyph() {
    let local = Workroom(name: "w", path: "/tmp/w", vcsName: "workroom/w", warnings: [])
      .target(inProject: "/proj")
    XCTAssertEqual(local.workroomGlyph, "cube")
    XCTAssertNil(local.hostKind)
    let docker = Workroom(
      name: "d", path: "/home/workroom/r", vcsName: "workroom/d", warnings: [],
      host: HostDescriptor(
        driver: "container", provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: "orbstack"))
    ).target(inProject: "/proj")
    XCTAssertEqual(docker.workroomGlyph, "network")
    XCTAssertEqual(docker.hostKind, "Docker container (orbstack) on this Mac")
    let destroyed = Workroom(
      name: "x", path: "/home/workroom/r", vcsName: "workroom/x", warnings: [],
      host: HostDescriptor(state: "destroyed", driver: "apple-container")
    ).target(inProject: "/proj")
    XCTAssertEqual(destroyed.workroomGlyph, "network")
    for driver in [HostKind.boxd.driver, HostKind.exeDev.driver] {
      let cloud = Workroom(
        name: "c", path: "/home/boxd/r", vcsName: "workroom/c", warnings: [],
        host: HostDescriptor(driver: driver, provisioner: RemoteWorkrooms.provisioner, id: UUID())
      ).target(inProject: "/proj")
      XCTAssertEqual(cloud.workroomGlyph, "cloud", driver)
    }
  }

  /// Release and Nightly share each other's boxd and exe.dev hosts, and nothing else: a container
  /// is its build's alone, a Dev build shares nothing, and a record that names no driver predates
  /// the field, so it is taken as its build's container.
  /// Value: protects=which build may open and delete a host; fails_when=containers or
  /// Dev hosts are shared, or Release and Nightly stop sharing a provider's host;
  /// why_new=nothing tested ownership across builds; seam=none
  func testReleaseAndNightlyShareOnlyRemoteProviderHosts() {
    let release = "com.developwithstyle.workroom"
    let nightly = "com.developwithstyle.workroom.nightly"
    let dev = "com.developwithstyle.workroom.dev"
    func host(_ driver: String?, by provisioner: String) -> HostDescriptor {
      HostDescriptor(driver: driver, provisioner: provisioner, id: UUID())
    }
    for driver in [HostKind.boxd.driver, HostKind.exeDev.driver] {
      XCTAssertTrue(RemoteWorkrooms.ownsHost(host(driver, by: nightly), as: release), driver)
      XCTAssertTrue(RemoteWorkrooms.ownsHost(host(driver, by: release), as: nightly), driver)
      XCTAssertFalse(RemoteWorkrooms.ownsHost(host(driver, by: release), as: dev), driver)
      XCTAssertFalse(RemoteWorkrooms.ownsHost(host(driver, by: dev), as: release), driver)
    }
    for driver in ["container", "apple-container", nil] {
      XCTAssertFalse(RemoteWorkrooms.ownsHost(host(driver, by: nightly), as: release))
      XCTAssertTrue(RemoteWorkrooms.ownsHost(host(driver, by: release), as: release))
    }
    XCTAssertTrue(RemoteWorkrooms.ownsHost(host("boxd", by: dev), as: dev))
  }

  /// A remote workroom's icon names its machine as its provider lists it, the name each driver gives
  /// it, so it can be found in the provider's dashboard; a destroyed one names none.
  func testAWorkroomOnAHostNamesItsMachine() {
    let id = UUID()
    let boxd = Workroom(
      name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
      host: HostDescriptor(driver: "boxd", provisioner: RemoteWorkrooms.provisioner, id: id)
    ).target(inProject: "/proj")
    let name = "workroom-\(id.uuidString.lowercased())"
    XCTAssertEqual(boxd.machineName, name)
    XCTAssertEqual(boxd.hostTooltip, "Remote workroom on boxd\nMachine: \(name)")
    let directory = FileManager.default.temporaryDirectory
    XCTAssertEqual(
      BoxdHostDriver(
        configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd"), hostSetup: .bundled),
        directory: directory
      ).name(of: id), name)
    XCTAssertEqual(
      ExeDevHostDriver(configuration: .init(hostSetup: .bundled), directory: directory).name(
        of: id),
      name)
    XCTAssertNil(HostDescriptor(state: "destroyed", driver: "boxd", id: id).machineName)
    let local = Workroom(name: "w", path: "/tmp/w", vcsName: "workroom/w", warnings: [])
      .target(inProject: "/proj")
    XCTAssertEqual(local.hostTooltip, "")
  }

  /// A workroom's icon says what kind of host it is on (#309).
  func testAHostSaysWhatKindItIs() {
    let host = { (driver: String?, context: String?) in
      HostDescriptor(driver: driver, container: Self.record(context: context))
    }
    XCTAssertEqual(host("container", nil).kindDescription, "Docker container on this Mac")
    XCTAssertEqual(
      host("container", "orbstack").kindDescription, "Docker container (orbstack) on this Mac")
    XCTAssertEqual(host("apple-container", nil).kindDescription, "Apple container on this Mac")
    XCTAssertEqual(host("boxd", nil).kindDescription, "Remote workroom on boxd")
    XCTAssertEqual(host(nil, nil).kindDescription, "Remote workroom")
  }

  /// Only a container on this Mac is a container workroom, which alone gets the Ports list: a
  /// remote provider publishes its machines' ports itself, and a local workroom needs none.
  func testOnlyAContainersWorkroomIsAContainer() {
    let workroom = { (driver: String?) in
      Workroom(
        name: "w", path: "/home/workroom/w", vcsName: "workroom/w", warnings: [],
        host: driver.map { HostDescriptor(driver: $0, id: UUID()) })
    }
    XCTAssertTrue(workroom("container").isContainer)
    XCTAssertTrue(workroom("apple-container").isContainer)
    XCTAssertFalse(workroom("boxd").isContainer)
    XCTAssertFalse(workroom(HostKind.exeDev.driver).isContainer)
    XCTAssertFalse(workroom(nil).isContainer)
  }

  /// The New Workroom menu says why its entries are off while a delete is taking the project
  /// (#309). REWRITTEN (#483, R3): a create in flight no longer holds the project.
  /// Value: protects=the menu's reason; fails_when=a running create is still given as a reason,
  /// or a delete isn't; no_claim=the menu's drawing
  @MainActor
  func testACreateBlockedProjectSaysWhy() {
    let store = AppStore()
    let project = Project(path: "/proj", vcs: "git", workrooms: [])
    XCTAssertNil(store.lifecycle.createBlockedReason(in: project))
    store.lifecycle.creationRuns[UUID()] = CreationRun(
      project: project, kind: nil, splitAnchor: nil, previousSelection: nil)
    XCTAssertNil(
      store.lifecycle.createBlockedReason(in: project), "a create in flight blocks nothing")
    store.lifecycle.deletingProjects.insert("/proj")
    XCTAssertEqual(store.lifecycle.createBlockedReason(in: project), "the project is being deleted")
  }

  /// No watcher refreshes a remote tree, so coming back to it reads it again; the same local path
  /// would be a no-op.
  @MainActor
  func testReactivatingARemoteTreeListsItAgain() async throws {
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

  /// A remote workroom this app can't reach (another build's, here) reads nothing on this Mac: its
  /// path names a directory on its host, not here.
  @MainActor
  func testAnUnreachableRemoteWorkroomReadsNothingHere() {
    let target = Workroom(
      name: "r", path: NSTemporaryDirectory(), vcsName: "workroom/r", warnings: [],
      host: HostDescriptor(provisioner: "another.build", id: UUID())
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
    printf '%s\\n' "$*" >> \(SSHTransport.shellQuoted(log.path))
    printf '%s' \(SSHTransport.shellQuoted(output))
    """.write(to: runtime, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    return (runtime, log)
  }

  /// A stand-in runtime CLI that logs every call and fails the image's presence check (the image is
  /// missing), `create`, and `pull` when `pullFails`, so `create` stops at its first container.
  private func failingRuntime(pullFails: Bool, said: String = "denied") throws -> (
    runtime: URL, log: URL
  ) {
    let (runtime, log) = try stubRuntime()
    let script = try String(contentsOf: runtime, encoding: .utf8)
    try
      (script + """

        case "$*" in "image inspect --format {{.Id}} "*) exit 1 ;; esac
        case "$1" in create) exit 1 ;; pull) \(pullFails ? "echo '\(said)' >&2; exit 1" : "exit 0") ;; esac
        """).write(to: runtime, atomically: true, encoding: .utf8)
    return (runtime, log)
  }

  /// A missing host image is pulled, by itself, before the base's container is made, and `create`
  /// never pulls: left to it, a missing image was looked for on Docker Hub (#309).
  func testAMissingHostImageIsPulledBeforeCreateAndCreateNeverPulls() async throws {
    let (runtime, log) = try failingRuntime(pullFails: false)
    do {
      _ = try await Self.driver(runtime: runtime, context: nil).create()
      XCTFail("create was meant to fail")
    } catch {}
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
      $0.split(separator: " ").prefix(2).joined(separator: " ")
    }
    XCTAssertEqual(Array(calls.prefix(2)), ["image inspect", "pull workroom-host"])
    // After the pull, only reads of the image (its user, its architecture) before the create.
    XCTAssertEqual(
      calls.dropFirst(2).first { $0 != "image inspect" }, "create --pull=never")
  }

  private final class Fractions: Sendable {
    private let heard = Mutex<[Double?]>([])
    var all: [Double?] { heard.withLock { $0 } }
    func add(_ fraction: Double?) { heard.withLock { $0.append(fraction) } }
  }

  /// A pull's progress reaches the create that asked for it as it goes, rising to the whole, then
  /// says it is done (#309). How many steps arrive between depends on how the pipe's reads fall, so
  /// only their order and ends are pinned (`ImagePullProgressTests` pins the parsing).
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
    let report: @Sendable (Double?) -> Void = { heard.add($0) }
    // The scripted `run` fails, after the pull.
    try? await ContainerHostDriver.$pullProgress.withValue(report) {
      _ = try await Self.driver(runtime: runtime, context: nil).create()
    }
    let all = heard.all
    XCTAssertEqual(all.last, .some(nil), "the pull never said it was done: \(all)")
    let fractions = all.dropLast().compactMap { $0 }
    XCTAssertEqual(fractions.count, all.count - 1, "done before the end: \(all)")
    XCTAssertEqual(fractions.last, 1, "\(all)")
    XCTAssertEqual(fractions, fractions.sorted(), "\(all)")
    XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) }, "\(all)")
  }

  /// A pull that fails says why, by cause, and runs nothing: a registry that refused the image, a
  /// runtime that isn't running, or else the network.
  func testAFailedPullSaysWhy() async throws {
    for (said, expected) in [
      ("denied", "the registry refused the image workroom-host"),
      (
        "Cannot connect to the Docker daemon at unix:///x. Is the docker daemon running?",
        "Docker didn't answer"
      ),
      (
        "Got permission denied while trying to connect to the Docker daemon socket at unix:///x",
        "Docker didn't answer"
      ),
      ("manifest unknown", "the registry refused the image workroom-host"),
      ("read: connection reset by peer", "couldn't download the image workroom-host"),
    ] {
      let (runtime, log) = try failingRuntime(pullFails: true, said: said)
      do {
        _ = try await Self.driver(runtime: runtime, context: nil).create()
        XCTFail("a failed pull created a host")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
      }
      XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("create "))
    }
  }

  /// A runtime that isn't running says so at its first command, rather than pulling: its inspect
  /// failing is not a missing image.
  func testARuntimeThatIsNotRunningSaysSo() async throws {
    for (dialect, said, expected) in [
      (
        ContainerRuntime.docker,
        "Cannot connect to the Docker daemon at unix:///x. Is the docker daemon running?",
        "Docker didn't answer"
      ),
      (
        .apple,
        "Error: interrupted: \"XPC connection error: Connection invalid\"\nEnsure container "
          + "system service has been started with `container system start`.",
        "container system start"
      ),
    ] {
      let (runtime, log) = try stubRuntime()
      let script = try String(contentsOf: runtime, encoding: .utf8)
      try (script + "\nprintf '%s\\n' \(SSHTransport.shellQuoted(said)) >&2; exit 1\n")
        .write(to: runtime, atomically: true, encoding: .utf8)
      do {
        _ = try await Self.driver(runtime: runtime, context: nil, dialect: dialect).create()
        XCTFail("created without a runtime")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
      }
      XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("pull"), "it pulled")
    }
  }

  private static func driver(
    runtime: URL, context: String?, dialect: ContainerRuntime = .docker,
    directory: URL? = nil
  ) -> ContainerHostDriver {
    // A directory of its own: a sweep writes down what it found unknown there (#284), which another
    // test's driver must not read.
    ContainerHostDriver(
      hosts: [:],
      directory: directory
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "wr-hosts-\(UUID().uuidString)", isDirectory: true),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "workroom-host", user: RemoteWorkrooms.user,
        daemonSocket: RemoteWorkrooms.daemonSocket, labels: ["workroom.provisioner=test"],
        context: context, dialect: dialect, daemon: { _ in daemon },
        daemonFolder: daemon.deletingLastPathComponent().appendingPathComponent("daemon")))
  }

  /// A stand-in for the bundled Linux daemon, which a create copies or mounts before it makes the
  /// container.
  private static let daemon: URL = {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-daemon-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("workroomd-linux")
    try? Data("ELF".utf8).write(to: file)
    return file
  }()

  private static func record(context: String?) -> ContainerHostRecord {
    ContainerHostRecord(user: RemoteWorkrooms.user, image: nil, context: context)
  }

  /// A container made before #308, reached by ssh.
  private static func sshRecord(context: String?) -> ContainerHostRecord {
    ContainerHostRecord(
      address: "127.0.0.1", port: 2222, user: RemoteWorkrooms.user, hostKey: "ssh-ed25519 AAAA",
      image: nil, context: context)
  }

  /// A record written before #309 has no context: it reads as nil, which names no context on any
  /// command, as every command did then. A pinned one keeps its context through config.
  func testARecordWithoutAContextReadsAsTheUnpinnedOne() throws {
    let old = Data(
      #"{"address":"127.0.0.1","port":2222,"user":"workroom","host_key":"ssh-ed25519 AAAA"}"#.utf8)
    let decoded = try JSONDecoder().decode(ContainerHostRecord.self, from: old)
    XCTAssertNil(decoded.context)
    XCTAssertEqual(decoded, Self.sshRecord(context: nil))

    // Written back with no `context` key at all, so an old record's bytes don't change.
    let written = try JSONSerialization.jsonObject(
      with: try JSONEncoder().encode(Self.sshRecord(context: nil)))
    XCTAssertNil((written as? [String: Any])?["context"])

    let pinned = Self.record(context: "orbstack")
    XCTAssertEqual(
      try JSONDecoder().decode(
        ContainerHostRecord.self, from: try JSONEncoder().encode(pinned)), pinned)
  }

  /// Every runtime command names a pinned context, ahead of the command (Docker refuses it after),
  /// and an unpinned driver's commands are exactly what they were before #309.
  func testRuntimeCommandsNameTheContextAheadOfTheCommand() async throws {
    for context in [nil, "orbstack"] as [String?] {
      let (runtime, log) = try stubRuntime()
      _ = await Self.driver(runtime: runtime, context: context).sweep(keeping: [])
      let calls = try self.calls(log)
      let prefix = context.map { "--context \($0) " } ?? ""
      XCTAssertEqual(
        calls,
        [
          "\(prefix)ps -a --filter label=workroom.provisioner=test --format "
            + "{{.Names}}\t{{.Label \"workroom.created\"}}\t{{.Label \"workroom.volumes\"}}",
          "\(prefix)images -aq --filter label=workroom.provisioner=test",
        ], "context \(context ?? "nil")")
    }
  }

  /// A new Docker workroom wants the context the CLI uses now, except `default`, which is whatever
  /// `DOCKER_HOST` says and so pins nothing. Apple's runtime has no contexts and asks nothing.
  func testANewWorkroomWantsTheCurrentDockerContext() async throws {
    for (current, expected) in [("orbstack", "orbstack"), ("default", nil)] as [(String, String?)] {
      let (runtime, log) = try stubRuntime(output: current + "\n")
      let remote = RemoteHosts(
        makeContainerDriver: { Self.driver(runtime: runtime, context: $0.context) }
      ).registry
      let key = try await remote.key(for: .docker)
      XCTAssertEqual(key, RemoteHosts.DriverKey(runtime: .docker, context: expected), current)
      XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "context show\n")
    }
    let remote = RemoteHosts(makeContainerDriver: { _ in
      XCTFail("Apple's key asked a runtime")
      throw RemoteWorkrooms.Failure.noDocker
    }).registry
    let apple = try await remote.key(for: .apple)
    XCTAssertEqual(apple, RemoteHosts.DriverKey(runtime: .apple))
  }

  /// A project an older build made keeps a base per runtime and Docker context (#309): the one for
  /// a key is found, a base made before #309 (no context) still serves Docker, and removing one
  /// keeps the others.
  func testAnOlderProjectsBasesAreFoundAndRemovedOneByOne() throws {
    let base = { (runtime: ContainerRuntime, context: String?) in
      HostDescriptor(
        driver: runtime.rawValue, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: context))
    }
    let old = base(.docker, nil)
    let key = { (runtime: ContainerRuntime, context: String?) in
      RemoteHosts.DriverKey(runtime: runtime, context: context)
    }
    // The one-base form a project before #309 has serves Docker on any context, and not Apple.
    XCTAssertEqual(
      BaseRetirement.base(in: BaseRetirement.bases(of: old), for: key(.docker, "orbstack"))?.id,
      old.id)
    XCTAssertNil(BaseRetirement.base(in: BaseRetirement.bases(of: old), for: key(.apple, nil)))

    let apple = base(.apple, nil)
    let both = HostDescriptor(bases: [old, apple])
    XCTAssertEqual(BaseRetirement.bases(of: both).map(\.id), [old.id, apple.id])
    XCTAssertEqual(
      BaseRetirement.base(in: BaseRetirement.bases(of: both), for: key(.apple, nil))?.id, apple.id)
    // An exact match wins over the context-less one.
    let pinned = base(.docker, "orbstack")
    let three = HostDescriptor(bases: [old, apple, pinned])
    XCTAssertEqual(
      BaseRetirement.base(in: BaseRetirement.bases(of: three), for: key(.docker, "orbstack"))?.id,
      pinned.id)
    XCTAssertEqual(
      BaseRetirement.base(in: BaseRetirement.bases(of: three), for: key(.docker, "desktop-linux"))?
        .id, old.id)
    // Round-trips through config, so a launch can read what it retires.
    let decoded = try JSONDecoder().decode(
      HostDescriptor.self, from: try JSONEncoder().encode(three))
    XCTAssertEqual(decoded, three)
  }

  /// Each recorded host is adopted into its own context's driver, and every driver's sweep keeps
  /// every recorded host: two contexts can name one daemon, and a sweep that kept only its own
  /// driver's hosts would remove the other's.
  func testHostsAreAdoptedByContextAndEverySweepKeepsThemAll() async throws {
    let (runtime, _) = try stubRuntime()
    let swept = Swept()
    let remote = RemoteHosts(
      makeContainerDriver: { Self.driver(runtime: runtime, context: $0.context) },
      sweepDriver: { driver, known, _, _ in
        swept.add(driver.provisioning?.context, known)
        return []
      })
    let (base, pinned) = (UUID(), UUID())
    let descriptor = { (id: UUID, context: String?) in
      HostDescriptor(
        driver: HostKind.container(.docker).driver, provisioner: RemoteWorkrooms.provisioner,
        id: id,
        container: Self.record(context: context))
    }
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
          host: descriptor(pinned, "orbstack"))
      ], host: descriptor(base, nil))

    remote.reachability.adopt([project])

    XCTAssertNil(
      try XCTUnwrap(remote.registry.existingDriver(holding: base) as? ContainerHostDriver)
        .provisioning?.context)
    XCTAssertEqual(
      (remote.registry.existingDriver(holding: pinned) as? ContainerHostDriver)?.provisioning?
        .context,
      "orbstack")
    for _ in 0..<500 where swept.calls.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(Set(swept.calls.map(\.context)), [nil, "orbstack"])
    for call in swept.calls { XCTAssertEqual(call.known, [base, pinned], call.context ?? "nil") }
  }

  /// A boxd host (#356) is its own driver key, never Docker's: before boxd had a key, a delete of
  /// one fell back to Docker (`DriverKey(host) ?? DriverKey()`), and a descriptor naming a driver
  /// this build doesn't know is refused rather than taken down with another.
  func testABoxdHostIsItsOwnDriverKeyNeverDockers() throws {
    let boxd = HostDescriptor(
      driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
      org: "acme", account: "usr_1")
    let key = RemoteHosts.DriverKey(boxd)
    XCTAssertEqual(key, .boxd(org: "acme", account: "usr_1"))
    XCTAssertNil(key?.runtime)
    XCTAssertEqual(key?.kind, .boxd)
    // A boxd machine logs in as `boxd`, so the clone goes in its home, not the container user's.
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    XCTAssertEqual(
      RemoteWorkrooms.clonePath(for: repository, on: try XCTUnwrap(key)), "/home/boxd/r")
    XCTAssertEqual(RemoteWorkrooms.clonePath(for: repository), "/home/workroom/r")
    XCTAssertEqual(try HostDriverRegistry.deletionKey(boxd), .boxd(org: "acme", account: "usr_1"))
    // A descriptor from before the `driver` field is Docker's, as it always was.
    XCTAssertEqual(
      try HostDriverRegistry.deletionKey(HostDescriptor(id: UUID())), RemoteHosts.DriverKey())
    XCTAssertThrowsError(
      try HostDriverRegistry.deletionKey(HostDescriptor(driver: "exe.dev", id: UUID())))
    // A boxd base serves only its own org and account; there is no unpinned form to fall back to.
    XCTAssertEqual(
      BaseRetirement.base(
        in: BaseRetirement.bases(of: boxd), for: .boxd(org: "acme", account: "usr_1"))?.id, boxd.id)
    XCTAssertNil(
      BaseRetirement.base(
        in: BaseRetirement.bases(of: boxd), for: .boxd(org: nil, account: "usr_1")))
    XCTAssertNil(
      BaseRetirement.base(in: BaseRetirement.bases(of: boxd), for: RemoteHosts.DriverKey()))
    // And the descriptor round-trips through config with its org and account.
    XCTAssertEqual(
      try JSONDecoder().decode(HostDescriptor.self, from: try JSONEncoder().encode(boxd)), boxd)
  }

  /// Value: protects=a delete (Remove Workroom or Delete Project) whose gone host's provider can't
  /// give an environment still goes ahead for the rest, leaving that host's delete to keep its
  /// record (`RemoteWorkrooms.delete`), while a live host's failure still refuses the delete before
  /// anything is removed (review 4, Y1); fails_when=Delete Project refuses for a gone host that
  /// Remove Workroom takes, or a live host's failure is swallowed; seam=HostDriverRegistry's
  /// environment(toDelete:gone:) with a driver seam that fails for one provider
  @MainActor
  func testAGoneHostsProviderFailingDoesNotStopTheDelete() throws {
    let remote = RemoteHosts(makeDriver: { key -> any HostTerminalDriver in
      if case .exeDev = key { throw HostDriverError.invalidConfiguration("exe.dev unavailable") }
      return BoxdHostDriver(
        configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd"), hostSetup: .bundled),
        directory: FileManager.default.temporaryDirectory)
    }).registry
    let live = HostDescriptor(
      driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
      org: "acme", account: "usr_1")
    let gone = HostDescriptor(
      driver: HostKind.exeDev.driver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
      account: "me@x.dev")
    XCTAssertThrowsError(try remote.environment(toDelete: [live, gone], gone: []))
    let deletion = try XCTUnwrap(try remote.environment(toDelete: [live, gone], gone: [gone.id!]))
    XCTAssertNotNil(deletion.environment(for: live))
    XCTAssertNil(deletion.environment(for: gone))
    XCTAssertNil(try remote.environment(toDelete: [gone], gone: [gone.id!]))
    XCTAssertThrowsError(try remote.environment(toDelete: [gone], gone: [live.id!]))
  }

  /// A delete of a remote provider's host asks for that provider's driver and environment, never
  /// Docker's; the environment's daemon socket is the driver's own, on the host's home disk, never
  /// the container image's tmpfs `/run/workroom` one; its git never borrows the Mac's `gh`
  /// (OQ20); and a clone that fails says the provider's own fix. One row per remote provider.
  @MainActor
  func testDeletingARemoteProviderHostUsesItsOwnDriver() throws {
    let rows: [(host: HostDescriptor, key: RemoteHosts.DriverKey, socket: String)] = [
      (
        HostDescriptor(
          driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
          org: "acme", account: "usr_1"),
        .boxd(org: "acme", account: "usr_1"),
        BoxdHostDriver.Configuration(cli: URL(fileURLWithPath: "/boxd"), hostSetup: .bundled)
          .daemonSocket
      ),
      (
        HostDescriptor(
          driver: HostKind.exeDev.driver, provisioner: RemoteWorkrooms.provisioner,
          id: UUID(), account: "me@x.dev"),
        .exeDev(account: "me@x.dev"),
        ExeDevHostDriver.Configuration(hostSetup: .bundled).daemonSocket
      ),
    ]
    for row in rows {
      let asked = Asked()
      let remote = RemoteHosts(makeDriver: { key -> any HostTerminalDriver in
        asked.add(key)
        if case .exeDev(let account) = key {
          return ExeDevHostDriver(
            configuration: .init(account: account, hostSetup: .bundled),
            directory: FileManager.default.temporaryDirectory)
        }
        return BoxdHostDriver(
          configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd"), hostSetup: .bundled),
          directory: FileManager.default.temporaryDirectory)
      }).registry
      let deletion = try XCTUnwrap(try remote.environment(toDelete: [row.host]))
      XCTAssertEqual(asked.all, [row.key], "\(row.key)")
      let environment = try XCTUnwrap(deletion.environment(for: row.host))
      XCTAssertEqual(environment.daemonSocket, row.socket, "\(row.key)")
      XCTAssertNotEqual(environment.daemonSocket, RemoteWorkrooms.daemonSocket, "\(row.key)")
      XCTAssertNil(
        environment.gitHubToken, "\(row.key): a remote host's git never borrows the Mac's gh")
      // Value: protects=a provider's failed clone says how to give its host GitHub access;
      // fails_when=HostDriverRegistry.environment stops passing its place's credentialHint;
      // why_new=the provisioning test hands its hint in itself; seam=none; no_claim=the wording
      let (_, creating) = try remote.environment(row.key)
      XCTAssertNotNil(creating.credentialHint, "\(row.key)")
      XCTAssertEqual(creating.credentialHint, row.key.kind.credentialHint, "\(row.key)")
      // Only exe.dev's create adds the repository's integration before the VM.
      XCTAssertEqual(
        creating.grantRepository != nil, row.key.kind == .exeDev, "\(row.key)")
    }
  }

  /// A workroom clones the project's origin as it is, ssh form included, when it names the
  /// repository; an origin naming another repository, or none, gives way to https.
  func testAWorkroomClonesTheProjectsOriginAsItIs() throws {
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    let https = "https://github.com/o/r.git"
    XCTAssertEqual(
      RemoteWorkrooms.cloneURL(for: repository, origin: "git@github.com:o/r.git\n"),
      "git@github.com:o/r.git")
    XCTAssertEqual(
      RemoteWorkrooms.cloneURL(for: repository, origin: "https://github.com/o/r"),
      "https://github.com/o/r")
    XCTAssertEqual(
      RemoteWorkrooms.cloneURL(for: repository, origin: "git@github.com:someone/fork.git"), https)
    XCTAssertEqual(
      RemoteWorkrooms.cloneURL(for: repository, origin: "https://github.com/someone/fork.git"),
      https)
    XCTAssertEqual(
      RemoteWorkrooms.cloneURL(for: repository, origin: "http://github.com/o/r"), https)
    // No host rewrites these to https, so they would clone over ssh with no key there.
    XCTAssertEqual(
      RemoteWorkrooms.cloneURL(for: repository, origin: "ssh://git@github.com/o/r.git"), https)
    XCTAssertEqual(RemoteWorkrooms.cloneURL(for: repository, origin: "github.com:o/r.git"), https)
    XCTAssertEqual(RemoteWorkrooms.cloneURL(for: repository, origin: nil), https)
  }

  /// A remote provider's failed clone says how that provider gives a host GitHub access, the
  /// command included; a container's is Workroom's own relay, which says so itself.
  func testOnlyARemoteProviderSaysHowToGiveItsHostGitHubAccess() {
    XCTAssertNil(HostKind.container(.docker).credentialHint)
    XCTAssertNil(HostKind.container(.apple).credentialHint)
    XCTAssertTrue(
      HostKind.boxd.credentialHint?.contains("boxd manage integrations connect git")
        == true)
    XCTAssertTrue(
      HostKind.exeDev.credentialHint?.contains("exe.dev/integrations") == true)
  }

  /// The Details pane's link to a host: each provider's own page for the machine, as its web app
  /// routes it; a container has none.
  func testADashboardURLIsTheProvidersPageForTheMachine() {
    let machine = "workroom-8a13f76f-01f4-45d1-9065-c14b5cbd86e1"
    XCTAssertEqual(
      HostKind.boxd.dashboardURL(machine: machine)?.absoluteString,
      "https://app.boxd.sh/machines?m=\(machine)")
    XCTAssertEqual(
      HostKind.exeDev.dashboardURL(machine: machine)?.absoluteString,
      "https://exe.dev/vm/\(machine)")
    XCTAssertNil(HostKind.container(.docker).dashboardURL(machine: machine))
  }

  /// After a relaunch a boxd workroom is reached without Docker: its driver is made by name, with
  /// the org and account its record holds, and a missing container runtime never reads as its host
  /// being gone, which would report a closed pane's session ended while it runs on (#356).
  func testABoxdWorkroomIsReachedAfterARelaunchWithoutDocker() throws {
    let remote = RemoteHosts()
    let id = UUID()
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/boxd/r", vcsName: "workroom/w", warnings: [],
          host: HostDescriptor(
            driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner, id: id,
            org: "acme", account: "usr_1"))
      ])

    remote.reachability.adopt([project])

    let driver = try XCTUnwrap(remote.registry.existingDriver(holding: id) as? BoxdHostDriver)
    XCTAssertEqual(driver.configuration.org, "acme")
    XCTAssertEqual(driver.configuration.account, "usr_1")
    // Discriminates only where no container runtime is installed (CI's runners): on a Mac with
    // Docker, `runtimeIsMissing` is false for any host, and no seam-free way picks the runtime
    // lookup (`RemoteHosts.executable`, fixed paths). Kept for CI; eng review D6.
    XCTAssertFalse(remote.registry.runtimeIsMissing(for: .remote(id)))
  }

  /// Value: protects=a Railway workroom is reached and deleted after a relaunch from config alone
  /// (#629); fails_when=its record isn't adopted at reload or at delete, so every pane, read and
  /// delete reads the host as unknown; or its clone goes in /home/root; seam=HostDriverRegistry
  @MainActor func testARailwayWorkroomIsReachedAndDeletedAfterARelaunch() throws {
    let id = UUID()
    let record = RailwayHostRecord(
      projectID: "prj", environmentID: "env-1", sandboxID: "sbx-1", hostKey: "ssh-ed25519 AAAA")
    let host = HostDescriptor(
      driver: HostKind.railway.driver, provisioner: RemoteWorkrooms.provisioner, id: id,
      railway: record)
    let key = try XCTUnwrap(RemoteHosts.DriverKey(host))
    XCTAssertEqual(key, .railway(environment: "env-1"))
    XCTAssertNil(
      RemoteHosts.DriverKey(HostDescriptor(driver: HostKind.railway.driver, id: id)),
      "a Railway host with no record names no driver")
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    XCTAssertEqual(RemoteWorkrooms.clonePath(for: repository, on: key), "/root/r")
    XCTAssertEqual(host.machineName, "sbx-1")

    let remote = RemoteHosts()
    remote.reachability.adopt([
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(name: "w", path: "/root/r", vcsName: "workroom/w", warnings: [], host: host)
        ])
    ])
    let driver = try XCTUnwrap(
      remote.registry.existingDriver(holding: id) as? RailwayHostDriver)
    XCTAssertEqual(driver.configuration.environmentID, "env-1")
    // Held, so a pane, a read and a delete reach it (an attach would write its ssh files).
    var adopted = HostDescriptor(driver: HostKind.railway.driver)
    driver.record(.remote(id), in: &adopted)
    XCTAssertEqual(adopted.railway, record)
    XCTAssertFalse(remote.registry.runtimeIsMissing(for: .remote(id)))

    // A delete straight after launch, before any reload adopted it.
    let fresh = RemoteHosts().registry
    let deletion = try XCTUnwrap(try fresh.environment(toDelete: [host]))
    let environment = try XCTUnwrap(deletion.environment(for: host))
    XCTAssertEqual(environment.daemonSocket, "/root/.local/state/workroom/daemon/workroomd.sock")
    XCTAssertNil(environment.gitHubToken)
    var recorded = HostDescriptor(driver: HostKind.railway.driver)
    (try fresh.driver(key) as? any HostRecording)?.record(.remote(id), in: &recorded)
    XCTAssertEqual(recorded.railway, record)
  }

  /// Railway at HTTP for the launch sweep (#630): lists the sandboxes it holds, all made long ago,
  /// and destroys what it's asked, recording each GraphQL request's query and variables.
  private final class SweptRailway: RailwayHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [[String: Any]] = []
    private var rows: [String]
    init(_ rows: [String]) { self.rows = rows }

    var sent: [[String: Any]] { lock.withLock { _sent } }
    func variables(_ field: String) -> [[String: Any]] {
      sent.filter { ($0["query"] as? String)?.contains("\(field)(") == true }
        .map { $0["variables"] as? [String: Any] ?? [:] }
    }
    var destroyed: [String] { variables("sandboxDestroy").compactMap { $0["id"] as? String } }

    func send(_ request: URLRequest) async throws -> RailwayHTTPResponse {
      let body =
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        ?? [:]
      let query = body["query"] as? String ?? ""
      let variables = body["variables"] as? [String: Any] ?? [:]
      let environment = variables["environmentId"] as? String ?? ""
      let data: [String: Any]? = lock.withLock {
        _sent.append(body)
        if query.contains("sandboxes(") {
          let edges = rows.map { id -> [String: Any] in
            [
              "cursor": id,
              "node": [
                "id": id, "status": "RUNNING", "createdAt": "2026-01-01T00:00:00Z",
                "environmentId": environment,
              ],
            ]
          }
          return ["sandboxes": ["edges": edges, "pageInfo": ["hasNextPage": false]]]
        }
        if query.contains("sandboxDestroy(") {
          let id = variables["id"] as? String ?? ""
          rows.removeAll { $0 == id }
          return ["sandboxDestroy": ["id": id, "status": "DESTROYING"]]
        }
        // The sign-in sees this Mac's workspace, so a lost reply may be reconciled.
        if query.contains("me {") {
          return ["me": ["workspaces": [["id": "ws-1", "name": "Mine", "plan": "PRO"]]]]
        }
        return nil
      }
      guard let data else {
        return RailwayHTTPResponse(
          status: 200, body: Data(#"{"errors":[{"message":"no stub"}]}"#.utf8))
      }
      return RailwayHTTPResponse(
        status: 200, body: try JSONSerialization.data(withJSONObject: ["data": data]))
    }
  }

  private struct RailwayToken: RailwayAccessTokenProviding {
    func accessToken() async throws -> String { "at" }
    func accessTokenRejected(_ token: String) async {}
  }

  /// Value: protects=no sandbox this Mac made is left billing that no workroom names, once per
  /// launch, no other environment is ever listed or touched, and only what this Mac's create
  /// ledger names goes, whatever config says (ADR 0071 and its amendment, #630); fails_when=adopt
  /// doesn't sweep Railway, sweeps an environment a record names instead of this Mac's, destroys a
  /// recorded sandbox, destroys an unledgered one, or sweeps twice a launch;
  /// seam=HostDriverRegistry.adopt with makeDriver and the environment seam
  func testALaunchSweepsThisMacsRailwayEnvironmentOnce() async throws {
    let railway = SweptRailway(["sbx-orphan", "sbx-kept", "sbx-live"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-railway-sweep-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    /// A launch: a registry of its own over the same Railway and the same Railway folder.
    func launch() -> RemoteHosts {
      RemoteHosts(
        makeDriver: { key in
          guard case .railway(let environment) = key else {
            throw HostDriverError.invalidConfiguration("\(key)")
          }
          return RailwayHostDriver(
            configuration: .init(
              environmentID: environment, projectID: nil, workspaceID: "ws-1", keys: root,
              relayHost: "relay.invalid", hostSetup: .bundled),
            api: RailwayAPI(transport: railway, tokens: RailwayToken()), directory: root)
        }, railwayEnvironment: { "env-1" })
    }
    func settle(_ remote: RemoteHosts) async throws {
      for _ in 0..<500 where remote.registry.sweepsRunning > 0 {
        try await Task.sleep(for: .milliseconds(2))
      }
    }
    func projects(_ records: [RailwayHostRecord]) -> [Project] {
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: records.map {
            Workroom(
              name: $0.sandboxID, path: "/root/r", vcsName: "workroom/w", warnings: [],
              host: HostDescriptor(
                driver: HostKind.railway.driver, provisioner: RemoteWorkrooms.provisioner,
                id: UUID(), railway: $0))
          })
      ]
    }
    let elsewhere = RailwayHostRecord(
      projectID: "prj", environmentID: "env-other", sandboxID: "sbx-elsewhere", hostKey: "k")
    let here = RailwayHostRecord(
      projectID: "prj", environmentID: "env-1", sandboxID: "sbx-kept", hostKey: "k")

    let ledger = RailwayCreateLedger(directory: root)
    let longAgo = Date().addingTimeInterval(-2 * RailwayHostDriver.sweepGrace)

    // No config at all, then one naming only another Mac's environment, with nothing ledgered:
    // nothing is even listed.
    var remote = launch()
    remote.reachability.adopt([])
    try await settle(remote)
    remote = launch()
    remote.reachability.adopt(projects([elsewhere]))
    try await settle(remote)
    XCTAssertTrue(railway.sent.isEmpty, "\(railway.sent)")

    // A lost reply whose window holds every sandbox here, with no record of this environment: a
    // sandbox no record names says nothing then (a create retried in the window, its record lost
    // with the config), so nothing is listed, and the intent waits.
    let january = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:01Z"))
    try await ledger.update { $0 = [.init(started: january)] }
    remote = launch()
    remote.reachability.adopt(projects([elsewhere]))
    try await settle(remote)
    XCTAssertTrue(railway.sent.isEmpty, "\(railway.sent)")
    let waiting = try await ledger.entries()
    XCTAssertEqual(waiting.count, 1)

    // A create left sbx-orphan in the ledger: only it goes, never the unledgered sbx-live.
    try await ledger.update { $0 = [.init(started: longAgo, sandbox: "sbx-orphan")] }
    remote = launch()
    remote.reachability.adopt(projects([elsewhere]))
    try await settle(remote)
    XCTAssertEqual(railway.destroyed, ["sbx-orphan"])

    // A config naming this environment changes nothing: a lost reply is matched by time, once a
    // launch, after a held sweep, and nothing made long before it goes.
    try await ledger.update { $0 = [.init(started: longAgo)] }
    remote = launch()
    remote.reachability.adopt(projects([here, elsewhere]), sweep: false)
    try await settle(remote)
    XCTAssertTrue(railway.variables("sandboxes").isEmpty, "a held sweep ran")
    remote.reachability.adopt(projects([here, elsewhere]))
    try await settle(remote)
    XCTAssertEqual(railway.variables("sandboxes").count, 1)
    XCTAssertEqual(railway.destroyed, ["sbx-orphan"])
    let sent = railway.variables("sandboxes") + railway.variables("sandboxDestroy")
    XCTAssertEqual(Set(sent.compactMap { $0["environmentId"] as? String }), ["env-1"])
    try await ledger.update { $0 = [.init(started: longAgo)] }
    remote.reachability.adopt(projects([here, elsewhere]))
    try await settle(remote)
    XCTAssertEqual(railway.variables("sandboxes").count, 1, "swept twice in a launch")
  }

  /// Value: protects=a Railway sweep that fails says it was the sweep and Railway's own reason,
  /// whatever step failed (review 3, I5); fails_when=every failure is labelled as listing the
  /// sandboxes (a workspace read, a ledger write) or loses Railway's words;
  /// seam=HostDriverRegistry.railwaySweepFailure
  func testARailwaySweepFailureSaysItWasTheSweepAndWhy() {
    XCTAssertEqual(
      HostDriverRegistry.railwaySweepFailure(RailwaySessionError.signedOut),
      "Railway sweep: Workroom isn't signed in to Railway.")
    XCTAssertEqual(
      HostDriverRegistry.railwaySweepFailure(RailwayAPIError.http(status: 503, message: "down")),
      "Railway sweep: Railway answered 503: down.")
  }

  /// Value: protects=a Railway sandbox leaves this Mac's create ledger only once config holds its
  /// record, so a config write that fails leaves it for the sweep (review #1); fails_when=the
  /// create's recorder takes it off before or without the write succeeding, or never does;
  /// seam=RemoteWorkrooms.Recorder.forgettingPending with a RailwayHostDriver and its ledger
  func testARailwaySandboxLeavesTheLedgerOnlyOnceItsRecordIsWritten() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-railway-record-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let driver = RailwayHostDriver(
      configuration: .init(
        environmentID: "env-1", projectID: nil, keys: root, relayHost: "relay.invalid",
        hostSetup: .bundled),
      api: RailwayAPI(transport: SweptRailway([]), tokens: RailwayToken()), directory: root)
    let ledger = RailwayCreateLedger(directory: root)
    try await ledger.update { $0 = [.init(started: Date(), sandbox: "sbx-1")] }
    let descriptor = HostDescriptor(
      driver: HostKind.railway.driver, id: UUID(),
      railway: RailwayHostRecord(
        projectID: nil, environmentID: "env-1", sandboxID: "sbx-1", hostKey: "k"))
    func recorder(failing: Bool) -> RemoteWorkrooms.Recorder {
      RemoteWorkrooms.Recorder(
        reserve: { _, _ in "w" },
        record: { _, _ in if failing { throw CocoaError(.fileWriteNoPermission) } },
        forget: { _ in }
      ).forgettingPending(in: nil, driver: driver)
    }

    do {
      try await recorder(failing: true).record("w", descriptor)
      XCTFail("the write went through")
    } catch {}
    var left = try await ledger.entries()
    XCTAssertEqual(left.compactMap(\.sandbox), ["sbx-1"], "forgotten before the write succeeded")

    try await recorder(failing: false).record("w", descriptor)
    left = try await ledger.entries()
    XCTAssertEqual(left, [], "kept after its record was written")
  }

  /// An exe.dev host (#259) is its own driver key, keyed by its account: never Docker's or boxd's.
  /// Its clone goes in the home of the user exe.dev logs in as, its base serves only its own
  /// account, and its descriptor round-trips through config.
  func testAnExeDevHostIsItsOwnDriverKey() throws {
    let host = HostDescriptor(
      driver: HostKind.exeDev.driver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
      account: "me@x.dev")
    let key = try XCTUnwrap(RemoteHosts.DriverKey(host))
    XCTAssertEqual(key, .exeDev(account: "me@x.dev"))
    XCTAssertTrue(key.isRemoteProvider)
    XCTAssertEqual(key.kind, .exeDev)
    XCTAssertEqual(key.account, "me@x.dev")
    XCTAssertNil(key.org)
    XCTAssertEqual(key.kind.driver, "exedev")
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    XCTAssertEqual(RemoteWorkrooms.clonePath(for: repository, on: key), "/home/exedev/r")
    XCTAssertEqual(try HostDriverRegistry.deletionKey(host), key)
    XCTAssertEqual(BaseRetirement.base(in: BaseRetirement.bases(of: host), for: key)?.id, host.id)
    XCTAssertNil(
      BaseRetirement.base(in: BaseRetirement.bases(of: host), for: .exeDev(account: "other@x.dev")))
    XCTAssertNil(
      BaseRetirement.base(
        in: BaseRetirement.bases(of: host), for: .boxd(org: nil, account: "me@x.dev")))
    XCTAssertEqual(host.kindDescription, "Remote workroom on exe.dev")
    XCTAssertEqual(
      try JSONDecoder().decode(HostDescriptor.self, from: try JSONEncoder().encode(host)), host)
    XCTAssertTrue(WorkroomPlace.all.contains(.remote(.exeDev)))
  }

  /// After a relaunch an exe.dev workroom is reached without Docker, by its driver made with the
  /// account its record holds, and a missing container runtime never reads as its host gone.
  func testAnExeDevWorkroomIsReachedAfterARelaunchWithoutDocker() throws {
    let remote = RemoteHosts()
    let id = UUID()
    remote.reachability.adopt([
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "w", path: "/home/exedev/r", vcsName: "workroom/w", warnings: [],
            host: HostDescriptor(
              driver: HostKind.exeDev.driver, provisioner: RemoteWorkrooms.provisioner,
              id: id, account: "me@x.dev"))
        ])
    ])
    let driver = try XCTUnwrap(remote.registry.existingDriver(holding: id) as? ExeDevHostDriver)
    XCTAssertEqual(driver.configuration.account, "me@x.dev")
    XCTAssertFalse(remote.registry.runtimeIsMissing(for: .remote(id)))
  }

  /// A workroom created on boxd records `driver: "boxd"` with its org and account, and no
  /// container record, from the moment its machine exists.
  func testABoxdWorkroomRecordsItsOrgAndAccount() async throws {
    let made = UUID()
    let driver = MachineDriver(made: made)
    // The driver wrote its machine down as pending; the record naming it takes it off (#373), so
    // the sweep can never take a machine config names, whatever a later config read says.
    let pending = try hostsDirectory()
    try PendingMachines.add(
      .init(id: made, driver: HostKind.boxd.driver, account: "usr_1"), in: pending)
    let key = RemoteHosts.DriverKey.boxd(org: "acme", account: "usr_1")
    let environment = RemoteProvisioning.Environment(
      driver: driver,
      daemonSocket: BoxdHostDriver.Configuration(
        cli: URL(fileURLWithPath: "/boxd"), hostSetup: .bundled
      ).daemonSocket,
      connect: { _ in throw HostDriverError.provisioning("stop after the checkpoint") })
    let recorded = Recorded()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, descriptor in
        recorded.add(descriptor)
        return "x"
      }, record: { _, descriptor in recorded.add(descriptor) }, forget: { _ in })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git", key: key, driver: driver,
        environment: environment, recorder: recorder, pendingIn: pending)
      XCTFail("the connect was meant to fail")
    } catch {}
    XCTAssertEqual(PendingMachines.entries(in: pending), [], "a recorded machine stayed pending")
    let live = try XCTUnwrap(recorded.all.last { $0.id == made })
    XCTAssertEqual(live.driver, HostKind.boxd.driver)
    XCTAssertEqual(live.org, "acme")
    XCTAssertEqual(live.account, "usr_1")
    XCTAssertNil(live.container)
    XCTAssertTrue(
      recorded.all.allSatisfy { $0.driver == HostKind.boxd.driver && $0.account == "usr_1" })
  }

  // Value: protects=a repository the provider won't grant fails the create before a name is
  // reserved or a machine made, and a granted one is the repository created; fails_when=the grant
  // moves after `reserve` or the machine's create, or is passed another repository; why_new=only
  // the closure's presence was pinned; seam=none
  /// The provider is given the repository before anything is made or recorded: a refusal ends the
  /// create there, and a grant is for the repository being created.
  func testTheRepositoryIsGrantedBeforeAnythingIsMade() async throws {
    struct Refused: Error {}
    final class Grants: Sendable {
      private let asked = Mutex<[GitHubRepository]>([])
      var all: [GitHubRepository] { asked.withLock { $0 } }
      func add(_ repository: GitHubRepository) { asked.withLock { $0.append(repository) } }
    }
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    for refuses in [true, false] {
      let pending = try hostsDirectory()
      let recorded = Recorded()
      let grants = Grants()
      let driver = MachineDriver(made: UUID())
      let environment = RemoteProvisioning.Environment(
        driver: driver, daemonSocket: "/workroomd.sock",
        grantRepository: { asked in
          XCTAssertTrue(recorded.all.isEmpty, "granted after the create reserved its name")
          grants.add(asked)
          if refuses { throw Refused() }
        },
        connect: { _ in throw HostDriverError.provisioning("stop after the checkpoint") })
      let recorder = RemoteWorkrooms.Recorder(
        reserve: { _, descriptor in
          recorded.add(descriptor)
          return "x"
        }, record: { _, descriptor in recorded.add(descriptor) }, forget: { _ in })
      do {
        _ = try await RemoteWorkrooms.create(
          repository: repository, cloneURL: "https://github.com/o/r.git",
          key: .exeDev(account: "me@x.dev"), driver: driver, environment: environment,
          recorder: recorder, pendingIn: pending)
        XCTFail("the create was meant to fail")
      } catch is Refused {
        XCTAssertTrue(refuses, "a granted create stopped at the grant")
      } catch {
        XCTAssertFalse(refuses, "a refused grant went on to \(error)")
      }
      XCTAssertEqual(grants.all, [repository], "refuses: \(refuses)")
      XCTAssertEqual(recorded.all.isEmpty, refuses, "refuses: \(refuses)")
    }
  }

  // Value: protects=a workroom that fell back to the Mac's token is recorded as relayed, with its
  // repository and clone URL, so a later launch gives it the credential relay and its GitHub
  // identity; fails_when=create records credentials from anything but the instance, or drops the
  // repository or clone URL; why_new=no test reaches a serving create's descriptor without Docker;
  // seam=none
  /// A workroom made with the Mac's token records `credentials: relay`, which is what a later launch
  /// reads to install the Mac's relay on its host, and the repository and clone URL it was made from.
  func testARelayedWorkroomIsRecordedAsSuch() async throws {
    let made = UUID()
    let driver = MachineDriver(made: made)
    let fake = try FakeDaemon(
      version: 4,
      execResult: #"{"stdout":"","stderr":"","exit_code":0,"timed_out":false,"signaled":false}"#)
    defer { fake.stop() }
    let environment = RemoteProvisioning.Environment(
      driver: driver,
      daemonSocket: BoxdHostDriver.Configuration(
        cli: URL(fileURLWithPath: "/boxd"), hostSetup: .bundled
      ).daemonSocket,
      gitHubToken: { "gho_mac" },
      connect: { host in
        try await DaemonClient.connect(host: host, socketPath: fake.socketPath)
      })
    let recorded = Recorded()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, descriptor in
        recorded.add(descriptor)
        return "x"
      }, record: { name, descriptor in recorded.add(descriptor, as: name) }, forget: { _ in })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))

    let created = try await RemoteWorkrooms.create(
      repository: repository, cloneURL: "https://github.com/o/r.git",
      key: .boxd(org: "acme", account: "usr_1"), driver: driver, environment: environment,
      recorder: recorder, pendingIn: nil)
    await created.instance.connection.close()

    XCTAssertTrue(created.instance.relayed)
    let serving = try XCTUnwrap(recorded.all.last)
    XCTAssertEqual(recorded.names.last, "x")
    XCTAssertEqual(serving.id, made)
    XCTAssertTrue(serving.isRelayed)
    XCTAssertEqual(serving.repository, "o/r")
    XCTAssertEqual(serving.cloneURL, "https://github.com/o/r.git")
    XCTAssertNil(serving.state, "a serving workroom's descriptor has a state")
  }

  // Value: protects=a create whose machine cannot be removed keeps the workroom's entry, failed,
  // naming the machine, so a delete can take the paid machine down; fails_when=the catch-all
  // forgets the entry on leftBehind; why_new=no test fails a create's machine rollback; seam=none
  /// A create whose driver leaves its machine running keeps the workroom's entry, `failed`, naming
  /// the machine, rather than forgetting it: otherwise a paid machine runs on with nothing in the
  /// app to find it (#356).
  func testACreateThatLeavesItsMachineBehindKeepsItsEntry() async throws {
    let made = UUID()
    let driver = MachineDriver(made: made, leavesItBehind: true)
    let key = RemoteHosts.DriverKey.boxd(org: "acme", account: "usr_1")
    let environment = RemoteProvisioning.Environment(
      driver: driver,
      daemonSocket: BoxdHostDriver.Configuration(
        cli: URL(fileURLWithPath: "/boxd"), hostSetup: .bundled
      ).daemonSocket)
    let recorded = Recorded()
    let forgot = Recorded()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, descriptor in
        recorded.add(descriptor)
        return "x"
      }, record: { name, descriptor in recorded.add(descriptor, as: name) },
      forget: { _ in forgot.add(HostDescriptor()) })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git", key: key, driver: driver,
        environment: environment, recorder: recorder)
      XCTFail("a create that left its machine behind succeeded")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let cleanup) {
      XCTAssertEqual(host, .remote(made))
      XCTAssertEqual(cleanup, ["machine x"])
    }
    XCTAssertTrue(forgot.all.isEmpty, "the entry naming a live machine was forgotten")
    let kept = try XCTUnwrap(recorded.all.last)
    XCTAssertEqual(kept.id, made)
    XCTAssertEqual(kept.state, "failed")
    // Over the entry reserved for it, not beside it: the `creating` placeholder would dangle.
    XCTAssertEqual(recorded.names.last, "x")
  }

  // Value: protects=a workroom whose create fails after its machine exists, and whose rollback
  // cannot destroy it, keeps its entry failed; fails_when=only the driver's own leftBehind is
  // recorded; why_new=the other test fails inside create(); seam=none
  /// A create that fails after its machine exists (here its first connect), with a destroy that
  /// fails too, keeps the workroom's entry, `failed`, naming the machine (#356).
  func testAWorkroomWhoseRollbackFailsKeepsItsEntry() async throws {
    let made = UUID()
    let driver = MachineDriver(made: made, destroyFails: true)
    let environment = RemoteProvisioning.Environment(
      driver: driver,
      daemonSocket: BoxdHostDriver.Configuration(
        cli: URL(fileURLWithPath: "/boxd"), hostSetup: .bundled
      ).daemonSocket,
      connect: { _ in throw HostDriverError.provisioning("no daemon") })
    let recorded = Recorded()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, _ in "x" }, record: { _, descriptor in recorded.add(descriptor) },
      forget: { _ in })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git",
        key: .boxd(org: "acme", account: "usr_1"), driver: driver, environment: environment,
        recorder: recorder)
      XCTFail("a create whose rollback failed succeeded")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, _) {
      XCTAssertEqual(host, .remote(made))
    }
    let failed = try XCTUnwrap(
      recorded.all.last { $0.id == made }, "the machine left running was not recorded")
    XCTAssertEqual(failed.state, "failed")

    // A record that fails too leaves the caller the original failure, not the record's.
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git",
        key: .boxd(org: "acme", account: "usr_1"), driver: driver, environment: environment,
        recorder: RemoteWorkrooms.Recorder(
          reserve: { _, _ in "x" },
          record: { _, _ in throw HostDriverError.provisioning("no record") },
          forget: { _ in }))
      XCTFail("a create whose rollback failed succeeded")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, _) {
      XCTAssertEqual(host, .remote(made))
    }
  }

  /// A driver whose create makes `made`, and whose destroy succeeds, unless told otherwise.
  private struct MachineDriver: HostTerminalDriver, ProvisioningHostDriver {
    let made: UUID
    /// The create fails and cannot remove the machine it made.
    var leavesItBehind = false
    var destroyFails = false
    /// Told of each host a destroy is asked for.
    var onDestroy: (@Sendable (HostID) -> Void)? = nil
    func create() async throws -> HostID {
      guard leavesItBehind else { return .remote(made) }
      throw HostDriverError.leftBehind(
        cause: "setup timed out", leftover: ["machine x"], host: .remote(made))
    }
    func destroy(_ host: HostID) async throws {
      onDestroy?(host)
      if destroyFails { throw HostDriverError.provisioning("remove failed") }
    }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no exec")
    }
    func attachCommand(
      to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
      metadata: [(key: String, value: String)], runCommand: String?
    ) throws -> String { "" }
    func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool { false }
    func lastAttach(of session: UUID, on host: HostID) -> LastAttach { .finished }
  }

  private final class Recorded: Sendable {
    private let made = Mutex<(descriptors: [HostDescriptor], names: [String?])>(([], []))
    var all: [HostDescriptor] { made.withLock { $0.descriptors } }
    /// The entry name each descriptor was recorded under, in step with `all`.
    var names: [String?] { made.withLock { $0.names } }
    func add(_ descriptor: HostDescriptor, as name: String? = nil) {
      made.withLock {
        $0.descriptors.append(descriptor)
        $0.names.append(name)
      }
    }
  }

  private typealias Asked = Calls<RemoteHosts.DriverKey>

  final class Swept: Sendable {
    private let made = Mutex<[(context: String?, known: Set<UUID>)]>([])
    var calls: [(context: String?, known: Set<UUID>)] { made.withLock { $0 } }
    func add(_ context: String?, _ known: Set<UUID>) {
      made.withLock { $0.append((context, known)) }
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

  /// A Docker stand-in whose `ps -a` lists `names`, each made long ago, and that logs every call.
  private func dockerListing(_ names: [String]) throws -> (runtime: URL, log: URL) {
    let lines = names.map { "\($0)\t1" }.joined(separator: "\n")
    let (runtime, log) = try stubRuntime()
    let script = try String(contentsOf: runtime, encoding: .utf8)
    try
      (script + "\ncase \"$1 $2\" in \"ps -a\") printf '%s' "
      + SSHTransport.shellQuoted(lines) + " ;; esac\n").write(
        to: runtime, atomically: true, encoding: .utf8)
    return (runtime, log)
  }

  /// A container no record names goes only once a second sweep (the next launch) finds it unknown
  /// too (#284): a config read lost, restored or half-written takes no live workroom on the launch
  /// that reads it. One that is known again by then stays.
  func testASweepRemovesAContainerOnlyWhenTwoSweepsFindItUnknown() async throws {
    let (orphan, back) = (UUID(), UUID())
    let names = [orphan, back].map(ContainerHostDriver.containerName)
    let (runtime, log) = try dockerListing(names)
    let driver = Self.driver(runtime: runtime, context: nil)
    func removed() throws -> [String] { try calls(log).filter { $0.hasPrefix("rm ") } }

    let firstSweep = await driver.sweep(keeping: [])

    XCTAssertEqual(firstSweep, [])
    XCTAssertEqual(try removed(), [], "a container went on the first sweep to miss it")

    let secondSweep = await driver.sweep(keeping: [back])

    XCTAssertEqual(secondSweep, [])
    XCTAssertEqual(try removed(), ["rm --force --volumes \(names[0])"])
  }

  // Value: protects=a container a crash left mid-create takes the named volumes made for it when the sweep removes it;
  // fails_when=the sweep drops only anonymous volumes, or removes a volume before its container; why_new=only destroy removed owned
  // volumes, and each create now names fresh ones (docker-in-docker's); seam=stub runtime; no_claim=Apple's sweep (same rule, JSON listing)
  /// The volumes a swept container's label names go after it; a container with none removes none.
  func testASweptContainerTakesItsOwnedVolumes() async throws {
    let orphan = ContainerHostDriver.containerName(UUID())
    let plain = ContainerHostDriver.containerName(UUID())
    let (runtime, log) = try stubRuntime()
    let script = try String(contentsOf: runtime, encoding: .utf8)
    try
      (script + "\ncase \"$1 $2\" in \"ps -a\") printf '%s\\n%s' "
      + SSHTransport.shellQuoted("\(orphan)\t1\tdind-a,cache-a") + " "
      + SSHTransport.shellQuoted("\(plain)\t1\t") + " ;; esac\n").write(
        to: runtime, atomically: true, encoding: .utf8)
    let driver = Self.driver(runtime: runtime, context: nil)

    _ = await driver.sweep(keeping: [])
    let failures = await driver.sweep(keeping: [])

    XCTAssertEqual(failures, [])
    let removals = try calls(log).filter { $0.hasPrefix("rm ") || $0.hasPrefix("volume ") }
    XCTAssertEqual(
      removals,
      [
        "rm --force --volumes \(orphan)", "volume rm dind-a cache-a",
        "rm --force --volumes \(plain)",
      ])
  }

  /// A sweep that cannot write down what it found unknown removes nothing (#284): the list left
  /// from an older sweep is not this sweep's predecessor, and a container known in between would
  /// otherwise go on its first sighting after a later config loss.
  func testASweepThatCannotRecordItsUnknownListRemovesNothing() async throws {
    let name = ContainerHostDriver.containerName(UUID())
    let (runtime, log) = try dockerListing([name])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-hosts-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let driver = Self.driver(runtime: runtime, context: nil, directory: directory)

    _ = await driver.sweep(keeping: [])
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    let failures = await driver.sweep(keeping: [])

    XCTAssertEqual(try calls(log).filter { $0.hasPrefix("rm ") }, [], "removed on a stale list")
    XCTAssertTrue(
      failures.contains { $0.hasPrefix("recording unknown containers") }, "\(failures)")
  }

  /// A sweep removes at most `cap` containers, and the rest go on later launches, `cap` at a time:
  /// even two bad config reads in a row take few (#284).
  func testASweepRemovesAtMostItsCapAndLeavesTheRestForLaterLaunches() async throws {
    let names = (0..<5).map { _ in ContainerHostDriver.containerName(UUID()) }
    let (runtime, log) = try dockerListing(names)
    let driver = Self.driver(runtime: runtime, context: nil)
    func removed() throws -> [String] { try calls(log).filter { $0.hasPrefix("rm ") } }

    _ = await driver.sweep(keeping: [], cap: 2)
    let failures = await driver.sweep(keeping: [], cap: 2)
    XCTAssertEqual(try removed(), names.prefix(2).map { "rm --force --volumes \($0)" })
    XCTAssertEqual(
      failures, ["3 unknown container(s) left for a later launch: at most 2 go per sweep"])
    // The stand-in still lists them all; a real daemon would not list the two removed.
    _ = await driver.sweep(keeping: [], cap: 2)
    XCTAssertEqual(try removed().count, 4)
  }

  /// A fresh directory for a driver's host files, removed after the test.
  private func hostsDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-hosts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  /// A create writes its container's name down as pending before running it, so a crash before
  /// config records the host still leaves it named (#284); a create that removed its container
  /// again takes the name off.
  func testACreateJournalsItsContainerUntilItIsRemoved() async throws {
    let directory = try hostsDirectory()
    let journal = directory.appendingPathComponent("pending-containers-docker.json")
    let seen = directory.appendingPathComponent("seen-at-run")
    let (failing, _) = try scriptedRuntime(
      "create*) cat \(SSHTransport.shellQuoted(journal.path)) >> "
        + "\(SSHTransport.shellQuoted(seen.path)); exit 1 ;;")
    let driver = Self.driver(runtime: failing, context: nil, directory: directory)
    do {
      _ = try await driver.create()
      XCTFail("create was meant to fail")
    } catch {}
    XCTAssertTrue(
      try String(contentsOf: seen, encoding: .utf8).contains("workroom-"),
      "the name was not pending when the container was made")
    XCTAssertEqual(driver.pendingContainers, [], "a removed container stayed pending")
    XCTAssertTrue(ContainerHostDriver.pending(in: directory).isEmpty)
  }

  /// With nothing recorded, a sweep takes only containers a create left pending, and no images
  /// (#284): a lost config, or a launch with a throwaway `HOME`, reads nothing, and every live
  /// container would look unknown.
  func testASweepWithNothingRecordedTakesOnlyPendingContainers() async throws {
    let directory = try hostsDirectory()
    let (leftover, live) = (
      ContainerHostDriver.containerName(UUID()), ContainerHostDriver.containerName(UUID())
    )
    try JSONEncoder().encode([leftover]).write(
      to: directory.appendingPathComponent("pending-containers-docker.json"))
    let (runtime, log) = try dockerListing([leftover, live])
    let driver = Self.driver(runtime: runtime, context: nil, directory: directory)

    _ = await driver.sweep(keeping: [], onlyPending: true)
    _ = await driver.sweep(keeping: [], onlyPending: true)

    XCTAssertEqual(
      try calls(log).filter { $0.hasPrefix("rm ") }, ["rm --force --volumes \(leftover)"])
    XCTAssertFalse(try calls(log).contains { $0.hasPrefix("images") }, "images were swept")
    XCTAssertEqual(driver.pendingContainers, [])
  }

  /// With nothing recorded and no driver made, a launch sweeps each runtime and context with a
  /// container pending, and only those (#284): a crash during a project's first base creation
  /// leaves exactly that. With none pending it makes no driver, so a user who never made a
  /// container workroom is never asked about Docker. Config recording a host takes it off.
  func testAdoptSweepsWhatACreateLeftPendingWithNothingRecorded() async throws {
    let directory = try hostsDirectory()
    let (runtime, _) = try stubRuntime()
    let swept = Swept()
    let make = {
      RemoteHosts(
        makeContainerDriver: {
          Self.driver(
            runtime: runtime, context: $0.context,
            dialect: $0.runtime == .apple ? .apple : .docker, directory: directory)
        },
        sweepDriver: { driver, known, _, onlyPending in
          swept.add(
            (driver.provisioning?.dialect == .apple ? "apple " : "docker ")
              + (driver.provisioning?.context ?? "nil") + (onlyPending ? " pending" : ""), known)
          return []
        }, pendingIn: directory)
    }

    make().reachability.adopt([])
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(swept.calls.isEmpty, "a launch with nothing pending swept")

    for name in ["pending-containers-docker@orbstack.json", "pending-containers-apple.json"] {
      try JSONEncoder().encode(["workroom-x"]).write(to: directory.appendingPathComponent(name))
    }
    try Data().write(to: directory.appendingPathComponent("unrelated"))
    make().reachability.adopt([])
    for _ in 0..<500 where swept.calls.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(
      Set(swept.calls.compactMap(\.context)), ["docker orbstack pending", "apple nil pending"])

    let boxd = HostDescriptor(
      driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
      account: "usr_1")
    make().reachability.adopt([Project(path: "/boxd", vcs: "git", workrooms: [], host: boxd)])
    for _ in 0..<500 where swept.calls.count < 4 { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(
      swept.calls.dropFirst(2).allSatisfy { $0.context?.hasSuffix("pending") == true },
      "a recorded boxd host made a container sweep take more than what was pending")

    let id = UUID()
    let recorded = HostDescriptor(
      driver: HostKind.container(.docker).driver, provisioner: RemoteWorkrooms.provisioner, id: id,
      container: Self.record(context: "orbstack"))
    let remote = make()
    remote.reachability.adopt([Project(path: "/proj", vcs: "git", workrooms: [], host: recorded)])
    for _ in 0..<500 where swept.calls.count < 6 { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(
      swept.calls.dropFirst(4).allSatisfy { $0.context?.hasSuffix("pending") == false },
      "a launch that records a host swept only what was pending")
    try JSONEncoder().encode([ContainerHostDriver.containerName(id), "workroom-x"]).write(
      to: directory.appendingPathComponent("pending-containers-docker@orbstack.json"))
    remote.reachability.adopt([Project(path: "/proj", vcs: "git", workrooms: [], host: recorded)])
    let pinned = try XCTUnwrap(remote.registry.existingDriver(holding: id) as? ContainerHostDriver)
    XCTAssertEqual(pinned.pendingContainers, ["workroom-x"], "a recorded host stayed pending")
  }

  /// A remote provider's machine a create left pending goes only on a later launch than the one
  /// that first found it unrecorded, once it is older than any create takes, at most `cap` a sweep
  /// (#373): a config that failed to read once costs nothing, and a create still under way in
  /// another copy of this build is never taken. One whose removal fails stays for a later launch.
  func testAPendingMachineGoesOnlyOnALaterLaunchAtMostCapAtATime() async throws {
    // Value: protects=a live workroom whose record one launch failed to read, or a create still
    // under way, is never destroyed, and a bad read takes few; fails_when=an entry goes on its first
    // sighting, twice in one launch counts as two, a young entry goes, the cap is ignored, or a
    // failed removal drops the entry; why_new=#373; seam=launch, now and destroy are parameters
    let directory = try hostsDirectory()
    let ids = (0..<5).map { _ in UUID() }
    for id in ids {
      try PendingMachines.add(
        .init(id: id, driver: HostKind.boxd.driver, account: "usr_1"), in: directory)
    }
    let (first, second, third) = (UUID(), UUID(), UUID())
    var gone: [UUID] = []
    _ = await PendingMachines.sweep(Set(ids), in: directory, launch: first) { gone.append($0) }
    _ = await PendingMachines.sweep(Set(ids), in: directory, launch: first) { gone.append($0) }
    XCTAssertEqual(gone, [], "a machine went in the launch that first found it unrecorded")

    _ = await PendingMachines.sweep(Set(ids), in: directory, launch: second) { gone.append($0) }
    XCTAssertEqual(gone, [], "a machine younger than any create takes went")

    let later = Date().addingTimeInterval(PendingMachines.grace + 60)
    let failures = await PendingMachines.sweep(
      Set(ids), in: directory, launch: second, now: later
    ) { gone.append($0) }
    XCTAssertEqual(gone, Array(ids.prefix(3)))
    XCTAssertTrue(failures.contains { $0.hasPrefix("2 unrecorded") }, "\(failures)")
    XCTAssertEqual(PendingMachines.entries(in: directory).map(\.id), Array(ids.suffix(2)))

    let failing = await PendingMachines.sweep(
      Set(ids), in: directory, launch: third, now: later
    ) { _ in throw HostDriverError.provisioning("signed in to another account") }
    XCTAssertEqual(failing.count, 2)
    XCTAssertEqual(PendingMachines.entries(in: directory).map(\.id), Array(ids.suffix(2)))
  }

  /// A sweep that cannot mark what it found unrecorded removes nothing (#373), as the container
  /// sweep does (#284).
  func testAPendingMachineSweepThatCannotMarkRemovesNothing() async throws {
    let directory = try hostsDirectory()
    let (old, new) = (UUID(), UUID())
    try PendingMachines.add(
      .init(
        id: old, driver: HostKind.boxd.driver, unrecordedIn: UUID(), made: .distantPast),
      in: directory)
    try PendingMachines.add(.init(id: new, driver: HostKind.boxd.driver), in: directory)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
    var gone: [UUID] = []
    let swept = await PendingMachines.sweep([old, new], in: directory) { gone.append($0) }
    XCTAssertEqual(gone, [])
    XCTAssertTrue(swept.contains { $0.hasPrefix("recording unrecorded") })
  }

  /// A launch sweeps the boxd and exe.dev machines a create left pending, each through its own
  /// driver key's destroy, which checks the account first (#373). One config records is taken off
  /// and never destroyed; one first found unrecorded now is marked for the next launch.
  func testAdoptSweepsMachinesACreateLeftPending() async throws {
    // Value: protects=a crashed create's paid machine is removed, by the account that made it, and
    // a recorded one never is; fails_when=adopt skips remote keys, routes to the wrong key, or
    // ignores records; why_new=#373; seam=makeDriver
    let directory = try hostsDirectory()
    let (earlier, fresh, recorded) = (UUID(), UUID(), UUID())
    try PendingMachines.add(
      .init(
        id: earlier, driver: HostKind.boxd.driver, account: "usr_1", unrecordedIn: UUID(),
        made: .distantPast),
      in: directory)
    try PendingMachines.add(
      .init(id: fresh, driver: HostKind.exeDev.driver, account: "me@x.dev"), in: directory)
    try PendingMachines.add(
      .init(
        id: recorded, driver: HostKind.boxd.driver, account: "usr_1", unrecordedIn: UUID(),
        made: .distantPast),
      in: directory)
    let destroyed = Swept()
    let remote = RemoteHosts(
      makeDriver: { key in
        MachineDriver(made: UUID(), onDestroy: { destroyed.add("\(key) \($0)", []) })
      }, pendingIn: directory)
    let host = HostDescriptor(
      driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner, id: recorded,
      account: "usr_1")

    remote.reachability.adopt([Project(path: "/boxd", vcs: "git", workrooms: [], host: host)])
    for _ in 0..<500 where remote.registry.sweepsRunning > 0 {
      try await Task.sleep(for: .milliseconds(2))
    }

    XCTAssertEqual(
      destroyed.calls.map(\.context),
      ["\(RemoteHosts.DriverKey.boxd(org: nil, account: "usr_1")) \(HostID.remote(earlier))"])
    let left = PendingMachines.entries(in: directory)
    XCTAssertEqual(left.map(\.id), [fresh])
    XCTAssertEqual(left.first?.unrecordedIn, PendingMachines.launch)
  }

  /// A machine config records is never swept, even when its pending entry could not be taken off
  /// (#373): the forget is best-effort, and an entry an earlier launch marked needs no write.
  func testAMachineConfigRecordsIsNeverSweptWhenItsEntryCannotBeForgotten() async throws {
    // Value: protects=a live recorded workroom is not destroyed when the pending file is
    // read-only; fails_when=adopt trusts the file's forget instead of filtering by records;
    // why_new=Copilot review on #385; seam=makeDriver
    let directory = try hostsDirectory()
    let id = UUID()
    try PendingMachines.add(
      .init(
        id: id, driver: HostKind.boxd.driver, account: "usr_1", unrecordedIn: UUID(),
        made: .distantPast), in: directory)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
    let destroyed = Swept()
    let remote = RemoteHosts(
      makeDriver: { _ in
        MachineDriver(made: UUID(), onDestroy: { destroyed.add("\($0)", []) })
      }, pendingIn: directory)
    let host = HostDescriptor(
      driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner, id: id,
      account: "usr_1")

    remote.reachability.adopt([Project(path: "/boxd", vcs: "git", workrooms: [], host: host)])
    for _ in 0..<500 where remote.registry.sweepsRunning > 0 {
      try await Task.sleep(for: .milliseconds(2))
    }
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertTrue(destroyed.calls.isEmpty, "a recorded machine was swept: \(destroyed.calls)")
  }

  /// A runtime that could not list its containers at launch (Docker not started yet) is swept on a
  /// later reload rather than skipped for the whole launch (#284), and once its sweep ran, no
  /// reload sweeps it again: a second sweep in one launch would pass for the next launch's.
  func testARuntimeDownAtLaunchIsSweptOnALaterReload() async throws {
    let directory = try hostsDirectory()
    try JSONEncoder().encode(["workroom-x"]).write(
      to: directory.appendingPathComponent("pending-containers-docker.json"))
    let (runtime, _) = try stubRuntime()
    let swept = Swept()
    let remote = RemoteHosts(
      makeContainerDriver: { Self.driver(runtime: runtime, context: $0.context) },
      sweepDriver: { driver, known, _, _ in
        swept.add(driver.provisioning?.context, known)
        return swept.calls.count == 1 ? [ContainerHostDriver.listingFailed + "daemon down"] : []
      }, pendingIn: directory)
    func reload(expecting calls: Int) async throws {
      remote.reachability.adopt([])
      // Until the sweep this reload started, if any, has ended (`finishSweep`).
      for _ in 0..<500 where swept.calls.count < calls || remote.registry.sweepsRunning > 0 {
        try await Task.sleep(for: .milliseconds(2))
      }
    }

    try await reload(expecting: 1)
    try await reload(expecting: 2)
    XCTAssertEqual(swept.calls.count, 2, "a sweep that could not list was not tried again")
    try await reload(expecting: 2)
    XCTAssertEqual(swept.calls.count, 2, "a sweep that ran was run again in the same launch")
  }

  /// A sweep whose listing failed leaves the last unknown list as it was (#284), so a runtime that
  /// is down for a launch neither resets the two-sweep count nor stands in for a sweep.
  func testAFailedListingKeepsTheLastUnknownList() async throws {
    let directory = try hostsDirectory()
    let name = ContainerHostDriver.containerName(UUID())
    let (runtime, log) = try dockerListing([name])
    let (down, _) = try scriptedRuntime("ps*) exit 1 ;;")
    let up = Self.driver(runtime: runtime, context: nil, directory: directory)

    _ = await up.sweep(keeping: [])
    let failures = await Self.driver(runtime: down, context: nil, directory: directory)
      .sweep(keeping: [])
    XCTAssertTrue(
      failures.first?.hasPrefix(ContainerHostDriver.listingFailed) == true, "\(failures)")
    XCTAssertEqual(try calls(log).filter { $0.hasPrefix("rm ") }, [], "removed on one sighting")
    _ = await up.sweep(keeping: [])

    XCTAssertEqual(try calls(log).filter { $0.hasPrefix("rm ") }, ["rm --force --volumes \(name)"])
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
  /// told its architecture: a missing image is pulled for arm64, and made with neither flag.
  func testAppleMakesAndPullsInItsOwnDialect() async throws {
    let pulled = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-pulled-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: pulled) }
    let (runtime, log) = try scriptedRuntime(
      """
      "image inspect workroom-host") [ -e \(pulled.path) ] && { echo '[]'; exit 0; }; exit 1 ;;
      "image pull"*) touch \(pulled.path) ;;
      create*) exit 1 ;;
      """)
    do {
      _ = try await Self.driver(runtime: runtime, context: nil, dialect: .apple).create()
      XCTFail("create was meant to fail")
    } catch {}
    let made = try calls(log)
    XCTAssertEqual(
      Array(made.prefix(2)),
      ["image inspect workroom-host", "image pull --arch arm64 workroom-host"])
    let create = try XCTUnwrap(made.first { $0.hasPrefix("create ") })
    XCTAssertTrue(create.hasPrefix("create --init --arch arm64 --name workroom-"), create)
    XCTAssertFalse(create.contains("--restart") || create.contains("--pull"), create)
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
      "list --all --format json") printf '%s' \(SSHTransport.shellQuoted(try json(list))) ;;
      "image list --format json") printf '%s' \(SSHTransport.shellQuoted(try json(images))) ;;
      """)
    let driver = Self.driver(runtime: runtime, context: nil, dialect: .apple)
    func removed() throws -> [String] {
      try calls(log).filter { $0.hasPrefix("delete ") || $0.hasPrefix("image delete ") }
    }
    // The unknown container waits for a second launch (#284); the leftover image doesn't.
    let firstSweep = await driver.sweep(keeping: [kept], images: ["recorded:1"])
    XCTAssertEqual(firstSweep, [])
    XCTAssertEqual(try removed(), ["image delete leftover:1"])
    let secondSweep = await driver.sweep(keeping: [kept], images: ["recorded:1"])
    XCTAssertEqual(secondSweep, [])
    XCTAssertEqual(
      try removed(),
      [
        "image delete leftover:1", "delete --force \(ContainerHostDriver.containerName(swept))",
        "image delete leftover:1",
      ])
  }

  /// A derive's snapshot image whose delete failed goes with the next sweep, though its workroom's
  /// container was run from it: Apple's container runs without its image, and the snapshot is a
  /// whole disk.
  func testAppleSweepRemovesALeftoverSnapshotItsContainerRanFrom() async throws {
    let workroom = UUID()
    let snapshot = ContainerHostDriver.deriveDirectoryPrefix + "abc:latest"
    let ours = ["workroom.provisioner": "test", "workroom.created": "1"]
    let list: [[String: Any]] = [
      [
        "id": ContainerHostDriver.containerName(workroom), "status": ["state": "running"],
        "configuration": ["labels": ours, "image": ["reference": snapshot]],
      ]
    ]
    let images: [[String: Any]] = [
      [
        "configuration": ["name": snapshot],
        "variants": [
          ["platform": ["architecture": "arm64"], "config": ["config": ["Labels": ours]]]
        ],
      ]
    ]
    let json = { (o: Any) in
      String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    let (runtime, log) = try scriptedRuntime(
      """
      "list --all --format json") printf '%s' \(SSHTransport.shellQuoted(try json(list))) ;;
      "image list --format json") printf '%s' \(SSHTransport.shellQuoted(try json(images))) ;;
      """)
    let failures = await Self.driver(runtime: runtime, context: nil, dialect: .apple).sweep(
      keeping: [workroom], images: [])
    XCTAssertEqual(failures, [])
    let removed = try calls(log).filter { $0.hasPrefix("delete ") || $0.hasPrefix("image delete ") }
    XCTAssertEqual(removed, ["image delete \(snapshot)"])
  }

  // Value: protects=a container a crash left mid-create on Apple's runtime takes the named
  // volumes made for it when the sweep removes it; fails_when=Apple's sweep stops reading the
  // workroom.volumes label from the JSON listing, or removes a volume before its container;
  // why_new=#308 /ship review (only Docker's sweep had this test); seam=stub runtime;
  // no_claim=Apple's not-found wording for a volume already gone
  /// The volumes a swept container's label names go after it; a container with none removes none.
  func testAppleSweptContainerTakesItsOwnedVolumes() async throws {
    let (orphan, plain) = (UUID(), UUID())
    let ours = ["workroom.provisioner": "test", "workroom.created": "1"]
    let list: [[String: Any]] = [
      [
        "id": ContainerHostDriver.containerName(orphan), "status": ["state": "stopped"],
        "configuration": [
          "labels": ours.merging(["workroom.volumes": "dind-a,cache-a"]) { $1 },
          "image": ["reference": "x:1"],
        ],
      ],
      [
        "id": ContainerHostDriver.containerName(plain), "status": ["state": "stopped"],
        "configuration": ["labels": ours, "image": ["reference": "x:1"]],
      ],
    ]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)
    let (runtime, log) = try scriptedRuntime(
      """
      "list --all --format json") printf '%s' \(SSHTransport.shellQuoted(json)) ;;
      "image list --format json") printf '[]' ;;
      """)
    let driver = Self.driver(runtime: runtime, context: nil, dialect: .apple)

    _ = await driver.sweep(keeping: [])
    let failures = await driver.sweep(keeping: [])

    XCTAssertEqual(failures, [])
    let removals = try calls(log).filter { $0.hasPrefix("delete ") || $0.hasPrefix("volume ") }
    XCTAssertEqual(
      removals,
      [
        "delete --force \(ContainerHostDriver.containerName(orphan))", "volume rm dind-a cache-a",
        "delete --force \(ContainerHostDriver.containerName(plain))",
      ])
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

  /// A recorded Apple host is adopted into Apple's driver, and a Docker one beside it into
  /// Docker's, by the descriptor's `driver`.
  func testHostsAreAdoptedIntoTheirRuntimesDrivers() throws {
    let (runtime, _) = try stubRuntime()
    let remote = RemoteHosts(
      makeContainerDriver: { key in
        Self.driver(
          runtime: runtime, context: key.context, dialect: key.runtime == .apple ? .apple : .docker)
      }, sweepDriver: { _, _, _, _ in [] })
    let (docker, apple) = (UUID(), UUID())
    let host = { (id: UUID, runtime: ContainerRuntime) in
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
    remote.reachability.adopt([project])
    XCTAssertEqual(
      (remote.registry.existingDriver(holding: docker) as? ContainerHostDriver)?.provisioning?
        .dialect,
      .docker)
    XCTAssertEqual(
      (remote.registry.existingDriver(holding: apple) as? ContainerHostDriver)?.provisioning?
        .dialect,
      .apple)
  }

  /// Why a container runtime's New Workroom entry is off, in the order a user has to fix it:
  /// Apple's needs Apple silicon and macOS 26 before installing it means anything (#309).
  func testARuntimeEntrySaysWhyItIsOff() {
    let ready = { (runtime: ContainerRuntime) in
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
      "run gh auth login")
  }

  /// REWRITTEN (#483, R3): a create's row shows the step it is on, with done, warning and skipped
  /// steps counted complete out of its kind's whole plan.
  /// Value: protects=the step circle reads its own run's plan; fails_when=the fraction ignores
  /// skipped steps or the label isn't the running step's title; no_claim=the circle's drawing
  @MainActor
  func testARemoteCreateShowsItsStepOfItsPlan() {
    let store = AppStore()
    let run = CreationRun(
      project: Project(path: "/proj", vcs: "git", workrooms: []), kind: .boxd, splitAnchor: nil,
      previousSelection: nil)
    store.lifecycle.register(run)
    let pane = SidebarID.creation(project: "/proj", id: run.id)
    run.begin("repository")
    run.begin("machine")
    XCTAssertEqual(store.createStep(for: pane), .init(fraction: 2.0 / 8, label: "Create machine"))
    run.begin("clone")
    XCTAssertEqual(store.createStep(for: pane)?.fraction, 5.0 / 8)
    XCTAssertNil(store.createStep(for: .workroom(project: "/proj", name: "other")))
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
        daemonSocket: RemoteWorkrooms.daemonSocket)
    }
    let keys = [
      RemoteHosts.DriverKey(runtime: .docker),
      RemoteHosts.DriverKey(runtime: .docker, context: "orbstack"),
      RemoteHosts.DriverKey(runtime: .apple),
    ]
    let deletion = HostDriverRegistry.Deletion(
      environments: Dictionary(uniqueKeysWithValues: keys.map { ($0, environment($0)) }))
    for key in keys {
      let host = HostDescriptor(
        driver: key.runtime?.rawValue, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: key.context))
      let driver = try XCTUnwrap(deletion.environment(for: host)?.driver as? ContainerHostDriver)
      XCTAssertEqual(driver.provisioning?.context, key.context)
      XCTAssertEqual(driver.provisioning?.dialect, key.runtime == .apple ? .apple : .docker)
    }
  }
}
