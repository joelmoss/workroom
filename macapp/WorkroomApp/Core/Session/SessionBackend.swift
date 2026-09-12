import Defaults
import Foundation

/// Which process owns persistent terminal sessions: the shipped Swift daemon, or the Rust agent
/// that replaces it (issue #154, `docs/designs/remote-workrooms.md` open question 14).
///
/// **Why this is not a third state on `backgroundSessions`.** The design doc suggested exactly
/// that, and the code says otherwise. `backgroundSessions` answers "should terminals outlive the
/// app?", and its `false` path is *deliberately destructive*: it raises the "Stop persisted
/// sessions?" alert and calls `endAllSessions`, because a session nothing will ever reattach to
/// would otherwise leak forever. Overloading that key with "which implementation?" inherits that
/// teardown on a question where it makes no sense, and turns a `Key<Bool>` every install has
/// already stored into an enum needing migration. Two questions, two keys.
///
/// **Switching backends strands running sessions, and that is not a bug we can fix here.** The
/// daemon and the agent are separate pty owners — the design deliberately has the agent *replace*
/// the daemon rather than proxy to it, because two pty owners is the thing "unify" exists to
/// prevent. So they share no sessions, and each keeps its own socket (below) precisely so a
/// half-switched app can never have both fighting over one. A switch therefore leaves the other
/// backend's sessions running and unattached; the UI says so before it happens.
enum SessionBackend: String, CaseIterable, Sendable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
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

  /// Whether this build offers the choice at all.
  ///
  /// Dev and Nightly only. PRODUCT.md principle 5 keeps unfinished capability out of stable, and
  /// this is the riskier half of the work — it replaces session code for *local* users, which the
  /// remote feature flag does not cover. Widening this to stable is a deliberate decision, not a
  /// default; it belongs with the decision about when the agent becomes the default at all.
  static var isSelectable: Bool {
    #if DEBUG
      return true
    #else
      return ReleaseChannel.current == .nightly
    #endif
  }
}

extension SessionBackend {
  /// The backend actually in force.
  ///
  /// A stored preference cannot select the agent on a build that does not offer it: a user who
  /// runs Nightly, switches to the agent, and later opens the stable app sharing no defaults
  /// suite would otherwise carry the choice across. Resolving it here means every call site gets
  /// the same answer and none of them has to remember the rule.
  static func selected(
    stored: SessionBackend = Defaults[.sessionBackend],
    selectable: Bool = SessionBackend.isSelectable
  ) -> SessionBackend {
    selectable ? stored : .default
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
