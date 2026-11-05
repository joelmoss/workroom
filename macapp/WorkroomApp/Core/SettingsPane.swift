import Defaults

/// The panes the Settings window's back and forward buttons walk, as System Settings' do: a new
/// choice clears the way forward, and choosing the open pane is no step.
struct SettingsHistory: Equatable {
  private var back: [SettingsPane] = []
  private var forward: [SettingsPane] = []

  var canGoBack: Bool { !back.isEmpty }
  var canGoForward: Bool { !forward.isEmpty }

  /// `current` is left for `next`, chosen in the sidebar.
  mutating func leave(_ current: SettingsPane, for next: SettingsPane) {
    guard current != next else { return }
    back.append(current)
    forward.removeAll()
  }

  /// The pane before `current`, or nil at the first.
  mutating func goBack(from current: SettingsPane) -> SettingsPane? {
    guard let previous = back.popLast() else { return nil }
    forward.append(current)
    return previous
  }

  /// The pane gone back from, or nil when there is none.
  mutating func goForward(from current: SettingsPane) -> SettingsPane? {
    guard let next = forward.popLast() else { return nil }
    back.append(current)
    return next
  }
}

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
  case notifications
  case appearance
  case terminal
  case agent
  case remoteHosts
  case about

  var id: Self { self }

  /// The label shown in the sidebar row and as the detail pane's title.
  var label: String {
    switch self {
    case .general: return "General"
    case .notifications: return "Notifications"
    case .appearance: return "Appearance"
    case .terminal: return "Terminal"
    case .agent: return "AI Agents"
    case .remoteHosts: return "Remote Hosts"
    case .about: return "About"
    }
  }

  /// SF Symbol for the sidebar row.
  var systemImage: String {
    switch self {
    case .general: return "gearshape"
    case .notifications: return "bell"
    case .appearance: return "paintbrush"
    case .terminal: return "terminal"
    case .agent: return "sparkles"
    case .remoteHosts: return "cloud"
    case .about: return "info.circle"
    }
  }
}
