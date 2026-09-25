import Foundation

/// Replaces the running local agent's program with the one this app bundles, keeping every session
/// and its shell's pid (#230; `wr-agent hand-off`, `vcs/crates/wr-agent/src/handoff.rs`).
///
/// Without it an agent from an older app runs until 30s after its last terminal closes, which can
/// be days, and meanwhile the services it predates degrade (design doc, "The local Mac hands off
/// too").
///
/// **Once a launch, just before its first pane attaches, and synchronously.** A pane attached to
/// the old program loses its connection when the program is replaced, so this has to finish first.
/// The agent does the deciding: it answers `current` at once when it is already this binary, so a
/// launch with nothing to hand off pays one connection and one read of the binary. An agent that
/// predates hand-off is never asked and keeps running.
enum AgentHandOff {
  /// Nightly and Dev only for now. A hand-off bug kills local terminals on an update, which has
  /// never been possible before, so stable waits until Nightly has proven it.
  static var isEnabled: Bool {
    #if DEBUG
      return true
    #else
      return ReleaseChannel.isNightlyBuild
    #endif
  }

  /// How long the app waits before killing the request and going on to attach its panes. Safe to
  /// give up: the agent tells its requester just before it replaces itself, and calls the hand-off
  /// off when the requester is gone. Longer than the agent's own worst case before that point
  /// (`QUIET_TIMEOUT` plus `CHECK_TIMEOUT` in `handoff.rs`, 5 s), so a busy launch is not given
  /// up on only for being busy. Giving up after the exec, while the command checks that the new
  /// program answers, costs only the log line: the hand-off has happened, and panes attach to the
  /// new program.
  static let timeout: TimeInterval = 6

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
