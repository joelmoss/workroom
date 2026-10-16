import Foundation
import WorkroomSystem
import XCTest

@testable import HostDrivers

/// The `$log` sink (#483): each line names its step, a command is logged as `$ <command line>`
/// with its output, and nothing that carries a credential reaches it.
final class ProvisioningLogTests: XCTestCase {
  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ step: ProvisioningProgress.Step, _ line: String) {
      lock.withLock { storage.append("\(step):\(line)") }
    }
    var all: [String] { lock.withLock { storage } }
  }

  private struct Canned: StatusCommandRunning {
    let result: CommandResult
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    { result }
  }

  func testStepAnnouncesAndFilesLinesUnderTheStep() async {
    let lines = Lines()
    let reported = Lines()
    let sink: @Sendable (ProvisioningProgress.Step, String) -> Void = { lines.add($0, $1) }
    let announce: @Sendable (ProvisioningProgress.Step) -> Void = { reported.add($0, "start") }
    await ProvisioningProgress.$log.withValue(sink) {
      await ProvisioningProgress.$reportStep.withValue(announce) {
        await ProvisioningProgress.step(.image) {
          ProvisioningProgress.record("one")
          await ProvisioningProgress.step(.machine, report: false) {
            ProvisioningProgress.record("two")
          }
        }
        ProvisioningProgress.record("outside")
      }
    }
    XCTAssertEqual(lines.all, ["image:one", "machine:two"])
    XCTAssertEqual(reported.all, ["image:start"])
  }

  func testCommandLineHidesEnvironmentAndTokens() {
    let line = ProvisioningProgress.commandLine(
      "docker",
      [
        "run", "--env", "AUTHORIZED_KEY=ssh-ed25519 AAAA secret", "-e", "GH_TOKEN=ghp_abc",
        "--env=PLAIN=value", "--token", "tok123", "--password=pw", "API_TOKEN=xyz", "--name",
        "workroom-1", "image",
      ])
    for secret in ["AAAA", "ghp_abc", "value", "tok123", "pw", "xyz"] {
      XCTAssertFalse(line.contains(secret), "\(secret) leaked: \(line)")
    }
    XCTAssertEqual(
      line,
      "$ docker run --env AUTHORIZED_KEY=… -e GH_TOKEN=… --env=PLAIN=… --token … --password=… "
        + "API_TOKEN=… --name workroom-1 image")
  }

  func testBoxdCommandIsLoggedWithItsOutputAndNoEnvironment() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let credentials = BoxdHostDriver.credentialsFile(home: home)
    try FileManager.default.createDirectory(
      at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"token":"boxd-secret-token"}"#.utf8).write(to: credentials)
    defer { try? FileManager.default.removeItem(at: home) }
    let driver = BoxdHostDriver(
      configuration: .init(cli: URL(fileURLWithPath: "/usr/local/bin/boxd"), home: home),
      directory: home,
      runner: Canned(
        result: CommandResult(
          stdout: #"{"user_id":"u1","active_org":null}"#, stderr: "", exitCode: 0, timedOut: false))
    )
    let lines = Lines()
    let sink: @Sendable (ProvisioningProgress.Step, String) -> Void = { lines.add($0, $1) }
    _ = try await ProvisioningProgress.$log.withValue(sink) {
      try await ProvisioningProgress.step(.account, report: false) { try await driver.signedIn() }
    }
    let logged = lines.all.joined(separator: "\n")
    XCTAssertTrue(logged.contains("account:$ boxd auth --json"), logged)
    XCTAssertTrue(logged.contains(#"account:{"user_id":"u1","active_org":null}"#), logged)
    XCTAssertFalse(logged.contains("boxd-secret-token"), logged)
    XCTAssertFalse(logged.contains("HOME"), logged)
  }
}
