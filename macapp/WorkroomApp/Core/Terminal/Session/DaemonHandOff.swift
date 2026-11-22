import Darwin
import Foundation
import HostDrivers
import os

/// Replaces the running local daemon's program with the one this app bundles, keeping every session
/// and its shell's pid (#230; `workroomd hand-off`, `vcs/crates/workroomd/src/daemon/handoff.rs`).
///
/// Without it a daemon from an older app runs until 30s after its last terminal closes, which can
/// be days, and meanwhile the services it predates degrade (design doc, "The local Mac hands off
/// too").
///
/// **Once a launch, in the background, as early as the launch allows** (`start`, from
/// `applicationDidFinishLaunching`). The daemon does the deciding: it answers `current` at once when
/// it is already this binary's daemon build (`daemon-build` in `protocol`, #680), so a launch with
/// nothing to hand off costs one connection and one read of the binary, and so does the first
/// launch after a Sparkle update that changed only CLI commands. A daemon from before #680 compares
/// the binary's bytes instead, so it is handed off to any other build. A daemon that predates
/// hand-off is never asked and keeps running. A daemon whose own file is gone is handed off whatever
/// its build (`mustMove`): the first launch after the swap (#681) moves it from
/// `Contents/MacOS/workroomd` to `Contents/Resources/workroom` that way, and tries again a while
/// when the daemon refuses for now (`isTransient`).
///
/// Panes do not wait for it, so launch never freezes on it. The daemon stops accepting while it
/// hands off, so a pane that connects meanwhile is attached by the new program, and `workroomd
/// attach` sends an attach again when the daemon closes before answering. A pane already attached
/// when the exec lands, as every pane is when a move refused for now goes in later, loses its
/// connection, and its `workroomd attach` attaches it again itself to its session in the new
/// program, which repaints it (#681; `reattach_local` in `cli/attach.rs`). One whose daemon died
/// finds nothing listening and ends as it always has. A REMOTE pane's attach exits 255 instead,
/// and the app attaches it again (#231; `DaemonBootstrap` is the remote side of this, on in every
/// build).
/// This Mac's daemon's completed hand-offs, told to whoever waits for the next (#694): what this
/// Mac's subscriptions wait on, as a remote host's wait on its link coming back
/// (`ProgramStatusMonitor.hostReconnected`). A subscription the old program refused (one that
/// predates a service or an event type) is asked again of the new one, where nothing else would
/// ask it again.
final class LocalDaemonHandOffs: @unchecked Sendable {
  static let shared = LocalDaemonHandOffs()

  private let lock = NSLock()
  private var waiting: [UUID: AsyncStream<Void>.Continuation] = [:]

  /// Returns once a hand-off completes after this was called, or once the task is cancelled.
  func next() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let id = UUID()
    continuation.onTermination = { [weak self] _ in
      self?.lock.withLock { _ = self?.waiting.removeValue(forKey: id) }
    }
    lock.withLock { waiting[id] = continuation }
    for await _ in stream { return }
  }

  /// A hand-off completed: every waiter returns.
  func completed() {
    let woken = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
      defer { waiting.removeAll() }
      return Array(waiting.values)
    }
    for continuation in woken {
      continuation.yield()
      continuation.finish()
    }
  }

  /// How many wait, for tests.
  var waiters: Int { lock.withLock { waiting.count } }
}

enum DaemonHandOff {
  /// How long the app waits before killing the request. Safe to give up: the daemon tells its
  /// requester just before it replaces itself, and calls the hand-off off when the requester is
  /// gone. Longer than the daemon's own worst case before that point (`QUIET_TIMEOUT`,
  /// `FREEZE_TIMEOUT`, `HANDOFF_FORMAT_DEADLINE`, `TABLE_WRITE_ALLOWANCE`, `CHECK_TIMEOUT` and
  /// `REPORT_GRACE` in `handoff.rs`, 6.2 s, checked there against this value), so a busy launch is
  /// not given up on only for being busy. Giving up after the exec, while the command checks that
  /// the new program answers, costs only the log line.
  static let timeout: TimeInterval = 7

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "PersistentSession")

  /// Starts this launch's hand-off and returns at once. The outcome is logged at `notice`, which
  /// the log store keeps, where `info` is dropped unless someone is streaming.
  /// The waits between attempts at a move the daemon refused for now (`isTransient`): about a
  /// minute and a half in all, while the app runs. A launch's move that never goes in leaves the
  /// daemon as it was, starting its run sessions from its own copy (`own_copy.rs`).
  static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15, 30, 30]

  /// `binary` and `socket` default to this app's; a test passes its own, and awaits the task.
  @MainActor @discardableResult
  static func start(
    binary: URL? = PersistentSessionPaths.binaryURL(for: .daemon),
    socket: String? = PersistentSessionService.shared.existingSocketPath(for: .daemon),
    delays: [TimeInterval] = retryDelays
  ) -> Task<[String], Never>? {
    guard let binary, let socket else { return nil }
    // Logged at the start too, so the hand-off's window can be placed beside what the daemon's own
    // log (`workroomd.log`) says happened to each session meanwhile.
    logger.notice("daemon hand-off: asking the daemon to become \(binary.path, privacy: .public)")
    return Task.detached(priority: .userInitiated) {
      await handOff(binary: binary, socket: socket, delays: delays)
    }
  }

  /// This launch's hand-off, and the move again while one the daemon refused for now
  /// (`isTransient`) is still needed (`mustMove`), after each of `delays`. Returns what each attempt
  /// said, each also logged.
  static func handOff(binary: URL, socket: String, delays: [TimeInterval]) async -> [String] {
    var said: [String] = []
    for attempt in 0...delays.count {
      let running = runningExecutable(socket: socket)
      let force = mustMove(running: running, to: binary)
      if force {
        logger.notice(
          "daemon hand-off: the daemon runs \(running ?? "?", privacy: .public), so it is moved")
      }
      let result = run(binary: binary, socket: socket, force: force)
      said.append(result)
      logger.notice("daemon hand-off: \(result, privacy: .public)")
      if handedOff(result) { LocalDaemonHandOffs.shared.completed() }
      guard force, isTransient(result), attempt < delays.count else { break }
      logger.notice("daemon hand-off: trying the move again in \(delays[attempt])s")
      try? await Task.sleep(for: .seconds(delays[attempt]))
    }
    return said
  }

  /// Whether `result` says the daemon's program was replaced: `workroom hand-off`'s success.
  static func handedOff(_ result: String) -> Bool {
    result.hasPrefix("exit 0:") && result.hasSuffix("handed off")
  }

  /// Whether a hand-off was refused only for now: a repository command, a stuck mount or a session
  /// ending or repainting held it up (`handoff.rs`: each says "try again when it…"), another one was
  /// in progress, the daemon did not greet (92), or no answer came in `timeout`.
  static func isTransient(_ result: String) -> Bool {
    result.hasPrefix("exit 92:") || result.contains("try again when it")
      || result.contains("another hand-off is in progress")
      || result == SessionBackendProbe.ProbeError.timedOut(timeout).localizedDescription
  }

  /// Whether the daemon must be handed off even when it is this binary's daemon build already. The
  /// daemon starts its run sessions from its own copy of itself (`own_copy.rs`), so a path the app
  /// no longer has costs it nothing there; what it still needs its file for is to be checked, and
  /// to be told apart from another build. So: when the file it was started from is gone, as the
  /// swap (#681) took `Contents/MacOS/workroomd` away, or holds another daemon build than
  /// `binary`. Not merely another path: a second copy of the app, or one App Translocation runs from
  /// elsewhere, would otherwise move it on every launch.
  ///
  /// The path is the one the daemon was exec'd with (`runningExecutable`). A Sparkle update
  /// replacing the file at that path leaves it there, so an update that changed CLI commands alone
  /// still finds the daemon `current` (#680). A path that can't be read moves nothing: the daemon
  /// build decides, as before.
  static func mustMove(running: String?, to binary: URL) -> Bool {
    guard let running, !running.isEmpty else { return false }
    let ours = binary.standardizedFileURL
    let theirs = URL(fileURLWithPath: running).standardizedFileURL
    if theirs.path == ours.path
      || theirs.resolvingSymlinksInPath().path == ours.resolvingSymlinksInPath().path
    {
      return false
    }
    guard let found = try? Data(contentsOf: theirs, options: .alwaysMapped) else { return true }
    guard let bundled = try? Data(contentsOf: ours, options: .alwaysMapped) else { return false }
    return DaemonBootstrap.daemonBuild(in: found) != DaemonBootstrap.daemonBuild(in: bundled)
  }

  /// The path the daemon on `socket` was exec'd with: its pid from the connection
  /// (`LOCAL_PEERPID`, the listener's, which a hand-off keeps), then the exec path the kernel kept
  /// for it (`KERN_PROCARGS2`). That survives the file being moved or deleted, where the file's own
  /// path (`proc_pidpath`) reads as missing. Nil when either can't be read.
  static func runningExecutable(socket: String) -> String? {
    guard var address = PersistentSessionControlClient.address(for: socket) else { return nil }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
    guard connected else { return nil }
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
      return nil
    }
    return execPath(of: pid)
  }

  /// `pid`'s exec path, the first string of `KERN_PROCARGS2` after its argument count.
  static func execPath(of pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    let path = buffer[MemoryLayout<Int32>.size..<size].prefix { $0 != 0 }
    return path.isEmpty ? nil : String(decoding: path, as: UTF8.self)
  }

  /// What the hand-off said, for the log. `force` hands off even to this daemon build (`mustMove`).
  static func run(binary: URL, socket: String, force: Bool = false) -> String {
    guard FileManager.default.fileExists(atPath: socket) else { return "no daemon running" }
    do {
      let (status, output) = try SessionBackendProbe.run(
        binary,
        arguments: ["hand-off", "--socket", socket, "--binary", binary.path]
          + (force ? ["--force"] : []),
        timeout: timeout)
      return "exit \(status): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    } catch {
      return error.localizedDescription
    }
  }
}
