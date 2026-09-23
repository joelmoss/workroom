import Foundation

/// Launches a throwaway `wr-agent serve` against a temp socket, and can put real sessions on it.
///
/// The Rust side has its own integration tests and they are cheaper, so this exists for the one
/// thing they structurally cannot cover: whether the bytes the agent writes are the bytes the
/// **app** reads. `AgentControlClient` hand-rolls the greeting, the envelope and the descriptor
/// decode in Swift against encoders written in Rust, and a field-width disagreement between them
/// would not fail anything on either side alone — it would show up as an empty sidebar.
final class AgentHarness {
  let socketPath: String
  private let process: Process
  private let directory: URL
  private var attachments: [Process] = []

  static func start(environment: [String: String]? = nil) throws -> AgentHarness {
    // sun_path is 104 bytes; NSTemporaryDirectory() + a UUID overflows it.
    let directory = URL(
      fileURLWithPath: "/tmp/wra-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socketPath = directory.appendingPathComponent("a.sock").path
    let binary = try binaryURL()

    let process = Process()
    process.executableURL = binary
    process.environment = environment
    // The idle timeout has to outlast the whole test: an agent with no sessions and no clients
    // exits on purpose, and between two assertions it is briefly both.
    process.arguments = ["serve", "--socket", socketPath, "--idle-timeout", "120"]
    process.standardOutput = FileHandle.nullDevice
    let errorURL = directory.appendingPathComponent("agent.err")
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    process.standardError = FileHandle(forWritingAtPath: errorURL.path)
    try process.run()

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) { break }
      if !process.isRunning { break }
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard FileManager.default.fileExists(atPath: socketPath) else {
      let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
      let status = process.isRunning ? "running" : "exited \(process.terminationStatus)"
      process.terminate()
      throw NSError(
        domain: "AgentHarness", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "agent socket never appeared at \(socketPath) (\(status), binary=\(binary.path), stderr=\(error))"
        ])
    }
    return AgentHarness(socketPath: socketPath, process: process, directory: directory)
  }

  private init(socketPath: String, process: Process, directory: URL) {
    self.socketPath = socketPath
    self.process = process
    self.directory = directory
  }

  /// Puts a real session on the agent, the way the app does: by running `wr-agent attach` with the
  /// session's configuration in its environment.
  ///
  /// Deliberately not by sending an `Attach` frame. The app never does that — it hands libghostty
  /// an attach command to run as the pane's shell — so driving the socket directly would be testing
  /// a path nothing uses and skipping the one that ships.
  @discardableResult
  func startSession(identifier: UUID, command: String = "cat") throws -> Process {
    let process = Process()
    process.executableURL = try Self.binaryURL()
    process.arguments = ["attach"]
    // No flags, exactly as `PersistentSessionService.attachCommand()` builds it: the environment
    // is the whole contract on the app's side, so passing `--socket` here would test a path the
    // app never takes.
    process.environment = [
      "WORKROOM_SESSION_SOCKET": socketPath,
      "WORKROOM_SESSION_ID": identifier.uuidString,
      "WORKROOM_SESSION_COMMAND": command,
      "WORKROOM_SESSION_SHELL": "/bin/sh",
      "WORKROOM_SESSION_CWD": NSTemporaryDirectory(),
      "TERM": "dumb",
      "PATH": "/bin:/usr/bin",
    ]
    process.standardInput = Pipe()
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    try process.run()
    attachments.append(process)
    return process
  }

  /// Waits until `condition` holds, so tests never sleep a fixed amount for a session to appear.
  func wait(seconds: TimeInterval = 5, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
  }

  func stop() {
    for attachment in attachments where attachment.isRunning {
      attachment.terminate()
    }
    attachments.removeAll()
    process.terminate()
    Self.waitForExit(process)
    try? FileManager.default.removeItem(at: directory)
  }

  /// Not `waitUntilExit`. In the serial test host (`-only-testing` turns parallel testing off, so
  /// every class shares one process) it intermittently never returned: the agent had exited and
  /// been reaped, no zombie was left, yet `isRunning` stayed true and the main thread blocked for
  /// good — the whole test host hung. Not reproduced outside the host; see TODOS "AgentHarness.stop
  /// hang". So the OS decides: once `waitpid` says the pid is no longer an unexited child of ours,
  /// it is gone. Not `kill(pid, 0)`: after a reap the pid can be reused, and the SIGKILL below
  /// would hit whatever got it. An unreaped child's pid cannot be reused, so the kill only ever
  /// reaches ours.
  static func waitForExit(_ process: Process, timeout: TimeInterval = 5) {
    let pid = process.processIdentifier
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, waitpid(pid, nil, WNOHANG) == 0 {
      guard Date() < deadline else {
        kill(pid, SIGKILL)
        return
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  static func binaryURL() throws -> URL {
    for name in ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR"] {
      if let directory = ProcessInfo.processInfo.environment[name] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("wr-agent")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
      }
    }
    // These are host-based tests, so `Bundle.main` is the app itself and the agent is where the
    // build phase embedded it — the same place `PersistentSessionPaths.binaryURL(for:)` looks.
    let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wr-agent")
    if FileManager.default.isExecutableFile(atPath: embedded.path) { return embedded }
    var candidate = Bundle(for: AgentHarness.self).bundleURL
    for _ in 0..<6 {
      let url = candidate.appendingPathComponent("wr-agent")
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
      candidate.deleteLastPathComponent()
    }
    throw NSError(
      domain: "AgentHarness", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "wr-agent binary not found"])
  }
}
