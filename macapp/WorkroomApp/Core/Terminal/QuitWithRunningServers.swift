import Defaults
import Foundation

/// What quitting does to the dev servers run commands are running (#522). A run is a daemon session,
/// so it outlives the app unless quitting stops it (ADR 0058).
enum QuitWithRunningServers: String, CaseIterable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
  /// Ask at the first quit with a run going, and keep the answer (Q9, Q10).
  case ask
  case keepRunning
  case stop

  var title: String {
    switch self {
    case .ask: return "Ask"
    case .keepRunning: return "Keep running"
    case .stop: return "Stop"
    }
  }

  /// What a quit does to running dev servers.
  enum Action: Equatable {
    /// Ask the user, who may also cancel the quit.
    case ask
    case keep
    case stop
  }

  /// What a quit does, given the setting: nothing to decide with no run going; an update's relaunch
  /// always keeps runs, whatever the setting, since its moment is not the user's (Q12); a quit
  /// nobody can be asked about (a SIGTERM) keeps them while the setting is still Ask.
  static func action(
    setting: QuitWithRunningServers, hasLiveRuns: Bool, isUpdateRelaunch: Bool, canAsk: Bool
  ) -> Action {
    guard hasLiveRuns, !isUpdateRelaunch else { return .keep }
    switch setting {
    case .keepRunning: return .keep
    case .stop: return .stop
    case .ask: return canAsk ? .ask : .keep
    }
  }
}
