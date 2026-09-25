import Darwin
import Foundation

/// How a provider's hosts are reached and what they can do, declared so a provider can be gated
/// when it is chosen (design doc, Phase 3 "the stream drivers", and Premise 8).
struct HostDriverTraits: Equatable, Sendable {
  enum Transport: Equatable, Sendable { case sshStdio, sdkExec, webSocket }

  let transport: Transport
  /// Roughly how long `deriveFromBase` takes, or nil for a driver that cannot derive yet.
  let deriveSpeed: Duration?
  /// Whether a derived instance carries the base's running processes (a live fork), or only its
  /// disk.
  let deriveCarriesLiveProcesses: Bool
  let durableDisk: Bool
  /// The wall clock an instance dies on, or nil for one that lives until destroyed.
  let maxLifetime: Duration?
}

/// One provider. Four methods, and the only one that is not provisioning is `openStream`
/// (design doc, Phase 3). `deriveFromBase` is the ONLY way a workroom instance comes to exist;
/// `create` makes the base it derives from.
///
/// **Every driver must authenticate its peer as strongly as a shell login.** The agent's exec
/// service runs `git` with arbitrary arguments, which is arbitrary code execution, so a stream
/// that reaches an agent is a shell whatever it is called. ssh meets that bar; an SDK exec or a
/// WebSocket driver must show it does before it counts as a driver.
protocol HostDriver: Sendable {
  var traits: HostDriverTraits { get }
  /// Provisions a base.
  func create() async throws -> HostID
  /// Provisions a workroom instance from `base`.
  func deriveFromBase(_ base: HostID) async throws -> HostID
  /// Takes down a base or an instance.
  func destroy(_ host: HostID) async throws
  /// A byte stream to the agent on `host`, base or instance, for
  /// `AgentVCSConnection.connect(host:stream:)`. Not the first thing to open on a host:
  /// `AgentBootstrap.connect` runs the bootstrap first (#231), which is what puts an agent there.
  func openStream(to host: HostID) async throws -> HostStream
  /// Runs `command`, a line for the host's shell, with the returned stream as its stdin and stdout:
  /// a one-off exchange (`HostStream.communicate`) rather than a connection, for what the agent
  /// bootstrap runs before there is an agent to talk to (#231). For ssh it is the remote command;
  /// an SDK driver runs it through the provider's exec call. `openStream` is this with the relay
  /// as the command.
  func exec(_ command: String, on host: HostID) async throws -> HostStream
}

enum PosixShell {
  /// One POSIX shell word, whatever `text` holds.
  static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

/// A driver whose hosts a terminal pane can attach to.
///
/// Not a fifth `HostDriver` method, and not `openStream`: a pane is a process libghostty spawns and
/// wires to its own pty, and a socketpair made in this process cannot become one. So the driver
/// hands over a command instead. For ssh that is `ssh -t <host> wr-agent attach …`, the far side's
/// attach client running in the pty ssh allocates there. An SDK-exec driver has no such command,
/// and would need a local bridge process: a Phase 4 question (design doc, Phase 3).
protocol HostTerminalDriver: HostDriver {
  /// The command a pane runs to attach to `session` on `host`, starting in `workingDirectory` if
  /// the session is new. `restored` for a pane reattaching after a relaunch or a lost link: the
  /// session must already exist there, and if it has ended the pane gets a shell that says so
  /// rather than a fresh one that looks like it (`wr-agent attach --no-create`).
  func attachCommand(to host: HostID, session: UUID, workingDirectory: String, restored: Bool)
    throws -> String
}

enum HostDriverError: Error, Equatable, Sendable, LocalizedError {
  case unknownHost(HostID)
  /// Provisioning lands in Phase 4, which is what says how a base and an instance come to exist.
  case notImplemented(String)
  case invalidConfiguration(String)

  var errorDescription: String? {
    switch self {
    case .unknownHost: return "This driver has no such host."
    case .notImplemented(let what): return "\(what) is not implemented yet."
    case .invalidConfiguration(let detail): return "Invalid host configuration: \(detail)"
    }
  }
}

/// A bidirectional byte stream to the agent on a far-side host: one end of a socketpair, whose
/// other end is the stdin and stdout of the local process carrying it (`ssh host wr-agent relay`).
///
/// Whoever connects over it owns both: `AgentVCSConnection` closes the descriptor and ends the
/// process with the connection. The carrier's exit is also how a lost link is noticed. The child
/// holds the only copy of its end of the pair, so when it exits, that end closes and the next read
/// on this one sees EOF.
final class HostStream: @unchecked Sendable {
  let descriptor: Int32
  /// How long the agent's greeting may take: a local relay answers at once, ssh must connect and
  /// authenticate first.
  let handshakeTimeout: TimeInterval
  private let process: Process
  private let lock = NSLock()
  private var errors = Data()
  /// stderr reached EOF: everything the carrier said is in `errors`.
  private var errorsClosed = false
  /// `end()` stopped a carrier that was still running, so its exit status is our own signal.
  private var endedByUs = false
  /// A connection took the descriptor and the process (`handOff`), so `deinit` leaves them alone.
  private var handedOff = false
  /// How the carrier exited, from its `terminationHandler`, which `exited` signals once.
  private var exit: (status: Int32, reason: Process.TerminationReason)?
  private let exited = DispatchSemaphore(value: 0)

  var processIdentifier: Int32 { process.processIdentifier }

  private init(descriptor: Int32, process: Process, handshakeTimeout: TimeInterval) {
    self.descriptor = descriptor
    self.process = process
    self.handshakeTimeout = handshakeTimeout
  }

  /// A stream nothing connected over is still this object's: an ssh whose stdin never reads EOF
  /// holds a healthy link open for good.
  deinit {
    guard !lock.withLock({ handedOff }) else { return }
    Darwin.close(descriptor)
    end()
  }

  /// Gives the descriptor and the process to the connection made over them, which closes and ends
  /// them from then on.
  func handOff() -> Int32 {
    lock.withLock { handedOff = true }
    return descriptor
  }

  /// Runs `executable` with a socketpair end as both its stdin and its stdout.
  ///
  /// `environment` is the carrier's WHOLE environment, never merged with the app's: whatever it
  /// holds can reach the far side, so a driver passes exactly what its transport needs.
  static func spawn(
    _ executable: URL, _ arguments: [String], environment: [String: String],
    handshakeTimeout: TimeInterval
  ) throws -> HostStream {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw HostConnectionError.serviceUnavailable("socketpair failed: errno \(errno)")
    }
    let (ours, theirs) = (pair[0], pair[1])
    AgentVCSConnection.noSignalOnWrite(ours)
    // Close-on-exec on both, so a process spawned later cannot inherit an end: a stray copy of the
    // child's end would keep it open after the carrier exits, and the lost link would never read
    // as EOF here. There is still a window between `socketpair` and these two calls, which Darwin
    // cannot close (it has no `SOCK_CLOEXEC`); Foundation's own spawns close every descriptor they
    // were not given, so only a raw `fork` in that window could catch one. The spawn below dup2s
    // the child's end onto 0 and 1, which clears the flag on those copies only.
    _ = fcntl(ours, F_SETFD, FD_CLOEXEC)
    _ = fcntl(theirs, F_SETFD, FD_CLOEXEC)

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let child = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
    process.standardInput = child
    process.standardOutput = child
    let errors = Pipe()
    process.standardError = errors
    let stream = HostStream(
      descriptor: ours, process: process, handshakeTimeout: handshakeTimeout)
    errors.fileHandleForReading.readabilityHandler = { [weak stream] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        stream?.lock.withLock { stream?.errorsClosed = true }
        return
      }
      stream?.collect(data)
    }
    // The exit is taken from this handler, never from `waitUntilExit` or `isRunning` alone: with
    // the process launched from an async context (`HostDriver.exec`'s caller) and the wait on a
    // GCD thread, `waitUntilExit` hung `communicate` for good after the child had exited
    // (observed; `SessionBackendProbe` and `ShellEnvironment`, which launch and wait on one
    // thread, do not hit it). The handler is delivered on a dispatch queue whatever the launching
    // thread, which is what `StatusCommandRunner` relies on too.
    process.terminationHandler = { [weak stream] finished in
      stream?.lock.withLock {
        stream?.exit = (finished.terminationStatus, finished.terminationReason)
      }
      stream?.exited.signal()
    }
    do {
      try process.run()
    } catch {
      // Only the child's end: `ours` is the stream's, and its `deinit` closes it on the way out.
      Darwin.close(theirs)
      errors.fileHandleForReading.readabilityHandler = nil
      throw HostConnectionError.serviceUnavailable(
        "Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
    }
    // The child now holds the only copy. Keeping this one would hide the child's exit.
    Darwin.close(theirs)
    return stream
  }

  /// Ends the carrier. Idempotent, and safe after it has exited by itself.
  func end() {
    guard process.isRunning, lock.withLock({ exit == nil }) else { return }
    lock.withLock { endedByUs = true }
    process.terminate()
  }

  /// The carrier as a plain command (`HostDriver.exec`): sends `input` as its stdin and closes
  /// it, reads its stdout to EOF, and waits for it to exit. `output` is what it printed, with
  /// its stderr after. Nothing connects over the stream afterwards.
  ///
  /// `timeout` bounds SILENCE, not the exchange: it is reset by every byte sent or received, and
  /// only a link that moves nothing for that long is ended, with this throwing. A bound on the
  /// whole exchange would be a throughput floor for an 11 MB push over a slow link, the
  /// `WRITE_TIMEOUT` mistake macapp/CLAUDE.md records.
  ///
  /// The writes and reads block, on GCD (`runBlocking`), not the cooperative pool: an 11 MB
  /// binary over a slow link is exactly the kind of wait that starves other blocking work there.
  func communicate(_ input: Data?, timeout: TimeInterval) async throws -> (
    status: Int32, output: String
  ) {
    let fd = descriptor
    let process = self.process
    let name = process.executableURL?.lastPathComponent ?? "carrier"
    // On silence: end the carrier, and shut the socket down too, which wakes a `send` or `recv`
    // below whatever the carrier does about SIGTERM (a child of its own holding the far end, say).
    let watchdog = SilenceWatchdog(timeout) { [weak self] in
      self?.end()
      // Two calls: on macOS `SHUT_RDWR` does nothing once the peer has shut its side.
      shutdown(fd, SHUT_RD)
      shutdown(fd, SHUT_WR)
    }
    defer { watchdog.stop() }
    // A cancelled caller (a pane closed, a host removed mid-push) ends the exchange the same way,
    // rather than leaving `runBlocking`, which cannot be cancelled, pushing 11 MB to no one.
    let (printed, exit): (Data, (status: Int32, reason: Process.TerminationReason)?) =
      try await withTaskCancellationHandler {
        try await runBlocking {
          if let input {
            input.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
              var sent = 0
              while sent < bytes.count {
                // In pieces, so `heard()` ticks as the link drains: one `send` of the whole 11 MB
                // would return only once the last byte was queued, and the silence bound would be
                // a transfer bound after all.
                let count = Darwin.send(
                  fd, bytes.baseAddress! + sent, min(bytes.count - sent, 64 * 1024), 0)
                if count < 0, errno == EINTR { continue }
                // `EPIPE` (`SO_NOSIGPIPE` is set), not a signal: the far side stopped reading.
                // What it printed before it did (`cat` failing to open its file, say) is still the
                // answer, so this goes on to read it rather than throwing.
                guard count > 0 else { break }
                sent += count
                watchdog.heard()
              }
            }
          }
          // EOF on the command's stdin, which is what ends a `cat >` there. Half-closed: its stdout
          // still flows back.
          shutdown(fd, SHUT_WR)
          var collected = Data()
          var chunk = [UInt8](repeating: 0, count: 64 * 1024)
          while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            // The scripts print a few lines; the first 1 MiB is kept (a host's shell startup
            // could be chatty), the rest drained, so a host that never stops printing cannot
            // grow the app.
            if collected.count < 1024 * 1024 { collected.append(chunk, count: count) }
            watchdog.heard()
          }
          watchdog.stop()
          // EOF on its output means the command closed it, not that it has exited; a bounded wait
          // for the handler (see `spawn`) covers a child of its own holding the descriptor open.
          guard self.exited.wait(timeout: .now() + 5) == .success else { return (collected, nil) }
          return (collected, self.lock.withLock { self.exit })
        }
      } onCancel: {
        self.end()
        shutdown(fd, SHUT_RD)
        shutdown(fd, SHUT_WR)
      }
    try Task.checkCancellation()
    guard let exit else {
      end()
      throw HostConnectionError.serviceUnavailable("\(name) closed its output but did not exit")
    }
    // The watchdog's own kill, whatever the carrier made of the SIGTERM (ssh catches it and exits
    // 255 by itself, so its reason is `.exit`). A carrier that exited 0 by itself in the same
    // instant is not exempt: its `SHUT_RD` may have discarded the last line queued, and a report
    // short of one line reads as an answer (a probe whose hand-off was refused reads as current).
    guard !watchdog.fired else {
      throw HostConnectionError.serviceUnavailable(
        "\(name) moved nothing for \(Int(timeout.rounded(.up)))s")
    }
    // Its stderr may still be draining through the readability handler after the exit.
    for _ in 0..<40 where !lock.withLock({ errorsClosed }) {
      try? await Task.sleep(for: .milliseconds(50))
    }
    let said = lock.withLock { String(decoding: errors, as: UTF8.self) }
    var output = String(decoding: printed, as: UTF8.self)
    if !said.isEmpty { output += (output.hasSuffix("\n") || output.isEmpty ? "" : "\n") + said }
    return (exit.status, output)
  }

  /// What the carrier said about why the stream ended, for a handshake it never answered: its
  /// stderr, or failing that how it ended. Waits for stderr to reach EOF rather than for the
  /// process to be reaped: the two are separate events, and the reason ("Host key verification
  /// failed.") is in the first.
  func failure() async -> String {
    for _ in 0..<40 where lock.withLock({ !errorsClosed || self.exit == nil }) {
      try? await Task.sleep(for: .milliseconds(50))
    }
    let (said, endedByUs, exit) = lock.withLock {
      (String(decoding: errors, as: UTF8.self), self.endedByUs, self.exit)
    }
    let reason = said.trimmingCharacters(in: .whitespacesAndNewlines)
    if !reason.isEmpty { return reason }
    let name = process.executableURL?.lastPathComponent ?? "carrier"
    // From the handler, never `terminationStatus` on the process: that raises an Objective-C
    // exception for a process not yet reaped, which Swift cannot catch, and a carrier stopped a
    // moment ago can still be unreaped once the wait above gives up.
    guard let exit else { return "\(name) did not answer in time" }
    // Our own SIGTERM, from `end()`: the carrier was still running when the handshake gave up.
    if endedByUs, exit.reason == .uncaughtSignal, exit.status == SIGTERM {
      return "\(name) did not answer in time"
    }
    return "\(name) exited with status \(exit.status)"
  }

  /// Fires `onSilence` once nothing has been `heard()` for `limit`, then never again. Each check
  /// is scheduled for `limit` after the last thing heard, so it fires at most `limit` late.
  /// Uptime, not the wall clock, which sleep and NTP move. `onSilence` runs under the lock, so a
  /// `stop()` cannot return while it runs: the descriptor it shuts down is still the exchange's,
  /// never one closed and reused by the next `exec` in between.
  private final class SilenceWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var last = DispatchTime.now()
    private var stopped = false
    private var hasFired = false
    private let limit: TimeInterval
    private let onSilence: @Sendable () -> Void

    init(_ limit: TimeInterval, onSilence: @escaping @Sendable () -> Void) {
      self.limit = limit
      self.onSilence = onSilence
      schedule(after: limit)
    }

    var fired: Bool { lock.withLock { hasFired } }
    func heard() { lock.withLock { last = DispatchTime.now() } }
    func stop() { lock.withLock { stopped = true } }

    private func schedule(after delay: TimeInterval) {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
        [weak self] in
        guard let self else { return }
        let remaining: TimeInterval? = self.lock.withLock {
          guard !self.stopped else { return nil }
          let quiet =
            Double(DispatchTime.now().uptimeNanoseconds - self.last.uptimeNanoseconds) / 1e9
          guard quiet >= self.limit else { return self.limit - quiet }
          self.hasFired = true
          self.onSilence()
          return nil
        }
        if let remaining { self.schedule(after: remaining) }
      }
    }
  }

  /// Keeps the first 16 KiB of stderr: enough for any diagnosis, and bounded against a chatty one.
  private func collect(_ data: Data) {
    lock.withLock {
      guard errors.count < 16 * 1024 else { return }
      errors.append(data.prefix(16 * 1024 - errors.count))
    }
  }
}
