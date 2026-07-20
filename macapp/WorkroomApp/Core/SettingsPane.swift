import Defaults

/// A group in the Settings window (⌘,), shown as a row in the source-list sidebar. The window is a
/// hand-rolled `HStack { sidebar; detail }` (not `NavigationSplitView`), so this enum drives both the
/// sidebar list and the `switch` that picks the detail pane.
///
/// Persisted via `Defaults[.settingsSelectedPane]` so the last-viewed pane reopens (macOS System
/// Settings behaviour). Stored as the bare raw string ("general"/…) via `PreferRawRepresentable` —
/// matching the `DiffViewMode`/`ThemePreference` convention. A stored raw string that no longer
/// matches a case decodes to `nil`, and `Defaults` falls back to the key's default (`.general`), so
/// a rename or corrupt value degrades gracefully rather than crashing.
///
/// `allCases` order IS the sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable, Defaults.Serializable,
  Defaults.PreferRawRepresentable
{
  case general
  case appearance
  case terminal
  case agent
  case about

  var id: Self { self }

  /// The label shown in the sidebar row and as the detail pane's title.
  var label: String {
    switch self {
    case .general: return "General"
    case .appearance: return "Appearance"
    case .terminal: return "Terminal"
    case .agent: return "Agent"
    case .about: return "About"
    }
  }

  /// SF Symbol for the sidebar row.
  var systemImage: String {
    switch self {
    case .general: return "gearshape"
    case .appearance: return "paintbrush"
    case .terminal: return "terminal"
    case .agent: return "sparkles"
    case .about: return "info.circle"
    }
  }
}
