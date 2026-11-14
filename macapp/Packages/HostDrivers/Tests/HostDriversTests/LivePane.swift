import Foundation

/// A pane for a live suite: the command a pane would run (an attach command), in a terminal of
/// this process's own, typed into and resized on demand, with everything it printed kept in a
/// file. libghostty isn't here, so the terminal is a small Python pty driver
/// (`LivePane.driverSource`): it answers the daemon's keepalive probe as libghostty would
/// (ADR 0070), until told to stop answering, which is how a suite makes a pane go stale.
///
/// The child is a session leader with the pty as its controlling terminal, so `workroomd attach`
/// sets raw mode on it and polls its size as in a real pane.
final class LivePane: @unchecked Sendable {
  let output: URL
  private let process = Process()
  private let input: FileHandle

  /// Starts `command` (one `/bin/sh -c` line) in a `rows`×`columns` terminal, with only
  /// `environment` (no inherited variable reaches it).
  init(
    _ command: String, rows: Int = 30, columns: Int = 100, in directory: URL,
    environment: [String: String]
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let driver = directory.appendingPathComponent("pty-driver.py")
    if !FileManager.default.fileExists(atPath: driver.path) {
      try Self.driverSource.write(to: driver, atomically: true, encoding: .utf8)
    }
    output = directory.appendingPathComponent("pane-\(UUID().uuidString).out")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let pipe = Pipe()
    input = pipe.fileHandleForWriting
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments =
      ["-I", driver.path, output.path, String(rows), String(columns), "/bin/sh", "-c", command]
    process.environment = environment
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }

  /// Everything the pane has printed so far, decoded leniently.
  var screen: String {
    String(decoding: (try? Data(contentsOf: output)) ?? Data(), as: UTF8.self)
  }

  var isRunning: Bool { process.isRunning }

  /// The pane's exit status, once it has ended.
  var exitStatus: Int32? {
    guard !process.isRunning else { return nil }
    let file = output.appendingPathExtension("exit")
    return (try? String(contentsOf: file, encoding: .utf8))
      .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  /// Types `text` as keys (a `\r` is Return).
  func type(_ text: String) { send(bytes: Array(text.utf8)) }

  func send(bytes: [UInt8]) {
    command("w " + bytes.map { String(format: "%02x", $0) }.joined())
  }

  func resize(rows: Int, columns: Int) { command("z \(rows) \(columns)") }

  /// Stops answering the daemon's keepalive probe, as a pane whose Mac went away.
  func stopAnswering() { command("quiet") }

  /// Kills the pane's whole process group.
  func kill() { command("kill") }

  /// Ends the driver too; safe to call more than once.
  func close() {
    if process.isRunning { kill() }
    try? input.close()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    if process.isRunning { process.terminate() }
  }

  private func command(_ line: String) {
    try? input.write(contentsOf: Data((line + "\n").utf8))
  }

  /// Waits until the screen, from `offset` on, matches `pattern` (a regular expression), and says
  /// whether it did within `timeout`.
  func wait(
    for pattern: String, after offset: Int = 0, timeout: TimeInterval = 30
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if Self.matches(pattern, in: String(screen.dropFirst(offset))) { return true }
      try? await Task.sleep(for: .milliseconds(200))
    } while Date() < deadline
    return Self.matches(pattern, in: String(screen.dropFirst(offset)))
  }

  /// Waits for the pane to end, and says its status.
  func waitForExit(timeout: TimeInterval = 30) async -> Int32? {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
    // The driver writes the status as it ends.
    try? await Task.sleep(for: .milliseconds(200))
    return exitStatus
  }

  static func matches(_ pattern: String, in text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }

  /// The pty driver: `pty-driver.py <output> <rows> <cols> <argv…>`. Commands on stdin, one a
  /// line: `w <hex>` types bytes, `z <rows> <cols>` resizes, `quiet` stops answering the probe,
  /// `kill` kills the child's process group. The child's exit status goes to `<output>.exit`.
  static let driverSource = #"""
    import os, sys, select, fcntl, termios, struct, signal
    out_path, rows, cols, argv = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
    PROBE = b"\x1b[?25930$p"
    ANSWER = b"\x1b[?25930;0$y"
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        if slave > 2:
            os.close(slave)
        os.execvp(argv[0], argv)
    os.close(slave)
    out = open(out_path, "ab", buffering=0)
    answering, tail, pending, stdin_open, status = True, b"", b"", True, None

    def command(line):
        global answering
        words = line.decode().split()
        if not words:
            return
        try:
            if words[0] == "w":
                os.write(master, bytes.fromhex(words[1]))
            elif words[0] == "z":
                size = struct.pack("HHHH", int(words[1]), int(words[2]), 0, 0)
                fcntl.ioctl(master, termios.TIOCSWINSZ, size)
            elif words[0] == "quiet":
                answering = False
            elif words[0] == "kill":
                os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass

    while True:
        r, _, _ = select.select([master] + ([0] if stdin_open else []), [], [], 0.2)
        if master in r:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if not data:
                break
            out.write(data)
            seen = tail + data
            if answering:
                for _ in range(seen.count(PROBE)):
                    os.write(master, ANSWER)
            tail = seen[-(len(PROBE) - 1):]
        if stdin_open and 0 in r:
            chunk = os.read(0, 4096)
            if not chunk:
                stdin_open = False
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                command(line)
        if status is None:
            done, raw = os.waitpid(pid, os.WNOHANG)
            if done:
                status = raw
    if status is None:
        _, status = os.waitpid(pid, 0)
    with open(out_path + ".exit", "w") as f:
        f.write(str(os.waitstatus_to_exitcode(status)))
    """#
}
