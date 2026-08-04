import Foundation

/// What the selected workroom's focused content tab is showing, reduced to the identity an inspector
/// row needs to decide "am I the selected row?".
///
/// This exists because that question used to be asked **per row**. `HistoryRow`,
/// `DivergentSiblingRow` and `ChangesPanel.ChangedFileRow` each held `@EnvironmentObject AppStore` +
/// `@ObservedObject TerminalSessions` purely to run the `selectedTarget` → `focusedTab(for:)` →
/// descriptor chain, so every terminal title update and activity pulse — which republish
/// `TerminalSessions` at the rate an agent writes output — invalidated every row in the pane. That is
/// the WORKROOM-2B App Hang (≥2000 ms on the main thread, sampled inside `HistoryRow.body`).
///
/// Now the *panel* reads it once per body pass and hands each row a plain value, so no row observes
/// anything. Keeping the chain in one place also means a new `TabContent` case has exactly one site to
/// teach, instead of three that fail silently by never highlighting.
/// `Equatable` because the inspector rows now take it as a plain value and are themselves `Equatable`
/// (the equality gate that keeps a terminal pulse from rebuilding them).
enum FocusedTabSelection: Equatable {

  /// The focused tab's content identity for the selected workroom, or `nil` when nothing is selected,
  /// the selection has no tabs, or the focused tab is a terminal (no inspector row corresponds to it).
  case changeset(commitID: String)
  case diff(path: String, source: DiffSource)
  case file(path: String)

  /// Resolve the focused content tab for `store`'s selected workroom.
  ///
  /// Deliberately a free function over the two stores rather than a computed property on `AppStore`:
  /// the tab strip lives in a separate observation tree from the inspector, so the caller must be the
  /// view that observes `TerminalSessions` (a panel), and making that dependency explicit at the call
  /// site is the whole point.
  @MainActor
  static func current(store: AppStore, sessions: TerminalSessions) -> FocusedTabSelection? {
    guard let target = store.selectedTarget, let tab = sessions.focusedTab(for: target) else {
      return nil
    }
    switch tab.content {
    case .changeset(let descriptor):
      return .changeset(commitID: descriptor.commitID)
    case .diff(let descriptor):
      return .diff(path: descriptor.path, source: descriptor.source)
    case .file(let descriptor):
      return .file(path: descriptor.path)
    case .terminal:
      return nil
    }
  }

  /// The focused changeset's commit id, if a changeset tab is focused. What the History rows compare
  /// their own commit against.
  var changesetCommitID: String? {
    if case .changeset(let commitID) = self { return commitID }
    return nil
  }

  /// Whether this selection is `path`'s diff from `source`, or `path`'s file tab. The Changes panel's
  /// rule, unchanged: a file tab has no revision, so it matches on path alone, while a diff keeps
  /// `source` so the same path under `@` vs `@-` selects the right row.
  func selectsChangedFile(path: String, source: DiffSource) -> Bool {
    switch self {
    case .diff(let selectedPath, let selectedSource):
      return selectedPath == path && selectedSource == source
    case .file(let selectedPath):
      return selectedPath == path
    case .changeset:
      return false
    }
  }
}
