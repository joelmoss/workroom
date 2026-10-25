import DaemonConnection
import Foundation
import Synchronization
import WorkroomSystem
import XCTest

@testable import HostDrivers

final class SSHHostDriverTests: XCTestCase {
  private struct Call: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
    let environment: [String: String]
  }

  private final class Recording: StatusCommandRunning, Sendable {
    let calls = Mutex<[Call]>([])
    let answer: @Sendable (Call) throws -> CommandResult
    let local: Bool

    init(
      local: Bool = false,
      answer: @escaping @Sendable (Call) throws -> CommandResult = { _ in
        CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
      }
    ) {
      self.local = local
      self.answer = answer
    }

    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      await run(executable, args, in: directory, timeout: timeout, environment: [:])
    }

    func run(
      _ executable: String, _ args: [String], in directory: String, timeout: TimeInterval,
      environment: [String: String]
    ) async -> CommandResult {
      let call = Call(
        executable: executable, arguments: args, timeout: timeout, environment: environment)
      calls.withLock { $0.append(call) }
      if local {
        return await StatusCommandRunner().run(
          "/bin/sh", ["-c", args.last!], in: "/private/tmp", timeout: timeout)
      }
      do { return try answer(call) } catch {
        return CommandResult(
          stdout: "", stderr: error.localizedDescription, exitCode: 99, timedOut: false)
      }
    }
  }

  private func temporaryHome() throws -> URL {
    let path = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(
      "ssh-driver-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return path
  }

  private func driver(home: String = "/home/joel", runner: any StatusCommandRunning) throws
    -> SSHHostDriver
  {
    let result = SSHHostDriver(
      configuration: .init(destination: "myserver", home: home, sshAgent: "/agent"),
      directory: URL(fileURLWithPath: "/private/tmp/ssh-logs"), runner: runner)
    try result.adopt(home: home)
    return result
  }

  func testUserOwnedSSHAndRunAttach() throws {
    let driver = try driver(runner: Recording())
    let route = try driver.route(spawned: true)
    XCTAssertEqual(route.destination, "myserver")
    XCTAssertEqual(route.environment["SSH_AUTH_SOCK"], "/agent")
    XCTAssertNotNil(route.environment["PATH"])
    XCTAssertFalse(route.options.contains("-F"))
    XCTAssertFalse(route.options.contains("-i"))
    XCTAssertFalse(route.options.contains(where: { $0.hasPrefix("HostKeyAlias=") }))
    for option in [
      "BatchMode=yes", "ForwardAgent=no", "ForwardX11=no", "StrictHostKeyChecking=yes",
    ] {
      XCTAssertTrue(route.options.contains(option), option)
    }
    let host: any HostDriver = driver
    XCTAssertFalse(host is any ProvisioningHostDriver)
    let attach = try driver.attachCommand(
      to: driver.hostID, session: UUID(), workingDirectory: "/home/joel/workrooms/test",
      restored: false, metadata: [], runCommand: "npm start")
    XCTAssertTrue(attach.contains("WORKROOM_SESSION_RUN=1"), attach)
    XCTAssertTrue(attach.contains("WORKROOM_SESSION_COMMAND="), attach)
    XCTAssertTrue(attach.contains("npm start"), attach)
    XCTAssertTrue(attach.contains("/home/joel/.local/state/workroom/daemon/workroomd.sock"), attach)
  }

  func testDestinationValidationAndStableUUIDv5() throws {
    for destination in ["", "-oProxyCommand=bad", "a b", "a\nb", "a\0b"] {
      XCTAssertThrowsError(try SSHHostDriver.validateDestination(destination))
    }
    for destination in ["myserver", "joel@1.2.3.4", "user@[::1]"] {
      XCTAssertNoThrow(try SSHHostDriver.validateDestination(destination))
    }
    let id = SSHHostDriver.id(for: "myserver")
    XCTAssertEqual(id, SSHHostDriver.id(for: "myserver"))
    XCTAssertNotEqual(id, SSHHostDriver.id(for: "joel@myserver"))
    XCTAssertEqual(id.uuidString.split(separator: "-")[2].first, "5")
  }

  func testChecksReadOnlyAndHomeAdopted() async throws {
    let runner = Recording { _ in
      CommandResult(
        stdout: "WRSSH home /home/joel\nWRSSH arch x86_64\n", stderr: "", exitCode: 0,
        timedOut: false)
    }
    let driver = SSHHostDriver(
      configuration: .init(destination: "myserver", sshAgent: nil),
      directory: URL(fileURLWithPath: "/private/tmp/ssh-logs"), runner: runner)
    let info = try await driver.checkHost()
    XCTAssertEqual(info.home, "/home/joel")
    XCTAssertEqual(driver.home, info.home)
    XCTAssertEqual(driver.daemonSocket, "/home/joel/.local/state/workroom/daemon/workroomd.sock")
    let calls = runner.calls.withLock { $0 }
    XCTAssertEqual(calls.count, 1)
    let command = try XCTUnwrap(calls.first?.arguments.last)
    for forbidden in ["mkdir", "sudo", "systemctl", "rm ", "PendingMachines", "destroy"] {
      XCTAssertFalse(command.contains(forbidden), command)
    }
    XCTAssertTrue(command.contains("uname -s"))
    XCTAssertTrue(command.contains("-lic"))
  }

  func testHomeSocketLimitAndParentValidation() throws {
    let driver = try driver(runner: Recording())
    XCTAssertEqual(try driver.resolveParent("~/workrooms"), "/home/joel/workrooms")
    XCTAssertThrowsError(try driver.resolveParent("/etc/workrooms"))
    XCTAssertThrowsError(try driver.resolveParent("~/../../etc"))
    XCTAssertThrowsError(try driver.adopt(home: "/home/" + String(repeating: "a", count: 80)))
    let dev = SSHHostDriver(
      configuration: .init(
        destination: "myserver", home: "/home/joel", stateDirectoryName: "workroom-dev"),
      directory: URL(fileURLWithPath: "/private/tmp/ssh-logs"))
    XCTAssertEqual(dev.daemonSocket, "/home/joel/.local/state/workroom-dev/daemon/workroomd.sock")
  }

  func testSystemGitDoesNotRunABrokenOrHangingLoginProfile() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let shell = home.appendingPathComponent("login-shell")
    let touched = home.appendingPathComponent("profile-was-run")
    try "#!/bin/sh\ntouch '\(touched.path)'\nsleep 60\n".write(
      to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    // Only the platform answer differs on this Mac. The real shell must bypass the profile
    // when git is already available in the daemon's fixed fallback environment.
    let script = SSHHostDriver.hostCheck
      .replacingOccurrences(of: "uname -s", with: "printf Linux")
      .replacingOccurrences(of: "uname -m", with: "printf aarch64")
    let started = ContinuousClock.now
    let result = await StatusCommandRunner().run(
      "/bin/sh", ["-c", script], in: home.path, timeout: 2,
      environment: ["SHELL": shell.path, "HOME": home.path])
    XCTAssertTrue(result.ok, result.stderr)
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    XCTAssertFalse(FileManager.default.fileExists(atPath: touched.path))
  }

  func testUnknownChangedAndPasswordKeysAreDifferentFailures() async throws {
    let cases: [(String, SSHHostDriver.Failure)] = [
      (
        "No ED25519 host key is known for myserver and you have requested strict checking.",
        .unknownHostKey
      ),
      ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", .changedHostKey("myserver")),
      ("Permission denied (publickey).", .authentication("myserver")),
    ]
    for (said, failure) in cases {
      let runner = Recording { _ in
        CommandResult(stdout: "", stderr: said, exitCode: 255, timedOut: false)
      }
      do {
        _ = try await driver(runner: runner).checkHost()
        XCTFail("accepted \(said)")
      } catch let error as SSHHostDriver.Failure { XCTAssertEqual(error, failure) }
      XCTAssertEqual(runner.calls.withLock { $0.count }, 1)
    }
  }

  func testTrustCapturesExactLineAndOnlyWritesAfterTrust() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let known = home.appendingPathComponent("known_hosts")
    let line = "[alias.example]:2222 ssh-ed25519 AAAACAPTURED"
    let runner = Recording { call in
      if let option = call.arguments.first(where: { $0.hasPrefix("UserKnownHostsFile=") }) {
        let scratch = String(option.dropFirst("UserKnownHostsFile=".count))
        try (line + "\n").write(toFile: scratch, atomically: true, encoding: .utf8)
        return CommandResult(
          stdout: "", stderr: "Permission denied", exitCode: 255, timedOut: false)
      }
      let output =
        call.executable == "/usr/bin/ssh-keygen"
        ? "256 SHA256:the-fingerprint alias.example (ED25519)\n"
        : "userknownhostsfile \(known.path) /another/file\n"
      return CommandResult(stdout: output, stderr: "", exitCode: 0, timedOut: false)
    }
    let driver = try driver(runner: runner)
    let key = try await driver.captureHostKey()
    XCTAssertFalse(FileManager.default.fileExists(atPath: known.path))
    XCTAssertTrue(key.fingerprint.contains("SHA256:the-fingerprint"))
    try driver.trustHostKey(key)
    XCTAssertEqual(try String(contentsOf: known, encoding: .utf8), line + "\n")
    let capture = try XCTUnwrap(runner.calls.withLock { $0.first })
    XCTAssertTrue(capture.arguments.contains("PreferredAuthentications=none"))
    XCTAssertTrue(capture.arguments.contains("StrictHostKeyChecking=accept-new"))
    XCTAssertTrue(capture.arguments.contains("GlobalKnownHostsFile=/dev/null"))
  }

  func testMarkedLeafCreationExistingRefusalAndRemovalAreFolderOnly() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let runner = Recording(local: true)
    let driver = try driver(home: home.path, runner: runner)
    let id = UUID()
    let path = home.appendingPathComponent("workrooms/one").path
    let sibling = home.appendingPathComponent("workrooms/two")
    try await driver.prepareFolder(path: path, workroom: id)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let marker = URL(
      fileURLWithPath: "\(driver.stateDirectory)/workrooms/\(id.uuidString.lowercased())")
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), path + "\n")
    do {
      try await driver.prepareFolder(path: path, workroom: UUID())
      XCTFail("accepted an existing folder")
    } catch let failure as SSHHostDriver.Failure { XCTAssertEqual(failure, .folderExists(path)) }
    let present = try await driver.folderState(path: path, workroom: id)
    XCTAssertEqual(present, .present)
    try await driver.removeFolder(path: path, workroom: id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: driver.stateDirectory))
    let calls = runner.calls.withLock { $0 }
    XCTAssertEqual(calls.last?.timeout, 600)
    let all = calls.flatMap(\.arguments).joined(separator: " ")
    for forbidden in ["sudo", "systemctl", "kill ", "destroy", "PendingMachines"] {
      XCTAssertFalse(all.contains(forbidden), all)
    }
    XCTAssertTrue(PendingMachines.entries(in: driver.directory).isEmpty)
  }

  func testMarkerMismatchOrMissingKeepsFolderAndGoneFolderSucceeds() async throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let driver = try driver(home: home.path, runner: Recording(local: true))
    let id = UUID()
    let path = home.appendingPathComponent("workrooms/one").path
    try await driver.prepareFolder(path: path, workroom: id)
    let marker = URL(
      fileURLWithPath: "\(driver.stateDirectory)/workrooms/\(id.uuidString.lowercased())")
    for contents in ["/another/folder\n", ""] {
      if contents.isEmpty {
        try FileManager.default.removeItem(at: marker)
      } else {
        try contents.write(to: marker, atomically: true, encoding: .utf8)
      }
      do {
        try await driver.removeFolder(path: path, workroom: id)
        XCTFail("removed an unverified folder")
      } catch let failure as SSHHostDriver.Failure {
        XCTAssertEqual(failure, .markerMismatch(path))
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
    try FileManager.default.removeItem(atPath: path)
    let gone = try await driver.folderState(path: path, workroom: id)
    XCTAssertEqual(gone, .gone)
    try await driver.removeFolder(path: path, workroom: id)
  }

  func testAnAncestorMovedOutsideHomeCannotCreateOrDeleteThere() async throws {
    let home = try temporaryHome()
    let outside = try temporaryHome()
    defer {
      try? FileManager.default.removeItem(at: home)
      try? FileManager.default.removeItem(at: outside)
    }
    let driver = try driver(home: home.path, runner: Recording(local: true))
    let id = UUID()
    let parent = home.appendingPathComponent("workrooms")
    let path = parent.appendingPathComponent("one").path
    try await driver.prepareFolder(path: path, workroom: id)
    try FileManager.default.moveItem(at: parent, to: outside.appendingPathComponent("moved"))
    try FileManager.default.createSymbolicLink(
      at: parent, withDestinationURL: outside.appendingPathComponent("moved"))
    do {
      try await driver.removeFolder(path: path, workroom: id)
      XCTFail("deleted through a parent moved outside home")
    } catch let failure as SSHHostDriver.Failure { XCTAssertEqual(failure, .markerMismatch(path)) }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: outside.appendingPathComponent("moved/one").path))
    do {
      try await driver.prepareFolder(
        path: parent.appendingPathComponent("nested/new").path, workroom: UUID())
      XCTFail("made a folder outside home")
    } catch {}
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: outside.appendingPathComponent("moved/nested").path))
  }
}
