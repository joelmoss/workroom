/// What a terminal tab's process is, fixed when the tab is made: a login shell, a command in the
/// pane's own process, or the project's run command in a daemon run session. A stored fact of the
/// tab, read where the tab is saved and where run status is matched to it, rather than asked of
/// its surface each time.
public enum TerminalLaunch: Sendable, Equatable {
  /// A login shell, attached to a daemon session when one is available.
  case shell
  /// A command in the pane's own process: an Investigate tab's agent (#49).
  case command
  /// The project's run command, which the daemon runs as a run session (#522).
  case runSession

  /// From the two things the surface is told when it is made: whether it is a run session, and
  /// whether it runs a fixed command rather than a login shell. A run session counts as one
  /// whatever its command, as the saved-layout rule has always read it.
  public init(isRunSession: Bool, runsCommand: Bool) {
    if isRunSession {
      self = .runSession
    } else {
      self = runsCommand ? .command : .shell
    }
  }

  /// A run tab (#522).
  public var isRunSession: Bool { self == .runSession }

  /// Whether a saved layout keeps the tab. A command in the pane's own process dies with the app,
  /// so its tab is not kept. A run session outlives the app, and its restored tab reattaches to
  /// the run rather than starting it, so it is kept.
  public var isSaved: Bool { self != .command }
}
