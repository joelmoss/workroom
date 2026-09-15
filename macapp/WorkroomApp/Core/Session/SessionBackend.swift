import Foundation

/// Which process owns a persistent terminal session: the Rust agent that owns every new one, or
/// the retired Swift daemon that may still be holding sessions from an older build (issue #154,
/// `docs/designs/remote-workrooms.md`).
///
/// **This is resolved per SESSION, not per app, and never by the user.** The two are separate pty
/// owners with separate sockets and cannot hand sessions to each other, so any app-wide switch
/// would strand whatever terminals were running at the moment it flipped. Instead:
///
/// - **Every new session goes to the agent.** `preferred()` names it, or names nothing at all.
/// - **The daemon is reachable but no longer runnable.** `workroom-session` still ships, but only
///   its attach client: the `daemon` subcommand is gone, so nothing in this build can start one.
///   The daemons it attaches to were started by an app at or before v2.0.0 and are still running on
///   the user's machine. They exit on their own once their last session closes.
///
/// **There is no fallback between them.** An agent that cannot run used to send new sessions to the
/// daemon; it now sends them nowhere, because a daemon this build cannot start is not a fallback —
/// routing at it would hand libghostty an attach command for a session nobody holds. `preferred()`
/// returns nil instead and the pane opens a plain shell: a working terminal without persistence,
/// rather than a dead one.
///
/// Not `Defaults.Serializable`: nothing stores this. Which backend owns a session is a fact about
/// the machine's live processes, answered by asking them, and a stored value would go stale the
/// moment a daemon exited or an upgrade landed.
enum SessionBackend: String, CaseIterable, Sendable {
  /// `workroom-session`, now an attach-only client. Never the destination for a NEW session; only
  /// ever resolved for a session a pre-existing daemon says it already holds.
  case swiftDaemon = "swift"
  /// `wr-agent`, the unified local+remote agent. Where every new session goes.
  case rustAgent = "rust"

  var label: String {
    switch self {
    case .swiftDaemon: return "Swift daemon"
    case .rustAgent: return "Rust agent"
    }
  }

  /// The helper this backend forks. Distinct binaries, so neither can be mistaken for the other.
  var binaryName: String {
    switch self {
    case .swiftDaemon: return "workroom-session"
    case .rustAgent: return "wr-agent"
    }
  }

  /// Distinct socket file names, which is the property that makes the two safe to hold at once: the
  /// two backends can never bind the same socket, so there is never a moment with two pty owners
  /// racing for one session. It also means a daemon's sessions survive independently while the
  /// agent owns everything new, instead of being silently adopted by a process that cannot own them.
  var socketFileName: String {
    switch self {
    case .swiftDaemon: return "session.sock"
    case .rustAgent: return "agent.sock"
    }
  }

  /// The backend a NEW session should be created in, or **nil when none can take one**.
  ///
  /// Nil is a real answer, not an error: this build can start an agent and nothing else, so an
  /// agent that fails its probe leaves nowhere for a new session to go. The caller opens a plain
  /// shell. See `SessionBackendProbe` for what "cannot run" is measured by, and note it is a
  /// liveness check rather than a guarantee — an agent that answers `protocol` can still fail at
  /// attach, which `GhosttySurfaceView` handles separately.
  static func preferred(
    probe: (SessionBackend) -> SessionBackendAvailability = { SessionBackendProbe.probe($0) }
  ) -> SessionBackend? {
    probe(.rustAgent).isReady ? .rustAgent : nil
  }
}

/// Why a backend cannot be used right now. Distinguishing these matters: "not in this build" is a
/// packaging fact the user can do nothing about, while "did not respond" is a health failure that
/// is exactly the signal a rollback decision needs.
enum SessionBackendAvailability: Equatable, Sendable {
  case ready(version: String)
  case notBundled
  case unhealthy(reason: String)

  var isReady: Bool {
    if case .ready = self { return true }
    return false
  }

  var summary: String {
    switch self {
    case .ready(let version): return "Ready — \(version)"
    case .notBundled: return "Not included in this build"
    case .unhealthy(let reason): return "Not responding — \(reason)"
    }
  }
}
