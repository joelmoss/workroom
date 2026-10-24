import DaemonConnection
import HostDrivers
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// The container driver's cases on a real runtime, alike for Docker and Apple's (#308, eng review
/// D11): containers made from a stock image (debian:bookworm-slim with git added, built here),
/// reached through the runtime's `exec`, with the bundled daemon placed by the driver. A runtime's
/// suite subclasses this, says its dialect and runtime, and calls each case from a `test…` method
/// of its own; none of these is a test by itself.
///
/// Opt-in, on a Mac with the runtime up: `WR_LINUX_DAEMON` names the Linux `workroomd` for the
/// runtime's architecture (`TEST_RUNNER_` in front of each, through `make app-test`): the one a
/// Debug build bundles (`Workroom Dev.app/Contents/Resources/workroomd-linux-<arch>`), which has
/// the `terminal-state` feature that keeps screens; a plain `cargo zigbuild` leaves it out.
class ContainerIntegrationTestCase: XCTestCase {
  /// The runtime's suite says which.
  var dialect: ContainerHostDriver.Dialect { .docker }
  /// The switch that opts the suite in.
  var optIn: String { "WR_DOCKER_CONTAINER_TESTS" }

  var directory: URL!
  var runtime: URL!
  /// This test's own label, so what it left is told apart from other tests' and other runs'.
  var label: String!
  var daemon: URL!
  var connections: [DaemonVCSConnection] = []
  private var cleanups: [() async -> Void] = []

  override func setUpWithError() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment[optIn] == "1" else {
      throw XCTSkip("set TEST_RUNNER_\(optIn)=1 and TEST_RUNNER_WR_LINUX_DAEMON to run")
    }
    guard let path = environment["WR_LINUX_DAEMON"] else {
      throw XCTSkip("set TEST_RUNNER_WR_LINUX_DAEMON to the Linux workroomd")
    }
    daemon = URL(fileURLWithPath: path)
    let runtimeKind: RemoteWorkrooms.Runtime = dialect == .apple ? .apple : .docker
    guard let found = RemoteHosts.executable(for: runtimeKind) else {
      throw XCTSkip("\(runtimeKind.rawValue)'s CLI isn't installed")
    }
    runtime = URL(fileURLWithPath: found)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-containers-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    label = "workroom.provisioner=container-test-\(UUID().uuidString.lowercased())"
  }

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    for cleanup in cleanups.reversed() { await cleanup() }
    cleanups.removeAll()
    if runtime != nil {
      for container in (try? ours()) ?? [] { _ = try? cli(remove(container)) }
      if dialect == .docker {
        for image in (try? cli(["images", "-a", "-q", "--filter", "label=\(label!)"]))?
          .split(separator: "\n") ?? []
        {
          _ = try? cli(["rmi", "--force", String(image)])
        }
      }
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
    try await super.tearDown()
  }

  // MARK: Helpers

  func driver(runtime override: URL? = nil, folder: String = "hosts") -> ContainerHostDriver {
    let daemon = self.daemon!
    return ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent(folder),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: override ?? runtime, image: "unused", user: "",
        daemonSocket: ContainerHostDriver.containerSocket, labels: [label], dialect: dialect,
        daemon: { _ in daemon }, daemonFolder: directory.appendingPathComponent("daemon")))
  }

  /// The stock image with git, which a workroom needs: built through the driver, so its build is
  /// exercised too, and labelled as this test's.
  func gitImage(_ driver: ContainerHostDriver) async throws -> String {
    let context = directory.appendingPathComponent("image", isDirectory: true)
    try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
    let dockerfile = context.appendingPathComponent("Dockerfile")
    try """
    FROM debian:bookworm-slim
    RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
    """.write(to: dockerfile, atomically: true, encoding: .utf8)
    // One tag for every test: each build of the same Dockerfile is the same layers, and Apple's
    // runtime keeps a copy per image. Docker's is removed with this test's label at tearDown.
    let tag = "workroom-test-git"
    try await driver.build(dockerfile: dockerfile, context: context, tag: tag)
    return tag
  }

  func create(
    _ driver: ContainerHostDriver, image: String, workspace: String = "/workspaces/app"
  ) async throws -> HostID {
    try await driver.create(spec: .init(image: image, workspaceFolder: workspace))
  }

  /// The real CLI, run from here rather than through the driver, so a check is never the driver
  /// checking itself.
  @discardableResult
  func cli(_ arguments: [String]) throws -> String {
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

  private func remove(_ container: String) -> [String] {
    dialect == .apple
      ? ["delete", "--force", container] : ["rm", "--force", "--volumes", container]
  }

  /// The containers carrying this test's label.
  func ours() throws -> [String] {
    if dialect == .apple {
      let ours = label.split(separator: "=")[1].description
      return try AppleContainerCLI.objects(cli(["list", "--all", "--format", "json"])).filter {
        AppleContainerCLI.labels(of: $0)["workroom.provisioner"] == ours
      }.compactMap(AppleContainerCLI.id)
    }
    return try cli(["ps", "-a", "--filter", "label=\(label!)", "--format", "{{.Names}}"])
      .split(separator: "\n").map(String.init)
  }

  func name(_ host: HostID) throws -> String {
    guard case .remote(let id) = host else { throw HostDriverError.unknownHost(host) }
    return ContainerHostDriver.containerName(id)
  }

  @discardableResult
  func onHost(_ driver: ContainerHostDriver, _ host: HostID, _ command: String) async throws
    -> String
  {
    let (status, output) = try await driver.exec(command, on: host).communicate(nil, timeout: 30)
    XCTAssertEqual(status, 0, "in the container, \(command) failed: \(output)")
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A pane on `host`, its attach run in a terminal (`script`), as libghostty runs it: `exec -t`
  /// refuses a stdin that isn't one.
  func pane(
    _ driver: ContainerHostDriver, _ host: HostID, session: UUID, restored: Bool = false,
    run: String? = nil
  ) throws -> RemoteHostIntegrationTests.Pane {
    let attach = try driver.attachCommand(
      to: host, session: session, workingDirectory: "/workspaces/app", restored: restored,
      metadata: [], runCommand: run)
    return try RemoteHostIntegrationTests.Pane(
      command: "/usr/bin/script -q /dev/null /bin/sh -c \(PosixShell.quoted(attach))")
  }

  func connect(_ driver: ContainerHostDriver, _ host: HostID, daemon: URL? = nil) async throws
    -> DaemonVCSConnection
  {
    let bundled = daemon ?? self.daemon!
    let connection = try await DaemonBootstrap.connect(
      host: host, driver: driver, socket: ContainerHostDriver.containerSocket,
      daemon: { _ in bundled }, resources: nil)
    connections.append(connection)
    return connection
  }

  /// A runtime that runs the real one, except for the subcommands listed in `failing` while that
  /// file exists; named with a `+`, the subcommand runs and THEN fails, as a CLI killed after the
  /// daemon took the request does.
  func failingRuntime() throws -> (runtime: URL, failing: URL) {
    let failing = directory.appendingPathComponent("failing")
    let script = directory.appendingPathComponent("runtime")
    try """
    #!/bin/sh
    steps=" $(cat \(PosixShell.quoted(failing.path)) 2>/dev/null) "
    case "$steps" in *" $1 "*) echo "injected failure" >&2; exit 1 ;; esac
    case "$steps" in *" $1+ "*)
      \(PosixShell.quoted(runtime.path)) "$@" >/dev/null; echo "injected failure" >&2; exit 1 ;;
    esac
    exec \(PosixShell.quoted(runtime.path)) "$@"

    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (script, failing)
  }

  // MARK: The cases

  /// A container from a stock image serves its daemon to the bootstrap's connect, Docker's with a
  /// restart policy, and destroying it leaves nothing.
  func aContainerServesAndDestroyingItLeavesNothing() async throws {
    let driver = driver()
    let host = try await create(driver, image: try await gitImage(driver))
    _ = try await connect(driver, host)
    XCTAssertEqual(try ours().count, 1)
    if dialect == .docker {
      XCTAssertEqual(
        try cli(["inspect", "-f", "{{.HostConfig.RestartPolicy.Name}}", try name(host)]),
        "unless-stopped")
    }
    try await driver.destroy(host)
    XCTAssertEqual(try ours(), [])
    do {
      _ = try await driver.exec("true", on: host)
      XCTFail("a destroyed host is still known")
    } catch HostDriverError.unknownHost {}
  }

  /// A stopped container is started again when its workroom is opened (#309).
  func aStoppedContainerIsStartedAgain() async throws {
    let driver = driver()
    let host = try await create(driver, image: try await gitImage(driver))
    try cli(["stop", try name(host)])
    try await driver.startIfStopped(host)
    let answer = try await onHost(driver, host, "echo up")
    XCTAssertEqual(answer, "up")
    try await driver.destroy(host)
  }

  /// A create that fails at any of its runtime's steps leaves no container behind.
  func aCreateThatFailsAtEachStepLeavesNothing() async throws {
    let (script, failing) = try failingRuntime()
    let image = try await gitImage(driver())
    let driver = driver(runtime: script)
    let steps =
      dialect == .apple ? ["create", "create+", "start"] : ["create", "create+", "cp", "start"]
    for step in steps {
      try step.write(to: failing, atomically: true, encoding: .utf8)
      do {
        _ = try await create(driver, image: image)
        XCTFail("a create that failed at \(step) succeeded")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertTrue(detail.contains("injected failure"), "\(step): \(detail)")
      }
      XCTAssertEqual(try ours(), [], "a create that failed at \(step) left a container")
    }
    try FileManager.default.removeItem(at: failing)
  }

  /// A create that fails and can't remove its container says what is still there (#280).
  func aCreateThatCannotRemoveItsContainerSaysWhatIsLeft() async throws {
    let (script, failing) = try failingRuntime()
    let image = try await gitImage(driver())
    let driver = driver(runtime: script)
    try (dialect == .apple ? "start delete" : "start rm").write(
      to: failing, atomically: true, encoding: .utf8)
    do {
      _ = try await create(driver, image: image)
      XCTFail("a create that failed succeeded")
    } catch HostDriverError.leftBehind(let cause, let leftover, _) {
      XCTAssertTrue(cause.contains("injected failure"), cause)
      XCTAssertTrue(leftover.contains { $0.hasPrefix("container workroom-") }, "\(leftover)")
    }
    try FileManager.default.removeItem(at: failing)
    // tearDown removes what was left, by label.
  }

  /// A pane reattaching after the container restarts is shown its last screen, ended, rather than
  /// a fresh shell (#232): screens live in the remote user's home, which outlives a restart.
  func aPaneIsShownItsLastScreenAfterARestart() async throws {
    let driver = driver()
    let host = try await create(driver, image: try await gitImage(driver))
    let session = UUID()
    let first = try pane(driver, host, session: session)
    defer { first.dropLink() }
    try await Task.sleep(for: .seconds(1))
    first.type("echo LAST-SC\"\"REEN\n")
    XCTAssertTrue(first.read(until: "LAST-SCREEN").contains("LAST-SCREEN"))
    let record = "~/.local/state/workroom/screens/\(session.uuidString.lowercased()).vt"
    var written = false
    for _ in 0..<100 where !written {
      let (status, _) = try await driver.exec("grep -q LAST-SCREEN \(record)", on: host)
        .communicate(nil, timeout: 20)
      written = status == 0
      if !written { try await Task.sleep(for: .milliseconds(200)) }
    }
    if !written {
      let (_, seen) = try await driver.exec(
        "echo HOME=$HOME; ls -la ~/.local/state/workroom/screens 2>&1; ps -o pid,user,args 2>&1"
          + " || ps aux", on: host
      ).communicate(nil, timeout: 20)
      let logs = (try? cli(["logs", try name(host)])) ?? ""
      XCTFail(
        "the screen was never written to \(record): \(seen)\nlogs: \(logs)\npane: "
          + first.read(until: "\u{0}", within: 0).debugDescription)
    }
    first.dropLink()

    try cli(["stop", try name(host)])
    try await driver.startIfStopped(host)
    let second = try pane(driver, host, session: session, restored: true)
    defer { second.dropLink() }
    let seen = second.read(until: "host restarted", within: 40)
    XCTAssertTrue(seen.contains("LAST-SCREEN"), seen)
    XCTAssertTrue(seen.contains("ended when its host restarted"), seen)
    try await driver.destroy(host)
  }

  /// A run tab's command runs under the daemon's run supervisor, its output in the pane (#522).
  func aRunTabRunsItsCommand() async throws {
    let driver = driver()
    let host = try await create(driver, image: try await gitImage(driver))
    let pane = try pane(driver, host, session: UUID(), run: "echo RUN-$((6*7)) in $(pwd)")
    defer { pane.dropLink() }
    let seen = pane.read(until: "RUN-42 in /workspaces/app", within: 30)
    XCTAssertTrue(seen.contains("RUN-42 in /workspaces/app"), seen)
    try await driver.destroy(host)
  }

  /// A later launch's driver takes back what an earlier one made from its record alone (#253),
  /// reaches the same container, and destroys it.
  func aLaterLaunchAdoptsARecordedContainer() async throws {
    let earlier = driver(folder: "earlier")
    let host = try await create(earlier, image: try await gitImage(earlier))
    try await onHost(earlier, host, "echo mine > /tmp/marker")
    let record = try XCTUnwrap(earlier.record(of: host))
    let stored = try JSONDecoder().decode(
      HostDescriptor.self,
      from: try JSONEncoder().encode(HostDescriptor(driver: "container", container: record)))
    XCTAssertEqual(stored.container, record)

    let later = driver(folder: "later")
    guard case .remote(let id) = host else { return XCTFail("not a remote host") }
    try later.adopt(id, try XCTUnwrap(stored.container))
    let marker = try await onHost(later, host, "cat /tmp/marker")
    XCTAssertEqual(marker, "mine")
    try await later.destroy(host)
    XCTAssertEqual(try ours(), [])
  }

  /// The sweep removes what carries the driver's labels and no record names, once it has found
  /// it unknown twice, and leaves recorded hosts and anything younger than its grace (#253, #284).
  func theSweepRemovesOnlyUnrecordedContainersPastTheirGrace() async throws {
    let driver = driver()
    let image = try await gitImage(driver)
    let kept = try await create(driver, image: image)
    let orphan = try await create(driver, image: image)
    guard case .remote(let keptID) = kept, case .remote(let orphanID) = orphan else {
      return XCTFail("not remote hosts")
    }
    let young = await driver.sweep(keeping: [keptID], grace: 3600)
    XCTAssertEqual(young, [])
    XCTAssertEqual(try ours().count, 2, "young ones went")
    let first = await driver.sweep(keeping: [keptID], grace: 0)
    XCTAssertEqual(first, [])
    XCTAssertEqual(try ours().count, 2, "one sweep took a container")
    let second = await driver.sweep(keeping: [keptID], grace: 0)
    XCTAssertEqual(second, [])
    XCTAssertEqual(try ours(), [ContainerHostDriver.containerName(keptID)])
    XCTAssertFalse(try ours().contains(ContainerHostDriver.containerName(orphanID)))
    try await onHost(driver, kept, "true")
    try await driver.destroy(kept)
  }

  /// Creates at once each get a container of their own, kept apart by the driver.
  func concurrentCreatesEachGetTheirOwnContainer() async throws {
    let driver = driver()
    let image = try await gitImage(driver)
    let hosts = try await withThrowingTaskGroup(of: HostID.self) { group in
      for _ in 0..<3 { group.addTask { try await self.create(driver, image: image) } }
      return try await group.reduce(into: [HostID]()) { $0.append($1) }
    }
    XCTAssertEqual(Set(hosts).count, 3)
    var names: Set<String> = []
    for host in hosts { names.insert(try await onHost(driver, host, "hostname")) }
    XCTAssertEqual(names.count, 3, "two creates share a container")
    for host in hosts { try await driver.destroy(host) }
    XCTAssertEqual(try ours(), [])
  }

  /// A port in the container is forwarded to this Mac over the daemon connection (#254): git's own
  /// daemon in the container, reached by a `git ls-remote` here.
  func aPortIsForwardedToThisMac() async throws {
    let driver = driver()
    let host = try await create(driver, image: try await gitImage(driver))
    try await onHost(
      driver, host,
      "git init -q --bare /tmp/served.git && git -C /tmp/served.git config daemon.uploadpack true"
        + " && git daemon --reuseaddr --listen=127.0.0.1 --port=9555 --base-path=/tmp"
        + " --export-all --detach /tmp")
    let connection = try await connect(driver, host)
    let forward = try connection.forwarding().listen(remotePort: 9555) { _ in }
    defer { forward.stop() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["ls-remote", "git://127.0.0.1:\(forward.localPort)/served.git"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, said)
    try await driver.destroy(host)
  }

  /// git in the container gets GitHub's credentials from this Mac through the relay (#309).
  @MainActor
  func gitAsksThisMacForCredentials() async throws {
    let driver = driver()
    let host = try await create(driver, image: try await gitImage(driver))
    let generation = UUID()
    let token = "ghs_relayed_\(UUID().uuidString.prefix(8))"
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
    _ = try await connect(driver, host)
    try await relay.install(
      on: host, driver: driver, daemonBinary: try XCTUnwrap(driver.daemonPath(on: host)),
      socket: ContainerHostDriver.containerSocket)
    guard case .remote(let id) = host else { return XCTFail("not a remote host") }
    defer { relay.close(id) }
    let said = try await onHost(
      driver, host, "printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill")
    XCTAssertTrue(said.contains("password=\(token)"), said)
    try await driver.destroy(host)
  }

  /// A workroom's setup and teardown scripts run in the container through the placed daemon's
  /// `run-script`, with the workroom's variables.
  func theWorkroomsScriptsRunInTheContainer() async throws {
    let driver = driver()
    let host = try await create(driver, image: try await gitImage(driver))
    _ = try await connect(driver, host)
    let checkout = "/workspaces/app"
    for script in ["workroom_setup", "workroom_teardown"] {
      try await onHost(
        driver, host,
        "mkdir -p \(checkout)/scripts && printf '#!/bin/sh\\necho \"%s $WORKROOM_NAME $(pwd)\"\\n'"
          + " \(script) > \(checkout)/scripts/\(script) && chmod 755 \(checkout)/scripts/\(script)")
    }
    for script in [RemoteProvisioning.Script.setup, .teardown] {
      let lines = Lines()
      let result = await RemoteProvisioning.runScript(
        script, workroom: "box", at: checkout, hostKind: "docker", rootScript: nil,
        daemonBinary: try XCTUnwrap(driver.daemonPath(on: host)), on: host, driver: driver,
        judge: { text in
          ScriptTrust(
            name: script.fileName, origin: "stdin", sha256: "",
            text: String(decoding: text, as: UTF8.self), trusted: true, exempt: false)
        }, onLine: { lines.add($0) })
      XCTAssertEqual(result, .passed)
      XCTAssertEqual(lines.all, ["\(script.fileName) box \(checkout)"])
    }
    try await driver.destroy(host)
  }

  /// This build's daemon placed over another build's (T7): the bootstrap stages it, checks it runs,
  /// hands the running daemon off to it, keeping its sessions, and puts it in place. A copy of the
  /// daemon with a byte added stands in for another build: an ELF ignores what follows it.
  func aNewerBuildIsPlacedAndHandedOff() async throws {
    let driver = driver()
    let host = try await create(driver, image: try await gitImage(driver))
    let session = UUID()
    let pane = try pane(driver, host, session: session)
    defer { pane.dropLink() }
    try await Task.sleep(for: .seconds(1))
    pane.type("echo KEPT-AC\"\"ROSS\n")
    XCTAssertTrue(pane.read(until: "KEPT-ACROSS").contains("KEPT-ACROSS"))

    let other = directory.appendingPathComponent("workroomd-other")
    var bytes = try Data(contentsOf: daemon)
    bytes.append(0)
    try bytes.write(to: other)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
    let outcome = try await DaemonBootstrap.ensure(
      host: host, driver: driver, socket: ContainerHostDriver.containerSocket,
      daemon: { _ in other }, resources: nil)
    XCTAssertEqual(outcome.daemon, .handedOff)
    // The entrypoint is the new build now, and the session is still there.
    let placed = try await onHost(
      driver, host,
      "wc -c < \(ContainerHostDriver.containerDaemon); ls \(ContainerHostDriver.daemonFolder)")
    XCTAssertEqual(placed.split(separator: "\n").first.map(String.init), String(bytes.count))
    XCTAssertFalse(placed.contains(".new."), "a staged copy was left: \(placed)")
    let listed = try await onHost(
      driver, host,
      "\(ContainerHostDriver.containerDaemon) list --socket \(ContainerHostDriver.containerSocket)")
    XCTAssertTrue(listed.lowercased().contains(session.uuidString.lowercased()), listed)
    try await driver.destroy(host)
  }

  final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
  }
}
