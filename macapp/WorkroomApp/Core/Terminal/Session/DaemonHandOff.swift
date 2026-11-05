import Foundation
import os

/// Replaces the running local daemon's program with the one this app bundles, keeping every session
/// and its shell's pid (#230; `workroomd hand-off`, `vcs/crates/workroomd/src/handoff.rs`).
///
/// Without it a daemon from an older app runs until 30s after its last terminal closes, which can
/// be days, and meanwhile the services it predates degrade (design doc, "The local Mac hands off
/// too").
///
/// **Once a launch, in the background, as early as the launch allows** (`start`, from
/// `applicationDidFinishLaunching`). The daemon does the deciding: it answers `current` at once when
/// it is already this binary, so a launch with nothing to hand off costs one connection and one
/// read of the binary. A daemon that predates hand-off is never asked and keeps running.
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
      let result = run(binary: binary, socket: socket)
      logger.notice("daemon hand-off: \(result, privacy: .public)")
    }
  }

  /// What the hand-off said, for the log.
  static func run(binary: URL, socket: String) -> String {
    guard FileManager.default.fileExists(atPath: socket) else { return "no daemon running" }
    do {
      let (status, output) = try SessionBackendProbe.run(
        binary, arguments: ["hand-off", "--socket", socket, "--binary", binary.path],
        timeout: timeout)
      return "exit \(status): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    } catch {
      return error.localizedDescription
    }
  }
}
