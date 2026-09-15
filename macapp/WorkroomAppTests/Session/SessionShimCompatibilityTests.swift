import Darwin
import Foundation
import WorkroomSessionProtocol
import XCTest

@testable import Workroom

/// The attach-only `workroom-session` against the daemon it actually has to talk to: the one
/// shipped in **v2.0.0**, pinned as a binary fixture.
///
/// **Why a pinned binary and not a fake.** The obvious cheap version of this test is a stub that
/// binds a socket and answers with `SessionFrame`s. It proves nothing. A fake built from
/// `WorkroomSessionProtocol` reads the same source the client does, so a change to that module
/// moves both sides together and the test stays green through exactly the break it was written to
/// catch. The only peer whose behaviour cannot drift with our source tree is a binary that was
/// compiled before it: `Fixtures/workroom-session-v2.0.0`, lifted unmodified from
/// `workroom-macos-app_2.0.0.dmg` (sha256 6f75e6f7…), which is what users in the field are running.
///
/// This is the whole justification for keeping the client half of `macapp/WorkroomSession/` at all.
/// If these fail, a user who updates while holding a terminal from an older build loses it — see
/// `docs/designs/remote-workrooms.md`. **`WorkroomSessionProtocol` is frozen while the shim ships**
/// precisely because this peer can never be recompiled to match a change.

/// Thrown after an `XCTFail` so the test stops without the failure being reported as a skip.
private enum CompatibilityFixtureError: Error {
  case unusable
}

final class SessionShimCompatibilityTests: XCTestCase {
  private var directory: URL!
  private var daemon: Process?

  override func setUpWithError() throws {
    try super.setUpWithError()
    // sun_path is 104 bytes; the per-test temporary directory blows that on its own.
    directory = URL(fileURLWithPath: "/tmp/wr-compat-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let daemon, daemon.isRunning {
      daemon.terminate()
      daemon.waitUntilExit()
    }
    daemon = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  /// The property the shim exists for: a session created by the v2.0.0 daemon, whose creating
  /// client has since gone away, is reattachable by THIS build — and the reattaching client is
  /// handed the output the shell produced before it existed.
  ///
  /// Asserting on the replayed marker rather than on "no error" is deliberate. A client that
  /// connects, fails the handshake and exits quietly would pass a liveness check; only bytes that
  /// originated in the old daemon's pty prove the session was really reached.
  func testReattachesASessionTheShippedDaemonHolds() throws {
    let socketPath = try startShippedDaemon()
    let sessionID = SessionIdentifier(UUID())
    let marker = "SHIM-COMPAT-\(UUID().uuidString.prefix(8))"
    let sentinel = directory.appendingPathComponent("printed").path

    // Created by the SHIPPED client, then detached: `/dev/null` on stdin ends it immediately while
    // the daemon keeps the pty, which is exactly the state a user's machine is left in when they
    // quit an older build of the app.
    let creator = try run(
      Self.shippedBinaryURL, arguments: ["attach"],
      environment: attachEnvironment(
        sessionID: sessionID, socketPath: socketPath,
        command: "sh -c 'echo \(marker); touch \(sentinel); sleep 120'"))
    creator.waitUntilExit()

    // Wait for the marker to be firmly in the PAST before attaching. Without this the new client
    // could be receiving it as live output and the test would pass either way — it would prove the
    // session exists, not that its history was replayed, which is the property a user notices.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !FileManager.default.fileExists(atPath: sentinel) {
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: sentinel),
      "the v2.0.0 daemon never ran the session's command; nothing to replay")

    let output = try attachWithCurrentBuild(sessionID: sessionID, socketPath: socketPath)

    XCTAssertTrue(
      output.contains(marker),
      """
      the attach-only client did not receive the v2.0.0 daemon's REPLAY for a session it holds — \
      the marker was already printed before this client connected. A user updating with a terminal \
      open would come back to a blank pane. Got: \(output.suffix(400))
      """)
  }

  /// **Typing.** The reattach test above proves bytes flow from the daemon to the pane; this one
  /// proves they flow the other way, which is the half a user notices within a second of coming
  /// back to a restored terminal.
  ///
  /// The observable is a file, not the echo. Echo would also appear if the client merely rendered
  /// what was typed locally without it ever reaching the session, which is exactly the failure
  /// worth catching.
  func testTypingInTheReattachedPaneReachesTheV2Session() throws {
    let socketPath = try startShippedDaemon()
    let session = try startShellSession(on: socketPath)
    let sentinel = directory.appendingPathComponent("typed").path

    let attached = try attachInteractively(
      sessionID: session.identifier, socketPath: socketPath)
    defer { attached.terminate() }
    XCTAssertTrue(
      attached.text().contains(session.marker),
      "this client got a session the daemon made for it, not the one already running")
    attached.type("touch \(sentinel)\n")

    XCTAssertTrue(
      waitForFile(at: sentinel),
      """
      keystrokes did not reach a session the v2.0.0 daemon holds. The pane repaints and then \
      ignores the user. got: \(attached.text().suffix(400))
      """)
  }

  /// **Ending.** The session's shell exits, and the pane must go with it carrying the same status.
  ///
  /// Everything else in this file is about a relay that must NOT exit (`wait_after_command` is
  /// false, so exiting leaves a dead pane). This is the one case where exiting is correct, and the
  /// two are one `if` apart in the same function — so the ordinary end of a terminal gets a test
  /// beside the failures.
  func testTheV2SessionsExitStatusBecomesTheClientsExitStatus() throws {
    let socketPath = try startShippedDaemon()
    let session = try startShellSession(on: socketPath)

    let attached = try attachInteractively(
      sessionID: session.identifier, socketPath: socketPath)
    defer { attached.terminate() }
    XCTAssertTrue(
      attached.text().contains(session.marker),
      "this client got a session the daemon made for it, not the one already running")
    attached.type("exit 7\n")

    XCTAssertTrue(
      attached.waitUntilExit(within: 10),
      "the client outlived the session's shell. got: \(attached.text().suffix(400))")
    XCTAssertEqual(
      attached.status(), 7,
      """
      the session exited 7 and the pane reported \(attached.status()). A shell's exit status is \
      what a script wrapping the pane reads, and 0 for a failed command is worse than no status.
      """)
    XCTAssertFalse(
      attached.text().contains("will not survive quitting"),
      "a clean session exit took the fallback path, which is for a FAILED attach")
  }

  /// **The control plane, not just the pty.** `list`, `info` and `kill` are how the app enumerates
  /// and tears down sessions, and this build sends all three at a daemon it can never recompile.
  ///
  /// `ownership(identifier:)` is in here on purpose: it is the newest method on the protocol —
  /// added because `list()` folds "no reply" into `[]` — and it is the one the reattach guard
  /// consults before letting a pane attach. Its answer against the REAL v2.0.0 daemon is the thing
  /// that decides whether a user's terminal is reconnected or replaced.
  func testTheControlPlaneStillWorksAgainstTheShippedDaemon() throws {
    let socketPath = try startShippedDaemon()
    let session = try startShellSession(on: socketPath)
    let client = PersistentSessionControlClient(socketPath: socketPath)

    let listed = client.list()
    XCTAssertTrue(
      listed.contains { $0.identifier == session.identifier },
      "this build's `list` could not see a session the v2.0.0 daemon is holding: \(listed)")
    XCTAssertEqual(client.info(identifier: session.identifier)?.identifier, session.identifier)
    guard case .owned = client.ownership(identifier: session.identifier) else {
      return XCTFail("the daemon holds this session but did not claim it, so a reattach is refused")
    }

    XCTAssertTrue(
      client.kill(identifier: session.identifier),
      "the v2.0.0 daemon refused this build's `kill`; closing a pane would leave the pty behind")

    // Killed, then gone: the daemon reaps asynchronously, so poll rather than assert on the next
    // line and call a race a regression.
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if !client.list().contains(where: { $0.identifier == session.identifier }) { break }
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertFalse(
      client.list().contains { $0.identifier == session.identifier },
      "the session survived a kill this build acknowledged")
    guard case .notOwned = client.ownership(identifier: session.identifier) else {
      return XCTFail(
        """
        a killed session still reads as owned, so a pane would attach to it — and the v2.0.0 \
        daemon creates on attach, which silently replaces the user's shell with a fresh one.
        """)
    }
  }

  /// The version handshake, ported from the deleted `SessionDaemonEndToEndTests` — the only test
  /// anywhere that exercised it, and the one most likely to be broken by an edit to
  /// `WorkroomSessionProtocol` made for the app's own control client.
  ///
  /// Driven straight against the SHIPPED daemon rather than a rebuilt one, so it measures the
  /// agreement that actually matters: what this tree encodes against what v2.0.0 decodes.
  func testTheShippedDaemonRefusesAFutureProtocolVersion() throws {
    let socketPath = try startShippedDaemon()
    var client = try SessionTestClient.connect(socketPath: socketPath)
    defer { client.closeConnection() }

    let request = SessionAttachRequest(
      version: SessionProtocolVersion.current + 1,
      identifier: SessionIdentifier(UUID()),
      columns: 80,
      rows: 24,
      workingDirectory: "/",
      command: "",
      shell: "/bin/sh",
      resourcesDirectory: "",
      environment: [])
    try client.send(SessionFrame(kind: .attach, payload: request.encoded()))

    let failure = try client.wait(for: .failure, timeout: 5)
    let message = try SessionTextPayload.decode(failure.payload)
    XCTAssertTrue(message.contains("different version"), message)
  }

  /// The current version is accepted by the same peer. Without this, the test above passes just as
  /// well when EVERY version is refused — which is what a real encoding break looks like.
  func testTheShippedDaemonAcceptsTheCurrentProtocolVersion() throws {
    let socketPath = try startShippedDaemon()
    var client = try SessionTestClient.connect(socketPath: socketPath)
    defer { client.closeConnection() }

    let request = SessionAttachRequest(
      identifier: SessionIdentifier(UUID()),
      columns: 80,
      rows: 24,
      workingDirectory: directory.path,
      command: "sh -c 'sleep 30'",
      shell: "/bin/sh",
      resourcesDirectory: "",
      environment: [])
    try client.send(SessionFrame(kind: .attach, payload: request.encoded()))

    XCTAssertNoThrow(
      try client.wait(for: .attached, timeout: 5),
      "v2.0.0 refused a request encoded by this tree — WorkroomSessionProtocol has drifted")
  }

  // MARK: - The attach-only client's own failure modes

  /// The retirement itself, asserted against the shipped binary rather than against the source.
  ///
  /// `workroom-session daemon` started a pty daemon in v2.0.0. This build must not: every new
  /// session belongs to `wr-agent`, and a daemon started now would hold none of the sessions this
  /// client exists to reach — it would bind the socket the OLD daemon's sessions live on and
  /// answer for none of them.
  func testTheDaemonSubcommandIsGone() throws {
    let socketPath = directory.appendingPathComponent("never.sock").path
    let (output, status) = try runCapturing(
      arguments: ["daemon", "--socket", socketPath], environment: [:])

    XCTAssertEqual(status, 2, "`daemon` must be rejected as an unknown command. got: \(output)")
    XCTAssertTrue(
      output.contains("unknown command"), "expected an unknown-command error: \(output)")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: socketPath),
      """
      this build bound a daemon socket. The pty daemon is retired: a new one would take the socket \
      the sessions this client reattaches to are reached through, and hold none of them.
      """)

    let (usage, usageStatus) = try runCapturing(arguments: [], environment: [:])
    XCTAssertEqual(usageStatus, 2)
    XCTAssertFalse(
      usage.contains("daemon"),
      "the usage text still advertises a subcommand this binary no longer has: \(usage)")
  }

  /// Nothing listening at all: the session the client was asked to reach is gone.
  ///
  /// **The elapsed bound is the real assertion.** `connect` used to spawn a daemon and wait for it
  /// to bind — 3 cycles of 50 × 20ms, three times over, ~9.2s of a pane showing nothing before the
  /// user was told anything. With no daemon to start there is nothing to wait for, and the budget
  /// is ~0.8s. A regression that restores the wait cannot be seen any other way: the exit code and
  /// the message are the same either way.
  func testAttachWithNothingListeningFailsFastAndStartsNothing() throws {
    let socketPath = directory.appendingPathComponent("absent.sock").path
    let started = Date()
    let (output, status) = try runCapturing(
      arguments: ["attach"],
      environment: attachEnvironment(
        sessionID: SessionIdentifier(UUID()), socketPath: socketPath, command: ""))
    let elapsed = Date().timeIntervalSince(started)

    // The client BECOMES a shell rather than exiting 92, so the status is the shell's. Asserting
    // 92 here pinned the dead pane: `config.wait_after_command` is false, so a relay that exits
    // leaves nothing to read the message in. What must still hold is that it says why first.
    XCTAssertTrue(
      output.contains("no session helper is listening"),
      "the pane fell back with no explanation of why: \(output)")
    XCTAssertTrue(
      output.contains("will not survive quitting"),
      "the user was not told persistence was lost: \(output)")
    XCTAssertNotEqual(
      status, 92,
      "exiting 92 means the relay died instead of becoming a shell, which is the dead pane")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: socketPath),
      "the client started a helper. It cannot serve any session that exists, and it takes the "
        + "socket a real one would need.")
    XCTAssertLessThan(
      elapsed, 5,
      """
      the client spent \(elapsed)s before giving up. The spawn-and-wait path is gone, so the \
      budget is ~0.8s; anything near 9s means it is back and the pane shows nothing meanwhile.
      """)
  }

  /// **A helper that accepts and then says nothing.** Wedged, not absent — and nothing bounded it:
  /// `poll` blocks indefinitely once no settle check is pending, so the pane sat blank forever with
  /// no message and no exit. The connect retries above bound only a REFUSED connect, which is a
  /// different failure entirely.
  ///
  /// The peer is held open well past the 5s deadline on purpose. Closing sooner is an EOF, which
  /// takes the retry path and reports "no session helper is listening" — so a short-sleeping fake
  /// would make this test pass while measuring the wrong thing.
  func testAWedgedHelperIsGivenUpOnRatherThanHangingThePane() throws {
    let socketPath = directory.appendingPathComponent("wedged.sock").path
    let listener = try UnixSocketListener.listen(at: socketPath)
    Thread.detachNewThread {
      let accepted = accept(listener, nil, nil)
      guard accepted >= 0 else { return }
      Thread.sleep(forTimeInterval: 12)
      close(accepted)
    }
    defer { close(listener) }

    let process = Process()
    process.executableURL = try Self.currentBinaryURL()
    process.arguments = ["attach"]
    process.environment = attachEnvironment(
      sessionID: SessionIdentifier(UUID()), socketPath: socketPath, command: "")
    let output = Pipe()
    // Held open for the whole run: a client whose stdin is already at EOF takes a different exit
    // out of the poll loop, and this test would never reach the deadline it exists to measure.
    let input = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = input

    // Collected incrementally rather than by reading to EOF. The client no longer EXITS on this
    // path — it becomes a shell, which inherits the held-open stdin and waits forever — so the
    // observable is the message arriving in time, not the process ending. Reading to EOF here is
    // what made this test sit until its own watchdog fired.
    let collected = NSMutableData()
    let lock = NSLock()
    let sawNotice = XCTestExpectation(description: "the client reports giving up")
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      lock.lock()
      collected.append(data)
      let seen = String(decoding: collected as Data, as: UTF8.self)
      lock.unlock()
      if seen.contains("did not answer the attach request") { sawNotice.fulfill() }
    }

    let started = Date()
    try process.run()
    // A regression here is an infinite wait, which would hang the whole suite rather than fail it.
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: watchdog)
    let outcome = XCTWaiter().wait(for: [sawNotice], timeout: 20)
    let elapsed = Date().timeIntervalSince(started)

    input.fileHandleForWriting.closeFile()
    process.terminate()
    process.waitUntilExit()
    watchdog.cancel()
    output.fileHandleForReading.readabilityHandler = nil
    lock.lock()
    let text = String(decoding: collected as Data, as: UTF8.self)
    lock.unlock()

    XCTAssertEqual(
      outcome, .completed,
      """
      the client never gave up on a helper that accepted the connection and then went silent. The \
      pane shows nothing, forever, with no message and no exit. got: \(text)
      """)
    XCTAssertLessThan(elapsed, 20, "gave up, but not within its own deadline. got: \(text)")
    XCTAssertTrue(
      text.contains("will not survive quitting"),
      """
      the client gave up and then exited instead of becoming a shell, which leaves the pane dead — \
      `wait_after_command` is false, so there is nothing left to read the message in. got: \(text)
      """)
    XCTAssertFalse(
      text.contains("no session helper is listening"),
      """
      a helper that ACCEPTED the connection was reported as absent. That message is the retry \
      path's, and retrying a slow peer makes it redo the introspection and replay each attempt \
      already paid for — it cannot converge. got: \(text)
      """)
  }

  // MARK: - Harness

  /// The pinned fixture, located from the source tree rather than the test bundle: an executable
  /// copied as a bundle resource does not reliably keep its exec bit, and `#filePath` is stable for
  /// every configuration this suite runs in.
  private static let shippedBinaryURL: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Session/
    .deletingLastPathComponent()  // WorkroomAppTests/
    .appendingPathComponent("Fixtures/workroom-session-v2.0.0")

  /// This build's `workroom-session`, beside the test host in the products directory.
  private static func currentBinaryURL() throws -> URL {
    for key in ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR"] {
      guard let directory = ProcessInfo.processInfo.environment[key] else { continue }
      let url = URL(fileURLWithPath: directory).appendingPathComponent("workroom-session")
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    let embedded = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/MacOS/workroom-session")
    if FileManager.default.isExecutableFile(atPath: embedded.path) { return embedded }
    var candidate = Bundle(for: SessionShimCompatibilityTests.self).bundleURL
    for _ in 0..<6 {
      let url = candidate.appendingPathComponent("workroom-session")
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
      candidate.deleteLastPathComponent()
    }
    // This build's own product, not an optional dependency: if it is missing the target did not
    // build, which is a failure however the suite was invoked.
    XCTFail("this build's workroom-session was not found beside the test bundle")
    throw CompatibilityFixtureError.unusable
  }

  /// **A missing fixture skips; a fixture that will not RUN fails.**
  ///
  /// The difference matters more than it looks. "Not checked out" is an environmental absence. "The
  /// pinned binary is here and cannot start" — a broken signature, quarantine, a future macOS
  /// refusing an old Mach-O — is this test's own subject failing, and reporting that as a skip would
  /// let all three tests in this file stop running indefinitely while the suite stayed green. That
  /// is precisely the wire-compatibility claim the whole change rests on, and `make app-test` does
  /// not print a summary under Xcode 26, so nobody would notice.
  private func startShippedDaemon() throws -> String {
    guard FileManager.default.fileExists(atPath: Self.shippedBinaryURL.path) else {
      throw XCTSkip("v2.0.0 fixture not present at \(Self.shippedBinaryURL.path)")
    }
    guard FileManager.default.isExecutableFile(atPath: Self.shippedBinaryURL.path) else {
      XCTFail("the pinned v2.0.0 fixture is present but not executable — check its mode in git")
      throw CompatibilityFixtureError.unusable
    }
    let socketPath = directory.appendingPathComponent("s.sock").path
    daemon = try run(
      Self.shippedBinaryURL,
      arguments: ["daemon", "--socket", socketPath, "--idle-timeout", "30000"],
      environment: [:])

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) { return socketPath }
      if let daemon, !daemon.isRunning { break }
      Thread.sleep(forTimeInterval: 0.02)
    }
    let status = daemon.map { $0.isRunning ? "still running" : "exited \($0.terminationStatus)" }
    XCTFail(
      """
      the pinned v2.0.0 daemon never bound \(socketPath) (\(status ?? "not started")). The fixture \
      is present, so this is the compatibility subject failing, not a missing test dependency — \
      do not downgrade it to a skip.
      """)
    throw CompatibilityFixtureError.unusable
  }

  /// Runs THIS build's attach client against the shipped daemon, holding stdin open with a pipe so
  /// the client stays attached long enough to be served, and returns everything it wrote.
  private func attachWithCurrentBuild(
    sessionID: SessionIdentifier, socketPath: String
  ) throws -> String {
    let process = Process()
    process.executableURL = try Self.currentBinaryURL()
    process.arguments = ["attach"]
    process.environment = attachEnvironment(
      sessionID: sessionID, socketPath: socketPath, command: "")
    let output = Pipe()
    let input = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = input
    try process.run()

    // Read on a background queue: the client streams until its stdin closes, and reading to EOF on
    // this thread would deadlock against our own write end being open.
    let collected = NSMutableData()
    let lock = NSLock()
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      lock.lock()
      collected.append(data)
      lock.unlock()
    }

    // Wait for the reattach to actually produce something, then for it to stop producing, rather
    // than for a fixed three seconds. A flat sleep is wrong in both directions: it is three seconds
    // of test time on every run, and on a loaded machine it is still not enough — the daemon has to
    // accept, look the session up and replay its buffer before a single byte is due.
    let settled = Self.waitForOutputToSettle(collected, lock: lock)
    XCTAssertTrue(
      settled, "the shipped daemon sent nothing within \(Self.attachCeiling)s of the attach")
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    output.fileHandleForReading.readabilityHandler = nil

    lock.lock()
    defer { lock.unlock() }
    return String(decoding: collected as Data, as: UTF8.self)
  }

  /// How long a reattach gets before we call it a failure. Generous on purpose: this bounds a
  /// process spawn, a connect and a replay on whatever machine CI gave us, and the poll below
  /// returns as soon as the output settles, so the ceiling is only ever paid by a real failure.
  private static let attachCeiling: TimeInterval = 10

  /// True once the client has written something and then gone quiet for `quiet` seconds.
  ///
  /// Quiescence, not just non-empty: the replay arrives in several writes and asserting on the
  /// first of them would read a prefix of the screen.
  private static func waitForOutputToSettle(
    _ collected: NSMutableData, lock: NSLock, quiet: TimeInterval = 0.25
  ) -> Bool {
    let deadline = Date().addingTimeInterval(attachCeiling)
    var lastLength = 0
    var lastChange = Date()
    while Date() < deadline {
      lock.lock()
      let length = collected.length
      lock.unlock()
      if length != lastLength {
        lastLength = length
        lastChange = Date()
      } else if length > 0, Date().timeIntervalSince(lastChange) >= quiet {
        return true
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return lastLength > 0
  }

  /// A session on the shipped daemon running a plain `/bin/sh` on its pty, created by the SHIPPED
  /// client and then detached — the state a user's machine is in after they quit an older build.
  private func startShellSession(on socketPath: String) throws -> ShellSession {
    let sessionID = SessionIdentifier(UUID())
    let marker = "V2-SHELL-\(UUID().uuidString.prefix(8))"
    let ready = directory.appendingPathComponent("ready-\(sessionID.uuidString.prefix(8))").path
    let creator = try run(
      Self.shippedBinaryURL, arguments: ["attach"],
      environment: attachEnvironment(
        sessionID: sessionID, socketPath: socketPath,
        // Print, touch, then `exec sh`. The marker goes into the daemon's replay buffer, the
        // sentinel proves the pty is up and running commands before a second client attaches, and
        // the `exec` leaves that same pty owned by an ordinary shell to type at.
        command: "sh -c 'echo \(marker); touch \(ready); exec /bin/sh'"))
    creator.waitUntilExit()
    XCTAssertTrue(
      waitForFile(at: ready),
      "the v2.0.0 daemon never started a shell for this session; there is nothing to type at")
    return ShellSession(identifier: sessionID, marker: marker)
  }

  /// A session the shipped daemon holds, plus the marker that proves a later attach REPLAYED it.
  ///
  /// The marker is not decoration. `SessionDaemon.handleAttach` creates a session for an id it does
  /// not hold, so an attach that silently missed would still hand the test a working shell — one it
  /// could type at and exit — and every assertion below it would pass against a pane the user's
  /// work is not in. The replayed marker is the only thing that tells the two apart.
  struct ShellSession {
    let identifier: SessionIdentifier
    let marker: String
  }

  private func waitForFile(at path: String, within seconds: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: path) { return true }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return false
  }

  /// This build's attach client, running, with its stdin held open so it can be typed at.
  private func attachInteractively(
    sessionID: SessionIdentifier, socketPath: String
  ) throws -> AttachedClient {
    let process = Process()
    process.executableURL = try Self.currentBinaryURL()
    process.arguments = ["attach"]
    process.environment = attachEnvironment(
      sessionID: sessionID, socketPath: socketPath, command: "")
    let output = Pipe()
    let input = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = input

    let client = AttachedClient(process: process, input: input, output: output)
    try process.run()

    // Type only once the session has repainted. Bytes written before the client finishes its
    // handshake are relayed into a socket the daemon is not reading yet, and the test would be
    // measuring the race rather than the feature.
    XCTAssertTrue(
      Self.waitForOutputToSettle(client.collected, lock: client.lock),
      "the shipped daemon sent nothing within \(Self.attachCeiling)s of the attach")
    return client
  }

  /// Owns the pipes for the lifetime of one attached client, so a test can type at it, read what
  /// came back, and clean it up without three locals and a `defer` each time.
  final class AttachedClient {
    let collected = NSMutableData()
    let lock = NSLock()
    private let process: Process
    private let input: Pipe
    private let output: Pipe

    init(process: Process, input: Pipe, output: Pipe) {
      self.process = process
      self.input = input
      self.output = output
      let collected = self.collected
      let lock = self.lock
      output.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        lock.lock()
        collected.append(data)
        lock.unlock()
      }
    }

    func type(_ text: String) {
      input.fileHandleForWriting.write(Data(text.utf8))
    }

    func text() -> String {
      lock.lock()
      defer { lock.unlock() }
      return String(decoding: collected as Data, as: UTF8.self)
    }

    func waitUntilExit(within seconds: TimeInterval) -> Bool {
      let deadline = Date().addingTimeInterval(seconds)
      while Date() < deadline {
        if !process.isRunning { return true }
        Thread.sleep(forTimeInterval: 0.02)
      }
      return false
    }

    func status() -> Int32 {
      process.isRunning ? -1 : process.terminationStatus
    }

    func terminate() {
      output.fileHandleForReading.readabilityHandler = nil
      if process.isRunning { process.terminate() }
      try? input.fileHandleForWriting.close()
    }
  }

  private func attachEnvironment(
    sessionID: SessionIdentifier, socketPath: String, command: String
  ) -> [String: String] {
    [
      "WORKROOM_SESSION_ID": sessionID.uuidString,
      "WORKROOM_SESSION_SOCKET": socketPath,
      "WORKROOM_SESSION_SHELL": "/bin/sh",
      "WORKROOM_SESSION_CWD": directory.path,
      "WORKROOM_SESSION_COMMAND": command,
    ]
  }

  @discardableResult
  private func run(
    _ url: URL, arguments: [String], environment: [String: String]
  ) throws -> Process {
    let process = Process()
    process.executableURL = url
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    if environment["WORKROOM_SESSION_ID"] != nil {
      process.standardInput = FileHandle.nullDevice
    }
    try process.run()
    return process
  }

  /// Runs this build's `workroom-session` to completion and returns everything it wrote.
  ///
  /// `readDataToEndOfFile` rather than a readability handler: `Process` closes the parent's copy of
  /// the child-side pipe ends after spawning, so the read end reaches EOF when the child exits.
  /// (`attachWithCurrentBuild` uses a handler because it has to close stdin at a chosen moment
  /// while output is still streaming — a different problem.) The watchdog is what keeps a hang
  /// regression a FAILURE rather than a blocked read.
  private func runCapturing(
    arguments: [String], environment: [String: String]
  ) throws -> (String, Int32) {
    let process = Process()
    process.executableURL = try Self.currentBinaryURL()
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice

    try process.run()
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: watchdog)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
  }
}

/// Minimal unix-socket client for protocol tests, carried over from the deleted
/// `SessionDaemonEndToEndTests` — the frames it sends are what this tree encodes, which is the
/// half of the comparison under test.
private struct SessionTestClient {
  let descriptor: Int32
  var decoder = SessionFrameDecoder()

  static func connect(socketPath: String) throws -> SessionTestClient {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw XCTSkip("socket() failed") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(descriptor)
      throw NSError(domain: "SessionTestClient", code: 1)
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { dest in
        for (i, byte) in path.enumerated() { dest[i] = byte }
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { casted in
        Darwin.connect(descriptor, casted, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      close(descriptor)
      throw NSError(
        domain: "SessionTestClient", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "connect failed: \(errno)"])
    }
    let flags = fcntl(descriptor, F_GETFL, 0)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    return SessionTestClient(descriptor: descriptor)
  }

  mutating func send(_ frame: SessionFrame) throws {
    var bytes = frame.encoded()
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { pointer -> Int in
        Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      if written > 0 {
        offset += written
        continue
      }
      if errno == EAGAIN || errno == EINTR {
        var pollfd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        _ = poll(&pollfd, 1, 1000)
        continue
      }
      throw NSError(domain: "SessionTestClient", code: 3)
    }
  }

  mutating func wait(for kind: SessionFrameKind, timeout: TimeInterval) throws -> SessionFrame {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let frame = try decoder.next() {
        if frame.kind == kind { return frame }
        continue
      }
      var pollfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let remaining = deadline.timeIntervalSinceNow
      let ready = poll(&pollfd, 1, Int32(max(remaining, 0) * 1000))
      if ready <= 0 { continue }
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      let capacity = buffer.count
      let count = buffer.withUnsafeMutableBytes { pointer in
        Darwin.read(descriptor, pointer.baseAddress, capacity)
      }
      if count > 0 {
        decoder.push(Array(buffer.prefix(count)))
      } else if count == 0 {
        throw NSError(
          domain: "SessionTestClient", code: 4,
          userInfo: [NSLocalizedDescriptionKey: "eof waiting for \(kind)"])
      }
    }
    throw NSError(
      domain: "SessionTestClient", code: 5,
      userInfo: [NSLocalizedDescriptionKey: "timeout waiting for \(kind)"])
  }

  func closeConnection() {
    Darwin.close(descriptor)
  }
}
