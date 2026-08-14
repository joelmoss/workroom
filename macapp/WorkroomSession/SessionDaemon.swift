import Darwin
import WorkroomSessionProtocol

enum SessionDaemonStart {
  case running(SessionDaemon)
  case lockHeld
  case failed(String)
}

final class SessionDaemon {
  static let replayCapacity = 256 * 1024
  static let clientOutputLimit = 4 * 1024 * 1024
  static let sessionInputLimit = 1024 * 1024
  static let maximumConnections = 64
  static let maximumSessions = 256
  static let idleTimeoutMilliseconds: Int32 = 10000
  static let replayChunkSize = 32 * 1024
  /// How long to leave a reattached session's pty bumped before resizing it back and signaling —
  /// long enough for the child to actually be scheduled and observe the transient size (see
  /// `SessionPTY.bumpedRowCount`), short enough nobody notices. Deferred through the poll loop
  /// rather than a blocking sleep: this daemon is single-threaded and serves every session across
  /// every open project, so blocking here would freeze all of them for the duration, worst-case
  /// stacking to N × this value when many persisted tabs reattach at once on relaunch.
  static let redrawSettleSeconds: Double = 0.03

  private let socketPath: String
  private let idleTimeout: Int32
  private let listener: Int32
  private let lockDescriptor: Int32
  private let signalPipe: SessionSignalPipe

  private var sessions: [SessionIdentifier: PTYSession] = [:]
  private var sessionsByMaster: [Int32: SessionIdentifier] = [:]
  private var connections: [Int32: SessionConnection] = [:]
  private var closingDescriptors: [Int32] = []
  /// Sessions bumped by `attach()`, awaiting their non-blocking resize-back-and-signal once
  /// `redrawSettleSeconds` has elapsed. Keyed by identifier, not master fd, so a session that gets
  /// killed and its fd reused before the deadline can't cause this to resize/signal the WRONG pty.
  private var pendingRedraws: [SessionIdentifier: PendingRedraw] = [:]

  private struct PendingRedraw {
    let deadline: Double
    let columns: UInt16
    let rows: UInt16
  }

  static func start(
    socketPath: String,
    idleTimeoutMilliseconds: Int32 = SessionDaemon.idleTimeoutMilliseconds
  ) -> SessionDaemonStart {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGHUP, SIG_IGN)

    guard let lock = SessionSocket.acquireLock(path: socketPath + ".lock") else {
      return .lockHeld
    }
    guard let signalPipe = SessionSignalPipe(signals: [SIGCHLD]) else {
      SessionIO.close(lock)
      return .failed("unable to create the signal pipe")
    }
    guard let listener = SessionSocket.makeListener(path: socketPath) else {
      SessionIO.close(lock)
      return .failed("unable to listen on \(socketPath)")
    }
    return .running(
      SessionDaemon(
        socketPath: socketPath,
        idleTimeout: idleTimeoutMilliseconds,
        listener: listener,
        lockDescriptor: lock,
        signalPipe: signalPipe))
  }

  private init(
    socketPath: String,
    idleTimeout: Int32,
    listener: Int32,
    lockDescriptor: Int32,
    signalPipe: SessionSignalPipe
  ) {
    self.socketPath = socketPath
    self.idleTimeout = idleTimeout
    self.listener = listener
    self.lockDescriptor = lockDescriptor
    self.signalPipe = signalPipe
  }

  func run() {
    while true {
      let isIdle = sessions.isEmpty && connections.isEmpty
      var descriptors = buildPollDescriptors()
      let ready = poll(&descriptors, nfds_t(descriptors.count), pollTimeout(isIdle: isIdle))
      if ready == 0 {
        if processExpiredRedraws() { continue }
        guard sessions.isEmpty, connections.isEmpty else { continue }
        acceptConnections()
        guard connections.isEmpty else { continue }
        break
      }
      if ready < 0 {
        switch errno {
        case EINTR, EAGAIN, ENOMEM:
          continue
        default:
          SessionLog.write("poll failed: \(String(cString: strerror(errno)))")
          break
        }
        break
      }
      handle(descriptors)
      processExpiredRedraws()
      reapChildren()
      flushConnections()
      closeMarkedConnections()
    }
    shutdown()
  }

  /// The nearest pending redraw's deadline overrides the ordinary idle/-1 timeout whenever one is
  /// outstanding, so the loop wakes up to resize-back-and-signal even with no other activity —
  /// without ever blocking inside a `usleep` the way the redraw used to.
  private func pollTimeout(isIdle: Bool) -> Int32 {
    guard let nearest = pendingRedraws.values.map(\.deadline).min() else {
      return isIdle ? idleTimeout : -1
    }
    let remainingMilliseconds = (nearest - SessionClock.monotonicSeconds()) * 1000
    return Int32(max(0, remainingMilliseconds.rounded(.up)))
  }

  /// Resize each expired pending redraw back to its real size and signal, non-blockingly. Collects
  /// expired keys into a copy first — mutating `pendingRedraws` while iterating it directly is
  /// unsafe. A session that died before its deadline is silently dropped: nothing to resize.
  @discardableResult
  private func processExpiredRedraws() -> Bool {
    guard !pendingRedraws.isEmpty else { return false }
    let now = SessionClock.monotonicSeconds()
    let expired = pendingRedraws.filter { $0.value.deadline <= now }
    guard !expired.isEmpty else { return false }
    for (identifier, pending) in expired {
      pendingRedraws.removeValue(forKey: identifier)
      guard let session = sessions[identifier] else { continue }
      SessionPTY.resize(
        masterDescriptor: session.masterDescriptor, columns: pending.columns, rows: pending.rows)
      SessionPTY.requestRedraw(
        masterDescriptor: session.masterDescriptor, fallbackProcessID: session.processID)
    }
    return true
  }

  private func shutdown() {
    for session in Array(sessions.values) {
      closeMaster(session)
    }
    for descriptor in connections.keys {
      SessionIO.close(descriptor)
    }
    SessionIO.close(listener)
    unlink(socketPath)
    // Deliberately NOT unlinking the lock file: closing this descriptor releases the flock on
    // its inode, but the path stays put so the next daemon's `acquireLock` opens the SAME inode
    // and re-flocks it. Unlinking here would leave a window where the path still exists but is
    // unlocked — a racing daemon could open+flock that inode before we unlink it, and a THIRD
    // daemon started after our unlink would then create a brand-new inode and also succeed,
    // leaving two daemons simultaneously believing they're the sole instance.
    SessionIO.close(lockDescriptor)
  }

  private func buildPollDescriptors() -> [pollfd] {
    var descriptors: [pollfd] = [
      pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
      pollfd(fd: signalPipe.readDescriptor, events: Int16(POLLIN), revents: 0),
    ]
    for connection in connections.values {
      var events = Int32(POLLIN)
      if connection.hasPendingOutput { events |= Int32(POLLOUT) }
      descriptors.append(pollfd(fd: connection.descriptor, events: Int16(events), revents: 0))
    }
    for session in sessions.values where session.masterDescriptor >= 0 {
      var events: Int32 = 0
      if !isClientBackedUp(session) { events |= Int32(POLLIN) }
      if session.hasPendingInput { events |= Int32(POLLOUT) }
      guard events != 0 else { continue }
      descriptors.append(pollfd(fd: session.masterDescriptor, events: Int16(events), revents: 0))
    }
    return descriptors
  }

  private func isClientBackedUp(_ session: PTYSession) -> Bool {
    guard let descriptor = session.clientDescriptor,
      let connection = connections[descriptor]
    else { return false }
    return connection.pendingByteCount >= Self.clientOutputLimit
  }

  private func handle(_ descriptors: [pollfd]) {
    for entry in descriptors where entry.revents != 0 {
      if entry.fd == listener {
        acceptConnections()
      } else if entry.fd == signalPipe.readDescriptor {
        signalPipe.drain()
      } else if connections[entry.fd] != nil {
        handleConnection(entry)
      } else if let identifier = sessionsByMaster[entry.fd] {
        handleMaster(entry, identifier: identifier)
      }
    }
  }

  private func acceptConnections() {
    while let descriptor = SessionSocket.accept(listener) {
      guard connections.count < Self.maximumConnections else {
        SessionIO.close(descriptor)
        continue
      }
      guard SessionSocket.peerUserID(descriptor) == getuid() else {
        SessionLog.write("rejected connection from another user")
        SessionIO.close(descriptor)
        continue
      }
      connections[descriptor] = SessionConnection(descriptor: descriptor)
    }
  }

  private func handleConnection(_ entry: pollfd) {
    guard let connection = connections[entry.fd] else { return }
    if entry.revents & Int16(POLLOUT) != 0, !connection.flush() {
      markForClose(entry.fd)
      return
    }
    guard entry.revents & Int16(POLLIN) != 0 || entry.revents & Int16(POLLHUP) != 0 else { return }

    var reachedEnd = false
    readLoop: while true {
      switch SessionIO.read(entry.fd) {
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
      do {
        guard let frame = try connection.decoder.next() else { break }
        handle(frame: frame, connection: connection)
      } catch {
        SessionLog.write("dropping connection with a malformed frame")
        markForClose(entry.fd)
        return
      }
    }

    if reachedEnd { markForClose(entry.fd) }
  }

  private func handle(frame: SessionFrame, connection: SessionConnection) {
    switch frame.kind {
    case .attach:
      handleAttach(payload: frame.payload, connection: connection)
    case .input:
      guard let identifier = connection.attachedSession, let session = sessions[identifier] else {
        return
      }
      session.appendInput(frame.payload, limit: Self.sessionInputLimit)
      session.flushInput()
    case .resize:
      guard let identifier = connection.attachedSession,
        let session = sessions[identifier],
        let size = try? SessionResizePayload.decode(frame.payload)
      else { return }
      guard SessionWindowSizePolicy.isUsable(columns: size.columns, rows: size.rows) else { return }
      SessionPTY.resize(
        masterDescriptor: session.masterDescriptor, columns: size.columns, rows: size.rows)
    case .list:
      connection.enqueue(
        SessionFrame(
          kind: .sessions,
          payload: SessionDescriptor.encodeList(sessions.values.map(\.descriptor))))
    case .info:
      guard let identifier = try? SessionIdentifierPayload.decode(frame.payload) else { return }
      let matches = sessions[identifier].map { [$0.descriptor] } ?? []
      connection.enqueue(
        SessionFrame(kind: .sessions, payload: SessionDescriptor.encodeList(matches)))
    case .kill:
      let stopped: Bool
      if let identifier = try? SessionIdentifierPayload.decode(frame.payload),
        let session = sessions[identifier]
      {
        stopped = endSession(session, status: 0, force: true)
      } else {
        stopped = true
      }
      enqueueStopResult(stopped, connection: connection)
    case .killAll:
      enqueueStopResult(endSessions(Array(sessions.values), status: 0), connection: connection)
    case .attached, .output, .exited, .failure, .sessions, .acknowledged:
      break
    }
  }

  private func handleAttach(payload: [UInt8], connection: SessionConnection) {
    guard let request = try? SessionAttachRequest.decode(payload) else {
      connection.enqueue(
        SessionFrame(
          kind: .failure, payload: SessionTextPayload.encode("malformed attach request")))
      connection.closesAfterFlush = true
      return
    }
    guard request.version == SessionProtocolVersion.current else {
      connection.enqueue(
        SessionFrame(
          kind: .failure,
          payload: SessionTextPayload.encode(
            "this background session is owned by a different version of Workroom; stop it to start a new one"
          )))
      connection.closesAfterFlush = true
      return
    }
    guard connection.attachedSession == nil else { return }

    if let session = sessions[request.identifier] {
      attach(session: session, request: request, connection: connection)
      return
    }
    create(request: request, connection: connection)
  }

  private func attach(
    session: PTYSession, request: SessionAttachRequest, connection: SessionConnection
  ) {
    if let previous = session.clientDescriptor, previous != connection.descriptor {
      connections[previous]?.attachedSession = nil
      markForClose(previous)
    }
    session.clientDescriptor = connection.descriptor
    session.metadata = request.metadata
    connection.attachedSession = session.identifier

    if SessionWindowSizePolicy.isUsable(columns: request.columns, rows: request.rows) {
      SessionPTY.resize(
        masterDescriptor: session.masterDescriptor,
        columns: request.columns,
        rows: request.rows)
    }
    connection.enqueue(
      SessionFrame(
        kind: .attached,
        payload: SessionAttachAccepted(
          created: false,
          shellProcessID: session.processID,
          ttyDevice: session.ttyDevice
        ).encoded()))
    // Synthesize a fresh title (OSC 2) and pwd (OSC 7) from the pty's CURRENT foreground process
    // before replaying anything. Both are normally set once by the shell's preexec/prompt hooks —
    // one-shot escapes emitted on the PRIMARY screen, before the foreground program (typically)
    // switches to the alternate screen — and `SessionReplayBuffer` drops its buffer the moment the
    // alternate screen activates, so a reattaching client never sees them; the foreground program
    // itself has no reason to re-emit either on the redraw `requestRedraw` forces. Excluding the
    // shell's own pgid (`forkpty` makes an idle prompt's foreground group equal `session.processID`)
    // keeps an idle reattached pane from showing a phantom "zsh"/"bash" title and stale pwd.
    if let group = SessionPTY.foregroundProcessGroup(masterDescriptor: session.masterDescriptor),
      group != session.processID
    {
      // Sanitized before ANY use below — both the log line and the OSC payloads. `name`/`cwd` come
      // from OS process introspection (an exec'd argv[0], a directory's real name) and can legally
      // contain any byte a filesystem path or exec argument allows, including a raw ESC or BEL. Left
      // unsanitized, such a byte would prematurely terminate the OSC 2/7 sequence it's interpolated
      // into (from the terminal's perspective) and let the remainder be reinterpreted as fresh,
      // attacker-chosen escape/terminal input in the reattaching client.
      let name = SessionPTY.executableName(processID: group).map(Self.sanitizedForEscapeSequence)
      let cwd = SessionPTY.workingDirectory(processID: group).map(Self.sanitizedForEscapeSequence)
      SessionLog.write(
        "attach \(session.identifier.uuidString): foreground pgid=\(group) name="
          + "\(name ?? "?") cwd=\(cwd ?? "?")")
      if let name, !name.isEmpty {
        connection.enqueue(
          SessionFrame(kind: .output, payload: Array("\u{1B}]2;\(name)\u{07}".utf8)))
      }
      if let cwd, !cwd.isEmpty {
        // Ghostty's OSC 7 handler validates the host against the local machine's hostname before
        // accepting the path (`internal_os.hostname.isLocal`) — except for the literal string
        // "localhost", which it special-cases as always-local. A locally-forked pty is never
        // remote, so that's the simpler, mismatch-proof choice over resolving the real hostname.
        connection.enqueue(
          SessionFrame(
            kind: .output, payload: Array("\u{1B}]7;kitty-shell-cwd://localhost\(cwd)\u{07}".utf8)))
      }
    } else {
      SessionLog.write(
        "attach \(session.identifier.uuidString): foreground is the login shell "
          + "(pid=\(session.processID)); skipping title/pwd synthesis")
    }
    enqueueReplay(session: session, connection: connection)
    // Query the CURRENT size fresh rather than trusting `request.columns/rows` — those may have
    // been rejected as unusable above (a transient tiny size from a not-yet-laid-out surface), in
    // which case the redraw must still bump from/to whatever size the session's pty actually has.
    //
    // The bump happens now (cheap, a single ioctl); the resize-back-and-signal is DEFERRED to the
    // poll loop (`processExpiredRedraws`), not done here inline with a blocking sleep — this daemon
    // is single-threaded and serves every session across every open project, so sleeping here would
    // freeze all of them for the duration, worst case stacking to N × the settle window when many
    // persisted tabs reattach at once on relaunch.
    if let current = SessionPTY.windowSize(descriptor: session.masterDescriptor) {
      SessionPTY.resize(
        masterDescriptor: session.masterDescriptor, columns: current.columns,
        rows: SessionPTY.bumpedRowCount(current.rows))
      pendingRedraws[session.identifier] = PendingRedraw(
        deadline: SessionClock.monotonicSeconds() + Self.redrawSettleSeconds,
        columns: current.columns, rows: current.rows)
    }
  }

  private func enqueueReplay(session: PTYSession, connection: SessionConnection) {
    let bytes = session.replay.replayBytes
    guard !bytes.isEmpty else { return }
    SessionLog.write(
      "attach \(session.identifier.uuidString): replaying \(bytes.count) bytes: "
        + Self.escapedPreview(bytes))
    var index = 0
    while index < bytes.count {
      let end = min(index + Self.replayChunkSize, bytes.count)
      connection.enqueue(SessionFrame(kind: .output, payload: Array(bytes[index..<end])))
      index = end
    }
  }

  private func create(request: SessionAttachRequest, connection: SessionConnection) {
    guard sessions.count < Self.maximumSessions else {
      connection.enqueue(
        SessionFrame(
          kind: .failure,
          payload: SessionTextPayload.encode("too many background sessions")))
      connection.closesAfterFlush = true
      return
    }
    let invocation = SessionShellIntegration.invocation(
      command: request.command,
      shell: request.shell,
      resourcesDirectory: request.resourcesDirectory,
      environment: request.environment)
    let size = SessionWindowSizePolicy.createSize(columns: request.columns, rows: request.rows)
    guard
      let process = SessionPTY.spawn(
        invocation: invocation,
        workingDirectory: request.workingDirectory,
        columns: size.columns,
        rows: size.rows)
    else {
      connection.enqueue(
        SessionFrame(
          kind: .failure, payload: SessionTextPayload.encode("failed to start the session")))
      connection.closesAfterFlush = true
      return
    }

    let session = PTYSession(
      identifier: request.identifier,
      process: process,
      workingDirectory: request.workingDirectory,
      replayCapacity: Self.replayCapacity)
    session.clientDescriptor = connection.descriptor
    session.metadata = request.metadata
    sessions[request.identifier] = session
    sessionsByMaster[process.masterDescriptor] = request.identifier
    connection.attachedSession = request.identifier

    connection.enqueue(
      SessionFrame(
        kind: .attached,
        payload: SessionAttachAccepted(
          created: true,
          shellProcessID: process.processID,
          ttyDevice: process.ttyDevice
        ).encoded()))
  }

  private func handleMaster(_ entry: pollfd, identifier: SessionIdentifier) {
    guard let session = sessions[identifier] else { return }
    if entry.revents & Int16(POLLOUT) != 0 {
      session.flushInput()
    }
    guard
      entry.revents & Int16(POLLIN) != 0
        || entry.revents & Int16(POLLHUP) != 0
        || entry.revents & Int16(POLLNVAL) != 0
    else { return }

    readLoop: while true {
      switch SessionIO.read(session.masterDescriptor) {
      case .bytes(let bytes):
        session.replay.append(bytes)
        if let descriptor = session.clientDescriptor, let connection = connections[descriptor] {
          connection.enqueue(SessionFrame(kind: .output, payload: bytes))
        }
        if isClientBackedUp(session) { break readLoop }
      case .wouldBlock:
        break readLoop
      case .endOfFile, .failed:
        closeMaster(session)
        return
      }
    }
  }

  private func closeMaster(_ session: PTYSession) {
    guard session.masterDescriptor >= 0 else { return }
    sessionsByMaster.removeValue(forKey: session.masterDescriptor)
    SessionIO.close(session.masterDescriptor)
    session.masterDescriptor = -1
    session.isEnding = true
    SessionPTY.terminate(processID: session.processID)
  }

  @discardableResult
  private func endSession(_ session: PTYSession, status: Int32, force: Bool = false) -> Bool {
    closeMaster(session)
    guard !force || SessionPTY.forceTerminate(processID: session.processID) else {
      SessionLog.write("failed to stop session \(session.identifier.uuidString)")
      return false
    }
    finishSession(session, status: status)
    return true
  }

  private func endSessions(_ endingSessions: [PTYSession], status: Int32) -> Bool {
    for session in endingSessions { closeMaster(session) }
    let failedProcessIDs = SessionPTY.forceTerminate(processIDs: endingSessions.map(\.processID))
    for session in endingSessions where !failedProcessIDs.contains(session.processID) {
      finishSession(session, status: status)
    }
    for session in endingSessions where failedProcessIDs.contains(session.processID) {
      SessionLog.write("failed to stop session \(session.identifier.uuidString)")
    }
    return failedProcessIDs.isEmpty
  }

  private func finishSession(_ session: PTYSession, status: Int32) {
    sessions.removeValue(forKey: session.identifier)
    guard let descriptor = session.clientDescriptor, let connection = connections[descriptor]
    else { return }
    connection.enqueue(
      SessionFrame(kind: .exited, payload: SessionExitPayload.encode(status: status)))
    connection.attachedSession = nil
    connection.closesAfterFlush = true
    session.clientDescriptor = nil
  }

  private func enqueueStopResult(_ stopped: Bool, connection: SessionConnection) {
    let frame =
      stopped
      ? SessionFrame(kind: .acknowledged)
      : SessionFrame(
        kind: .failure, payload: SessionTextPayload.encode("failed to stop one or more sessions"))
    connection.enqueue(frame)
  }

  private func reapChildren() {
    while true {
      var status: Int32 = 0
      let processID = waitpid(-1, &status, WNOHANG)
      guard processID > 0 else { return }
      guard let session = sessions.values.first(where: { $0.processID == processID }) else {
        continue
      }
      endSession(session, status: Self.exitCode(status))
    }
  }

  static func exitCode(_ status: Int32) -> Int32 {
    let terminationSignal = status & 0o177
    if terminationSignal == 0 { return (status >> 8) & 0xFF }
    if terminationSignal == 0o177 { return 0 }
    return 128 + terminationSignal
  }

  /// Renders bytes for a log line: printable ASCII passes through, `ESC` becomes `<ESC>` (so
  /// escape-sequence boundaries are visible at a glance), everything else becomes `\xNN`. Capped so
  /// one attach with a large buffer can't blow up the log file.
  private static func escapedPreview(_ bytes: [UInt8], limit: Int = 2048) -> String {
    let hexDigits = Array("0123456789ABCDEF")
    var result = ""
    for byte in bytes.prefix(limit) {
      switch byte {
      case 0x1B:
        result += "<ESC>"
      case 0x20...0x7E:
        result.append(Character(UnicodeScalar(byte)))
      default:
        result += "\\x"
        result.append(hexDigits[Int(byte >> 4)])
        result.append(hexDigits[Int(byte & 0x0F)])
      }
    }
    if bytes.count > limit { result += "…(+\(bytes.count - limit) more bytes)" }
    return result
  }

  /// Strips C0 controls (0x00–0x1F), DEL (0x7F), and C1 controls (0x80–0x9F) — the bytes an 8-bit
  /// or 7-bit terminal could read as an escape/CSI/OSC introducer or terminator — from a value
  /// before it's interpolated into an OSC payload or a log line. `name`/`cwd` come from OS process
  /// introspection (`SessionPTY.executableName`/`workingDirectory`), not from this daemon's own
  /// generated data, so they must be treated as untrusted content here.
  private static func sanitizedForEscapeSequence(_ value: String) -> String {
    String(
      String.UnicodeScalarView(
        value.unicodeScalars.filter { scalar in
          scalar.value >= 0x20 && scalar.value != 0x7F
            && !(0x80...0x9F).contains(scalar.value)
        }))
  }

  private func flushConnections() {
    for connection in connections.values {
      if !connection.flush() {
        markForClose(connection.descriptor)
        continue
      }
      if connection.closesAfterFlush, !connection.hasPendingOutput {
        markForClose(connection.descriptor)
      }
    }
  }

  private func markForClose(_ descriptor: Int32) {
    guard !closingDescriptors.contains(descriptor) else { return }
    closingDescriptors.append(descriptor)
  }

  private func closeMarkedConnections() {
    let descriptors = closingDescriptors
    closingDescriptors.removeAll(keepingCapacity: true)
    for descriptor in descriptors {
      guard let connection = connections.removeValue(forKey: descriptor) else { continue }
      if let identifier = connection.attachedSession,
        let session = sessions[identifier],
        session.clientDescriptor == descriptor
      {
        session.clientDescriptor = nil
      }
      SessionIO.close(descriptor)
    }
  }
}
