import Darwin
import Foundation
import XCTest

@testable import Workroom

/// The update every stable user makes (#525): Workroom v2.1.0 left its daemon running as `wr-agent`
/// on `agent.sock`, holding their terminals, and this build is `workroomd` on `daemon.sock`.
/// Tested against that daemon itself, pinned as `Fixtures/wr-agent-v2.1.0` (lifted unmodified from
/// the v2.1.0 app, sha256 c2f48815…), for the reason `SessionShimCompatibilityTests` pins v2.0.0's
/// helper: a stand-in built from this tree moves with it and cannot catch the drift.
///
/// The v2.1.0 daemon speaks protocol 1 and predates hand-off (protocol 6), so the update cannot
/// replace it in place. What keeps the terminals is that nothing tries to: the hand-off is refused
/// with the daemon untouched, the app finds it under the old name (`PersistentSessionPaths
/// .daemonSocket`), and this build's client reattaches its sessions. It goes when its last
/// terminal closes, and the next daemon is this build's, on the new name (eng review D4).
final class DaemonUpdateCompatibilityTests: XCTestCase {
  private var directory: URL!
  private var running: [Process] = []

  /// From the source tree, as the v2.0.0 fixture is: a bundle resource does not reliably keep its
  /// exec bit.
  private static let shippedDaemon = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Session/
    .deletingLastPathComponent()  // WorkroomAppTests/
    .appendingPathComponent("Fixtures/wr-agent-v2.1.0")

  override func setUpWithError() throws {
    try super.setUpWithError()
    // sun_path is 104 bytes; the per-test temporary directory blows that on its own.
    directory = URL(fileURLWithPath: "/tmp/wr-update-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    for process in running where process.isRunning { process.terminate() }
    for process in running { process.waitUntilExit() }
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  func testAV210DaemonKeepsItsTerminalsAndThisBuildReattachesThem() throws {
    guard FileManager.default.isExecutableFile(atPath: Self.shippedDaemon.path) else {
      XCTFail("the pinned v2.1.0 daemon is missing or not executable: check its mode in git")
      return
    }
    let bundled = try XCTUnwrap(
      PersistentSessionPaths.binaryURL(for: .daemon), "this build's workroomd is not bundled")
    let socket = directory.appendingPathComponent("agent.sock").path

    // The daemon v2.1.0 started, holding a terminal with something on its screen.
    let daemon = try start(
      Self.shippedDaemon, ["serve", "--socket", socket, "--idle-timeout", "60"])
    XCTAssertTrue(
      wait(10) { PersistentSessionPaths.answers(socket) }, "the v2.1.0 daemon never accepted")
    let session = UUID().uuidString
    let client = try start(
      Self.shippedDaemon, ["attach", "--socket", socket, "--session", session], input: true)
    try type("echo BEF\"\"ORE-UPDATE; echo \"PID=$$=\"", into: client)
    let shell = try XCTUnwrap(
      pid(in: try read(client, until: "=\r\n")), "the v2.1.0 session never answered")
    client.terminate()
    client.waitUntilExit()
    XCTAssertTrue(
      wait(5) {
        (try? self.run(bundled, ["list", "--socket", socket]).output)?
          .contains("detached") == true
      },
      "the session never detached")

    // The app finds it under the old name, so it neither starts a second daemon nor misses it.
    let found = PersistentSessionPaths.daemonSocket(
      preferredDirectory: directory.path, fallbackDirectory: "/nonexistent",
      answers: { path in
        PersistentSessionPaths.answers(path)
      })
    XCTAssertEqual(found.live, socket)

    // The update's hand-off is refused, and refusing changes nothing.
    let handOff = try run(
      bundled, ["hand-off", "--socket", socket, "--binary", bundled.path])
    XCTAssertEqual(handOff.status, 3, "a daemon that predates hand-off is not asked: \(handOff)")
    XCTAssertTrue(daemon.isRunning, "the v2.1.0 daemon was stopped")
    XCTAssertEqual(kill(shell, 0), 0, "the terminal's shell did not survive the update")

    // This build's client lists and reattaches the terminal the v2.1.0 daemon holds.
    let listed = try run(bundled, ["list", "--socket", socket]).output
    XCTAssertTrue(listed.lowercased().contains(session.lowercased()), listed)
    let reattached = try start(
      bundled, ["attach", "--socket", socket, "--session", session, "--no-create"], input: true)
    try type("echo SAME=\"\"$$=", into: reattached)
    XCTAssertTrue(
      try read(reattached, until: "SAME=\(shell)=").contains("SAME=\(shell)="),
      "another shell answered: the v2.1.0 session was not reattached")
  }

  // MARK: - Harness

  private func start(_ binary: URL, _ arguments: [String], input: Bool = false) throws -> Process {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    if input { process.standardInput = Pipe() }
    try process.run()
    running.append(process)
    return process
  }

  private func type(_ line: String, into process: Process) throws {
    let input = try XCTUnwrap(process.standardInput as? Pipe)
    // Split from its output by the quotes, so the pty's echo of the line never matches.
    try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
  }

  /// What `process` has written by the time `marker` appears, or within 10 seconds.
  private func read(_ process: Process, until marker: String) throws -> String {
    let handle = try XCTUnwrap(process.standardOutput as? Pipe).fileHandleForReading
    var seen = ""
    let deadline = Date().addingTimeInterval(10)
    let flags = fcntl(handle.fileDescriptor, F_GETFL)
    _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    while Date() < deadline, !seen.contains(marker) {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
      if count > 0 {
        seen += String(decoding: buffer[0..<count], as: UTF8.self)
      } else {
        Thread.sleep(forTimeInterval: 0.02)
      }
    }
    return seen
  }

  /// The last `PID=<n>=` the shell printed: the pty's echo of the command holds `$$`, not a pid.
  private func pid(in output: String) -> pid_t? {
    output.components(separatedBy: "PID=").last?.split(separator: "=").first
      .flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
  }

  private func run(_ binary: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
  }
}
