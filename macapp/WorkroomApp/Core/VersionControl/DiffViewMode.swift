import Defaults

/// How the in-app diff viewer (issue #66) lays out a file's diff:
/// - `.unified` (default) — the inline old/new-gutter view with `+`/`-` lines stacked in one column.
/// - `.sideBySide` — old on the left, new on the right, lines aligned across the two columns.
///
/// Persisted via `Defaults[.diffViewMode]`. Stored as the bare raw string ("unified"/"sideBySide")
/// via `PreferRawRepresentable` — matching the `ThemePreference` convention. `DiffViewer` reads it at
/// view-construct time (a narrow pane additionally falls back to unified). UI tests pin it through
/// `UITestFixture.applyFixtureDefaults` (`-WorkroomUITestDiffViewMode …`) rather than the raw key, so
/// a launch never inherits the developer's Settings choice.
enum DiffViewMode: String, CaseIterable, Defaults.Serializable, Defaults.PreferRawRepresentable {
  case unified
  case sideBySide

  /// The label shown in the Settings picker.
  var label: String {
    switch self {
    case .unified: return "Unified"
    case .sideBySide: return "Side by Side"
    }
  }

  /// SF Symbol for the tab toolbar's diff-mode switch. A document metaphor (one page vs two pages),
  /// deliberately NOT a split-rectangle — that reads as the toolbar's separate "Split right" pane
  /// control (`square.split.2x1`).
  var symbol: String {
    switch self {
    case .unified: return "doc.plaintext"
    case .sideBySide: return "doc.on.doc"
    }
  }
}
