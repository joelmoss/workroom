import Darwin
import MachO
import WorkroomSessionProtocol

enum SessionAttachExitCode {
  static let transportFailure: Int32 = 90
  static let protocolFailure: Int32 = 91
  static let daemonUnavailable: Int32 = 92
  static let startupFailure: Int32 = 93
}

enum SessionAttachClient {
  static let connectCycles = 3
  static let connectAttemptsPerCycle = 50
  static let connectRetryMicroseconds: useconds_t = 20000
  static let handshakeAttempts = 3
  static let handshakeRetryMicroseconds: useconds_t = 100_000
  static let inputBacklogLimit = 4 * 1024 * 1024
  /// How long after attaching to re-check the terminal size once more (seconds).
  ///
  /// A reattached session's redraw fires immediately on `.attached`, using whatever size THIS
  /// process's controlling pty reports at that instant — which, for a pane the host app spawns
  /// eagerly off-window at a placeholder size (so a restored session appears instantly instead of
  /// waiting for a click), is not yet the pane's real on-screen size. The host's own later resize
  /// SHOULD retrigger a correct redraw via the normal SIGWINCH path, but that depends on the
  /// signal actually landing after this process has armed its handler — a race on process
  /// startup. This settle re-check doesn't depend on catching any signal: it just re-reads the
  /// CURRENT size (already updated by the kernel regardless of whether we saw a SIGWINCH for it)
  /// once the host has almost certainly finished laying out the real pane, and resends it —
  /// closing that race unconditionally rather than hoping it doesn't occur.
  static let settleCheckDelaySeconds: Double = 0.3

  struct Configuration {
    let identifier: SessionIdentifier
    let socketPath: String
    let command: String
    let shell: String
    let resourcesDirectory: String
    let workingDirectory: String
    let metadata: [SessionEnvironmentEntry]
  }

  private enum Outcome {
    case finished(Int32)
    case retry
    case failed(Int32)
  }

  private enum ConnectionOutcome {
    case connected(Int32)
    case retry
    case failed(Int32)
  }

  private enum DaemonLaunchOutcome {
    case started
    case retryableFailure
    case fatalFailure
  }

  static func run(configuration: Configuration) -> Int32 {
    signal(SIGPIPE, SIG_IGN)

    guard let signalPipe = SessionSignalPipe(signals: [SIGWINCH]) else {
      return SessionAttachExitCode.startupFailure
    }

    let originalTerminal = enterRawMode()
    defer {
      if var originalTerminal {
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTerminal)
      }
    }

    for attempt in 0..<handshakeAttempts {
      switch attach(configuration: configuration, signalPipe: signalPipe) {
      case .finished(let status), .failed(let status):
        return status
      case .retry:
        if attempt + 1 < handshakeAttempts {
          usleep(handshakeRetryMicroseconds)
        }
      }
    }

    report("could not reach the session daemon")
    return SessionAttachExitCode.daemonUnavailable
  }

  private static func attach(configuration: Configuration, signalPipe: SessionSignalPipe) -> Outcome
  {
    let socket: Int32
    switch connect(socketPath: configuration.socketPath) {
    case .connected(let descriptor):
      socket = descriptor
    case .retry:
      return .retry
    case .failed(let status):
      return .failed(status)
    }
    defer { SessionIO.close(socket) }
    SessionIO.setNonBlocking(socket)

    let payload = makeRequest(configuration).encoded()
    guard payload.count <= SessionFrame.maximumPayloadSize else {
      // Fail fast and specifically rather than retrying `handshakeAttempts` times against the
      // same oversized payload and reporting the generic, misleading "could not reach the
      // session daemon" — this is almost always a bloated shell environment (exported functions,
      // PATH bloat from asdf/direnv/nvm hooks), not a daemon problem.
      report(
        "attach request too large (\(payload.count) bytes, limit "
          + "\(SessionFrame.maximumPayloadSize)) — check for an oversized shell environment")
      return .failed(SessionAttachExitCode.protocolFailure)
    }

    let connection = SessionConnection(descriptor: socket)
    connection.enqueue(SessionFrame(kind: .attach, payload: payload))
    return loop(connection: connection, signalPipe: signalPipe)
  }

  private static func loop(connection: SessionConnection, signalPipe: SessionSignalPipe) -> Outcome
  {
    var isAttached = false
    var settleDeadline: Double?
    while true {
      guard connection.flush() else { return transportOutcome(isAttached: isAttached) }

      var descriptors = [
        pollfd(fd: signalPipe.readDescriptor, events: Int16(POLLIN), revents: 0),
        pollfd(
          fd: connection.descriptor,
          events: Int16(
            connection.hasPendingOutput ? Int32(POLLIN) | Int32(POLLOUT) : Int32(POLLIN)),
          revents: 0),
      ]
      if isAttached, connection.pendingByteCount < inputBacklogLimit {
        descriptors.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0))
      }

      let ready = poll(&descriptors, nfds_t(descriptors.count), pollTimeout(until: settleDeadline))
      if ready == 0, let deadline = settleDeadline, SessionClock.monotonicSeconds() >= deadline {
        settleDeadline = nil
        sendResize(connection)
        continue
      }
      if ready < 0 {
        guard errno == EINTR else { return transportOutcome(isAttached: isAttached) }
        continue
      }

      for entry in descriptors where entry.revents != 0 {
        if entry.fd == signalPipe.readDescriptor {
          signalPipe.drain()
          sendResize(connection)
        } else if entry.fd == STDIN_FILENO {
          guard forwardInput(connection) else { return .finished(0) }
        } else if let outcome = receive(connection, revents: entry.revents, isAttached: &isAttached)
        {
          _ = connection.flush()
          return outcome
        }
      }
      // Arm the one-shot settle re-check the moment `.attached` lands, not before — there's
      // nothing to settle until the daemon has actually accepted us.
      if isAttached, settleDeadline == nil {
        settleDeadline = SessionClock.monotonicSeconds() + settleCheckDelaySeconds
      }
    }
  }

  /// `poll`'s timeout in milliseconds: bounded while a settle check is pending (so we wake up to
  /// fire it even with no other activity), `-1` (block indefinitely) once there's nothing to wait
  /// for — this is a single terminal session's I/O loop, not a busy-poll.
  private static func pollTimeout(until deadline: Double?) -> Int32 {
    guard let deadline else { return -1 }
    let remaining = deadline - SessionClock.monotonicSeconds()
    guard remaining > 0 else { return 0 }
    return Int32((remaining * 1000).rounded(.up))
  }

  private static func transportOutcome(isAttached: Bool) -> Outcome {
    isAttached ? .failed(SessionAttachExitCode.transportFailure) : .retry
  }

  private static func forwardInput(_ connection: SessionConnection) -> Bool {
    switch SessionIO.read(STDIN_FILENO) {
    case .bytes(let bytes):
      connection.enqueue(SessionFrame(kind: .input, payload: bytes))
      return true
    case .wouldBlock:
      return true
    case .endOfFile, .failed:
      return false
    }
  }

  private static func receive(
    _ connection: SessionConnection,
    revents: Int16,
    isAttached: inout Bool
  ) -> Outcome? {
    if revents & Int16(POLLOUT) != 0, !connection.flush() {
      return transportOutcome(isAttached: isAttached)
    }
    guard revents & Int16(POLLIN) != 0 || revents & Int16(POLLHUP) != 0 else { return nil }

    var reachedEnd = false
    readLoop: while true {
      switch SessionIO.read(connection.descriptor) {
      case .bytes(let bytes):
        connection.decoder.push(bytes)
      case .wouldBlock:
        break readLoop
      case .endOfFile, .failed:
        reachedEnd = true
        break readLoop
      }
    }

    while true {
      let frame: SessionFrame?
      do {
        frame = try connection.decoder.next()
      } catch {
        return .failed(SessionAttachExitCode.protocolFailure)
      }
      guard let frame else { break }
      switch frame.kind {
      case .attached:
        isAttached = true
      case .output:
        guard SessionIO.writeAll(STDOUT_FILENO, frame.payload) else {
          return transportOutcome(isAttached: isAttached)
        }
      case .exited:
        return .finished((try? SessionExitPayload.decode(frame.payload)) ?? 0)
      case .failure:
        report((try? SessionTextPayload.decode(frame.payload)) ?? "session failed")
        return .failed(SessionAttachExitCode.protocolFailure)
      case .attach, .input, .resize, .list, .info, .kill, .killAll, .sessions, .acknowledged:
        break
      }
    }

    return reachedEnd ? transportOutcome(isAttached: isAttached) : nil
  }

  private static func report(_ message: String) {
    SessionIO.writeAll(STDERR_FILENO, Array(("workroom-session: " + message + "\r\n").utf8))
  }

  private static func sendResize(_ connection: SessionConnection) {
    let size = SessionWindowSizePolicy.attachSize(
      from: SessionPTY.windowSize(descriptor: STDIN_FILENO))
    guard SessionWindowSizePolicy.isUsable(columns: size.columns, rows: size.rows) else { return }
    connection.enqueue(
      SessionFrame(
        kind: .resize,
        payload: SessionResizePayload.encode(columns: size.columns, rows: size.rows)))
  }

  private static func makeRequest(_ configuration: Configuration) -> SessionAttachRequest {
    let size = SessionWindowSizePolicy.attachSize(
      from: SessionPTY.windowSize(descriptor: STDIN_FILENO))
    let environment = SessionProcessEnvironment.current()
      .filter { !$0.key.hasPrefix("WORKROOM_SESSION_") }
      .map { SessionEnvironmentEntry(key: $0.key, value: $0.value) }
    return SessionAttachRequest(
      identifier: configuration.identifier,
      columns: size.columns,
      rows: size.rows,
      workingDirectory: configuration.workingDirectory,
      command: configuration.command,
      shell: configuration.shell,
      resourcesDirectory: configuration.resourcesDirectory,
      environment: environment,
      metadata: configuration.metadata)
  }

  private static func enterRawMode() -> termios? {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
    var raw = original
    cfmakeraw(&raw)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
    return original
  }

  private static func connect(socketPath: String) -> ConnectionOutcome {
    for _ in 0..<connectCycles {
      if let descriptor = SessionSocket.connect(path: socketPath) {
        return .connected(descriptor)
      }
      switch launchDaemon(socketPath: socketPath) {
      case .started, .retryableFailure:
        break
      case .fatalFailure:
        return .failed(SessionAttachExitCode.startupFailure)
      }
      for _ in 0..<connectAttemptsPerCycle {
        usleep(connectRetryMicroseconds)
        if let descriptor = SessionSocket.connect(path: socketPath) {
          return .connected(descriptor)
        }
      }
    }
    return .retry
  }

  private static func launchDaemon(socketPath: String) -> DaemonLaunchOutcome {
    guard let binaryPath = executablePath() else {
      report("unable to locate the session daemon binary")
      return .fatalFailure
    }
    let arguments = SessionCStringArray([binaryPath, "daemon", "--socket", socketPath])

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_addopen(
      &fileActions,
      STDERR_FILENO,
      socketPath + ".log",
      O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW,
      0o600)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

    var processID: pid_t = 0
    let result = posix_spawn(
      &processID, binaryPath, &fileActions, &attributes, arguments.pointer, environ)
    guard result != 0 else { return .started }
    report("could not start the session daemon (\(result))")
    return result == EAGAIN || result == EINTR ? .retryableFailure : .fatalFailure
  }

  static func executablePath() -> String? {
    if let provided = SessionProcessEnvironment.value("WORKROOM_SESSION_BINARY") {
      return provided
    }
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    return buffer.withUnsafeBufferPointer { pointer in
      guard let base = pointer.baseAddress else { return nil }
      return String(cString: base)
    }
  }
}
