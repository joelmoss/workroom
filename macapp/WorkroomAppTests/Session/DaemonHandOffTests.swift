import DaemonConnection
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
  /// `Contents/Resources/workroom`. `WR_FORMER_DAEMON` (`TEST_RUNNER_WR_FORMER_DAEMON`) names a
  /// real pre-swap build to run at the old path (`macapp/Scripts/build-pre-swap-daemon.sh`),
  /// started by its own attach as the older app's pane started it. `none`, or unset outside CI,
  /// puts this build's own binary there, the case where the daemon would answer `current` unasked.
  /// In CI (`CI`, which `make app-test` passes on) it must be set: ci-app.yml's `app` job builds
  /// the pre-swap daemon, and the nightly and the release, which don't, say `none`. Through
  /// `start`, the launch's own wiring, the daemon is moved: the session, its shell and a run
  /// session are kept, the daemon runs the new path, the next launch leaves it, and a new run
  /// session starts.
  @MainActor
  func testTheFirstLaunchAfterTheSwapMovesTheDaemonToTheNewPathKeepingItsSessions() async throws {
    let app = try appBundle()
    let former = app.appendingPathComponent("Contents/MacOS/workroomd")
    let ours = app.appendingPathComponent("Contents/Resources/workroom")
    try copy(try Self.formerDaemon() ?? DaemonHarness.binaryURL(), to: former)
    let socket = app.deletingLastPathComponent().appendingPathComponent("s").path
    // Started as the older app started it: by a pane's own attach, from the old bundle's file.
    let session = UUID()
    let client = try attach(former, socket: socket, session: session, command: "/bin/sh")
    let shell = try XCTUnwrap(try shellPID(of: client), "the session's shell never answered")
    let daemon = try XCTUnwrap(peer(of: socket), "no daemon on \(socket)")
    addTeardownBlock { kill(daemon, SIGTERM) }
    let runSession = UUID()
    let run = try attach(
      former, socket: socket, session: runSession, command: "echo RUN-\"\"UP; sleep 300",
      run: true)
    XCTAssertTrue(try read(run, until: "RUN-UP").contains("RUN-UP"), "the run never started")

    // The update: the old bundle's file is gone, and the new one's is in place.
    try FileManager.default.removeItem(at: former)
    try copy(try DaemonHarness.binaryURL(), to: ours)
    XCTAssertEqual(DaemonHandOff.runningExecutable(socket: socket), former.path)

    let said = await DaemonHandOff.start(binary: ours, socket: socket, delays: [1, 1])?.value
    XCTAssertEqual(said?.last, "exit 0: handed off", "\(said ?? [])")
    XCTAssertEqual(DaemonHandOff.execPath(of: daemon), ours.path, "the daemon did not move")
    XCTAssertEqual(kill(shell, 0), 0, "the session's shell did not survive the hand-off")
    let listed = try SessionBackendProbe.run(
      ours, arguments: ["list", "--socket", socket], timeout: 5
    ).output.lowercased()
    for kept in [session, runSession] {
      XCTAssertTrue(listed.contains(kept.uuidString.lowercased()), listed)
    }
    XCTAssertFalse(
      DaemonHandOff.mustMove(running: DaemonHandOff.runningExecutable(socket: socket), to: ours),
      "the next launch would move it again")

    let next = try attach(
      ours, socket: socket, session: UUID(), command: "echo RUN-\"\"OK", run: true)
    XCTAssertTrue(
      try read(next, until: "RUN-OK").contains("RUN-OK"),
      "the moved daemon could not start a run session")
  }

  /// A move the daemon refuses for now is tried again (#681): a repository command that outlasts
  /// the hand-off's 2 s wait for it (`QUIET_TIMEOUT`) refuses the first, and a later one goes in,
  /// after which run sessions start.
  @MainActor
  func testAMoveRefusedForARepositoryCommandIsTriedAgain() async throws {
    let app = try appBundle()
    let former = app.appendingPathComponent("Contents/MacOS/workroomd")
    let ours = app.appendingPathComponent("Contents/Resources/workroom")
    try copy(try DaemonHarness.binaryURL(), to: former)
    let daemon = try DaemonHarness.start(binary: former)
    defer { daemon.stop() }
    try FileManager.default.removeItem(at: former)
    try copy(try DaemonHarness.binaryURL(), to: ours)

    let connection = try await DaemonClient.connect(host: .local, socketPath: daemon.socketPath)
    let folder = app.deletingLastPathComponent().path
    let held = Task {
      await DaemonCommandRunner(connection: connection).run(
        "git", ["-c", "alias.hold=!sleep 4", "hold"], in: folder, timeout: 20)
    }
    // Until the command holds its slot: the daemon lists it as running a repository command only
    // by refusing the hand-off, so this waits a moment of the 4 s it holds it for.
    try await Task.sleep(for: .milliseconds(500))
    let said =
      await DaemonHandOff.start(binary: ours, socket: daemon.socketPath, delays: [1, 1, 1, 1])?
      .value ?? []
    _ = await held.value
    XCTAssertGreaterThan(said.count, 1, "\(said)")
    XCTAssertTrue(said.first?.contains("repository command") == true, "\(said)")
    XCTAssertEqual(said.last, "exit 0: handed off", "\(said)")
    XCTAssertEqual(DaemonHandOff.execPath(of: daemon.pid), ours.path)
    let run = try daemon.startSession(identifier: UUID(), command: "echo RUN-\"\"OK", run: true)
    XCTAssertTrue(try read(run, until: "RUN-OK").contains("RUN-OK"))
  }

  /// Two copies of the app, both there, the daemon running the other's file (#681): the same daemon
  /// build, so nothing is moved, on this launch or the next.
  @MainActor
  func testTwoLiveCopiesOfTheAppDoNotMoveTheDaemonOnEachLaunch() async throws {
    let first = try appBundle()
    let second = try appBundle()
    let theirs = first.appendingPathComponent("Contents/Resources/workroom")
    let ours = second.appendingPathComponent("Contents/Resources/workroom")
    try copy(try DaemonHarness.binaryURL(), to: theirs)
    try copy(try DaemonHarness.binaryURL(), to: ours)
    let daemon = try DaemonHarness.start(binary: theirs)
    defer { daemon.stop() }
    for launch in 1...2 {
      let said =
        await DaemonHandOff.start(binary: ours, socket: daemon.socketPath, delays: [1])?.value
      XCTAssertEqual(said, ["exit 0: current"], "launch \(launch)")
      XCTAssertEqual(DaemonHandOff.execPath(of: daemon.pid), theirs.path, "launch \(launch)")
    }
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

  /// What moves a daemon: its file gone, or another daemon build in it. Not another path with the
  /// same daemon build, nor the bundled path however it is spelled, nor a path that can't be read.
  func testOnlyAMissingFileOrAnotherDaemonBuildMovesTheDaemon() throws {
    let app = try appBundle()
    let ours = app.appendingPathComponent("Contents/Resources/workroom")
    try Data("x WORKROOMD-DAEMON-BUILD:ab12; y".utf8).write(to: ours)
    let same = app.appendingPathComponent("Contents/MacOS/same")
    try Data("other bytes WORKROOMD-DAEMON-BUILD:ab12;".utf8).write(to: same)
    let other = app.appendingPathComponent("Contents/MacOS/other")
    try Data("WORKROOMD-DAEMON-BUILD:cd34;".utf8).write(to: other)
    let none = app.appendingPathComponent("Contents/MacOS/none")
    try Data("a Go CLI".utf8).write(to: none)
    XCTAssertFalse(DaemonHandOff.mustMove(running: nil, to: ours))
    XCTAssertFalse(DaemonHandOff.mustMove(running: "", to: ours))
    XCTAssertFalse(DaemonHandOff.mustMove(running: ours.path, to: ours))
    XCTAssertFalse(
      DaemonHandOff.mustMove(running: app.path + "/Contents/MacOS/../Resources/workroom", to: ours))
    XCTAssertFalse(DaemonHandOff.mustMove(running: same.path, to: ours), "a second copy")
    XCTAssertTrue(DaemonHandOff.mustMove(running: other.path, to: ours), "another daemon build")
    XCTAssertTrue(DaemonHandOff.mustMove(running: none.path, to: ours), "no daemon build")
    XCTAssertTrue(
      DaemonHandOff.mustMove(running: app.path + "/Contents/MacOS/workroomd", to: ours), "gone")
  }

  /// What is tried again: a refusal for now, never one that says no for good.
  func testOnlyARefusalForNowIsTriedAgain() {
    for transient in [
      "exit 1: error: a repository command is still running; try again when it finishes",
      "exit 1: error: a session is being ended or repainted; try again when it finishes",
      "exit 1: error: a filesystem operation is still stuck on a mount; try again when it returns",
      "exit 1: error: another hand-off is in progress",
      "exit 92: error: no daemon listening on /x",
      SessionBackendProbe.ProbeError.timedOut(DaemonHandOff.timeout).localizedDescription,
    ] {
      XCTAssertTrue(DaemonHandOff.isTransient(transient), transient)
    }
    for final in [
      "exit 0: handed off", "exit 0: current", "exit 3: the daemon predates hand-off",
      "exit 1: error: /x is build 1, older than this daemon's build 2",
    ] {
      XCTAssertFalse(DaemonHandOff.isTransient(final), final)
    }
  }

  /// `binary attach` for `session` on `socket`, as a pane runs it: from the environment the app
  /// exports, so a missing daemon is started from `binary`.
  private func attach(
    _ binary: URL, socket: String, session: UUID, command: String, run: Bool = false
  ) throws -> Process {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["attach"]
    var environment = [
      "WORKROOM_SESSION_SOCKET": socket, "WORKROOM_SESSION_ID": session.uuidString,
      "WORKROOM_SESSION_COMMAND": command, "WORKROOM_SESSION_SHELL": "/bin/sh",
      "WORKROOM_SESSION_CWD": NSTemporaryDirectory(), "TERM": "dumb", "PATH": "/bin:/usr/bin",
      "SHELL": "/bin/sh",
    ]
    if run { environment["WORKROOM_SESSION_RUN"] = "1" }
    process.environment = environment
    process.standardInput = Pipe()
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    try process.run()
    addTeardownBlock { if process.isRunning { process.terminate() } }
    return process
  }

  /// The pid of the daemon listening on `socket`.
  private func peer(of socket: String) -> pid_t? {
    for _ in 0..<100 {
      guard var address = PersistentSessionControlClient.address(for: socket) else { return nil }
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      defer { close(descriptor) }
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
      }
      var pid: pid_t = 0
      var length = socklen_t(MemoryLayout<pid_t>.size)
      if connected, getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 {
        return pid
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return nil
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

  /// The pre-swap daemon `WR_FORMER_DAEMON` names, or `nil` for this build's own binary: when it
  /// says `none`, or is unset outside CI. A CI run without it fails rather than quietly testing
  /// the easy case, as does a path that is no executable file.
  private static func formerDaemon() throws -> URL? {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["WR_FORMER_DAEMON"], !path.isEmpty else {
      if let ci = environment["CI"], !ci.isEmpty {
        throw FormerDaemonError(
          "CI=\(ci) but TEST_RUNNER_WR_FORMER_DAEMON is unset: build the pre-swap daemon with "
            + "macapp/Scripts/build-pre-swap-daemon.sh and name it, or say `none`")
      }
      return nil
    }
    if path == "none" { return nil }
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw FormerDaemonError("TEST_RUNNER_WR_FORMER_DAEMON=\(path) is no executable file")
    }
    return URL(fileURLWithPath: path)
  }

  private struct FormerDaemonError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
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
