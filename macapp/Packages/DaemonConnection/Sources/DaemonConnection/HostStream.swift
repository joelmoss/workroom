import Darwin
import Foundation
import WorkroomSystem

/// A bidirectional byte stream to the daemon on a far-side host: one end of a socketpair, whose
/// other end is the stdout of the local process carrying it (`ssh host workroomd relay`), and its
/// stdin too for a connection (see `Purpose`).
///
/// Whoever connects over it owns both: `DaemonVCSConnection` closes the descriptor and ends the
/// process with the connection. The carrier's exit is also how a lost link is noticed. The child
/// holds the only copy of its end of the pair, so when it exits, that end closes and the next read
/// on this one sees EOF.
public final class HostStream: @unchecked Sendable {
  /// What the stream is spawned for, which decides how the carrier's stdin is wired.
  public enum Purpose {
    /// A connection (`DaemonVCSConnection.connect(host:stream:)`): the carrier's stdin and stdout
    /// are one socket, the descriptor handed off.
    case connection
    /// A one-off exchange (`communicate`): the carrier's stdin is a socketpair of its own, so the
    /// end of the input can be a `close` of it. A `shutdown(SHUT_WR)` of a shared socket, the
    /// other way to half-close, is recorded on the far end but does not always wake a carrier
    /// blocked in `read` there: it sleeps on with the EOF unread (#305; measured in a C harness,
    /// 4 in 1600 exchanges with `sh -c 'wc -c'`, none in 2500 with this). A carrier that `poll`s
    /// its stdin saw that EOF every time (none in 2500).
    case exchange
  }

  public let descriptor: Int32
  /// How long the daemon's greeting may take: a local relay answers at once, ssh must connect and
  /// authenticate first.
  public let handshakeTimeout: TimeInterval
  private let process: Process
  private let purpose: Purpose
  private let lock = NSLock()
  /// An exchange's end of the carrier's stdin, until `communicate` closes it to send EOF. Taken
  /// under `lock` both to close and to shut down, so a shutdown never lands on a descriptor
  /// number already closed and reused by something else.
  private var inputDescriptor: Int32?
  /// `communicate` has claimed the stream. Set in the same `withLock` that reads
  /// `inputDescriptor`, so two concurrent calls cannot both pass (#316).
  private var communicating = false
  private var errors = Data()
  /// stderr reached EOF: everything the carrier said is in `errors`.
  private var errorsClosed = false
  /// Told each piece of output as it arrives, stdout's and stderr's alike (`communicate`).
  private var onOutput: (@Sendable (Data, _ stderr: Bool) -> Void)?
  /// Told stderr spoke, so output there counts against `communicate`'s silence bound too: a pull or
  /// build may report its progress there alone.
  private var heard: (@Sendable () -> Void)?
  /// `end()` stopped a carrier that was still running, so its exit status is our own signal.
  private var endedByUs = false
  /// A connection took the descriptor and the process (`handOff`), so `deinit` leaves them alone.
  private var handedOff = false
  /// How the carrier exited, from its `terminationHandler`, which `exited` signals once.
  private var exit: (status: Int32, reason: Process.TerminationReason)?
  private let exited = DispatchSemaphore(value: 0)

  public var processIdentifier: Int32 { process.processIdentifier }

  private init(
    descriptor: Int32, inputDescriptor: Int32?, process: Process, purpose: Purpose,
    handshakeTimeout: TimeInterval
  ) {
    self.descriptor = descriptor
    self.inputDescriptor = inputDescriptor
    self.process = process
    self.purpose = purpose
    self.handshakeTimeout = handshakeTimeout
  }

  /// A stream nothing connected over is still this object's: an ssh whose stdin never reads EOF
  /// holds a healthy link open for good.
  deinit {
    closeInput()
    guard !lock.withLock({ handedOff }) else { return }
    Darwin.close(descriptor)
    end()
  }

  /// Gives the descriptor and the process to the connection made over them, which closes and ends
  /// them from then on.
  public func handOff() -> Int32 {
    precondition(purpose == .connection, "an exchange's stream is not a connection's")
    lock.withLock { handedOff = true }
    return descriptor
  }

  /// Closes an exchange's end of the carrier's stdin, which is EOF there. Idempotent.
  private func closeInput() {
    lock.withLock {
      guard let inputDescriptor else { return }
      Darwin.close(inputDescriptor)
      self.inputDescriptor = nil
    }
  }

  /// Wakes a `send` blocked on an exchange's input, if it is still open.
  private func shutDownInput() {
    lock.withLock {
      guard let inputDescriptor else { return }
      shutdown(inputDescriptor, SHUT_WR)
    }
  }

  /// A connected pair of stream sockets: ours, with `SO_NOSIGPIPE`, and the child's.
  ///
  /// Close-on-exec on both, so a process spawned later cannot inherit an end: a stray copy of the
  /// child's end would keep it open after the carrier exits, and the lost link would never read
  /// as EOF here. There is still a window between `socketpair` and the `fcntl`s, which Darwin
  /// cannot close (it has no `SOCK_CLOEXEC`); Foundation's own spawns close every descriptor they
  /// were not given, so only a raw `fork` in that window could catch one. The spawn dup2s the
  /// child's end onto its stdin or stdout, which clears the flag on those copies only.
  private static func socketPair() throws -> (ours: Int32, theirs: Int32) {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw HostConnectionError.serviceUnavailable("socketpair failed: errno \(errno)")
    }
    DaemonVCSConnection.noSignalOnWrite(pair[0])
    _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)
    return (pair[0], pair[1])
  }

  /// Runs `executable` with a socketpair end as its stdout, and as its stdin too for a
  /// `.connection`; an `.exchange` gives its stdin a pair of its own (see `Purpose`).
  ///
  /// `environment` is the carrier's WHOLE environment, never merged with the app's: whatever it
  /// holds can reach the far side, so a driver passes exactly what its transport needs.
  public static func spawn(
    _ executable: URL, _ arguments: [String], environment: [String: String],
    handshakeTimeout: TimeInterval, purpose: Purpose
  ) throws -> HostStream {
    let (ours, theirs) = try socketPair()
    let input: (ours: Int32, theirs: Int32)?
    do {
      input = purpose == .exchange ? try socketPair() : nil
    } catch {
      Darwin.close(ours)
      Darwin.close(theirs)
      throw error
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let child = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
    process.standardInput =
      input.map { FileHandle(fileDescriptor: $0.theirs, closeOnDealloc: false) } ?? child
    process.standardOutput = child
    let errors = Pipe()
    process.standardError = errors
    let stream = HostStream(
      descriptor: ours, inputDescriptor: input?.ours, process: process, purpose: purpose,
      handshakeTimeout: handshakeTimeout)
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
      // Only the child's ends: ours are the stream's, and its `deinit` closes them on the way out.
      Darwin.close(theirs)
      if let input { Darwin.close(input.theirs) }
      errors.fileHandleForReading.readabilityHandler = nil
      throw HostConnectionError.serviceUnavailable(
        "Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
    }
    // The child now holds the only copies. Keeping these would hide the child's exit, and keep its
    // stdin from ever reading EOF.
    Darwin.close(theirs)
    if let input { Darwin.close(input.theirs) }
    return stream
  }

  /// Ends the carrier. Idempotent, and safe after it has exited by itself.
  public func end() {
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
  /// `WRITE_TIMEOUT` mistake macapp/AGENTS.md records.
  ///
  /// The writes and reads block, on GCD (`runBlocking`), not the cooperative pool: an 11 MB
  /// binary over a slow link is exactly the kind of wait that starves other blocking work there.
  ///
  /// `onOutput` is told each piece of its output as it arrives, from stdout or stderr (which it is
  /// told, since the two interleave), for a
  /// command that reports progress (`ContainerHostDriver`'s image pull).
  public func communicate(
    _ input: Data?, timeout: TimeInterval,
    onOutput: (@Sendable (Data, _ stderr: Bool) -> Void)? = nil
  ) async throws -> (
    status: Int32, output: String
  ) {
    try await exchange(input.map(Input.data), timeout: timeout, onOutput: onOutput)
  }

  /// `communicate` with `file`'s contents as the command's stdin, read from disk a piece at a time
  /// as the link drains, so a file of any size never sits in memory (#367's archive push). A file
  /// that can't be opened throws before anything is sent, and leaves the stream to its caller to
  /// `end`.
  public func communicate(
    contentsOf file: URL, timeout: TimeInterval,
    onOutput: (@Sendable (Data, _ stderr: Bool) -> Void)? = nil
  ) async throws -> (
    status: Int32, output: String
  ) {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    return try await exchange(.file(handle), timeout: timeout, onOutput: onOutput)
  }

  /// What `communicate` sends as the command's stdin.
  private enum Input: Sendable {
    case data(Data)
    case file(FileHandle)
  }

  private func exchange(
    _ input: Input?, timeout: TimeInterval,
    onOutput: (@Sendable (Data, _ stderr: Bool) -> Void)?
  ) async throws -> (
    status: Int32, output: String
  ) {
    precondition(purpose == .exchange, "communicate needs a stream spawned for an exchange")
    lock.withLock { self.onOutput = onOutput }
    let fd = descriptor
    // Claimed once: only this exchange closes it, after its last `send` on it. A second call, even
    // a concurrent one, traps rather than sending on a descriptor this one may have closed.
    let claimed: Int32? = lock.withLock {
      guard !communicating, let inputDescriptor else { return nil }
      communicating = true
      return inputDescriptor
    }
    guard let inputFD = claimed else {
      preconditionFailure("communicate runs once per stream")
    }
    let process = self.process
    let name = process.executableURL?.lastPathComponent ?? "carrier"
    // On silence: end the carrier, and shut the sockets down too, which wakes a `send` or `recv`
    // below whatever the carrier does about SIGTERM (a child of its own holding the far end, say).
    let watchdog = SilenceWatchdog(timeout) { [weak self] in
      self?.end()
      self?.shutDownInput()
      // Two calls: on macOS `SHUT_RDWR` does nothing once the peer has shut its side.
      shutdown(fd, SHUT_RD)
      shutdown(fd, SHUT_WR)
    }
    lock.withLock { heard = { watchdog.heard() } }
    defer {
      lock.withLock { heard = nil }
      watchdog.stop()
    }
    // A cancelled caller (a pane closed, a host removed mid-push) ends the exchange the same way,
    // rather than leaving `runBlocking`, which cannot be cancelled, pushing 11 MB to no one.
    let (printed, exit): (Data, (status: Int32, reason: Process.TerminationReason)?) =
      try await withTaskCancellationHandler {
        try await runBlocking {
          // Whether all of `data` went: false once the far side stops reading.
          func send(_ data: Data) -> Bool {
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
              var sent = 0
              while sent < bytes.count {
                // In pieces, so `heard()` ticks as the link drains: one `send` of the whole 11 MB
                // would return only once the last byte was queued, and the silence bound would be
                // a transfer bound after all.
                let count = Darwin.send(
                  inputFD, bytes.baseAddress! + sent, min(bytes.count - sent, 64 * 1024), 0)
                if count < 0, errno == EINTR { continue }
                // `EPIPE` (`SO_NOSIGPIPE` is set), not a signal: the far side stopped reading.
                // What it printed before it did (`cat` failing to open its file, say) is still the
                // answer, so this goes on to read it rather than throwing.
                guard count > 0 else { return false }
                sent += count
                watchdog.heard()
              }
              return true
            }
          }
          switch input {
          case .data(let data): _ = send(data)
          case .file(let handle):
            // A read that fails ends the input early, as a far side that stops reading does: the
            // command sees a short stdin and says so in its answer.
            while let piece = try? handle.read(upToCount: 64 * 1024), !piece.isEmpty, send(piece) {}
          case nil: break
          }
          // EOF on the command's stdin, which is what ends a `cat >` there. A close of its own
          // pair, never a `shutdown` of the one its stdout flows back on (see `Purpose`).
          self.closeInput()
          var collected = Data()
          var chunk = [UInt8](repeating: 0, count: 64 * 1024)
          while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            // The last 1 MiB is kept, so a host that never stops printing cannot grow the app,
            // and the scripts' report, which comes after whatever a shell startup printed,
            // survives even a startup that printed more than that.
            collected.append(chunk, count: count)
            onOutput?(Data(chunk[0..<count]), false)
            if collected.count > 1024 * 1024 {
              collected.removeFirst(collected.count - 1024 * 1024)
            }
            watchdog.heard()
          }
          watchdog.stop()
          // EOF on its output means the command closed it, not that it has exited; a bounded wait
          // for the handler (see `spawn`) covers a child of its own holding the descriptor open.
          // Read before that wait: a SIGTERM already sent (silence, or a cancel that woke the
          // reads) has had the whole wait as its grace; one sent during it may have had none.
          let terminatedBeforeWait = self.lock.withLock { self.endedByUs }
          guard self.exited.wait(timeout: .now() + 5) == .success else {
            // Still running: SIGTERM, then SIGKILL for a carrier that ignores it, so no path out
            // of here (silence, cancel, a closed output) leaves it behind (#316). The exit this
            // reaps is not the answer, so the exchange still fails.
            self.end()
            var exitedInGrace = false
            if !terminatedBeforeWait {
              exitedInGrace = self.exited.wait(timeout: .now() + 2) == .success
            }
            if !exitedInGrace, process.isRunning {
              // The whole tree, so a child of the carrier's own holding the socket goes too. A
              // carrier that yielded to the SIGTERM has already orphaned its children out of reach.
              // ponytail: `isRunning` then a signal can race a reap and a pid's reuse; macOS has
              // no atomic way to signal a process, and `StatusCommandRunner` takes the same window.
              ProcessTree.killTree(process.processIdentifier)
              _ = self.exited.wait(timeout: .now() + 1)
            }
            return (collected, nil)
          }
          return (collected, self.lock.withLock { self.exit })
        }
      } onCancel: {
        self.end()
        self.shutDownInput()
        shutdown(fd, SHUT_RD)
        shutdown(fd, SHUT_WR)
      }
    try Task.checkCancellation()
    // The watchdog's own kill, whatever the carrier made of the SIGTERM (ssh catches it and exits
    // 255 by itself, so its reason is `.exit`). A carrier that exited 0 by itself in the same
    // instant is not exempt: its `SHUT_RD` may have discarded the last line queued, and a report
    // short of one line reads as an answer (a probe whose hand-off was refused reads as current).
    // Before the exit check, so a carrier that ignored the SIGTERM still reads as silence (#316).
    guard !watchdog.fired else {
      throw HostConnectionError.serviceUnavailable(
        "\(name) moved nothing for \(Int(timeout.rounded(.up)))s")
    }
    guard let exit else {
      throw HostConnectionError.serviceUnavailable("\(name) closed its output but did not exit")
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
  public func failure() async -> String {
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
    let (listener, heard) = lock.withLock {
      () -> ((@Sendable (Data, Bool) -> Void)?, (@Sendable () -> Void)?) in
      if errors.count < 16 * 1024 { errors.append(data.prefix(16 * 1024 - errors.count)) }
      return (onOutput, self.heard)
    }
    heard?()
    listener?(data, true)
  }
}
