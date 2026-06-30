import Foundation

/// Pure presentation of an `AgentBannerState` (issue #49, T8): the text and which controls the
/// inline-agent banner shows. Keeps `TerminalAgentBanner` a dumb renderer and unit-testable.
struct AgentBannerViewModel: Equatable {
  enum Style: Equatable { case awaiting, loading, ready, failure, remote }

  let style: Style
  let headline: String
  let detail: String?
  /// The suggested fix command (shown in a code chip) when one is available.
  let fixCommand: String?
  /// Whether the fix is destructive/network (rm -rf, curl|sh, …) — the view requires an extra
  /// confirm before inserting it (X4).
  let fixIsDestructive: Bool
  let showsDiagnoseButton: Bool
  let showsInsertFix: Bool
  let showsInvestigate: Bool
  let showsDismiss: Bool

  init(state: AgentBannerState) {
    switch state {
    case .awaitingDiagnose(let failure):
      style = .awaiting
      headline = "Command failed (exit \(failure.exitCode))"
      detail = failure.command
      fixCommand = nil
      fixIsDestructive = false
      showsDiagnoseButton = true
      showsInsertFix = false
      showsInvestigate = false
      showsDismiss = true

    case .loading:
      style = .loading
      headline = "Diagnosing…"
      detail = nil
      fixCommand = nil
      fixIsDestructive = false
      showsDiagnoseButton = false
      showsInsertFix = false
      showsInvestigate = false
      showsDismiss = true

    case .ready(_, let diagnosis):
      style = .ready
      headline = diagnosis.summary
      detail = diagnosis.detail
      fixCommand = diagnosis.fixCommand
      fixIsDestructive = diagnosis.fixCommand.map(DestructiveCommandDetector.isDestructive) ?? false
      showsDiagnoseButton = false
      showsInsertFix = diagnosis.fixCommand != nil
      showsInvestigate = true
      showsDismiss = true

    case .failure(_, let kind):
      style = .failure
      headline = Self.message(for: kind)
      detail = nil
      fixCommand = nil
      fixIsDestructive = false
      showsDiagnoseButton = Self.isRetryable(kind)
      showsInsertFix = false
      showsInvestigate = false
      showsDismiss = true

    case .remoteCaveat(let failure):
      style = .remote
      headline = "Remote session — a local diagnosis may be inaccurate"
      detail = failure.command
      fixCommand = nil
      fixIsDestructive = false
      showsDiagnoseButton = false
      showsInsertFix = false
      // Investigate would open a LOCAL agent that can't see the remote host (X5).
      showsInvestigate = false
      showsDismiss = true
    }
  }

  /// User-facing message for an error outcome.
  static func message(for kind: AgentErrorKind) -> String {
    switch kind {
    case .cliNotFound: return "No agent CLI found — install Claude Code or Codex"
    case .notAuthenticated: return "Agent not signed in — run `claude login`"
    case .timedOut: return "Diagnosis timed out"
    case .emptyOutput: return "No diagnosis returned"
    case .malformed: return "Couldn't read the diagnosis"
    case .other(let detail): return "Diagnosis failed (\(detail))"
    }
  }

  /// Whether a failed diagnosis is worth a retry button. A missing/unauthenticated CLI won't fix
  /// itself on retry; a timeout / transient parse failure might.
  static func isRetryable(_ kind: AgentErrorKind) -> Bool {
    switch kind {
    case .timedOut, .emptyOutput, .malformed, .other: return true
    case .cliNotFound, .notAuthenticated: return false
    }
  }
}
