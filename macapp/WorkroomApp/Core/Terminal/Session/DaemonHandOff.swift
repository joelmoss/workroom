import Darwin
import Foundation
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
/// hand-off is never asked and keeps running. A daemon running from another path than the bundled
/// binary's is handed off whatever its build (`mustMove`): the first launch after the swap (#681)
/// moves it from `Contents/MacOS/workroomd` to `Contents/Resources/workroom` that way.
///
/// Panes do not wait for it, so launch never freezes on it. The daemon stops accepting while it
/// hands off, so a pane that connects meanwhile is attached by the new program, and `workroomd
/// attach` sends an attach again when the daemon closes before answering. A pane already attached
/// when the exec lands still loses its connection and ends as if its shell had, with the session
/// carrying on detached: a launch-only race, since panes attach after this is asked for. A REMOTE
/// pane's attach exits 255 instead, and the app attaches it again (#231; `DaemonBootstrap` is the
/// remote side of this, on in every build).
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
  @MainActor static func start() {
    guard let binary = PersistentSessionPaths.binaryURL(for: .daemon),
      let socket = PersistentSessionService.shared.existingSocketPath(for: .daemon)
    else { return }
    // Logged at the start too, so the hand-off's window can be placed beside what the daemon's own
    // log (`workroomd.log`) says happened to each session meanwhile.
    logger.notice("daemon hand-off: asking the daemon to become \(binary.path, privacy: .public)")
    Task.detached(priority: .userInitiated) {
      let running = runningExecutable(socket: socket)
      let force = mustMove(running: running, to: binary)
      if force {
        logger.notice(
          "daemon hand-off: the daemon runs \(running ?? "?", privacy: .public), so it is moved")
      }
      let result = run(binary: binary, socket: socket, force: force)
      logger.notice("daemon hand-off: \(result, privacy: .public)")
    }
  }

  /// Whether the daemon must be handed off even when it is this binary's daemon build already: it
  /// runs from another path than `binary`'s. The daemon runs its own path again for every run
  /// session (`run-supervisor`), and for the hand-off check, so a daemon left on a path the app no
  /// longer has can't start one. The first launch after the swap (#681) is that: the daemon was
  /// `Contents/MacOS/workroomd`, which the update took away, and is now `Contents/Resources/workroom`
  /// (ADR 0078), and the two can be the same daemon build. So can an app moved to another folder.
  ///
  /// The path is the one the daemon was exec'd with (`runningExecutable`), which a Sparkle update
  /// replacing the file at the same path leaves equal: an update that changed CLI commands alone
  /// still finds the daemon `current` (#680). A path that can't be read moves nothing: the daemon
  /// build decides, as before.
  static func mustMove(running: String?, to binary: URL) -> Bool {
    guard let running, !running.isEmpty else { return false }
    let ours = binary.standardizedFileURL
    let theirs = URL(fileURLWithPath: running).standardizedFileURL
    return theirs.path != ours.path
      && theirs.resolvingSymlinksInPath().path != ours.resolvingSymlinksInPath().path
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
