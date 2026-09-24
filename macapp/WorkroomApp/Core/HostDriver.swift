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
  /// `AgentVCSConnection.connect(host:stream:)`.
  func openStream(to host: HostID) async throws -> HostStream
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
    guard process.isRunning else { return }
    lock.withLock { endedByUs = true }
    process.terminate()
  }

  /// What the carrier said about why the stream ended, for a handshake it never answered: its
  /// stderr, or failing that how it ended. Waits for stderr to reach EOF rather than for the
  /// process to be reaped: the two are separate events, and the reason ("Host key verification
  /// failed.") is in the first.
  func failure() async -> String {
    for _ in 0..<40 where !lock.withLock({ errorsClosed }) || process.isRunning {
      try? await Task.sleep(for: .milliseconds(50))
    }
    let (said, endedByUs) = lock.withLock {
      (String(decoding: errors, as: UTF8.self), self.endedByUs)
    }
    let reason = said.trimmingCharacters(in: .whitespacesAndNewlines)
    if !reason.isEmpty { return reason }
    let name = process.executableURL?.lastPathComponent ?? "carrier"
    // `isRunning` first: `terminationReason` and `terminationStatus` raise an Objective-C
    // exception for a process that has not been reaped yet, which Swift cannot catch. A carrier
    // stopped a moment ago can still be running once the wait above gives up.
    if process.isRunning { return "\(name) did not answer in time" }
    // Our own SIGTERM, from `end()`: the carrier was still running when the handshake gave up.
    if endedByUs, process.terminationReason == .uncaughtSignal,
      process.terminationStatus == SIGTERM
    {
      return "\(name) did not answer in time"
    }
    return "\(name) exited with status \(process.terminationStatus)"
  }

  /// Keeps the first 16 KiB of stderr: enough for any diagnosis, and bounded against a chatty one.
  private func collect(_ data: Data) {
    lock.withLock {
      guard errors.count < 16 * 1024 else { return }
      errors.append(data.prefix(16 * 1024 - errors.count))
    }
  }
}
