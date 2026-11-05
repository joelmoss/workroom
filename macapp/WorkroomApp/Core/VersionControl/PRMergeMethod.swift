import Defaults

/// How a pull request is merged (issue #88), mapped to a `gh pr merge` strategy flag. The split
/// "Merge" button's chosen method is persisted **globally** (`Defaults[.prMergeMethod]`) so it
/// sticks across projects and app restarts — not per-project, per the issue.
///
/// Stored as the bare raw string ("merge"/"squash"/"rebase") via `PreferRawRepresentable`, matching
/// the `DiffViewMode`/`ThemePreference` convention. The raw values are a stored-data contract —
/// keep them byte-for-byte stable once shipped.
enum PRMergeMethod: String, CaseIterable, Sendable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
  case merge
  case squash
  case rebase

  /// The split button's own label for the chosen method (issue #88): the merge-commit method is
  /// just "Merge"; the other two spell out the strategy.
  var buttonLabel: String {
    switch self {
    case .merge: return "Merge"
    case .squash: return "Squash and merge"
    case .rebase: return "Rebase and merge"
    }
  }

  /// The dropdown item's label. `.merge` reads "Create a merge commit" (GitHub's wording); the
  /// other two match their button labels.
  var menuLabel: String {
    switch self {
    case .merge: return "Create a merge commit"
    case .squash: return "Squash and merge"
    case .rebase: return "Rebase and merge"
    }
  }

  /// The `gh pr merge` strategy flag for this method.
  var ghFlag: String {
    switch self {
    case .merge: return "--merge"
    case .squash: return "--squash"
    case .rebase: return "--rebase"
    }
  }

  /// `gh` arguments to merge PR `number` with this method.
  func arguments(number: Int) -> [String] { ["pr", "merge", "\(number)", ghFlag] }
}
