import XCTest

@testable import HostDrivers

/// The container driver's transport (#308): its own runtime's `exec`, not ssh. Each check runs a
/// stub runtime, a script that records what it was asked and answers as the test says, so the real
/// argument lists and the real attach wrapper are what run.
final class ContainerExecTransportTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// A runtime that writes its arguments, one per line, to `args`, then runs `body`.
  private func stubRuntime(_ body: String = "exit 0") throws -> URL {
    let script = directory.appendingPathComponent("runtime")
    try """
    #!/bin/sh
    printf '%s\\n' "$@" > \(directory.appendingPathComponent("args").path)
    \(body)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private var asked: [String] {
    get throws {
      try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
  }

  private func target(_ runtime: URL, dialect: ContainerHostDriver.Dialect = .docker)
    -> ContainerExecTransport.Target
  {
    ContainerExecTransport.Target(
      runtime: runtime, dialect: dialect, context: dialect == .docker ? "orbstack" : nil,
      container: "workroom-abc", user: "vscode",
      daemonSocket: "/home/vscode/.workroom/run/workroomd.sock")
  }

  /// A one-off command is a shell line, run by the container's `sh` as the remote user, with stdin
  /// kept open for the input `communicate` sends and closes; `--context` goes before `exec`.
  func testExecRunsAShellLineAsTheRemoteUser() async throws {
    let runtime = try stubRuntime("cat; echo out")
    let (status, output) = try await ContainerExecTransport.exec(
      "echo hi", on: target(runtime), purpose: .exchange
    ).communicate(Data("in\n".utf8), timeout: 10)
    XCTAssertEqual(status, 0)
    XCTAssertEqual(output, "in\nout\n")
    XCTAssertEqual(
      try asked,
      [
        "--context", "orbstack", "exec", "-i", "-u", "vscode", "workroom-abc", "sh", "-c",
        "echo hi",
      ])
  }

  /// Apple's CLI takes the same `exec` flags, and has no contexts.
  func testAppleSpellsExecTheSameWithoutAContext() async throws {
    let runtime = try stubRuntime()
    _ = try await ContainerExecTransport.exec(
      "true", on: target(runtime, dialect: .apple), purpose: .exchange
    ).communicate(nil, timeout: 10)
    XCTAssertEqual(try asked, ["exec", "-i", "-u", "vscode", "workroom-abc", "sh", "-c", "true"])
  }

  /// The service stream is the daemon's relay, run by path, with no shell in between.
  func testTheStreamIsTheDaemonsRelay() throws {
    XCTAssertEqual(
      ContainerExecTransport.relayArguments(target(URL(fileURLWithPath: "/usr/bin/false"))),
      [
        "--context", "orbstack", "exec", "-i", "-u", "vscode", "workroom-abc",
        "/home/vscode/.workroom/run/workroomd", "relay", "--socket",
        "/home/vscode/.workroom/run/workroomd.sock",
      ])
  }

  private func attach(_ runtime: URL, session: UUID) throws -> (status: Int32, screen: String) {
    let command = ContainerExecTransport.attachCommand(
      on: target(runtime), in: directory, session: session, workingDirectory: "/workspaces/app",
      restored: false, metadata: [], runCommand: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let screen = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, screen)
  }

  /// A pane attaches through `exec -it` as the remote user, starting where the session is, running
  /// the same in-container attach as an ssh host's.
  func testAPaneAttachesThroughExecWithATerminal() throws {
    let runtime = try stubRuntime()
    let session = UUID()
    _ = try attach(runtime, session: session)
    let args = try asked
    XCTAssertEqual(
      Array(args.prefix(8)),
      ["--context", "orbstack", "exec", "-i", "-t", "-u", "vscode", "workroom-abc"])
    XCTAssertEqual(Array(args.dropFirst(8).prefix(2)), ["sh", "-c"])
    XCTAssertTrue(args.last?.contains("WORKROOM_SESSION_ID=\(session.uuidString)") ?? false)
    XCTAssertTrue(args.last?.contains("WORKROOM_SESSION_CWD=/workspaces/app") ?? false)
    XCTAssertTrue(args.last?.contains("attach") ?? false)
    // First, in the container, it waits for a postStartCommand not yet run since the start (#308).
    XCTAssertTrue(args.last?.hasPrefix(ContainerHostDriver.postStartWait + "; ") ?? false)
    XCTAssertEqual(ContainerExecTransport.lastAttach(of: session, in: directory), .finished)
  }

  /// The wait itself, in a shell: none without a hook or once it is done; with a hook not done, it
  /// waits and says so.
  func testAPaneWaitsForAPostStartNotYetRun() throws {
    let root = directory.appendingPathComponent("poststart")
    let hook = root.appendingPathComponent("hook").path
    let done = root.appendingPathComponent("done").path
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let wait = ContainerHostDriver.postStartWait
      .replacingOccurrences(of: ContainerHostDriver.postStartHook, with: hook)
      .replacingOccurrences(of: ContainerHostDriver.postStartDone, with: done)
    func run() throws -> (seconds: TimeInterval, said: String) {
      let started = Date()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", wait + "; echo attached"]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      process.waitUntilExit()
      return (
        Date().timeIntervalSince(started),
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      )
    }
    XCTAssertEqual(try run().said, "attached\n", "no hook waits")
    FileManager.default.createFile(atPath: hook, contents: nil)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
      FileManager.default.createFile(atPath: done, contents: nil)
    }
    let (seconds, said) = try run()
    XCTAssertGreaterThan(seconds, 1)
    XCTAssertTrue(said.hasPrefix("Waiting for the dev container's postStartCommand"), said)
    XCTAssertTrue(said.hasSuffix("attached\n"), said)
    XCTAssertEqual(try run().said, "attached\n", "a done one waits")
  }

  /// A stopped container is a link that comes back (the workroom starts it when opened): recorded
  /// as one, said in plain words, and not a refusal. The session's own failure is its own.
  func testAStoppedContainerIsALostLinkNotTheSessionsExit() throws {
    let stopped = try stubRuntime(
      "echo 'Error response from daemon: container workroom-abc is not running' >&2; exit 1")
    let session = UUID()
    let (status, screen) = try attach(stopped, session: session)
    XCTAssertEqual(status, 255)
    XCTAssertEqual(ContainerExecTransport.lastAttach(of: session, in: directory), .lostLink)
    XCTAssertTrue(screen.contains(SSHTransport.retryNotice), screen)
    XCTAssertFalse(ContainerExecTransport.refusedLastAttach(of: session, in: directory))

    let exitedOne = try stubRuntime("exit 1")
    let other = UUID()
    XCTAssertEqual(try attach(exitedOne, session: other).status, 1)
    XCTAssertEqual(ContainerExecTransport.lastAttach(of: other, in: directory), .finished)
  }

  /// A container that's gone won't come back: the pane says so and stops trying.
  func testAMissingContainerIsARefusal() throws {
    let gone = try stubRuntime(
      "echo 'Error response from daemon: No such container: workroom-abc' >&2; exit 1")
    let session = UUID()
    let (_, screen) = try attach(gone, session: session)
    XCTAssertTrue(ContainerExecTransport.refusedLastAttach(of: session, in: directory))
    XCTAssertTrue(screen.contains("No such container"), screen)
  }
}
