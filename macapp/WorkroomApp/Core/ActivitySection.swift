import Defaults

/// A top-level section in the right **activity bar** (the vertical icon rail pinned to the window's
/// trailing edge). Each case is one large icon; clicking it shows that section's **pane** in the
/// inspector. A pane stacks one or more `InspectorSectionKind` sub-sections via `InspectorSplitView`
/// — the Changes pane stacks Changes + Pull Request, the Files pane is a single sub-section. Future
/// sections plug in by adding a case + its `subSections`.
///
/// `allCases` order IS the bar order (top to bottom). Persisted via `Defaults[.activeInspectorSection]`
/// as the bare raw string (`PreferRawRepresentable`, matching `SettingsPane`/`DiffViewMode`); a
/// stored value matching no case falls back to the key default (`.changes`), so a rename or corrupt
/// value degrades gracefully rather than crashing.
enum ActivitySection: String, CaseIterable, Identifiable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
  case changes
  case files

  var id: Self { self }

  /// The pane title and the bar icon's tooltip / accessibility label.
  var label: String {
    switch self {
    case .changes: return "Changes"
    case .files: return "Files"
    }
  }

  /// SF Symbol for the bar icon.
  var systemImage: String {
    switch self {
    case .changes: return "arrow.triangle.branch"
    case .files: return "folder"
    }
  }

  /// The stacked sub-sections this pane shows, top to bottom. More than one → a collapsible/resizable
  /// stack (Changes pane = Changes + Pull Request); a single element → one section, no collapse chevron.
  var subSections: [InspectorSectionKind] {
    switch self {
    case .changes: return [.changes, .pullRequest]
    case .files: return [.files]
    }
  }

  /// The View-menu shortcut hint shown in the icon's tooltip, for discoverability.
  var shortcutHint: String {
    switch self {
    case .changes: return "⌥⌘C"
    case .files: return "⌥⌘F"
    }
  }
}

extension InspectorSectionKind {
  /// This sub-section's index in the canonical `allCases` order (changes = 0, files = 1,
  /// pullRequest = 2). The per-workroom collapse flags + size-weights are stored as full 3-vectors in
  /// that order (`InspectorPaneState`), so a pane slices out — and writes back — the entries for the
  /// sub-sections it actually shows by this index.
  var storeIndex: Int { InspectorSectionKind.allCases.firstIndex(of: self) ?? 0 }
}
