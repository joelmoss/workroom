import DaemonConnection
import Defaults
import HostDrivers
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// The provisioning sequence (#252) on the ssh fixture's containers: workrooms made, cloned and
/// checked out, each on a host of its own, with every failure undoing what it made. A workroom
/// clones its host's `/srv/origin.git` by path unless a test says otherwise; the credentials'
/// choice is pinned by `RemoteProvisioningTests`. The fixture's own git credential helper answers
/// its GitHub (`fake-github.py`) as a provider's integration does, so most tests stand for a remote
/// provider's host, which Workroom gives no credential. Skipped unless run through the fixture
/// script:
///
///   vcs/scripts/ssh-fixture/run.sh <linux workroomd> \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/RemoteProvisioningIntegrationTests
final class RemoteProvisioningIntegrationTests: XCTestCase {
  private var directory: URL!
  private var label: String!
  private var runtime: URL!
  private var cleanups: [() async -> Void] = []

  /// The clone token the fixture's GitHub accepts (run.sh reads it out of the image), which stands
  /// in for the Mac's own `gh` token.
  private static var token: String {
    ProcessInfo.processInfo.environment["WR_SSH_FIXTURE_CLONE_TOKEN"] ?? ""
  }
  private static let path = "/home/workroom/project"

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-provision-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    label = "workroom.test=\(UUID().uuidString.lowercased())"
  }

  override func tearDown() async throws {
    for cleanup in cleanups.reversed() { await cleanup() }
    cleanups.removeAll()
    if let runtime, let label {
      for container in (try? leftovers("ps", label: label)) ?? [] {
        _ = try? docker(runtime, ["rm", "--force", "--volumes", container])
      }
      for image in (try? leftovers("images", label: label)) ?? [] {
        _ = try? docker(runtime, ["rmi", "--force", image])
      }
    }
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private struct Fixture {
    let provisioning: ContainerHostDriver.Provisioning
    let daemon: URL
  }

  private func fixture(runtime override: URL? = nil) throws -> Fixture {
    let environment = ProcessInfo.processInfo.environment
    func need(_ name: String) throws -> String {
      guard let value = environment[name], !value.isEmpty else {
        throw XCTSkip("\(name) is unset; run these through vcs/scripts/ssh-fixture/run.sh")
      }
      return value
    }
    runtime = URL(fileURLWithPath: try need("WR_SSH_FIXTURE_RUNTIME_PATH"))
    // Read where it is used (`token`); needed here so an older run.sh skips these tests rather
    // than failing them.
    _ = try need("WR_SSH_FIXTURE_CLONE_TOKEN")
    let daemon = URL(fileURLWithPath: try need("WR_SSH_FIXTURE_DAEMON"))
    // Made from the fixture's image the way the app makes any container now (#308): the daemon
    // placed and run as its entrypoint, reached through `docker exec`, as the fixture's user.
    return Fixture(
      provisioning: ContainerHostDriver.Provisioning(
        runtime: override ?? runtime, image: try need("WR_SSH_FIXTURE_IMAGE"),
        user: try need("WR_SSH_FIXTURE_USER"), identityFile: try need("WR_SSH_FIXTURE_IDENTITY"),
        publicKey: try need("WR_SSH_FIXTURE_PUBLIC_KEY"),
        daemonSocket: ContainerHostDriver.containerSocket,
        labels: [try need("WR_SSH_FIXTURE_LABEL"), label], daemon: { _ in daemon },
        daemonFolder: directory.appendingPathComponent("daemon")),
      daemon: daemon)
  }

  /// The sequence's environment over `driver`, as a remote provider's: Workroom gives the host no
  /// credential, and the fixture's own helper answers its GitHub.
  @MainActor
  private func environment(
    _ fixture: Fixture, driver: ContainerHostDriver,
    connect: (@Sendable (HostID) async throws -> DaemonVCSConnection)? = nil
  ) -> RemoteProvisioning.Environment {
    let daemon = fixture.daemon
    var environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: fixture.provisioning.daemonSocket,
      connect: connect ?? { host in
        try await DaemonBootstrap.connect(
          host: host, driver: driver, socket: fixture.provisioning.daemonSocket,
          daemon: { $0 == "aarch64" || $0 == "x86_64" ? daemon : nil }, handOff: false,
          resources: nil)
      })
    environment.makeHost = makeHost(driver)
    return environment
  }

  /// A container from the fixture's image, with the fixture's GitHub serving in it. `entrypoint.sh`
  /// started that, and the daemon is the entrypoint now, so it starts here, as root.
  private func makeHost(_ driver: ContainerHostDriver) -> @Sendable () async throws -> HostID {
    let runtime = self.runtime!
    return {
      let host = try await driver.create()
      guard case .remote(let id) = host else { return host }
      let container = ContainerHostDriver.containerName(id)
      _ = try Self.run(
        runtime,
        [
          "exec", "-d", "-u", "0", container, "sh", "-c",
          "grep -q ' github.com$' /etc/hosts || echo '127.0.0.1 github.com' >> /etc/hosts;"
            + " setpriv --reuid=workroom --regid=workroom --init-groups"
            + " --inh-caps=+net_bind_service --ambient-caps=+net_bind_service"
            + " env -i PATH=/usr/bin:/bin python3 /usr/local/bin/fake-github.py",
        ])
      // Until it answers on 443.
      for _ in 0..<50 {
        let up = try Self.run(
          runtime,
          ["exec", container, "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/443 && echo up"])
        if up.contains("up") { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      return host
    }
  }

  private static func run(_ runtime: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = runtime
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  @discardableResult
  private func docker(_ runtime: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = runtime
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `-a` for both: `images` lists an untagged image only with it.
  private func leftovers(_ kind: String, label: String) throws -> [String] {
    try docker(runtime, [kind, "-a", "-q", "--filter", "label=\(label)"])
      .split(separator: "\n").map(String.init)
  }

  /// A shell command on the host and its exit status: through the driver's ssh, never the daemon.
  private func onHost(_ driver: ContainerHostDriver, _ host: HostID, _ command: String)
    async throws -> (status: Int32, output: String)
  {
    let (status, output) = try await driver.exec(command, on: host).communicate(nil, timeout: 30)
    return (status, output.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private func provision(
    _ environment: RemoteProvisioning.Environment, branch: String,
    cloneURL: String = "/srv/origin.git", startBranch: String? = nil,
    checkpoint: @Sendable (_ host: HostID) async throws -> Void = { _ in }
  ) async throws -> RemoteProvisioning.Instance {
    try await RemoteProvisioning.provision(
      cloneURL: cloneURL, path: Self.path, branch: branch, startBranch: startBranch,
      in: environment, checkpoint: checkpoint)
  }

  /// The fixture with a runtime that runs the real one, except for the subcommand named in the
  /// returned file while it exists: a provider failing one step on purpose.
  private func failingFixture() throws -> (Fixture, failing: URL) {
    let script = directory.appendingPathComponent("runtime")
    let failing = directory.appendingPathComponent("failing")
    let fixture = try fixture(runtime: script)
    try """
    #!/bin/sh
    if [ "$1" = "$(cat \(PosixShell.quoted(failing.path)) 2>/dev/null)" ]; then
      echo "injected failure" >&2; exit 1
    fi
    exec \(PosixShell.quoted(runtime.path)) "$@"

    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (fixture, failing)
  }

  // MARK: Creating from the app (#253)

  /// What `RemoteWorkrooms.create` wrote to config, in order, in place of the CLI.
  private final class Recorded: @unchecked Sendable {
    enum Call: Equatable {
      case reserve(path: String, HostDescriptor)
      case record(workroom: String?, HostDescriptor)
      case forget(String)
    }
    private let lock = NSLock()
    private var log: [Call] = []
    private var next = 0
    var calls: [Call] { lock.withLock { log } }

    var recorder: RemoteWorkrooms.Recorder {
      RemoteWorkrooms.Recorder(
        reserve: { path, descriptor in
          self.lock.withLock {
            self.log.append(.reserve(path: path, descriptor))
            self.next += 1
            return "w\(self.next)"
          }
        },
        record: { workroom, descriptor in
          self.lock.withLock { self.log.append(.record(workroom: workroom, descriptor)) }
        },
        forget: { workroom in self.lock.withLock { self.log.append(.forget(workroom)) } })
    }
  }

  /// The project the tests create for, with the fixture's GitHub serving `/srv/origin.git`.
  private static let repository = GitHubRepository(host: "github.com", owner: "o", name: "r")!
  private static let originURL = "https://github.com/origin.git"

  /// A create names the workroom before its host is made, records each live thing as soon as it
  /// exists, and records everything a later launch needs to reach it. The project records nothing.
  @MainActor
  func testCreatingARemoteWorkroomRecordsWhatALaterLaunchNeeds() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    // The workroom clones https://github.com with the host's own credentials.
    let environment = environment(fixture, driver: driver)
    let recorded = Recorded()

    let first = try await RemoteWorkrooms.create(
      repository: Self.repository, cloneURL: Self.originURL, driver: driver,
      environment: environment, recorder: recorded.recorder)
    await first.instance.connection.close()
    cleanups.append { try? await driver.destroy(first.instance.host) }

    guard recorded.calls.count == 3, case .reserve(let path, let creating) = recorded.calls[0],
      case .record("w1", let hostMade) = recorded.calls[1],
      case .record("w1", let workroom) = recorded.calls[2]
    else { return XCTFail("calls: \(recorded.calls)") }
    XCTAssertEqual(path, RemoteWorkrooms.clonePath(for: Self.repository))
    XCTAssertEqual(creating.state, "creating")
    // The host is recorded as soon as it exists, so a crash mid-create leaves a delete what to take
    // down (#253).
    XCTAssertEqual(hostMade.state, "creating")
    XCTAssertEqual(hostMade.id, workroom.id)
    XCTAssertNotNil(hostMade.container)
    XCTAssertTrue(RemoteWorkrooms.isLive(hostMade))
    XCTAssertNil(workroom.state, "a serving workroom's descriptor has a state")
    XCTAssertEqual(workroom.driver, RemoteWorkrooms.containerDriver)
    XCTAssertNil(workroom.credentials, "a provider's host was relayed")
    XCTAssertEqual(workroom.workroomID, creating.workroomID)
    XCTAssertEqual(workroom.repository, "o/r")
    XCTAssertEqual(workroom.container, driver.record(of: first.instance.host))
    XCTAssertEqual(first.name, "w1")

    // The workroom's branch is named for it, and another launch reaches it from its record.
    let later = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("later"),
      provisioning: fixture.provisioning)
    try later.adopt(try XCTUnwrap(workroom.id), try XCTUnwrap(workroom.container))
    let head = try await onHost(
      later, first.instance.host, "git -C \(path) rev-parse --abbrev-ref HEAD")
    XCTAssertEqual(head.output, RemoteWorkrooms.branch(for: "w1"))

    // A pane mounts there as the app mounts one: its session registered with the host, its
    // command from the app's routing, starting in the workroom's checkout on its branch.
    let session = UUID()
    PersistentSessionService.shared.registerRemoteSession(
      session, on: first.instance.host, via: driver, workingDirectory: path)
    // In a terminal (`script`), as libghostty runs it: `docker exec -t` refuses a stdin that isn't.
    let attach = try XCTUnwrap(PersistentSessionService.shared.attachCommand(forSession: session))
    let pane = try RemoteHostIntegrationTests.Pane(
      command: "/usr/bin/script -q /dev/null /bin/sh -c \(PosixShell.quoted(attach))")
    defer { pane.dropLink() }
    try await Task.sleep(for: .seconds(1))
    // Typed with a split marker, so only the shell's answer reads `:END`.
    pane.type("echo \"AT:$(pwd):ON:$(git rev-parse --abbrev-ref HEAD):E\"\"ND\"\n")
    let seen = pane.read(until: ":END")
    XCTAssertTrue(seen.contains("AT:\(path):ON:workroom/w1:END"), seen)

    // A second create makes a host of its own.
    let second = try await RemoteWorkrooms.create(
      repository: Self.repository, cloneURL: Self.originURL, driver: driver,
      environment: environment, recorder: recorded.recorder)
    await second.instance.connection.close()
    cleanups.append { try? await driver.destroy(second.instance.host) }
    XCTAssertEqual(second.name, "w2")
    XCTAssertFalse(recorded.calls.contains { if case .record(nil, _) = $0 { true } else { false } })
    XCTAssertEqual(try leftovers("ps", label: label).count, 2, "two workrooms, and nothing else")
  }

  /// Deleting a remote workroom from the app (#253) removes its box, then drops its entry. One whose
  /// box can't be removed keeps its entry, `failed`, until deleting it again finishes the job.
  @MainActor
  func testDeletingRemoteWorkroomsTakesThemDown() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    let recorded = Recorded()
    var made: [String: HostDescriptor] = [:]
    for name in ["w1", "w2"] {
      let created = try await RemoteWorkrooms.create(
        repository: Self.repository, cloneURL: Self.originURL, driver: driver,
        environment: environment, recorder: recorded.recorder)
      await created.instance.connection.close()
      cleanups.append { try? await driver.destroy(created.instance.host) }
      guard case .record(name, let descriptor) = recorded.calls.last else {
        return XCTFail("calls: \(recorded.calls)")
      }
      made[name] = descriptor
    }
    XCTAssertEqual(try leftovers("ps", label: label).count, 2, "two workrooms")

    try await RemoteWorkrooms.delete(
      "w1", host: try XCTUnwrap(made["w1"]), environment: environment,
      recorder: recorded.recorder)
    XCTAssertEqual(recorded.calls.last, .forget("w1"))
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "the workroom's box was kept")

    try "rm".write(to: failing, atomically: true, encoding: .utf8)
    do {
      try await RemoteWorkrooms.delete(
        "w2", host: try XCTUnwrap(made["w2"]), environment: environment,
        recorder: recorded.recorder)
      XCTFail("a failed removal was swallowed")
    } catch RemoteProvisioning.Failure.rollbackIncomplete {}
    guard case .record("w2", let left) = recorded.calls.last else {
      return XCTFail("what is still live was not recorded: \(recorded.calls)")
    }
    XCTAssertEqual(left.state, "failed")
    XCTAssertEqual(left.id, made["w2"]?.id, "the live box was not kept")
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "the second box went")

    try FileManager.default.removeItem(at: failing)
    try await RemoteWorkrooms.delete(
      "w2", host: left, environment: environment, recorder: recorded.recorder)
    XCTAssertEqual(recorded.calls.last, .forget("w2"))
    XCTAssertEqual(try leftovers("ps", label: label), [], "the second box was kept")
  }

  /// A checkpoint that cannot be recorded is a failed step (#253): the create undoes itself, so its
  /// box is removed rather than living on unrecorded.
  @MainActor
  func testAProvisionWhoseCheckpointFailsUndoesItself() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)

    do {
      _ = try await provision(environment(fixture, driver: driver), branch: "wr-checkpoint") { _ in
        throw WorkroomCLIError.timedOut
      }
      XCTFail("a create whose checkpoint failed succeeded")
    } catch WorkroomCLIError.timedOut {}
    XCTAssertEqual(try leftovers("ps", label: label), [], "its box was left")
  }

  /// A create whose machine fails, and undoes itself, drops the name it took; nothing is recorded
  /// for it.
  @MainActor
  func testACreateWhoseMachineFailsForgetsTheNameItTook() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    try "create".write(to: failing, atomically: true, encoding: .utf8)
    let recorded = Recorded()

    do {
      _ = try await RemoteWorkrooms.create(
        repository: Self.repository, cloneURL: Self.originURL, driver: driver,
        environment: environment(fixture, driver: driver), recorder: recorded.recorder)
      XCTFail("a create whose machine failed succeeded")
    } catch {}
    guard recorded.calls.count == 2, case .reserve = recorded.calls[0] else {
      return XCTFail("calls: \(recorded.calls)")
    }
    XCTAssertEqual(recorded.calls[1], .forget("w1"))
    XCTAssertEqual(try leftovers("ps", label: label), [], "a box was left")
  }

  /// A workroom whose clone fails is removed.
  @MainActor
  func testAWorkroomWhoseCloneFailsIsRemoved() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)

    do {
      _ = try await provision(
        environment(fixture, driver: driver), branch: "wr-clone", cloneURL: "/srv/no-such.git")
      XCTFail("a clone of nothing succeeded")
    } catch RemoteProvisioning.Failure.git(let command, _) {
      XCTAssertEqual(command, "clone")
    }
    XCTAssertEqual(try leftovers("ps", label: label), [], "a failed workroom was left running")
  }

  /// Value: protects=the root's included files land in a Linux host's checkout through GNU tar as
  /// the host's ordinary user, with their modes despite its umask, and a file the checkout has is
  /// kept (#367); fails_when=`-p` or `-k` is dropped, or the stream never reaches tar;
  /// no_claim=boxd's and exe.dev's images (Debian here), and the CLI's own archive (a ustar the
  /// test makes stands in)
  func testIncludedFilesLandInTheCheckoutOnALinuxHost() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let instance = try await provision(environment(fixture, driver: driver), branch: "wr-include")
    await instance.connection.close()
    cleanups.append { try? await driver.destroy(instance.host) }
    _ = try await onHost(driver, instance.host, "echo kept > \(Self.path)/kept.env")

    let root = directory.appendingPathComponent("root")
    let files = [".env": 0o600, "config/shared.yml": 0o664, "kept.env": 0o644]
    for (path, mode) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("from the root".utf8).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    let paths = files.keys.sorted()
    let result = await RemoteProvisioning.copyIncluded(
      into: Self.path, on: instance.host, driver: driver
    ) { output in
      let tar = Process()
      tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      tar.environment = ["COPYFILE_DISABLE": "1"]
      tar.arguments = ["--format", "ustar", "-cf", output.path, "-C", root.path] + paths
      try tar.run()
      tar.waitUntilExit()
      return IncludeArchive(paths: paths, bytes: 0, warnings: [])
    }

    // GNU tar's -k refuses the file the checkout has, and says so: a warning, the rest extracted.
    guard case .warning(let text, _) = result else { return XCTFail("\(result)") }
    XCTAssertTrue(text.contains("kept.env"), text)
    let (_, modes) = try await onHost(
      driver, instance.host,
      "cd \(Self.path) && stat -c '%a %n' .env config/shared.yml && cat kept.env && umask")
    XCTAssertEqual(
      modes.split(separator: "\n").prefix(3), ["600 .env", "664 config/shared.yml", "kept"])
  }

  /// Value: protects=a remote workroom's script on a real Linux host: the host user's login
  /// environment (bash -lic reading ~/.profile), the remote contract (testdata/script-env), the
  /// 126 path, and `run-script`'s wall clock ending a tree with a `setsid` escaper (/proc-based
  /// `descendants`); fails_when=the Linux daemon probes or kills differently from the macOS one the
  /// unit tests drive; no_claim=boxd's and exe.dev's own images and users (Debian here), and a
  /// hangup when the Mac side ends
  func testAWorkroomScriptRunsOnALinuxHostAsTheContractSays() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = await environment(fixture, driver: driver)
    let instance = try await provision(environment, branch: "wr-script")
    await instance.connection.close()
    cleanups.append { try? await driver.destroy(instance.host) }

    let contract = URL(fileURLWithPath: String(describing: #filePath))
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("testdata/script-env")
    let script = try Data(contentsOf: contract.appendingPathComponent("workroom_script"))
    let setup = "\(Self.path)/scripts/workroom_setup"
    let (written, said) = try await driver.exec(
      "mkdir -p \(Self.path)/scripts && cat > \(setup) && chmod 755 \(setup)"
        + " && echo 'export FROM_PROFILE=yes' >> ~/.profile"
        + " && printf '#!/bin/sh\\necho \"profile=$FROM_PROFILE\"\\n' > \(Self.path)/scripts/workroom_teardown"
        + " && chmod 755 \(Self.path)/scripts/workroom_teardown",
      on: instance.host
    ).communicate(script, timeout: 30)
    XCTAssertEqual(written, 0, said)

    let lines = Lines()
    let result = await RemoteProvisioning.runScript(
      .setup, workroom: "contract", at: Self.path, hostKind: "boxd", rootScript: nil,
      daemonBinary: environment.daemonBinary(on: instance.host), on: instance.host, driver: driver,
      judge: RemoteScriptTests.approveAll, onLine: { lines.add($0) })
    XCTAssertEqual(result, .passed)
    let want = try String(
      contentsOf: contract.appendingPathComponent("remote.txt"), encoding: .utf8
    ).replacingOccurrences(of: "{DIR}", with: Self.path)
    XCTAssertEqual(lines.all, want.split(separator: "\n").map(String.init))

    // The login shell's profile reaches the script, as a terminal's shell gets it.
    let profile = Lines()
    let teardown = await RemoteProvisioning.runScript(
      .teardown, workroom: "contract", at: Self.path, hostKind: "boxd", rootScript: nil,
      daemonBinary: environment.daemonBinary(on: instance.host), on: instance.host, driver: driver,
      judge: RemoteScriptTests.approveAll, onLine: { profile.add($0) })
    XCTAssertEqual(teardown, .passed)
    XCTAssertEqual(profile.all, ["profile=yes"])

    // A script without its execute bit can't start: the script's failure, as locally.
    _ = try await onHost(driver, instance.host, "chmod 644 \(setup)")
    let unstarted = await RemoteProvisioning.runScript(
      .setup, workroom: "contract", at: Self.path, hostKind: "boxd", rootScript: nil,
      daemonBinary: environment.daemonBinary(on: instance.host), on: instance.host, driver: driver,
      judge: RemoteScriptTests.approveAll, onLine: { _ in })
    XCTAssertEqual(unstarted, .failed("setup script failed: \(setup) could not be started"))

    // The wall clock ends the whole tree, a grandchild that left its process group included.
    let (status, output) = try await onHost(
      driver, instance.host,
      "printf '#!/bin/sh\\nsetsid sleep 60 &\\necho $! > /tmp/escaper\\nsleep 60\\n' > /tmp/slow"
        + " && chmod 755 /tmp/slow"
        + " && { \(environment.daemonBinary(on: instance.host)) run-script --dir /tmp --timeout 1 -- /tmp/slow; echo \"exit=$?\"; }"
        + " && sleep 1 && if kill -0 \"$(cat /tmp/escaper)\" 2>/dev/null; then echo alive; else echo gone; fi"
    )
    XCTAssertEqual(status, 0, output)
    XCTAssertTrue(output.contains("exit=124"), output)
    // The output is stdout, then stderr (`run-script`'s own "timed out" line).
    XCTAssertTrue(output.contains("gone"), output)
    XCTAssertFalse(output.contains("alive"), output)
    XCTAssertTrue(output.contains("timed out after 1 s"), output)
  }

  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
  }

  // MARK: Workrooms

  @MainActor
  func testWorkroomsServeOnTheirOwnBranch() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)

    for branch in ["wr-one", "wr-two"] {
      let instance = try await provision(environment, branch: branch)
      cleanups.append { try? await driver.destroy(instance.host) }

      XCTAssertFalse(instance.relayed)
      let remote = try await onHost(
        driver, instance.host, "git -C \(Self.path) remote get-url origin")
      XCTAssertEqual(
        remote.output, "/srv/origin.git", "the remote URL carries something besides the repository")
      // It serves: a request over its own connection, answered by its own daemon.
      let head = try await RemoteProvisioning.git(
        ["rev-parse", "--abbrev-ref", "HEAD"], in: instance.path, on: instance.connection)
      XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), branch)

      try await RemoteProvisioning.destroy(instance, in: environment)
    }
    XCTAssertEqual(try leftovers("ps", label: label), [], "a workroom's box was left")
  }

  /// A remote workroom registered as the project listing registers it reads through the router,
  /// which connects its host itself, as git reports it on the box: its status, log, file listing,
  /// file contents and a working diff (#253).
  @MainActor
  func testARegisteredRemoteWorkroomReadsThroughTheRouterAsGitReportsItOnTheBox() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    let instance = try await provision(environment, branch: "wr-read")
    await instance.connection.close()
    cleanups.append { try? await driver.destroy(instance.host) }
    guard case .remote(let id) = instance.host else { return XCTFail("\(instance.host)") }

    // A change on the box: a tracked file edited and a new file.
    let path = instance.path
    let tracked = try await onHost(driver, instance.host, "git -C \(path) ls-files | head -n 1")
      .output
    XCTAssertFalse(tracked.isEmpty)
    let edit = try await onHost(
      driver, instance.host, "cd \(path) && echo edited >> '\(tracked)' && echo new > fresh.txt")
    XCTAssertEqual(edit.status, 0, edit.output)
    let mine = RemoteWorkrooms.provisioner
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: path, vcsName: "workroom/w", warnings: [],
          host: HostDescriptor(provisioner: mine, id: id, repository: "o/r"))
      ])
    let manager = HostConnectionManager()
    let router = RepositoryRouter(
      connections: manager,
      connectRemote: { host in
        _ = try await manager.connectIfDisconnected(host: host) {
          try await DaemonBootstrap.connect(
            host: host, driver: driver, socket: RemoteWorkrooms.daemonSocket)
        }
      })
    router.replaceRemote(RemoteWorkrooms.registrations([project]))
    let location = try XCTUnwrap(
      project.workrooms[0].target(inProject: project.path).remoteLocation)

    let reader = try await router.reader(for: location)
    let status = try await reader.workingStatus()
    // Cut on the host: `onHost` trims, which would take a first line's leading status space.
    let changed = try await onHost(
      driver, instance.host, "git -C \(path) status --porcelain | cut -c4-")
    XCTAssertEqual(status.dirty, true)
    XCTAssertEqual(
      Set(status.changedFiles?.map(\.path) ?? []),
      Set(changed.output.split(separator: "\n").map(String.init)))

    let log = try await reader.log(limit: 5)
    let gitLog = try await onHost(driver, instance.host, "git -C \(path) log -n 5 --format=%H")
    XCTAssertEqual(
      log.commits.map(\.commitID), gitLog.output.split(separator: "\n").map(String.init))

    let files = try await router.files(for: location)
    let listing = try await files.list()
    XCTAssertTrue(listing.ok, listing.stderr)
    XCTAssertTrue(listing.stdout.contains(tracked), listing.stdout)
    XCTAssertTrue(listing.stdout.contains("fresh.txt"), listing.stdout)
    let data = try await files.read(path: tracked, symlinks: .followWithinRoot, maxBytes: 1 << 20)
    let cat = try await onHost(driver, instance.host, "cat '\(path)/\(tracked)'")
    XCTAssertEqual(
      String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
      cat.output)

    let diff = try await reader.workingFileDiff(path: tracked)
    let gitDiff = try await onHost(driver, instance.host, "git -C \(path) diff -- '\(tracked)'")
    XCTAssertTrue(diff.contains("+edited"), diff)
    XCTAssertTrue(gitDiff.output.contains("+edited"), gitDiff.output)
  }

  /// A failure at each step leaves no host behind.
  @MainActor
  func testAWorkroomThatFailsAtEachStepLeavesNoHost() async throws {
    // The runtime fails `run` only when told to.
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)

    struct Injected: Error {}
    // The step, the environment that fails it, and the branch.
    let steps: [(String, RemoteProvisioning.Environment, String)] = [
      ("machine", environment(fixture, driver: driver), "wr-a"),
      ("connect", environment(fixture, driver: driver, connect: { _ in throw Injected() }), "wr-b"),
      // git refuses the name only once the workroom is cloned.
      ("checkout", environment(fixture, driver: driver), "bad..name"),
    ]
    for (step, environment, branch) in steps {
      if step == "machine" {
        try "create".write(to: failing, atomically: true, encoding: .utf8)
      } else {
        try? FileManager.default.removeItem(at: failing)
      }

      do {
        _ = try await provision(environment, branch: branch)
        XCTFail("a workroom that failed at \(step) was made")
      } catch {
        // The failure is the step's own, so the assertion below is about that step.
        switch (step, error) {
        case ("machine", HostDriverError.provisioning), ("connect", is Injected),
          ("checkout", RemoteProvisioning.Failure.git("switch", _)):
          break
        default: XCTFail("\(step) failed for another reason: \(error)")
        }
      }

      XCTAssertEqual(try leftovers("ps", label: label), [], "a failure at \(step) left a host")
    }
  }

  /// The box authenticates on its own (#252), as a remote provider's does: it clones over https
  /// from the fixture's GitHub, and with the Mac's connection gone it fetches and pushes there, with
  /// the credential helper the box came with (the fixture's stands in for boxd's). Commands run
  /// through the runtime's exec, the provider's control plane, not over the Mac's link.
  @MainActor
  func testAWorkroomFetchesAndPushesWithTheMacDisconnected() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    let instance = try await provision(
      environment, branch: "wr-pushed", cloneURL: "https://github.com/origin.git")
    cleanups.append { try? await driver.destroy(instance.host) }
    await instance.connection.close()

    // The driver names each container after its host.
    guard case .remote(let id) = instance.host else { return XCTFail("not a remote host") }
    let container = "workroom-\(id.uuidString.lowercased())"
    func onBox(_ script: String) throws -> String {
      try docker(
        runtime,
        [
          "exec", "--user", "workroom", "--env", "HOME=/home/workroom", "--workdir", Self.path,
          container, "sh", "-c", script + "; echo exit=$?",
        ])
    }
    // Disconnected: no relay to the Mac's daemon connection is left on the box, once the closed
    // link's ssh has gone. `[w]`, so the pattern does not match the shell running it.
    var relays = ""
    for _ in 0..<50 {
      relays = try onBox("pgrep -f '[w]r-daemon relay'")
      if relays == "exit=1" { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertEqual(relays, "exit=1", "a relay to the Mac is still running")

    let commit = try onBox(
      "git -c user.name=W -c user.email=w@example.com commit -q --allow-empty -m pushed"
        + " && git rev-parse HEAD")
    let pushed = try XCTUnwrap(commit.split(separator: "\n").first.map(String.init), commit)
    // The fixture's GitHub refuses a push with no token, so the one below is the helper's doing.
    let refused = try onBox("git -c credential.https://github.com.helper= push -q origin HEAD 2>&1")
    XCTAssertFalse(refused.hasSuffix("exit=0"), "the fixture's GitHub took a push with no token")

    XCTAssertTrue(try onBox("git fetch -q origin").hasSuffix("exit=0"), "the fetch failed")
    let push = try onBox("git push -q origin HEAD 2>&1")
    XCTAssertTrue(push.hasSuffix("exit=0"), push)
    XCTAssertEqual(
      try onBox("git -C /srv/origin.git rev-parse refs/heads/wr-pushed"), "\(pushed)\nexit=0")
  }

  /// A local container workroom (#309) clones with the Mac's own GitHub token, and git in it gets
  /// credentials through the Mac's relay, ahead of any helper the box came with: a push works while
  /// the app is connected and says so when it isn't. The fixture's GitHub takes its clone token,
  /// which stands in for the Mac's `gh`.
  @MainActor
  func testARelayedWorkroomPushesThroughTheMac() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let daemon = fixture.daemon
    let socket = fixture.provisioning.daemonSocket
    let token = Self.token
    var environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: socket, gitHubToken: { token },
      connect: { host in
        try await DaemonBootstrap.connect(
          host: host, driver: driver, socket: socket,
          daemon: { $0 == "aarch64" || $0 == "x86_64" ? daemon : nil }, handOff: false,
          resources: nil)
      })
    environment.makeHost = makeHost(driver)
    let instance = try await provision(
      environment, branch: "wr-relayed", cloneURL: "https://github.com/origin.git")
    cleanups.append { try? await driver.destroy(instance.host) }
    XCTAssertTrue(instance.relayed)

    // The relay, over a connection of its own as the app's registry holds one.
    let generation = UUID()
    let relay = CredentialRelay(
      answer: { _ in "username=x-access-token\npassword=\(token)\n" },
      transport: .init(
        forwarding: { host in
          let connection = try await DaemonVCSConnection.connect(
            host: host, stream: try await driver.openStream(to: host))
          return (.init(host: host, generation: generation), try connection.forwarding())
        },
        updates: { host in
          AsyncStream {
            $0.yield(.init(lease: .init(host: host, generation: generation), status: .connected))
          }
        }))
    try await relay.install(
      on: instance.host, driver: driver,
      daemonBinary: try XCTUnwrap(driver.daemonPath(on: instance.host)), socket: socket)

    guard case .remote(let id) = instance.host else { return XCTFail("not a remote host") }
    let container = "workroom-\(id.uuidString.lowercased())"
    func onBox(_ script: String) throws -> String {
      try docker(
        runtime,
        [
          "exec", "--user", "workroom", "--env", "HOME=/home/workroom", "--workdir", Self.path,
          container, "sh", "-c", script + "; echo exit=$?",
        ])
    }
    _ = try onBox(
      "git -c user.name=W -c user.email=w@example.com commit -q --allow-empty -m relayed")
    let push = try onBox("git push -q origin HEAD 2>&1")
    XCTAssertTrue(push.hasSuffix("exit=0"), push)
    XCTAssertTrue(
      try onBox("git -C /srv/origin.git rev-parse --verify -q refs/heads/wr-relayed")
        .hasSuffix("exit=0"))

    // With the relay gone, git is told why rather than asked for a password.
    relay.close(id)
    var failed = ""
    for _ in 0..<50 {
      failed = try onBox("git -c credential.interactive=false push -q origin HEAD:wr-later 2>&1")
      if !failed.hasSuffix("exit=0") { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertTrue(failed.contains("isn't connected to this workroom"), failed)
  }

  /// A project's base branch setting: the workroom starts from origin's copy of that branch, not
  /// from the default branch. The branch is made on the host's origin before the clone.
  @MainActor
  func testAWorkroomStartsFromTheProjectsBaseBranch() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    let develop = Develop()

    let instance = try await provision(
      environment, branch: "wr-develop", startBranch: "develop"
    ) { host in
      let (status, output) = try await driver.exec(
        "git -C /srv/origin.git -c user.name=t -c user.email=t@t commit-tree -p main"
          + " -m develop main^{tree} | xargs git -C /srv/origin.git branch develop"
          + " && git -C /srv/origin.git rev-parse develop", on: host
      ).communicate(nil, timeout: 30)
      XCTAssertEqual(status, 0, output)
      develop.set(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    cleanups.append { try? await driver.destroy(instance.host) }

    let head = try await RemoteProvisioning.git(
      ["rev-parse", "HEAD"], in: instance.path, on: instance.connection)
    XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), develop.get())
  }

  private final class Develop: @unchecked Sendable {
    private let lock = NSLock()
    private var commit: String?
    func set(_ value: String) { lock.withLock { commit = value } }
    func get() -> String? { lock.withLock { commit } }
  }

  /// A base an older build made goes, and its record only once it is gone (`BaseRetirement`).
  @MainActor
  func testRetiringABaseRemovesItAndForgetsItsRecordOnlyOnceItIsGone() async throws {
    let fixture = try fixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    guard case .remote(let host) = try await driver.create() else { return XCTFail("not remote") }
    let project = Project(
      path: "/p", vcs: "git", workrooms: [],
      host: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: host))
    let forgotten = Forgotten()
    let effects = { (driver: ContainerHostDriver, forget: @escaping @Sendable () throws -> Void) in
      BaseRetirement.Effects(
        setHost: { _, _, _ in try forget() },
        destroy: { try await driver.destroy(.remote($0.id!)) })
    }

    // Forgetting fails the first time: the box is gone, and a retry gets past the destroy it
    // already did to forget the record.
    do {
      _ = try await BaseRetirement.retireBases(
        of: project, effects: effects(driver) { throw WorkroomCLIError.timedOut })
      XCTFail("a failed forget was swallowed")
    } catch WorkroomCLIError.timedOut {}
    XCTAssertEqual(try leftovers("ps", label: label), [])
    _ = try await BaseRetirement.retireBases(
      of: project, effects: effects(driver) { forgotten.add("forgot") })
    XCTAssertEqual(forgotten.all, ["forgot"])

    // A base this driver never knew (an app relaunched since) keeps its record: nothing has shown
    // it is gone.
    let relaunched = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    do {
      _ = try await BaseRetirement.retireBases(
        of: project, effects: effects(relaunched) { forgotten.add("forgot again") })
      XCTFail("an unknown base was destroyed")
    } catch HostDriverError.unknownHost {}
    XCTAssertEqual(forgotten.all, ["forgot"])
  }

  private final class Forgotten: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    func add(_ what: String) { lock.withLock { said.append(what) } }
    var all: [String] { lock.withLock { said } }
  }

  /// A teardown whose removal fails names the box still up.
  @MainActor
  func testDestroyingAWorkroomWhoseBoxCannotBeRemovedNamesIt() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    let instance = try await provision(environment, branch: "wr-both")
    cleanups.append { try? await driver.destroy(instance.host) }
    try "rm".write(to: failing, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: failing) }

    do {
      try await RemoteProvisioning.destroy(instance, in: environment)
      XCTFail("a failed teardown was swallowed")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, let cleanup) {
      XCTAssertEqual(host, instance.host, "the box still up was not named")
      XCTAssertEqual(cleanup.count, 1, "\(cleanup)")
    }
  }

  /// A failure whose undoing fails too names the box still live (#252 review), rather than leaving
  /// one that nothing records.
  @MainActor
  func testAWorkroomWhoseRollbackFailsSaysWhatIsStillLive() async throws {
    let (fixture, failing) = try failingFixture()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: fixture.provisioning)
    let environment = environment(fixture, driver: driver)
    // The checkout fails on its branch name, then the box's removal fails.
    try "rm".write(to: failing, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: failing) }

    do {
      _ = try await provision(environment, branch: "bad..name")
      XCTFail("a workroom with an unusable branch was made")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(let cause, let host, let cleanup) {
      XCTAssertTrue(cause.contains("switch"), cause)
      XCTAssertNotNil(host, "the box still up was not named")
      XCTAssertEqual(cleanup.count, 1, "\(cleanup)")
    }
    XCTAssertEqual(try leftovers("ps", label: label).count, 1, "the workroom should still be up")
  }
}
