import DaemonConnection
import Foundation
import HostDrivers
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

final class SSHWorkroomTests: XCTestCase {
  private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String] = []
    private var hosts: [HostDescriptor] = []
    var all: [String] { lock.withLock { saved } }
    var descriptors: [HostDescriptor] { lock.withLock { hosts } }
    func add(_ text: String) { lock.withLock { saved.append(text) } }
    func record(_ host: HostDescriptor) { lock.withLock { hosts.append(host) } }
    var recorder: RemoteWorkrooms.Recorder {
      .init(
        reserve: { _, _ in
          XCTFail("SSH used a fixed clone path")
          return "wrong"
        },
        record: { _, host in self.record(host) }, forget: { self.add("forget \($0)") },
        reserveInParent: { path, host in
          self.add("reserve \(path)")
          self.record(host)
          return "quiet-river"
        })
    }
  }

  private struct Runner: StatusCommandRunning {
    let calls: Calls
    var checkExit: Int32 = 0
    var folderExit: Int32 = 0
    var guardExit: Int32? = nil
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      let command = args.last ?? ""
      calls.add(command)
      if command.contains("WRSSH home") {
        return .init(
          stdout: "WRSSH home /home/joel\nWRSSH arch x86_64\n", stderr: "",
          exitCode: checkExit, timedOut: false)
      }
      if command.contains("exit 46"), let guardExit {
        return .init(stdout: "", stderr: "", exitCode: guardExit, timedOut: false)
      }
      return .init(
        stdout: "", stderr: "", exitCode: command.contains("mkdir --") ? folderExit : 0,
        timedOut: false)
    }
  }

  private struct ControlRunner: StatusCommandRunning {
    let calls: Calls
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      calls.add(args.joined(separator: " "))
      return .init(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    }
  }

  func testNetworkChangeInvalidatesAnUnansweringSSHHostsPrivateTransport() async throws {
    let calls = Calls()
    let destination = "wake-test-\(UUID().uuidString)"
    let driver = SSHHostDriver(
      configuration: .init(destination: destination, home: "/home/joel"),
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      runner: ControlRunner(calls: calls))
    let id = SSHHostDriver.id(for: destination)
    let hosts = RemoteHosts(makeDriver: { _ in driver }, pendingIn: nil)
    hosts.reachability.adopt(
      [
        Project(
          path: "/ssh-wake-test", vcs: "git",
          workrooms: [
            Workroom(
              name: "w", path: "/home/joel/w", vcsName: "git", warnings: [],
              host: .init(
                driver: "ssh", provisioner: RemoteWorkrooms.provisioner, id: id,
                sshDestination: destination, sshHome: "/home/joel"))
          ])
      ], sweep: false)
    let unanswering = await hosts.reachability.unansweringProviderHosts()
    XCTAssertEqual(unanswering, [.remote(id)])
    XCTAssertEqual(calls.all.count, 1)
    XCTAssertTrue(calls.all[0].contains("-O exit \(destination)"))
    XCTAssertTrue(calls.all[0].contains("ControlMaster=auto"))
    XCTAssertFalse(calls.all[0].contains("kill"))
  }

  private func driver(_ calls: Calls, checkExit: Int32 = 0, folderExit: Int32 = 0) -> SSHHostDriver
  {
    SSHHostDriver(
      configuration: .init(destination: "myserver", home: "/home/joel"),
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      runner: Runner(calls: calls, checkExit: checkExit, folderExit: folderExit))
  }

  private func create(
    _ driver: SSHHostDriver, calls: Calls,
    connect: @escaping @Sendable (HostID) async throws -> DaemonVCSConnection = { _ in
      XCTFail("The rejected create connected to a daemon")
      throw HostDriverError.provisioning("unexpected connect")
    }
  ) async throws -> RemoteWorkrooms.Created {
    try await RemoteWorkrooms.createSSH(
      repository: try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r")),
      cloneURL: "git@github.com:o/r.git", startBranch: nil, startCommit: nil,
      parent: "~/workrooms", driver: driver,
      environment: .init(driver: driver, daemonSocket: driver.daemonSocket, connect: connect),
      recorder: calls.recorder)
  }

  func testHostChecksFailBeforeReservingOrMakingAFolder() async throws {
    let calls = Calls()
    do {
      _ = try await create(driver(calls, checkExit: 42), calls: calls)
      XCTFail("missing git was accepted")
    } catch SSHHostDriver.Failure.unsupportedHost {}
    XCTAssertFalse(calls.all.contains { $0.hasPrefix("reserve") || $0.contains("mkdir --") })
    XCTAssertTrue(calls.descriptors.isEmpty)
  }

  func testExistingFolderForgetsReservationWithoutRemovingAnything() async throws {
    let calls = Calls()
    do {
      _ = try await create(driver(calls, folderExit: 43), calls: calls)
      XCTFail("existing folder was accepted")
    } catch SSHHostDriver.Failure.folderExists(let path) {
      XCTAssertEqual(path, "/home/joel/workrooms/quiet-river")
    }
    XCTAssertTrue(calls.all.contains("forget quiet-river"))
    XCTAssertFalse(calls.all.contains { $0.contains("rm -rf") })
    XCTAssertEqual(calls.descriptors.first?.id, SSHHostDriver.id(for: "myserver"))
  }

  func testFailedCloneRemovesOnlyTheMarkedFolderAndForgetsIt() async throws {
    let calls = Calls()
    let driver = driver(calls)
    let fake = try FakeDaemon(
      version: 4,
      execResult:
        #"{"stdout":"","stderr":"denied","exit_code":128,"timed_out":false,"signaled":false}"#)
    defer { fake.stop() }
    do {
      _ = try await create(driver, calls: calls) { host in
        try await DaemonVCSConnection.connect(host: host, socketPath: fake.socketPath)
      }
      XCTFail("failed clone was accepted")
    } catch RemoteProvisioning.Failure.git {}
    let removal = try XCTUnwrap(calls.all.first { $0.contains("rm -rf") })
    XCTAssertTrue(removal.contains("/home/joel/workrooms/quiet-river"))
    XCTAssertTrue(removal.contains("/workrooms/"))
    XCTAssertTrue(calls.all.contains("forget quiet-river"))
    XCTAssertFalse(calls.all.contains { $0.contains("sudo") || $0.contains("systemctl") })
    XCTAssertTrue(PendingMachines.entries(in: driver.directory).isEmpty)
    // `serving` is the create's last record: never written before the checkout exists.
    XCTAssertFalse(
      calls.descriptors.contains { $0.lifecycle == .serving }, "recorded serving before the clone")
    let reacher: any HostDriver = driver
    XCTAssertFalse(reacher is any ProvisioningHostDriver)
  }

  // Value: protects=a failed SSH clone ends with how to give the host GitHub access;
  // fails_when=the SSH create stops giving the shared clone the SSH hint (its environment carries
  // none); why_new=the failed-clone test above never reads the message; seam=none
  /// A clone that fails on an SSH host says git's own words, then how to set up its credentials.
  func testAFailedSSHCloneSaysHowToSetUpCredentialsOnTheHost() async throws {
    let calls = Calls()
    let fake = try FakeDaemon(
      version: 4,
      execResult:
        #"{"stdout":"","stderr":"denied","exit_code":128,"timed_out":false,"signaled":false}"#)
    defer { fake.stop() }
    let hint = try XCTUnwrap(HostKind.ssh.credentialHint)
    do {
      _ = try await create(driver(calls), calls: calls) { host in
        try await DaemonVCSConnection.connect(host: host, socketPath: fake.socketPath)
      }
      XCTFail("failed clone was accepted")
    } catch RemoteProvisioning.Failure.git(let command, let detail) {
      XCTAssertEqual(command, "clone")
      XCTAssertEqual(detail, "denied\n\n" + hint)
    }
  }

  private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [RemoteWorkrooms.ScriptRequest] = []
    var all: [RemoteWorkrooms.ScriptRequest] { lock.withLock { made } }
    func add(_ request: RemoteWorkrooms.ScriptRequest) { lock.withLock { made.append(request) } }
  }

  // Value: protects=an SSH workroom's teardown runs in its folder as its SSH host, and a failed one
  // removes nothing and keeps the entry; fails_when=the SSH delete gives the shared teardown another
  // key, host, path or name, or goes on past its failure; why_new=only the fixture-backed
  // SSHHostIntegrationTests ran an SSH teardown; seam=Teardown.run
  /// An SSH workroom's teardown runs as its host, and one that fails stops the delete.
  func testAnSSHTeardownRunsAsItsHostAndAFailedOneKeepsTheFolder() async throws {
    let calls = Calls()
    let driver = driver(calls)
    let id = SSHHostDriver.id(for: "myserver")
    let descriptor = HostDescriptor(
      driver: "ssh", provisioner: RemoteWorkrooms.provisioner, id: id, workroomID: UUID(),
      path: "/home/joel/workrooms/w", sshDestination: "myserver", sshHome: "/home/joel")
    let requests = Requests()
    let teardown = RemoteWorkrooms.Teardown(
      path: "/home/joel/workrooms/w", rootScript: nil,
      judge: { _ in throw HostDriverError.provisioning("unexpected judge") },
      onLine: { calls.add($0) },
      run: { request in
        requests.add(request)
        return .failed("teardown script failed: boom")
      })
    do {
      try await RemoteWorkrooms.delete(
        "w", host: descriptor,
        environment: .init(driver: driver, daemonSocket: driver.daemonSocket),
        recorder: calls.recorder, teardown: teardown, onForgotten: { _ in })
      XCTFail("a failed teardown deleted the workroom")
    } catch RemoteWorkrooms.Failure.teardownScriptFailed(let why) {
      XCTAssertEqual(why, "teardown script failed: boom")
    }
    let request = try XCTUnwrap(requests.all.first)
    XCTAssertEqual(requests.all.count, 1)
    XCTAssertEqual(request.script, .teardown)
    XCTAssertEqual(request.workroom, "w")
    XCTAssertEqual(request.path, "/home/joel/workrooms/w")
    XCTAssertEqual(request.host, .remote(id))
    XCTAssertEqual(request.key, .ssh(destination: "myserver"))
    XCTAssertFalse(calls.all.contains("forget w"))
    XCTAssertFalse(calls.all.contains { $0.contains("rm -rf") })
  }

  func testSSHCloneKeepsTheHostsChosenCredentialScheme() throws {
    let repo = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    for origin in [
      "ssh://git@github.com/o/r.git", "git@github.com:o/r.git", "https://github.com/o/r.git",
    ] {
      XCTAssertEqual(RemoteWorkrooms.cloneURL(for: repo, origin: origin, onSSHHost: true), origin)
    }
    XCTAssertEqual(
      RemoteWorkrooms.cloneURL(for: repo, origin: "github.com:o/r.git", onSSHHost: true),
      "git@github.com:o/r.git")
    XCTAssertEqual(
      RemoteWorkrooms.cloneURL(for: repo, origin: "ssh://git@github.com/o/r.git"),
      "https://github.com/o/r.git")
  }

  func testMissingMarkerStopsBeforeTeardownAndDeleteAnywayNamesTheFolder() async throws {
    let calls = Calls()
    let driver = SSHHostDriver(
      configuration: .init(destination: "myserver", home: "/home/joel"),
      directory: FileManager.default.temporaryDirectory,
      runner: Runner(calls: calls, guardExit: 46))
    let descriptor = HostDescriptor(
      driver: "ssh", provisioner: RemoteWorkrooms.provisioner,
      id: SSHHostDriver.id(for: "myserver"), workroomID: UUID(),
      path: "/home/joel/workrooms/w", sshDestination: "myserver", sshHome: "/home/joel")
    let environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: driver.daemonSocket)
    var teardown = RemoteWorkrooms.Teardown(
      path: "/home/joel/workrooms/w", rootScript: nil,
      judge: { _ in
        XCTFail("marker failure ran teardown")
        throw HostDriverError.provisioning("unexpected script")
      }, onLine: { calls.add($0) })
    do {
      try await RemoteWorkrooms.delete(
        "w", host: descriptor, environment: environment, recorder: calls.recorder,
        teardown: teardown, onForgotten: { _ in })
      XCTFail("unverified folder was deleted")
    } catch SSHHostDriver.Failure.markerMismatch {}
    XCTAssertFalse(calls.all.contains("forget w"))
    teardown.skip = true
    try await RemoteWorkrooms.delete(
      "w", host: descriptor, environment: environment, recorder: calls.recorder,
      teardown: teardown, onForgotten: { _ in })
    XCTAssertTrue(calls.all.contains("forget w"))
    XCTAssertTrue(calls.all.contains { $0.hasPrefix("Left /home/joel/workrooms/w on myserver:") })
    XCTAssertFalse(calls.all.contains { $0.contains("rm -rf") })
  }

  func testDescriptorsRejectUnsafeDestinationsBeforeRouting() {
    for destination in ["", "-oProxyCommand=anything", "two hosts", "host\0name"] {
      XCTAssertNil(RemoteHosts.DriverKey(.init(driver: "ssh", sshDestination: destination)))
    }
  }

  func testUnreachableHostKeepsTheWorkroomUntilDeleteAnyway() async throws {
    let calls = Calls()
    let driver = SSHHostDriver(
      configuration: .init(destination: "myserver", home: "/home/joel"),
      directory: FileManager.default.temporaryDirectory,
      runner: Runner(calls: calls, guardExit: 255))
    let host = HostDescriptor(
      driver: "ssh", provisioner: RemoteWorkrooms.provisioner,
      id: SSHHostDriver.id(for: "myserver"), workroomID: UUID(),
      path: "/home/joel/workrooms/w", sshDestination: "myserver", sshHome: "/home/joel")
    let environment = RemoteProvisioning.Environment(
      driver: driver, daemonSocket: driver.daemonSocket)
    var teardown = RemoteWorkrooms.Teardown(
      path: "/home/joel/workrooms/w", rootScript: nil,
      judge: { _ in throw HostDriverError.provisioning("unexpected script") },
      onLine: { calls.add($0) })
    do {
      try await RemoteWorkrooms.delete(
        "w", host: host, environment: environment, recorder: calls.recorder, teardown: teardown,
        onForgotten: { _ in })
      XCTFail("unreachable workroom was forgotten")
    } catch SSHHostDriver.Failure.unreachable {}
    XCTAssertFalse(calls.all.contains("forget w"))
    teardown.skip = true
    try await RemoteWorkrooms.delete(
      "w", host: host, environment: environment, recorder: calls.recorder, teardown: teardown,
      onForgotten: { _ in })
    XCTAssertTrue(calls.all.contains("forget w"))
    XCTAssertTrue(calls.all.contains { $0.hasPrefix("Left /home/joel/workrooms/w on myserver:") })
  }

  @MainActor
  func testPortListsArePerWorkroomWhileContainerListsStayPerHost() {
    let host = HostID.remote(UUID())
    let firstID = UUID()
    let secondID = UUID()
    let first = PortForwardingModel.model(for: host, workroom: firstID)
    let second = PortForwardingModel.model(for: host, workroom: secondID)
    XCTAssertFalse(first === second)
    XCTAssertTrue(first === PortForwardingModel.model(for: host, workroom: firstID))
    PortForwardingModel.forgetWorkroom(firstID, on: host)
    XCTAssertTrue(second === PortForwardingModel.model(for: host, workroom: secondID))
    let container = PortForwardingModel.model(for: host)
    XCTAssertTrue(container === PortForwardingModel.model(for: host))
    PortForwardingModel.forgetHost(host)
    XCTAssertNil(PortForwardingModel.models[host])
    XCTAssertNil(PortForwardingModel.workroomModels[.init(host: host, workroom: secondID)])
  }
}
