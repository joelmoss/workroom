import Defaults

/// A project's "Run command" config (issue #7). Configured per PROJECT (keyed by the project's
/// absolute path in `Defaults[.runCommands]`), but executed in the SELECTED WORKROOM's directory.
/// `Codable` → `Defaults` serialises it as JSON. The field names (`command`/`autoRun`) and the key
/// string (`runCommands`) are a stored-data contract: changing either silently drops every user's
/// saved config on upgrade, so keep them byte-for-byte stable once shipped.
struct RunConfig: Codable, Hashable, Defaults.Serializable {
  var command: String
  var autoRun: Bool

  static let empty = RunConfig(command: "", autoRun: false)

  /// True when there's a non-blank command to run.
  var hasCommand: Bool { !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The single source of truth for every persisted preference: each `Key` owns both the
/// UserDefaults key string *and* the default value, so a default lives in exactly one place
/// (no more duplicating it across an enum getter and every `@Default`/`@AppStorage` site).
/// Read via `@Default(.foo)` in SwiftUI views and `Defaults[.foo]` everywhere else.
///
/// The key *strings* must stay byte-for-byte what they were under the old `@AppStorage`/enum-wrapper
/// storage so existing users' stored preferences carry over on upgrade. Sparkle's
/// `SUEnableAutomaticChecks` is deliberately absent — it's owned by `SPUUpdater`, not us.
extension Defaults.Keys {
  /// Appearance: System (follows the OS) / Light / Dark. Stored as the bare raw string via
  /// `ThemePreference: PreferRawRepresentable` (matching the old `@AppStorage` encoding).
  static let theme = Key<ThemePreference>("themePreference", default: .system)

  /// Copy a finished terminal selection to the pasteboard automatically (xterm/iTerm2 convention).
  static let copyOnSelect = Key<Bool>("copyOnSelect", default: true)

  /// Confirm before quitting (quitting tears down every terminal with no undo).
  static let confirmOnQuit = Key<Bool>("confirmOnQuit", default: true)

  /// Confirm before closing a terminal (closing kills its shell and any running process, no undo).
  static let confirmOnCloseTerminal = Key<Bool>("confirmOnCloseTerminal", default: true)

  /// Whether the global ⌘§ show/hide hotkey is registered (issue #13).
  static let globalHotkey = Key<Bool>("globalHotkeyEnabled", default: true)

  /// Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  static let filePathEditor = Key<String>("filePathEditorBundleID", default: "")

  /// Bundle id of the last editor picked from the toolbar "Open in…" menu; "" = none yet.
  static let lastEditor = Key<String>("openInEditorBundleID", default: "")

  /// Whether the right-hand notifications inspector is open.
  static let showNotifications = Key<Bool>("showNotificationsInspector", default: false)

  /// Whether the notifications menu bar item is shown (issue #33). On by default.
  static let showMenuBarItem = Key<Bool>("showMenuBarItem", default: true)

  /// The persisted selected sidebar target as a `TerminalTarget.ID` string, or nil (issue #14).
  static let sidebarSelection = Key<String?>("sidebar.selectionTargetID", default: nil)

  /// Project paths the user has collapsed in the sidebar; absence of a path means expanded
  /// (the default). Persisted natively as a string array (issue #14).
  static let collapsedProjects = Key<Set<String>>("sidebar.collapsedProjects", default: [])

  /// Per-project "Run command" config, keyed by the project's absolute path (issue #7). Absence of a
  /// path means no run command configured. A single path-keyed map (mirrors `collapsedProjects`):
  /// `Defaults` keys are static, so per-project keys aren't an option.
  static let runCommands = Key<[String: RunConfig]>("runCommands", default: [:])

  /// Remembered order of the workroom tab bar, as `TerminalTarget.ID` strings (issue #23, same
  /// encoding as `sidebarSelection`). Terminals don't survive relaunch, so this is just an ordering
  /// hint applied to whatever is currently active — stale ids resolve away harmlessly.
  static let workroomTabOrder = Key<[String]>("workroomsView.tabOrder", default: [])

  /// Whether the right inspector's "Changes" section is collapsed (issue #24). The inspector now
  /// composes two sections (Changes + Notifications); per-section collapse persists independently.
  static let changesSectionCollapsed = Key<Bool>(
    "inspector.changesSectionCollapsed", default: false)
  /// Whether the right inspector's "Notifications" section is collapsed (issue #24).
  static let notificationsSectionCollapsed = Key<Bool>(
    "inspector.notificationsSectionCollapsed", default: false)
}
