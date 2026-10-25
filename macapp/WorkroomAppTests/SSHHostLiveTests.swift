import DaemonConnection
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import WorkroomWire
import XCTest

@testable import Workroom

/// Opt-in, on a server explicitly supplied for this check. Uses only uniquely named, marked
/// checkout folders and a separate daemon state directory; never stops a host or daemon.
final class SSHHostLiveTests: XCTestCase {
  private final class Records: @unchecked Sendable {
    private let lock = NSLock()
    private var available = ["one", "two", "other"]
    private var saved: [String: HostDescriptor] = [:]
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

  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String] = []
    func add(_ line: String) { lock.withLock { saved.append(line) } }
    var all: [String] { lock.withLock { saved } }
  }

  @discardableResult
  private func shell(_ command: String, driver: SSHHostDriver) async throws -> String {
    let result = try await driver.exec(command, on: driver.hostID).communicate(nil, timeout: 30)
    guard result.status == 0 else { throw VCSError.io("\(command): \(result.output)") }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func upload(_ text: String, to path: String, driver: SSHHostDriver) async throws {
    let q = PosixShell.quoted
    let parent = (path as NSString).deletingLastPathComponent
    let command =
      "test ! -L \(q(parent)) && test ! -L \(q(path)) && mkdir -p -- \(q(parent))"
      + " && cat > \(q(path)) && chmod 700 -- \(q(path))"
    let result = try await driver.exec(command, on: driver.hostID)
      .communicate(Data(text.utf8), timeout: 30)
    guard result.status == 0 else { throw VCSError.io(result.output) }
  }

  @MainActor
  func testThreeWorkroomsOnTheSuppliedServer() async throws {
    let variables = ProcessInfo.processInfo.environment
    guard let destination = variables["WR_SSH_LIVE_DESTINATION"], !destination.isEmpty,
      let state = variables["WR_SSH_LIVE_STATE_DIRECTORY"], state.hasPrefix("workroom-check-")
    else {
      throw XCTSkip(
        "set WR_SSH_LIVE_DESTINATION and WR_SSH_LIVE_STATE_DIRECTORY for an authorised live check")
    }
    let local = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-ssh-live-\(UUID())")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: local) }
    let driver = SSHHostDriver(
      configuration: .init(destination: destination, stateDirectoryName: state), directory: local)
    let info = try await driver.checkHost()
    let parent = try driver.resolveParent(
      "~/workrooms/ssh-driver-check-\(UUID().uuidString.lowercased())")
    let q = PosixShell.quoted
    let outcome = try await DaemonBootstrap.ensure(
      host: driver.hostID, driver: driver, socket: driver.daemonSocket)
    let binary = DaemonInstall.binary(besideSocket: driver.daemonSocket)
    let foundPID = try await shell(
      "ps -eo pid=,args= | awk -v target=\(q(binary)) '$2 == target && $3 == \"serve\" { print $1 }'",
      driver: driver)
    let daemonPID = try XCTUnwrap(outcome.startedPID ?? Int32(foundPID))
    print(
      "SSH live check: \(destination), \(info.architecture), parent=\(parent), socket=\(driver.daemonSocket), pid=\(daemonPID)"
    )
    let records = Records()
    let environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: driver.daemonSocket,
      connect: { host in
        try await DaemonBootstrap.connect(
          host: host, driver: driver, socket: driver.daemonSocket)
      })
    let hosts = RemoteHosts(
      makeDriver: { _ in driver },
      connectDaemon: { host, driver in
        try await DaemonBootstrap.connect(
          host: host, driver: driver, socket: driver.daemonSocket)
      }, pendingIn: nil)
    var connections: [DaemonVCSConnection] = []
    var panes: [RemoteHostIntegrationTests.Pane] = []
    defer {
      for pane in panes { pane.dropLink() }
      PortForwardingModel.forgetHost(driver.hostID)
      ProgramStatusMonitor.shared.forget(driver.hostID)
    }
    func adopt() {
      let entries = records.descriptors.map { name, descriptor in
        Workroom(name: name, path: descriptor.path!, vcsName: "git", warnings: [], host: descriptor)
      }
      hosts.adopt(
        [
          Project(
            path: "/ssh-live/project-one", vcs: "git",
            workrooms: entries.filter { $0.name != "other" }),
          Project(
            path: "/ssh-live/project-two", vcs: "git",
            workrooms: entries.filter { $0.name == "other" }),
        ], sweep: false)
    }
    func cleanup() async throws {
      adopt()
      var failures: [String] = []
      for (name, descriptor) in records.descriptors {
        do {
          try await RemoteWorkrooms.delete(
            name, host: descriptor, environment: environment, recorder: records.recorder,
            hosts: hosts)
        } catch { failures.append("\(descriptor.path ?? name): \(error.localizedDescription)") }
      }
      for connection in connections { await connection.close() }
      connections.removeAll()
      if failures.isEmpty {
        // Never remove a parent recursively, including after a failed create.
        _ = try await shell(
          "if test -d \(q(parent)); then rmdir -- \(q(parent)); fi", driver: driver)
      } else {
        throw VCSError.io("Live check left marked folders: " + failures.joined(separator: "; "))
      }
    }
    do {
      var created: [RemoteWorkrooms.Created] = []
      let setupText =
        "#!/bin/sh\nprintf 'SSH_SETUP:%s:%s\\n' \"$WORKROOM_HOST\" \"$WORKROOM_NAME\"\n"
      let teardownText =
        "#!/bin/sh\nprintf 'SSH_TEARDOWN:%s:%s\\n' \"$WORKROOM_HOST\" \"$WORKROOM_NAME\"\n"
      let judge: RemoteProvisioning.ScriptJudge = { bytes in
        let text = String(decoding: bytes, as: UTF8.self)
        guard text == setupText || text == teardownText else {
          throw VCSError.io("the live check only runs its own generated scripts")
        }
        return ScriptTrust(
          name: "live-check", origin: "checkout", sha256: "", text: text, trusted: true,
          exempt: false)
      }
      for index in 0..<3 {
        let repository = try XCTUnwrap(
          GitHubRepository(
            host: "github.com", owner: index < 2 ? "joelmoss" : "octocat",
            name: index < 2 ? "workroom" : "Hello-World"))
        let item = try await RemoteWorkrooms.createSSH(
          repository: repository,
          cloneURL: "https://github.com/\(repository.owner)/\(repository.name).git",
          startBranch: nil, startCommit: nil, parent: parent, driver: driver,
          environment: environment, recorder: records.recorder)
        created.append(item)
        connections.append(item.instance.connection)
        XCTAssertEqual(item.instance.host, driver.hostID)
        XCTAssertFalse(item.instance.relayed)
        let location = try RepositoryLocation.remote(
          host: SSHHostDriver.id(for: destination), path: item.instance.path)
        let manager = HostConnectionManager()
        _ = try await manager.connect(host: driver.hostID) { item.instance.connection }
        let router = RepositoryRouter(connections: manager)
        try router.register(.init(location: location, sharedLocation: location))
        let reader = try await router.reader(for: location)
        let history = try await reader.log(limit: 3)
        XCTAssertFalse(history.commits.isEmpty)
        let ref = try await reader.currentRef()
        XCTAssertEqual(ref.name, item.instance.branch)
        let readme = index < 2 ? "README.md" : "README"
        try await shell(
          "printf '\\nSSH_LIVE_DIFF\\n' >> \(q(item.instance.path + "/" + readme))", driver: driver)
        let diff = try await reader.workingFileDiff(path: readme)
        XCTAssertTrue(diff.contains("+SSH_LIVE_DIFF"), diff)
        // Replace hooks only inside these new marked clones, so no repository installer runs.
        try await upload(
          setupText, to: item.instance.path + "/scripts/workroom_setup", driver: driver)
        try await upload(
          teardownText, to: item.instance.path + "/scripts/workroom_teardown", driver: driver)
        let lines = Lines()
        let setup = await RemoteProvisioning.runScript(
          .setup, workroom: item.name, at: item.instance.path, hostKind: "ssh", rootScript: nil,
          daemonBinary: binary, on: driver.hostID, driver: driver, judge: judge,
          onLine: { lines.add($0) })
        XCTAssertEqual(setup, .passed)
        XCTAssertTrue(lines.all.contains("SSH_SETUP:ssh:\(item.name)"), lines.all.description)
        let descriptor = try XCTUnwrap(records.descriptors[item.name])
        let workroom = try XCTUnwrap(descriptor.workroomID)
        let pane = try RemoteHostIntegrationTests.Pane(
          command: driver.attachCommand(
            to: driver.hostID, session: UUID(), workingDirectory: item.instance.path,
            restored: false, metadata: [(SessionMetadataKey.workroom, workroom.uuidString)],
            runCommand: nil))
        panes.append(pane)
        pane.type("pwd; echo LIVE_RE\"\"ADY\n")
        XCTAssertTrue(pane.read(until: "LIVE_READY").contains(item.instance.path))
      }
      adopt()
      try await hosts.ensureConnected(driver.hostID, wake: true)
      let originalLease = await HostConnectionManager.shared.snapshot(for: driver.hostID).lease
      let firstDescriptor = try XCTUnwrap(records.descriptors[created[0].name])
      let firstID = try XCTUnwrap(firstDescriptor.workroomID)
      let runID = UUID()
      let run = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: driver.hostID, session: runID, workingDirectory: created[0].instance.path,
          restored: false, metadata: [(SessionMetadataKey.workroom, firstID.uuidString)],
          runCommand: "printf 'SSH_LIVE_RUN:%s\\n' \"$PWD\"; sleep 60"))
      panes.append(run)
      let runMarker = "SSH_LIVE_RUN:\(created[0].instance.path)"
      XCTAssertTrue(run.read(until: runMarker).contains(runMarker))
      let sshConnection = try await shell("printf '%s' \"$SSH_CONNECTION\"", driver: driver)
      let serverPort = try XCTUnwrap(
        sshConnection.split(separator: " ").last.flatMap { UInt16($0) })
      var models: [PortForwardingModel] = []
      for item in created.prefix(2) {
        let descriptor = try XCTUnwrap(records.descriptors[item.name])
        let workroom = try XCTUnwrap(descriptor.workroomID)
        let configPath = ".devcontainer/devcontainer.json"
        try await upload(
          "{\"forwardPorts\":[\(serverPort)]}\n", to: item.instance.path + "/" + configPath,
          driver: driver)
        let location = try RepositoryLocation.remote(
          host: SSHHostDriver.id(for: destination), path: item.instance.path)
        let files = try item.instance.connection.files(
          context: FileContext(location: location, sharedLocation: nil))
        let model = PortForwardingModel(
          host: driver.hostID, transport: .on(driver.hostID, manager: .shared), sameLocalPort: false
        )
        PortForwardingModel.workroomModels[.init(host: driver.hostID, workroom: workroom)] = model
        await model.forwardDeclared {
          (
            path: configPath,
            data: try await files.read(path: configPath, symlinks: .refuse, maxBytes: 65536)
          )
        }
        XCTAssertNil(model.message)
        XCTAssertEqual(model.forwards.count, 1)
        models.append(model)
      }
      let ports = try models.map { try XCTUnwrap($0.forwards.first?.localPort) }
      XCTAssertNotEqual(ports[0], ports[1])
      for port in ports {
        let client = try TCPClient(port: port)
        XCTAssertEqual(String(decoding: try client.read(8, timeout: 10), as: UTF8.self), "SSH-2.0-")
        client.close()
      }
      for (index, item) in created.enumerated() {
        let descriptor = try XCTUnwrap(records.descriptors[item.name])
        let lines = Lines()
        try await RemoteWorkrooms.delete(
          item.name, host: descriptor, environment: environment, recorder: records.recorder,
          teardown: .init(
            path: item.instance.path, rootScript: nil, judge: judge, onLine: { lines.add($0) },
            run: { await RemoteWorkrooms.runScript($0, hosts: hosts) }), hosts: hosts)
        XCTAssertTrue(lines.all.contains("SSH_TEARDOWN:ssh:\(item.name)"), lines.all.description)
        if index == 0 {
          let snapshot = await HostConnectionManager.shared.snapshot(for: driver.hostID)
          XCTAssertEqual(snapshot.lease, originalLease)
          XCTAssertTrue(models[0].forwards.isEmpty)
          XCTAssertEqual(models[1].forwards.count, 1)
          let sessions = try await HostConnectionManager.shared.sessions(on: driver.hostID)
          XCTAssertFalse(sessions.contains { $0.identifier.uuid == runID })
          for other in created.dropFirst() {
            let otherID = try XCTUnwrap(records.descriptors[other.name]?.workroomID)
            XCTAssertTrue(
              sessions.contains {
                $0.value(forMetadataKey: SessionMetadataKey.workroom) == otherID.uuidString
              })
          }
          let client = try TCPClient(port: ports[1])
          XCTAssertEqual(
            String(decoding: try client.read(8, timeout: 10), as: UTF8.self), "SSH-2.0-")
          client.close()
        }
      }
      let final = await HostConnectionManager.shared.snapshot(for: driver.hostID)
      XCTAssertEqual(final.status, .disconnected)
      XCTAssertTrue(records.descriptors.isEmpty)
      try await cleanup()
      let alive = try await shell("ps -p \(daemonPID) -o pid=", driver: driver)
      XCTAssertEqual(Int32(alive), daemonPID)
      print(
        "SSH live check passed: 3 workrooms removed; parent removed; daemon \(daemonPID) remains at \(driver.daemonSocket)"
      )
    } catch {
      do { try await cleanup() } catch {
        XCTFail("Live-check cleanup failed: \(error.localizedDescription)")
      }
      throw error
    }
  }
}
