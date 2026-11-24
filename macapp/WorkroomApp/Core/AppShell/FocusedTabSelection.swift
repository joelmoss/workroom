import Foundation

/// What the selected workroom's focused content tab is showing, reduced to the identity an inspector
/// row needs to decide "am I the selected row?".
///
/// This exists because that question used to be asked **per row**. `HistoryRow`,
/// `DivergentSiblingRow` and `ChangesPanel.ChangedFileRow` each held `@EnvironmentObject AppStore` +
/// `@ObservedObject TerminalPanes` purely to run the `selectedTarget` → `focusedTab(for:)` →
/// descriptor chain, so every terminal title update and activity pulse — which republish
/// `TerminalPanes` at the rate an agent writes output — invalidated every row in the pane. That is
/// the WORKROOM-2B App Hang (≥2000 ms on the main thread, sampled inside `HistoryRow.body`).
///
/// Now the *panel* reads it once per body pass and hands each row a plain value, so no row observes
/// `TerminalPanes`, and that is what keeps a pulse from rebuilding them (measured for #538: a pulse
/// never reaches a row's `==`). Keeping the chain in one place also means a new `TabContent` case has
/// exactly one site to teach, instead of three that fail silently by never highlighting.
/// `Equatable` because the inspector rows now take it as a plain value and are themselves `Equatable`:
/// their equality gate is what stops a data change, such as a status sweep that adds one changed file,
/// from rebuilding every row.
enum FocusedTabSelection: Equatable {

  /// The focused tab's content identity for the selected workroom, or `nil` when nothing is selected,
  /// the selection has no tabs, or the focused tab is a terminal (no inspector row corresponds to it).
  /// A changeset matches on its commit alone, as its tab does (`ChangesetDescriptor.sameChangeset`).
  case changeset(commitID: String)
  /// `root` is the diff's repository when it is not the tab's target's own (a followed
  /// repository's, #807), as `DiffDescriptor.sameFile` keys on it: one terminal can follow several
  /// repositories, each with its own `src/a.txt`.
  case diff(path: String, source: DiffSource, root: String? = nil)
  /// `root` is the folder the path is relative to when it is not the target's (#809).
  case file(path: String, root: String? = nil)

  /// Resolve the focused content tab for `store`'s selected workroom.
  ///
  /// Deliberately a free function over the two stores rather than a computed property on `AppStore`:
  /// the tab strip lives in a separate observation tree from the inspector, so the caller must be the
  /// view that observes `TerminalPanes` (a panel), and making that dependency explicit at the call
  /// site is the whole point.
  @MainActor
  static func current(store: AppStore, panes: TerminalPanes) -> FocusedTabSelection? {
    guard let target = store.selectedTarget, let tab = panes.focusedTab(for: target) else {
      return nil
    }
    // The per-kind switch lives in `init?(content:)`, beside `TabContent` — navigation history reduces
    // a tab the same way, and one switch means a new case cannot be taught here and forgotten there.
    return Self(content: tab.content)
  }

  /// `current(store:panes:)` over `store`'s own window panes, which is what both inspector panels
  /// read. It reads `store.terminals` itself, so whichever body calls it observes the panes.
  @MainActor
  static func current(store: AppStore) -> FocusedTabSelection? {
    current(store: store, panes: store.terminals)
  }

  /// The focused changeset's commit id, if a changeset tab is focused. What the History rows compare
  /// their own commit against.
  var changesetCommitID: String? {
    if case .changeset(let commitID) = self { return commitID }
    return nil
  }

  /// Whether this selection is `path`'s diff from `source`, or `path`'s file tab, in the repository
  /// at `root` (nil: the target's own). The Changes panel's rule: a file tab has no revision, so it
  /// matches on path alone, while a diff keeps `source` so the same path from the worktree vs a
  /// commit selects the right row. Both keep the root, so a tab from repository A never selects the
  /// same-path row while the inspector shows repository B.
  func selectsChangedFile(path: String, source: DiffSource, root: String? = nil) -> Bool {
    switch self {
    case .diff(let selectedPath, let selectedSource, let selectedRoot):
      return selectedPath == path && selectedSource == source && selectedRoot == root
    case .file(let selectedPath, let selectedRoot):
      return selectedPath == path && selectedRoot == root
    case .changeset:
      return false
    }
  }

  /// The repository root the Changes panel's rows are relative to under `subject`, as their tabs
  /// name it (`AppStore.followedRepositoryRoot`): a followed folder's repository, else nil for the
  /// target's own.
  static func changedFileRoot(for subject: InspectorSubject) -> String? {
    guard case .followed(let followed) = subject else { return nil }
    return followed.repository?.root
  }
}
