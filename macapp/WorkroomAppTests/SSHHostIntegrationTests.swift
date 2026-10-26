import DaemonConnection
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import WorkroomWire
import XCTest

@testable import Workroom

/// The user's-server path, with the fixture's daemon supervisor explicitly disabled:
///
/// WR_FIXTURE_SUPERVISOR=0 vcs/scripts/ssh-fixture/run.sh <linux workroomd> \
///   make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/SSHHostIntegrationTests
///
/// The tests use the real user's-ssh driver with a fixture-only -F configuration. No provider
/// account, root setup, fixture supervisor or external daemon restart can make them pass.
final class SSHHostIntegrationTests: XCTestCase {
  private struct Fixture {
    let config: String
    let daemon: URL
  }

  private var directory: URL!
  private var connections: [DaemonVCSConnection] = []

  private final class Records: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String>
    init(_ names: [String]) { self.names = Set(names) }
    var recorder: RemoteWorkrooms.Recorder {
      .init(
        reserve: { _, _ in
          XCTFail("delete reserved a workroom")
          return ""
        },
        record: { _, _ in XCTFail("SSH delete recorded a failed machine") },
        forget: { name in _ = self.lock.withLock { self.names.remove(name) } },
        hasWorkrooms: { _ in self.lock.withLock { !self.names.isEmpty } })
    }
  }

  private final class CreationRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [String]
    private var saved: [String: HostDescriptor] = [:]
    init(_ names: [String]) { available = names }
    var descriptors: [String: HostDescriptor] { lock.withLock { saved } }
    var recorder: RemoteWorkrooms.Recorder {
      .init(
        reserve: { _, _ in
          XCTFail("SSH used a fixed clone path")
          return ""
        },
        record: { name, descriptor in
          if let name { self.lock.withLock { self.saved[name] = descriptor } }
        },
        forget: { name in _ = self.lock.withLock { self.saved.removeValue(forKey: name) } },
        reserveInParent: { parent, descriptor in
          self.lock.withLock {
            let name = self.available.removeFirst()
            var descriptor = descriptor
            descriptor.path = parent + "/" + name
            self.saved[name] = descriptor
            return name
          }
        },
        hasWorkrooms: { id in self.lock.withLock { self.saved.values.contains { $0.id == id } } })
    }
  }

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-ssh-\(UUID().uuidString)")
  }

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func fixture() throws -> Fixture {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WR_SSH_FIXTURE_SUPERVISOR"] == "0",
      let config = environment["WR_SSH_FIXTURE_CONFIG"],
      let daemon = environment["WR_SSH_FIXTURE_DAEMON"]
    else {
      throw XCTSkip("run with WR_FIXTURE_SUPERVISOR=0 through vcs/scripts/ssh-fixture/run.sh")
    }
    return Fixture(config: config, daemon: URL(fileURLWithPath: daemon))
  }

  private func driver(_ fixture: Fixture, config: String? = nil) -> SSHHostDriver {
    SSHHostDriver(
      configuration: .init(
        destination: "fixture", stateDirectoryName: "workroom-test-\(UUID().uuidString.prefix(8))",
        sshAgent: nil, sshOptions: ["-F", config ?? fixture.config]),
      directory: directory)
  }

  @discardableResult
  private func onHost(_ fixture: Fixture, _ command: String) async throws -> String {
    let result = await StatusCommandRunner().run(
      "/usr/bin/ssh", ["-F", fixture.config, "fixture", command], in: NSHomeDirectory(), timeout: 30
    )
    guard result.ok else {
      XCTFail("fixture command failed: \(result.stderr) \(result.stdout)")
      throw VCSError.io(result.stderr)
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func ensure(
    _ driver: SSHHostDriver, daemon: URL
  ) async throws -> DaemonBootstrap.Outcome {
    try await DaemonBootstrap.ensure(
      host: driver.hostID, driver: driver, socket: driver.daemonSocket,
      daemon: { _ in daemon }, resources: nil)
  }

  private func connect(_ driver: SSHHostDriver) async throws -> DaemonVCSConnection {
    let connection = try await DaemonVCSConnection.connect(
      host: driver.hostID, stream: try await driver.openStream(to: driver.hostID))
    connections.append(connection)
    return connection
  }

  private func restart(_ fixture: Fixture) async throws {
    let environment = ProcessInfo.processInfo.environment
    let runtime = try XCTUnwrap(environment["WR_SSH_FIXTURE_RUNTIME_PATH"])
    let container = try XCTUnwrap(environment["WR_SSH_FIXTURE_CONTAINER"])
    let runner = StatusCommandRunner()
    let restarted = await runner.run(
      runtime, ["restart", container], in: NSHomeDirectory(), timeout: 60)
    guard restarted.ok else { throw VCSError.io(restarted.stderr) }
    let published = await runner.run(
      runtime, ["port", container, "22/tcp"], in: NSHomeDirectory(), timeout: 10)
    let first = try XCTUnwrap(published.stdout.split(separator: "\n").first)
    let port = try XCTUnwrap(first.split(separator: ":").last.flatMap { UInt16($0) })
    let original = try String(contentsOfFile: fixture.config, encoding: .utf8)
    let config = original.split(separator: "\n").map { line in
      line.trimmingCharacters(in: .whitespaces).hasPrefix("Port ")
        ? "  Port \(port)" : String(line)
    }.joined(separator: "\n")
    try config.write(toFile: fixture.config, atomically: true, encoding: .utf8)
    for _ in 0..<100 {
      let ready = await runner.run(
        "/usr/bin/ssh", ["-F", fixture.config, "fixture", "true"], in: NSHomeDirectory(), timeout: 5
      )
      if ready.ok { return }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw VCSError.io("the restarted SSH fixture didn't answer")
  }

  private func acceptedConnections() async throws -> Int {
    let variables = ProcessInfo.processInfo.environment
    let runtime = try XCTUnwrap(variables["WR_SSH_FIXTURE_RUNTIME_PATH"])
    let container = try XCTUnwrap(variables["WR_SSH_FIXTURE_CONTAINER"])
    let log = await StatusCommandRunner().run(
      runtime, ["logs", container], in: NSHomeDirectory(), timeout: 10)
    guard log.ok else { throw VCSError.io(log.stderr) }
    return (log.stdout + log.stderr).components(separatedBy: "\n").filter {
      $0.contains("Accepted publickey for workroom from ")
    }.count
  }

  func testUnknownKeyRequiresTrustAndThenUsesTheExactCapturedKey() async throws {
    let fixture = try fixture()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let config = directory.appendingPathComponent("ssh_config")
    let known = directory.appendingPathComponent("known_hosts")
    // All the fixture's connection settings stay; only its known_hosts is empty for this test.
    let original = try String(contentsOfFile: fixture.config, encoding: .utf8)
    let custom = original.split(separator: "\n").map { line in
      line.trimmingCharacters(in: .whitespaces).hasPrefix("UserKnownHostsFile ")
        ? "  UserKnownHostsFile \(known.path)" : String(line)
    }.joined(separator: "\n")
    try custom.write(to: config, atomically: true, encoding: .utf8)
    let driver = driver(fixture, config: config.path)
    do {
      _ = try await driver.checkHost()
      XCTFail("an unknown host key connected")
    } catch let failure as SSHHostDriver.Failure { XCTAssertEqual(failure, .unknownHostKey) }
    let captured = try await driver.captureHostKey()
    XCTAssertFalse(FileManager.default.fileExists(atPath: known.path))
    XCTAssertTrue(captured.fingerprint.contains("SHA256:"), captured.fingerprint)
    try driver.trustHostKey(captured)
    let info = try await driver.checkHost()
    XCTAssertEqual(info.home, "/home/workroom")
    XCTAssertEqual(try String(contentsOf: known, encoding: .utf8), captured.lines + "\n")
  }

  func testChecksAndExecReuseOneSSHConnection() async throws {
    let fixture = try fixture()
    let driver = driver(fixture)
    let before = try await acceptedConnections()
    var connections = Set<String>()
    for _ in 0..<12 {
      _ = try await driver.checkHost()
      let result = try await driver.exec("printf '%s\\n' \"$SSH_CONNECTION\"", on: driver.hostID)
        .communicate(nil, timeout: 20)
      XCTAssertEqual(result.status, 0, result.output)
      let connection = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      XCTAssertEqual(connection.split(separator: " ").count, 4, connection)
      connections.insert(connection)
    }
    XCTAssertEqual(
      connections.count, 1,
      "preflight and exec exchanges opened multiple SSH transports: \(connections)")
    let accepted = try await acceptedConnections() - before
    // SSH_CONNECTION proves the exec path; sshd's authentication log also catches a preflight
    // path that still opens fresh transports even if exec alone learned to reuse one.
    XCTAssertLessThanOrEqual(
      accepted, 1, "preflight and exec authenticated \(accepted) SSH transports")
    await driver.invalidateConnection()
  }

  func testInvalidationReplacesOnlyTheSSHTransport() async throws {
    let fixture = try fixture()
    let driver = driver(fixture)
    let before = try await acceptedConnections()
    _ = try await driver.checkHost()
    let first = try await driver.exec("printf '%s\\n' \"$SSH_CONNECTION\"", on: driver.hostID)
      .communicate(nil, timeout: 20)
    XCTAssertEqual(first.status, 0, first.output)
    await driver.invalidateConnection()
    let second = try await driver.exec("printf '%s\\n' \"$SSH_CONNECTION\"", on: driver.hostID)
      .communicate(nil, timeout: 20)
    XCTAssertEqual(second.status, 0, second.output)
    XCTAssertNotEqual(first.output, second.output)
    let accepted = try await acceptedConnections() - before
    XCTAssertEqual(
      accepted, 2, "an invalidated SSH transport was reused or redialled more than once")
    await driver.invalidateConnection()
  }

  func testMoreThanTenPanesKeepIndependentSSHConnections() async throws {
    let fixture = try fixture()
    let driver = driver(fixture)
    _ = try await driver.checkHost()
    _ = try await ensure(driver, daemon: fixture.daemon)
    // Keep the service channel open too. A pane accidentally using the private control master
    // would reach sshd's default MaxSessions=10 rather than open all twelve panes.
    let service = try await connect(driver)
    var panes: [RemoteHostIntegrationTests.Pane] = []
    defer { for pane in panes { pane.dropLink() } }
    var sessions: [UUID] = []
    var connections = Set<String>()
    for index in 0..<12 {
      let session = UUID()
      sessions.append(session)
      let pane = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: driver.hostID, session: session, workingDirectory: driver.home, restored: false))
      panes.append(pane)
      pane.type(
        "printf 'PANE_CONNECTION:%s\\n' \"$SSH_CONNECTION\"; echo PA\"\"NE_READY_\(index)\n")
      let seen = pane.read(until: "PANE_READY_\(index)")
      XCTAssertTrue(seen.contains("PANE_READY_\(index)"), seen)
      XCTAssertTrue(
        seen.hasPrefix("\u{1b}7workroom: waiting for this terminal's host...\u{1b}8\u{1b}[J"), seen)
      let reported = seen.components(separatedBy: "PANE_CONNECTION:").dropFirst().compactMap {
        tail in
        tail.split(whereSeparator: { $0.isNewline }).first.map(String.init)
      }.first { $0.split(separator: " ").count == 4 && !$0.contains("%s") }
      connections.insert(try XCTUnwrap(reported, seen))
    }
    XCTAssertEqual(connections.count, 12, "terminal panes shared SSH transports: \(connections)")
    for session in sessions { _ = try await service.endSession(session) }
    await service.close()
    await driver.invalidateConnection()
  }

  func testAppStartsDaemonAndRestartsItWithAStaleSocket() async throws {
    let fixture = try fixture()
    let driver = driver(fixture)
    _ = try await driver.checkHost()
    let before = try await acceptedConnections()
    let socket = PosixShell.quoted(driver.daemonSocket)
    let absent = try await driver.exec("test ! -e \(socket) && echo absent", on: driver.hostID)
      .communicate(nil, timeout: 20)
    XCTAssertEqual(absent.status, 0, absent.output)
    XCTAssertEqual(absent.output.trimmingCharacters(in: .whitespacesAndNewlines), "absent")
    let first = try await ensure(driver, daemon: fixture.daemon)
    XCTAssertEqual(first.daemon, .installed)
    let firstPID = try XCTUnwrap(first.startedPID, "the app didn't report starting the daemon")
    let coldStartAuthentications = try await acceptedConnections() - before
    XCTAssertEqual(
      coldStartAuthentications, 1,
      "cold daemon startup must close its own SSH login; probe/install should reuse the established transport"
    )
    let alive = try await onHost(fixture, "kill -0 \(firstPID) && echo alive")
    XCTAssertEqual(alive, "alive")
    let connection = try await connect(driver)
    _ = try await connection.sessions()
    let session = UUID()
    let pane = try RemoteHostIntegrationTests.Pane(
      command: driver.attachCommand(
        to: driver.hostID, session: session, workingDirectory: driver.home, restored: false))
    defer { pane.dropLink() }
    pane.type("echo SSH-LAST-SC\"\"REEN\n")
    XCTAssertTrue(pane.read(until: "SSH-LAST-SCREEN").contains("SSH-LAST-SCREEN"))
    let screen = "\(driver.stateDirectory)/daemon/screens/\(session.uuidString.lowercased()).vt"
    var written = false
    for _ in 0..<100 where !written {
      written =
        try await onHost(
          fixture,
          "if grep -q SSH-LAST-SCREEN \(PosixShell.quoted(screen)); then echo yes; else echo no; fi"
        ) == "yes"
      if !written { try await Task.sleep(for: .milliseconds(200)) }
    }
    XCTAssertTrue(written, "the daemon never persisted the terminal's screen")
    pane.dropLink()
    await connection.close()
    // SIGKILL leaves the Unix socket behind. The fixture's supervisor is off, so only the
    // app's next connect can create the second daemon process.
    try await onHost(fixture, "kill -9 \(firstPID); test -S \(socket) && echo stale")
    let second = try await ensure(driver, daemon: fixture.daemon)
    let secondPID = try XCTUnwrap(second.startedPID)
    XCTAssertNotEqual(secondPID, firstPID)
    let newAlive = try await onHost(fixture, "kill -0 \(secondPID) && echo alive")
    XCTAssertEqual(newAlive, "alive")
    _ = try await connect(driver).sessions()
    let restored = try RemoteHostIntegrationTests.Pane(
      command: driver.attachCommand(
        to: driver.hostID, session: session, workingDirectory: driver.home, restored: true))
    defer { restored.dropLink() }
    let lastScreen = restored.read(until: "host restarted")
    XCTAssertTrue(lastScreen.contains("SSH-LAST-SCREEN"), lastScreen)
    XCTAssertTrue(lastScreen.contains("ended when its host restarted"), lastScreen)
    restored.dropLink()
    try await restart(fixture)
    let rebooted = try await ensure(driver, daemon: fixture.daemon)
    XCTAssertNotNil(rebooted.startedPID, "no supervisor exists to start the daemon after reboot")
    let afterReboot = try RemoteHostIntegrationTests.Pane(
      command: driver.attachCommand(
        to: driver.hostID, session: session, workingDirectory: driver.home, restored: true))
    defer { afterReboot.dropLink() }
    let rebootScreen = afterReboot.read(until: "host restarted")
    XCTAssertTrue(rebootScreen.contains("SSH-LAST-SCREEN"), rebootScreen)
    XCTAssertTrue(rebootScreen.contains("ended when its host restarted"), rebootScreen)
  }

  @MainActor
  func testThreeWorkroomsShareADaemonAndDeletingOneKeepsOtherSessionsAndForwards() async throws {
    let fixture = try fixture()
    let driver = driver(fixture)
    _ = try await driver.checkHost()
    let outcome = try await ensure(driver, daemon: fixture.daemon)
    let daemonPID = try XCTUnwrap(outcome.startedPID)
    let host = driver.hostID
    let workrooms = [UUID(), UUID(), UUID()]
    let parent = "/home/workroom/workrooms/test-\(UUID().uuidString.prefix(8))"
    var panes: [RemoteHostIntegrationTests.Pane] = []
    defer { for pane in panes { pane.dropLink() } }
    var paths: [String] = []
    var descriptors: [HostDescriptor] = []
    let names = ["one", "two", "other-project"]
    for (index, workroom) in workrooms.enumerated() {
      let path = "\(parent)/\(index == 2 ? "another-project" : "same-project")-\(index)"
      paths.append(path)
      try await driver.prepareFolder(path: path, workroom: workroom)
      descriptors.append(
        HostDescriptor(
          driver: "ssh", provisioner: RemoteWorkrooms.provisioner,
          id: SSHHostDriver.id(for: driver.destination), workroomID: workroom,
          path: path, sshDestination: driver.destination, sshHome: driver.home))
      let pane = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: driver.hostID, session: UUID(), workingDirectory: path, restored: false,
          metadata: [(SessionMetadataKey.workroom, workroom.uuidString)], runCommand: nil))
      panes.append(pane)
      pane.type("pwd; echo RE\"\"ADY\n")
      XCTAssertTrue(pane.read(until: "READY").contains(path))
    }
    let hosts = RemoteHosts(
      makeDriver: { _ in driver },
      connectDaemon: { host, driver in
        try await DaemonBootstrap.connect(
          host: host, driver: driver, socket: driver.daemonSocket,
          daemon: { _ in fixture.daemon }, resources: nil)
      }, pendingIn: nil)
    let entries = zip(names.indices, names).map { index, name in
      Workroom(
        name: name, path: paths[index], vcsName: "git", warnings: [], host: descriptors[index])
    }
    hosts.adopt(
      [
        Project(path: "/fixture-project-one", vcs: "git", workrooms: Array(entries.prefix(2))),
        Project(path: "/fixture-project-two", vcs: "git", workrooms: Array(entries.suffix(1))),
      ], sweep: false)
    try await hosts.ensureConnected(host, wake: true)
    let before = await HostConnectionManager.shared.snapshot(for: host)
    let lease = try XCTUnwrap(before.lease)
    // Use the product registry, with ephemeral Mac ports so forwarding the fixture's sshd
    // cannot take this Mac's own ssh port.
    let models = workrooms.prefix(2).map { workroom in
      let model = PortForwardingModel(
        host: host, transport: .on(host, manager: .shared), sameLocalPort: false)
      PortForwardingModel.workroomModels[.init(host: host, workroom: workroom)] = model
      return model
    }
    defer { PortForwardingModel.forgetHost(host) }
    for model in models {
      model.draft = "22"
      await model.add()
      XCTAssertNil(model.message)
    }
    let firstPort = try XCTUnwrap(models[0].forwards.first?.localPort)
    let secondPort = try XCTUnwrap(models[1].forwards.first?.localPort)
    XCTAssertNotEqual(firstPort, secondPort)
    ProgramStatusMonitor.shared.seed(UUID(), host: host, records: [])
    let records = Records(names)
    let environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: driver.daemonSocket)
    try await RemoteWorkrooms.delete(
      names[0], host: descriptors[0], environment: environment, recorder: records.recorder,
      hosts: hosts)
    let afterOne = await HostConnectionManager.shared.snapshot(for: host)
    XCTAssertEqual(afterOne.lease, lease)
    XCTAssertNotNil(ProgramStatusMonitor.shared.hosts[host])
    XCTAssertTrue(models[0].forwards.isEmpty)
    XCTAssertEqual(models[1].forwards.count, 1)
    let remaining = try await HostConnectionManager.shared.sessions(on: host)
    XCTAssertFalse(
      remaining.contains {
        $0.value(forMetadataKey: SessionMetadataKey.workroom) == workrooms[0].uuidString
      })
    XCTAssertEqual(
      remaining.filter {
        $0.value(forMetadataKey: SessionMetadataKey.workroom) == workrooms[1].uuidString
      }.count, 1)
    XCTAssertEqual(
      remaining.filter {
        $0.value(forMetadataKey: SessionMetadataKey.workroom) == workrooms[2].uuidString
      }.count, 1)
    let client = try TCPClient(port: secondPort)
    defer { client.close() }
    XCTAssertEqual(String(decoding: try client.read(8, timeout: 10), as: UTF8.self), "SSH-2.0-")
    for index in 1..<3 {
      try await RemoteWorkrooms.delete(
        names[index], host: descriptors[index], environment: environment,
        recorder: records.recorder,
        hosts: hosts)
    }
    let afterLast = await HostConnectionManager.shared.snapshot(for: host)
    XCTAssertEqual(afterLast.status, .disconnected)
    XCTAssertNil(ProgramStatusMonitor.shared.hosts[host])
    let lastAlive = try await onHost(fixture, "kill -0 \(daemonPID) && echo alive")
    XCTAssertEqual(lastAlive, "alive", "deleting the last folder stopped the shared daemon")
  }

  func testNewerBuildWinsAndOlderMacKeepsTheSharedSession() async throws {
    let fixture = try fixture()
    let driver = driver(fixture)
    _ = try await driver.checkHost()
    _ = try await ensure(driver, daemon: fixture.daemon)
    let session = UUID()
    let pane = try RemoteHostIntegrationTests.Pane(
      command: driver.attachCommand(
        to: driver.hostID, session: session, workingDirectory: driver.home, restored: false))
    defer { pane.dropLink() }
    pane.type("MARK=kept; echo RE\"\"ADY\n")
    XCTAssertTrue(pane.read(until: "READY").contains("READY"))
    // A build marker read at runtime is changed in place, preserving the ELF's layout. Both
    // the Mac's scanner and the daemon's protocol report now identify a real newer build.
    var bytes = try Data(contentsOf: fixture.daemon)
    let build = DaemonBootstrap.buildNumber(in: bytes)
    let oldMarker = Data("WORKROOMD-BUILD:\(build);".utf8)
    let newMarker = Data("WORKROOMD-BUILD:\(build + 1);".utf8)
    XCTAssertEqual(oldMarker.count, newMarker.count)
    let range = try XCTUnwrap(bytes.range(of: oldMarker))
    bytes.replaceSubrange(range, with: newMarker)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let newer = directory.appendingPathComponent("workroomd-newer")
    try bytes.write(to: newer)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newer.path)
    let upgraded = try await ensure(driver, daemon: newer)
    XCTAssertEqual(upgraded.daemon, .handedOff)
    let older = try await ensure(driver, daemon: fixture.daemon)
    guard case .keptNewer = older.daemon else { return XCTFail("\(older)") }
    let connection = try await connect(driver)
    let sessions = try await connection.sessions()
    XCTAssertTrue(sessions.contains { $0.identifier.uuid == session })
    let keptDigest = try await onHost(
      fixture,
      "sha256sum < \(PosixShell.quoted(DaemonInstall.binary(besideSocket: driver.daemonSocket))) | cut -c1-64"
    )
    XCTAssertEqual(keptDigest, try DaemonBootstrap.digest(of: newer))
    _ = try await connection.endSession(session)
  }

  @MainActor
  func testBashAndFishLoginShellsAttachWithoutChangingScriptBytesOrPTY() async throws {
    let fixture = try fixture()
    let variables = ProcessInfo.processInfo.environment
    let runtime = try XCTUnwrap(variables["WR_SSH_FIXTURE_RUNTIME_PATH"])
    let container = try XCTUnwrap(variables["WR_SSH_FIXTURE_CONTAINER"])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for user in ["workroom", "workroom-fish"] {
      let config = directory.appendingPathComponent(user + ".config")
      let original = try String(contentsOfFile: fixture.config, encoding: .utf8)
      try original.replacingOccurrences(of: "User workroom", with: "User " + user)
        .write(to: config, atomically: true, encoding: .utf8)
      let driver = driver(fixture, config: config.path)
      _ = try await driver.checkHost()
      _ = try await ensure(driver, daemon: fixture.daemon)
      let connection = try await connect(driver)
      // These bytes cross the user's login shell before sh interprets the attach script.
      let unusual = "quote' slashes\\\\\nsecond line"
      let path = driver.home + "/" + unusual
      let made = await StatusCommandRunner().run(
        runtime, ["exec", "--user", user, container, "mkdir", "-p", path],
        in: NSHomeDirectory(), timeout: 20)
      XCTAssertTrue(made.ok, made.stderr)
      let workroom = UUID().uuidString
      let session = UUID()
      let pane = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: driver.hostID, session: session, workingDirectory: path, restored: false,
          metadata: [
            (SessionMetadataKey.workroom, workroom), (SessionMetadataKey.title, unusual),
          ], runCommand: nil))
      defer { pane.dropLink() }
      pane.type("sh -c 'test -t 0 && echo PTY_\"\"READY'\n")
      let said = pane.read(until: "PTY_READY")
      XCTAssertTrue(said.contains("PTY_READY"), said)
      let sessions = try await connection.sessions()
      let attached = try XCTUnwrap(sessions.first { $0.identifier.uuid == session })
      XCTAssertEqual(attached.value(forMetadataKey: SessionMetadataKey.title), unusual)
      XCTAssertEqual(attached.value(forMetadataKey: SessionMetadataKey.workroom), workroom)
      pane.dropLink()
      let restored = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: driver.hostID, session: session, workingDirectory: path, restored: true))
      defer { restored.dropLink() }
      restored.type("echo RESTORED_\"\"READY\n")
      let reattached = restored.read(until: "RESTORED_READY")
      XCTAssertTrue(reattached.contains("RESTORED_READY"), reattached)
      _ = try await connection.endSession(session)
      let runSession = UUID()
      let run = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: driver.hostID, session: runSession, workingDirectory: path, restored: false,
          metadata: [],
          runCommand: "printf '%s' \"$PWD\" > run-pwd; "
            + "printf '%s' \"quote' slashes\\\\\\\\\nsecond line\" > result; "
            + "echo RUN_READY; sleep 60"))
      defer { run.dropLink() }
      let ran = run.read(until: "RUN_READY")
      XCTAssertTrue(ran.contains("RUN_READY"), ran)
      let content = await StatusCommandRunner().run(
        runtime, ["exec", "--user", user, container, "cat", path + "/result"],
        in: NSHomeDirectory(), timeout: 20)
      XCTAssertTrue(content.ok, content.stderr)
      XCTAssertEqual(content.stdout, unusual)
      let runPath = await StatusCommandRunner().run(
        runtime, ["exec", "--user", user, container, "cat", path + "/run-pwd"],
        in: NSHomeDirectory(), timeout: 20)
      XCTAssertTrue(runPath.ok, runPath.stderr)
      XCTAssertEqual(runPath.stdout, path)
      _ = try await connection.endSession(runSession)
      // A restored unknown id must not silently create a fresh shell.
      let missing = UUID()
      let unknown = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: driver.hostID, session: missing, workingDirectory: path, restored: true))
      defer { unknown.dropLink() }
      let ended = unknown.read(until: "This terminal has ended. Close it to start again.")
      XCTAssertTrue(ended.contains("This terminal has ended. Close it to start again."), ended)
      unknown.type("echo NO\"\"SHELL\n")
      XCTAssertFalse(unknown.read(until: "NOSHELL", within: 2).contains("NOSHELL"))
      let after = try await connection.sessions()
      XCTAssertFalse(after.contains { $0.identifier.uuid == missing })
      unknown.dropLink()
      let binary = DaemonInstall.binary(besideSocket: driver.daemonSocket)
      let hidden = await StatusCommandRunner().run(
        runtime, ["exec", "--user", user, container, "mv", binary, binary + ".saved"],
        in: NSHomeDirectory(), timeout: 20)
      XCTAssertTrue(hidden.ok, hidden.stderr)
      let unavailable = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: driver.hostID, session: UUID(), workingDirectory: path, restored: false))
      let notInstalled = unavailable.read(until: "no daemon is installed")
      unavailable.dropLink()
      // Restore before asserting: this fixture's running daemon needs its client binary again.
      let replaced = await StatusCommandRunner().run(
        runtime, ["exec", "--user", user, container, "mv", binary + ".saved", binary],
        in: NSHomeDirectory(), timeout: 20)
      XCTAssertTrue(replaced.ok, replaced.stderr)
      XCTAssertTrue(notInstalled.contains("no daemon is installed"), notInstalled)
    }
  }

  func testCreatesCloneOnTheHostAndRunScriptsWithSSHEnvironment() async throws {
    let fixture = try fixture()
    let driver = driver(fixture)
    _ = try await driver.checkHost()
    let records = CreationRecords(["same-project-one", "same-project-two", "other-project-one"])
    let environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: driver.daemonSocket,
      connect: { host in
        try await DaemonBootstrap.connect(
          host: host, driver: driver, socket: driver.daemonSocket,
          daemon: { _ in fixture.daemon }, resources: nil)
      })
    let parent = "/home/workroom/workrooms/create-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let setup = directory.appendingPathComponent("setup")
    try "#!/bin/sh\nprintf '%s %s\\n' \"$WORKROOM_HOST\" \"$WORKROOM_NAME\" > ssh-setup.txt\n"
      .write(to: setup, atomically: true, encoding: .utf8)
    let teardown = directory.appendingPathComponent("teardown")
    try
      "#!/bin/sh\nprintf '%s %s\\n' \"$WORKROOM_HOST\" \"$WORKROOM_NAME\" > ../teardown-\"$WORKROOM_NAME\"\n"
      .write(to: teardown, atomically: true, encoding: .utf8)
    for script in [setup, teardown] {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
    let judge: RemoteProvisioning.ScriptJudge = { text in
      ScriptTrust(
        name: "workroom_setup", origin: "stdin", sha256: "",
        text: String(decoding: text, as: UTF8.self), trusted: true, exempt: false)
    }
    var created: [RemoteWorkrooms.Created] = []
    for index in 0..<3 {
      let repository = try XCTUnwrap(
        GitHubRepository(
          host: "github.com", owner: "fixture", name: index < 2 ? "same" : "other"))
      let workroom = try await RemoteWorkrooms.createSSH(
        repository: repository,
        // The fixture's HTTPS GitHub asks its own credential helper; the Mac supplies no token.
        cloneURL: "https://github.com/origin.git", startBranch: nil, startCommit: nil,
        parent: parent, driver: driver, environment: environment, recorder: records.recorder)
      created.append(workroom)
      connections.append(workroom.instance.connection)
      XCTAssertEqual(workroom.instance.host, driver.hostID)
      XCTAssertFalse(workroom.instance.relayed)
      let location = try RepositoryLocation.remote(
        host: SSHHostDriver.id(for: driver.destination), path: workroom.instance.path)
      let manager = HostConnectionManager()
      _ = try await manager.connect(host: driver.hostID) { workroom.instance.connection }
      let router = RepositoryRouter(connections: manager)
      try router.register(.init(location: location, sharedLocation: location))
      let reader = try await router.reader(for: location)
      let ref = try await reader.currentRef()
      XCTAssertEqual(ref.name, workroom.instance.branch)
      let history = try await reader.log(limit: 5)
      XCTAssertEqual(history.commits.first?.summary, "initial")
      try await onHost(
        fixture, "printf 'changed\\n' > \(PosixShell.quoted(workroom.instance.path + "/README"))")
      let diff = try await reader.workingFileDiff(path: "README")
      XCTAssertTrue(diff.contains("+changed"), diff)
      let script = await RemoteProvisioning.runScript(
        .setup, workroom: workroom.name, at: workroom.instance.path, hostKind: "ssh",
        rootScript: setup, daemonBinary: environment.daemonBinary(on: driver.hostID),
        on: driver.hostID, driver: driver, judge: judge, onLine: { _ in })
      XCTAssertEqual(script, RemoteProvisioning.ScriptRun.passed)
      let setupOutput = try await onHost(
        fixture, "cat \(PosixShell.quoted(workroom.instance.path + "/ssh-setup.txt"))")
      XCTAssertEqual(setupOutput, "ssh \(workroom.name)")
      if index == 0 {
        let session = UUID()
        let run = try RemoteHostIntegrationTests.Pane(
          command: driver.attachCommand(
            to: driver.hostID, session: session, workingDirectory: workroom.instance.path,
            restored: false, metadata: [],
            runCommand: "printf 'SSH_RUN:%s\\n' \"$PWD\"; sleep 60"))
        defer { run.dropLink() }
        let marker = "SSH_RUN:\(workroom.instance.path)"
        XCTAssertTrue(
          run.read(until: marker).contains(marker), "the run didn't execute in the SSH workroom")
        let running = try await workroom.instance.connection.sessions()
        XCTAssertTrue(running.contains { $0.identifier.uuid == session })
        _ = try await workroom.instance.connection.endSession(session)
      }
    }
    let descriptors = records.descriptors
    let hosts = RemoteHosts(
      makeDriver: { _ in driver },
      connectDaemon: { host, driver in
        try await DaemonBootstrap.connect(
          host: host, driver: driver, socket: driver.daemonSocket,
          daemon: { _ in fixture.daemon }, resources: nil)
      }, pendingIn: nil)
    hosts.adopt(
      [
        Project(
          path: "/fixture-created", vcs: "git",
          workrooms: created.map {
            Workroom(
              name: $0.name, path: $0.instance.path, vcsName: "git", warnings: [],
              host: descriptors[$0.name])
          })
      ], sweep: false)
    for workroom in created {
      try await RemoteWorkrooms.delete(
        workroom.name, host: try XCTUnwrap(descriptors[workroom.name]), environment: environment,
        recorder: records.recorder,
        teardown: .init(
          path: workroom.instance.path, rootScript: teardown, judge: judge, onLine: { _ in },
          run: { request in await RemoteWorkrooms.runScript(request, hosts: hosts) }),
        hosts: hosts)
      let teardownOutput = try await onHost(
        fixture, "cat \(PosixShell.quoted(parent + "/teardown-" + workroom.name))")
      XCTAssertEqual(teardownOutput, "ssh \(workroom.name)")
    }
    XCTAssertTrue(records.descriptors.isEmpty)
  }
}
