import Foundation

/// Which process owns a persistent terminal session: the shipped Swift daemon, or the Rust agent
/// that replaces it (issue #154, `docs/designs/remote-workrooms.md`).
///
/// **This is resolved per SESSION, not per app, and never by the user.** The two are separate pty
/// owners with separate sockets and cannot hand sessions to each other, so any app-wide switch
/// would strand whatever terminals were running at the moment it flipped. Instead the migration
/// drains: a session the daemon already owns stays with the daemon until it closes on its own, and
/// every new session goes to the agent. Nothing is taken away, so nothing is noticed, and the
/// daemon idles out and exits once its last session ends.
///
/// That is also what makes an automatic fallback safe here. Falling back would be dangerous if
/// both could own one session — two pty owners racing is the thing "unify" exists to prevent — but
/// the sockets are distinct and ownership is per session, so a session lives in exactly one of
/// them by construction.
/// Not `Defaults.Serializable`: nothing stores this. Which backend owns a session is a fact about
/// the machine's live processes, answered by asking them, and a stored value would go stale the
/// moment a daemon exited or an upgrade landed.
enum SessionBackend: String, CaseIterable, Sendable {
  /// `workroom-session`, shipped and incident-hardened. The default, and the rollback target.
  case swiftDaemon = "swift"
  /// `wr-agent`, the unified local+remote agent.
  case rustAgent = "rust"

  static let `default`: SessionBackend = .swiftDaemon

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

  /// Distinct socket file names, which is the property that makes a mid-flight switch safe: the
  /// two backends can never bind the same socket, so there is never a moment with two pty owners
  /// racing for one session. It also means each backend's sessions survive independently while
  /// the other is selected, instead of being silently adopted by a process that cannot own them.
  var socketFileName: String {
    switch self {
    case .swiftDaemon: return "session.sock"
    case .rustAgent: return "agent.sock"
    }
  }

  /// The backend a NEW session should be created in.
  ///
  /// The agent, unless it cannot run — see `SessionBackendProbe`. A build where the agent is
  /// missing or broken keeps working on the daemon rather than failing to open a terminal.
  static func preferred(
    probe: (SessionBackend) -> SessionBackendAvailability = { SessionBackendProbe.probe($0) }
  ) -> SessionBackend {
    probe(.rustAgent).isReady ? .rustAgent : .swiftDaemon
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
