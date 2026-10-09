import Foundation
import os

/// Replaces the running local agent's program with the one this app bundles, keeping every session
/// and its shell's pid (#230; `wr-agent hand-off`, `vcs/crates/wr-agent/src/handoff.rs`).
///
/// Without it an agent from an older app runs until 30s after its last terminal closes, which can
/// be days, and meanwhile the services it predates degrade (design doc, "The local Mac hands off
/// too").
///
/// **Once a launch, in the background, as early as the launch allows** (`start`, from
/// `applicationDidFinishLaunching`). The agent does the deciding: it answers `current` at once when
/// it is already this binary, so a launch with nothing to hand off costs one connection and one
/// read of the binary. An agent that predates hand-off is never asked and keeps running.
///
/// Panes do not wait for it, so launch never freezes on it. The agent stops accepting while it
/// hands off, so a pane that connects meanwhile is attached by the new program, and `wr-agent
/// attach` sends an attach again when the agent closes before answering. A pane already attached
/// when the exec lands still loses its connection and ends as if its shell had, with the session
/// carrying on detached: a launch-only race, since panes attach after this is asked for. A REMOTE
/// pane's attach exits 255 instead, and the app attaches it again (#231; `AgentBootstrap` is the
/// remote side of this, on in every build).
enum AgentHandOff {
  /// How long the app waits before killing the request. Safe to give up: the agent tells its
  /// requester just before it replaces itself, and calls the hand-off off when the requester is
  /// gone. Longer than the agent's own worst case before that point (`QUIET_TIMEOUT`,
  /// `FREEZE_TIMEOUT`, `CHECK_TIMEOUT` and `REPORT_GRACE` in `handoff.rs`, 5.7 s, checked there
  /// against this value), so a busy launch is
  /// not given up on only for being busy. Giving up after the exec, while the command checks that
  /// the new program answers, costs only the log line.
  static let timeout: TimeInterval = 6

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "PersistentSession")

  /// Starts this launch's hand-off and returns at once. The outcome is logged at `notice`, which
  /// the log store keeps, where `info` is dropped unless someone is streaming.
  @MainActor static func start() {
    guard let binary = PersistentSessionPaths.binaryURL(for: .rustAgent),
      let socket = PersistentSessionService.shared.existingSocketPath(for: .rustAgent)
    else { return }
    // Logged at the start too, so the hand-off's window can be placed beside what the agent's own
    // log (`agent.log`) says happened to each session meanwhile.
    logger.notice("agent hand-off: asking the agent to become \(binary.path, privacy: .public)")
    Task.detached(priority: .userInitiated) {
      let result = run(binary: binary, socket: socket)
      logger.notice("agent hand-off: \(result, privacy: .public)")
    }
  }

  /// What the hand-off said, for the log.
  static func run(binary: URL, socket: String) -> String {
    guard FileManager.default.fileExists(atPath: socket) else { return "no agent running" }
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
