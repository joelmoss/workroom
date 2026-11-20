import WorkroomWire
import XCTest

@testable import Workroom

/// The app's side of hand-off (#230): what it gets back from a real daemon. What the daemon then does
/// with the request is `vcs/crates/workroomd/tests/hand_off.rs`.
final class DaemonHandOffTests: XCTestCase {
  /// The launch with nothing to hand off, end to end: the app runs the bundled binary's `hand-off`
  /// against a live daemon that is already that binary, and the daemon says so and carries on.
  func testADaemonAlreadyRunningTheBundledBinaryIsLeftAlone() throws {
    let daemon = try DaemonHarness.start()
    defer { daemon.stop() }
    let result = DaemonHandOff.run(binary: try DaemonHarness.binaryURL(), socket: daemon.socketPath)
    XCTAssertEqual(result, "exit 0: current")
    let anyone = try XCTUnwrap(SessionIdentifier(bytes: Array(repeating: 1, count: 16)))
    XCTAssertEqual(
      DaemonControlClient(socketPath: daemon.socketPath).ownership(identifier: anyone), .notOwned,
      "the daemon should still be answering")
  }

  /// The first launch after a Sparkle update that changed only CLI commands (#680): the bundled
  /// binary is another file but the same daemon build, so the daemon says `current` and keeps
  /// running as it was.
  func testABundledBinaryWhoseCLICommandsAloneChangedIsLeftAlone() throws {
    let daemon = try DaemonHarness.start()
    defer { daemon.stop() }
    let bundled = try bundledBinary(daemonBuild: try Self.daemonBuild())
    let result = DaemonHandOff.run(binary: bundled.binary, socket: daemon.socketPath)
    XCTAssertEqual(result, "exit 0: current")
    XCTAssertEqual(try bundled.runs(), ["hand-off"], "the daemon ran the bundled binary itself")
    let anyone = try XCTUnwrap(SessionIdentifier(bytes: Array(repeating: 1, count: 16)))
    XCTAssertEqual(
      DaemonControlClient(socketPath: daemon.socketPath).ownership(identifier: anyone), .notOwned,
      "the daemon should still be answering")
  }

  /// An update that changed the daemon, and one from before daemon builds were marked: each is
  /// another daemon, so the local daemon is handed off to it.
  func testABundledBinaryWithAnotherDaemonBuildOrNoneIsHandedTo() throws {
    let daemon = try DaemonHarness.start()
    defer { daemon.stop() }
    let ours = try Self.daemonBuild()
    let other = ["0", "1"].map { String(repeating: $0, count: 64) }.first { $0 != ours }
    for build in [other, nil] {
      let bundled = try bundledBinary(daemonBuild: build)
      let result = DaemonHandOff.run(binary: bundled.binary, socket: daemon.socketPath)
      XCTAssertEqual(result, "exit 0: handed off", "daemon build \(build ?? "none")")
      XCTAssertTrue(
        try bundled.runs().contains("serve"), "daemon build \(build ?? "none") was not handed to")
    }
  }

  /// The daemon build the harness's binary states in `protocol`.
  private static func daemonBuild() throws -> String {
    let (_, output) = try SessionBackendProbe.run(
      try DaemonHarness.binaryURL(), arguments: ["protocol"], timeout: 5)
    let line = output.split(separator: "\n").first { $0.hasPrefix("daemon-build ") }
    return String(
      try XCTUnwrap(line, "no daemon-build in \(output)").dropFirst("daemon-build ".count))
  }

  /// A bundled binary as the daemon sees one: a script carrying `daemonBuild` in the marker the
  /// daemon reads (none for `nil`), that runs the harness's binary for every command and records
  /// each one.
  private func bundledBinary(daemonBuild: String?) throws -> (
    binary: URL, runs: () throws -> [String]
  ) {
    let directory = URL(
      fileURLWithPath: "/tmp/wra-bundle-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("workroom")
    let runs = directory.appendingPathComponent("runs")
    let marker = daemonBuild.map { "# WORKROOMD-DAEMON-BUILD:\($0);\n" } ?? ""
    try
      "#!/bin/sh\n\(marker)echo \"$1\" >> '\(runs.path)'\nexec '\(try DaemonHarness.binaryURL().path)' \"$@\"\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (
      script,
      {
        ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").map(
          String.init)
      }
    )
  }

  /// No daemon, no request: the first launch after a reboot has nothing to hand off.
  func testNoDaemonIsNotAnError() throws {
    let result = DaemonHandOff.run(
      binary: try DaemonHarness.binaryURL(), socket: "/tmp/wra-none-\(UUID().uuidString.prefix(8))")
    XCTAssertEqual(result, "no daemon running")
  }

  /// `DaemonHandOff.run` shares its process runner (`SessionBackendProbe.run`) with the protocol
  /// probe, refactored in this change from a fixed `["protocol"]` invocation to a general one. A
  /// binary that never answers is killed and reported as a timeout rather than left to hang the
  /// 7s `DaemonHandOff.timeout` forever — `exec sleep` so the timed-out process IS the sleep (no
  /// child of its own left holding the pipe once killed, the way a plain `sleep` inside `sh`
  /// would).
  func testARunnerThatNeverAnswersIsKilledAndReportedAsATimeout() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wra-hang-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("hangs")
    try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    XCTAssertThrowsError(
      try SessionBackendProbe.run(script, arguments: [], timeout: 0.3)
    ) { error in
      XCTAssertEqual(error as? SessionBackendProbe.ProbeError, .timedOut(0.3))
    }
  }
}
