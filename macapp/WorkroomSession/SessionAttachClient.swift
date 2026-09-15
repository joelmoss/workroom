import Darwin
import WorkroomSessionProtocol

enum SessionAttachExitCode {
  static let transportFailure: Int32 = 90
  static let protocolFailure: Int32 = 91
  static let daemonUnavailable: Int32 = 92
  static let startupFailure: Int32 = 93
}

enum SessionAttachClient {
  /// How hard to retry a refused connect, and for how long to wait once connected.
  ///
  /// These used to be far larger (3 cycles of 50 × 20ms) because `connect` STARTED a daemon when
  /// none answered and then had to wait for it to bind its socket. This build cannot start one —
  /// the `daemon` subcommand is gone — so there is nothing to wait for that is not already there.
  /// What remains covers a live helper that is momentarily slow to `accept`, which is the only real
  /// wait left. Worst case is now ~0.7s rather than ~9.2s of a pane showing nothing.
  static let connectAttempts = 10
  static let connectRetryMicroseconds: useconds_t = 20000
  static let handshakeAttempts = 3
  static let handshakeRetryMicroseconds: useconds_t = 100_000
  /// How long to wait, once CONNECTED, for the helper to answer the attach request (seconds).
  ///
  /// Shrinking the connect retries above bounds only a REFUSED connect. A helper that accepts and
  /// then says nothing — a wedged one — is a different failure, and nothing bounded it: `poll`
  /// blocks indefinitely once no settle check is pending, so the pane sat blank forever with no
  /// message and no exit.
  ///
  /// **Generous, and deliberately not retried.** The v2.0.0 daemon answers an attach from a single
  /// poll iteration that first runs process introspection (`foregroundProcessGroup`,
  /// `executableName`, `workingDirectory`) and then enqueues the whole replay buffer, flushing only
  /// once that returns. On a loaded machine that is slow rather than broken, so a tight deadline
  /// plus a retry is the worst combination available: each attempt tears down the connection, makes
  /// the peer redo the same introspection and replay, and hands the next attempt an even busier
  /// daemon. It cannot converge. One long wait converges or it does not.
  static let attachHandshakeTimeoutSeconds: Double = 5
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

    report("no session helper is listening; the session it held is gone")
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
    // Cleared the moment `.attached` lands. Until then it bounds the whole wait, checked at the top
    // of every iteration rather than only on a poll timeout — a helper can keep this loop busy with
    // traffic that never includes the attach reply.
    var handshakeDeadline: Double? =
      SessionClock.monotonicSeconds() + attachHandshakeTimeoutSeconds
    while true {
      if let deadline = handshakeDeadline, SessionClock.monotonicSeconds() >= deadline {
        // TERMINAL, not `.retry`. Retrying reconnects and re-sends the attach, which on a slow peer
        // makes it redo the introspection and replay this attempt already paid for — three attempts
        // against a progressively busier daemon, converging on nothing. It also let `run`'s final
        // "no session helper is listening" overwrite this line on screen, which is false in this
        // path: the helper was listening, we reached it three times.
        report(
          "connected to the session helper, but it did not answer the attach request within "
            + "\(Int(attachHandshakeTimeoutSeconds))s — the session may still be running")
        return .failed(SessionAttachExitCode.daemonUnavailable)
      }
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

      let ready = poll(
        &descriptors, nfds_t(descriptors.count),
        pollTimeout(untilEarliestOf: settleDeadline, handshakeDeadline))
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
      // The attach reply has landed, so the handshake is no longer what we are waiting for. Past
      // this point an idle connection is a healthy one and blocking indefinitely is correct.
      // Cleared BEFORE the settle deadline is armed, so the two are never live at once.
      if isAttached { handshakeDeadline = nil }
      // Arm the settle re-check the moment `.attached` lands, not before — there's nothing to
      // settle until the daemon has actually accepted us.
      //
      // NOT one-shot, despite how it reads, and this comment used to claim otherwise. Firing it
      // sets `settleDeadline = nil` and `continue`s past this block; the next wake then finds
      // `isAttached` with no deadline armed and starts another. So a resize trails every burst of
      // output by ~300ms. Pre-existing and harmless — the v2.0.0 peer's `.resize` is a plain
      // `SessionPTY.resize` with no forced redraw — but worth knowing when reading the timeouts.
      if isAttached, settleDeadline == nil {
        settleDeadline = SessionClock.monotonicSeconds() + settleCheckDelaySeconds
      }
    }
  }

  /// `poll`'s timeout in milliseconds: the nearest pending deadline, or `-1` (block indefinitely)
  /// when none is pending — this is a single terminal session's I/O loop, not a busy-poll.
  ///
  /// Both deadlines are passed even though only one can be armed at a time (the handshake one is
  /// cleared in the same block that arms the settle one), because the alternative is a caller that
  /// has to know which is live. What actually enforces the handshake bound is the top-of-loop
  /// check, not this — `poll` only has to wake up in time for it.
  private static func pollTimeout(untilEarliestOf deadlines: Double?...) -> Int32 {
    guard let deadline = deadlines.compactMap({ $0 }).min() else { return -1 }
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
      from: SessionTerminalSize.of(descriptor: STDIN_FILENO))
    guard SessionWindowSizePolicy.isUsable(columns: size.columns, rows: size.rows) else { return }
    connection.enqueue(
      SessionFrame(
        kind: .resize,
        payload: SessionResizePayload.encode(columns: size.columns, rows: size.rows)))
  }

  private static func makeRequest(_ configuration: Configuration) -> SessionAttachRequest {
    let size = SessionWindowSizePolicy.attachSize(
      from: SessionTerminalSize.of(descriptor: STDIN_FILENO))
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

  /// Connect to a helper that is ALREADY running, or give up.
  ///
  /// This used to `posix_spawn` `workroom-session daemon` when nothing answered, then wait for the
  /// new process to bind. That is gone with the daemon itself: the only sessions this client can
  /// reach are held by a daemon some OLDER build of the app started, and starting a fresh one would
  /// serve no session that exists. What is left is a short retry for a live helper that is
  /// momentarily slow to `accept`.
  private static func connect(socketPath: String) -> ConnectionOutcome {
    for attempt in 0..<connectAttempts {
      if let descriptor = SessionSocket.connect(path: socketPath) {
        return .connected(descriptor)
      }
      if attempt + 1 < connectAttempts { usleep(connectRetryMicroseconds) }
    }
    return .retry
  }
}
