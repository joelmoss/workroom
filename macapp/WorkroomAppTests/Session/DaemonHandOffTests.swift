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

  // MARK: - The swap (#681)

  /// The first launch after the swap (#681, ADR 0078): the daemon the older app started runs
  /// `Contents/MacOS/workroomd`, which the update took away, and this build's one binary is
  /// `Contents/Resources/workroom`. The daemon is moved to it even when it is the same daemon
  /// build, which is the case this uses (this build's own binary at the old path) since it is the
  /// one where the daemon answers `current` unasked: `WR_FORMER_DAEMON`
  /// (`TEST_RUNNER_WR_FORMER_DAEMON`) names a real pre-swap build to run there instead. The session
  /// and its shell are kept, and the daemon runs the new path after, so a run session, which it
  /// starts from its own path (`run-supervisor`), works.
  func testTheFirstLaunchAfterTheSwapMovesTheDaemonToTheNewPathKeepingItsSessions() throws {
    let app = try appBundle()
    let former = app.appendingPathComponent("Contents/MacOS/workroomd")
    let ours = app.appendingPathComponent("Contents/Resources/workroom")
    let formerBuild =
      ProcessInfo.processInfo.environment["WR_FORMER_DAEMON"].map(URL.init(fileURLWithPath:))
    try copy(try formerBuild ?? DaemonHarness.binaryURL(), to: former)
    let daemon = try DaemonHarness.start(binary: former)
    defer { daemon.stop() }
    let session = UUID()
    let client = try daemon.startSession(identifier: session, command: "/bin/sh")
    let shell = try XCTUnwrap(try shellPID(of: client), "the session's shell never answered")

    // The update: the old bundle's file is gone, and the new one's is in place.
    try FileManager.default.removeItem(at: former)
    try copy(try DaemonHarness.binaryURL(), to: ours)

    let running = DaemonHandOff.runningExecutable(socket: daemon.socketPath)
    XCTAssertEqual(running, former.path, "the daemon's exec path, though its file is gone")
    XCTAssertTrue(DaemonHandOff.mustMove(running: running, to: ours))
    let result = DaemonHandOff.run(binary: ours, socket: daemon.socketPath, force: true)
    XCTAssertEqual(result, "exit 0: handed off")
    XCTAssertEqual(DaemonHandOff.execPath(of: daemon.pid), ours.path, "the daemon did not move")
    XCTAssertEqual(kill(shell, 0), 0, "the session's shell did not survive the hand-off")
    let listed = try SessionBackendProbe.run(
      ours, arguments: ["list", "--socket", daemon.socketPath], timeout: 5
    ).output
    XCTAssertTrue(listed.lowercased().contains(session.uuidString.lowercased()), listed)
    XCTAssertFalse(
      DaemonHandOff.mustMove(
        running: DaemonHandOff.runningExecutable(socket: daemon.socketPath), to: ours),
      "the next launch would move it again")

    let run = try daemon.startSession(identifier: UUID(), command: "echo RUN-\"\"OK", run: true)
    XCTAssertTrue(
      try read(run, until: "RUN-OK").contains("RUN-OK"),
      "the moved daemon could not start a run session from its own path")
  }

  /// The negative control: an update that replaces the binary at the same path (a Sparkle update
  /// after the swap) leaves the daemon's exec path equal, so nothing is forced, and a binary of the
  /// same daemon build stays `current` (#680).
  func testAnUpdateThatReplacesTheBinaryAtTheSamePathForcesNothing() throws {
    let app = try appBundle()
    let ours = app.appendingPathComponent("Contents/Resources/workroom")
    try copy(try DaemonHarness.binaryURL(), to: ours)
    let daemon = try DaemonHarness.start(binary: ours)
    defer { daemon.stop() }
    let staged = app.appendingPathComponent("Contents/Resources/.workroom-update")
    try copy(try DaemonHarness.binaryURL(), to: staged)
    XCTAssertEqual(rename(staged.path, ours.path), 0, "the update's rename")

    let running = DaemonHandOff.runningExecutable(socket: daemon.socketPath)
    XCTAssertEqual(running, ours.path)
    XCTAssertFalse(DaemonHandOff.mustMove(running: running, to: ours))
    XCTAssertEqual(DaemonHandOff.run(binary: ours, socket: daemon.socketPath), "exit 0: current")
  }

  /// What moves a daemon: another path, however it is spelled; never an unreadable one.
  func testOnlyAReadablePathThatIsNotTheBundledBinaryMovesTheDaemon() {
    let ours = URL(fileURLWithPath: "/Applications/Workroom.app/Contents/Resources/workroom")
    XCTAssertFalse(DaemonHandOff.mustMove(running: nil, to: ours))
    XCTAssertFalse(DaemonHandOff.mustMove(running: "", to: ours))
    XCTAssertFalse(DaemonHandOff.mustMove(running: ours.path, to: ours))
    XCTAssertFalse(
      DaemonHandOff.mustMove(
        running: "/Applications/Workroom.app/Contents/MacOS/../Resources/workroom", to: ours))
    XCTAssertTrue(
      DaemonHandOff.mustMove(
        running: "/Applications/Workroom.app/Contents/MacOS/workroomd", to: ours))
    XCTAssertTrue(
      DaemonHandOff.mustMove(
        running: "/Users/me/Downloads/Workroom.app/Contents/Resources/workroom", to: ours))
  }

  /// An app bundle's skeleton in a folder of this test's own, removed after it.
  private func appBundle() throws -> URL {
    let root = URL(
      fileURLWithPath: "/tmp/wra-swap-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Workroom.app")
    for folder in ["Contents/MacOS", "Contents/Resources"] {
      try FileManager.default.createDirectory(
        at: app.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    return app
  }

  private func copy(_ binary: URL, to url: URL) throws {
    try FileManager.default.copyItem(at: binary, to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  /// The pid the session's shell prints. Split by the quotes, so the pty's echo of the line holds
  /// `$$`, not a pid.
  private func shellPID(of client: Process) throws -> pid_t? {
    let input = try XCTUnwrap(client.standardInput as? Pipe)
    try input.fileHandleForWriting.write(contentsOf: Data("echo \"PID=$$=\"\"\"\n".utf8))
    let seen = try read(client, until: "=\r\n")
    return seen.components(separatedBy: "PID=").last?.split(separator: "=").first
      .flatMap { pid_t($0) }
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
