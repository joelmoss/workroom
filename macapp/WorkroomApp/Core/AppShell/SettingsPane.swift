import Defaults
import Observation

/// Where the Settings window is: a pane, and in Projects, the project open in it (nil: the list).
struct SettingsLocation: Equatable {
  var pane: SettingsPane
  var project: String?
}

/// The places the Settings window's back and forward buttons walk, as System Settings' do: a new
/// choice clears the way forward, and choosing where you are is no step.
struct SettingsHistory: Equatable {
  private var back: [SettingsLocation] = []
  private var forward: [SettingsLocation] = []

  var canGoBack: Bool { !back.isEmpty }
  var canGoForward: Bool { !forward.isEmpty }

  /// `current` is left for `next`, chosen in the sidebar or a pane.
  mutating func leave(_ current: SettingsLocation, for next: SettingsLocation) {
    guard current != next else { return }
    back.append(current)
    forward.removeAll()
  }

  /// The place before `current`, or nil at the first.
  mutating func goBack(from current: SettingsLocation) -> SettingsLocation? {
    guard let previous = back.popLast() else { return nil }
    forward.append(current)
    return previous
  }

  /// The place gone back from, or nil when there is none.
  mutating func goForward(from current: SettingsLocation) -> SettingsLocation? {
    guard let next = forward.popLast() else { return nil }
    back.append(current)
    return next
  }
}

/// Which project Settings ▸ Projects shows. Main windows ask for one through `show(project:)`, so
/// the pane opens on it whether the Settings window was open already or opens for it.
@MainActor
@Observable
final class SettingsRoute {
  static let shared = SettingsRoute()

  /// The project open in the pane, by path; nil shows the list of projects.
  var project: String?
  /// The project whose Run found no command (#127): its pane warns while the command is blank.
  private(set) var warnedProject: String?
  /// Bumped on every `show`, so an open Settings window goes to the project asked for.
  private(set) var requests = 0
  private var requested: String?

  func show(project path: String, runWarning: Bool) {
    requested = path
    warnedProject = runWarning ? path : nil
    Defaults[.settingsSelectedPane] = .projects
    requests += 1
  }

  /// Run's warning is for its one request: leaving the project ends it.
  func leave(project path: String) {
    if warnedProject == path { warnedProject = nil }
  }

  /// The project a main window asked for that the Settings window has yet to go to.
  func takeRequest() -> String? {
    defer { requested = nil }
    return requested
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
  case projects
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
    case .projects: return "Projects"
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
    case .projects: return "folder"
    case .remoteHosts: return "cloud"
    case .about: return "info.circle"
    }
  }
}
