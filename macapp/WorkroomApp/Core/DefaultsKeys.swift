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

  /// The selected theme **family** name (issue #36). The family bundles a dark + light variant;
  /// the active variant follows `theme`/the OS appearance. Defaults to the shipped `Workroom`
  /// family so existing users get the Workroom look on upgrade. Resolved by `ThemeService`.
  static let themeFamily = Key<String>("themeFamily", default: ThemeService.defaultFamilyName)

  /// Copy a finished terminal selection to the pasteboard automatically (xterm/iTerm2 convention).
  static let copyOnSelect = Key<Bool>("copyOnSelect", default: true)

  /// Confirm before quitting (quitting tears down every terminal with no undo).
  static let confirmOnQuit = Key<Bool>("confirmOnQuit", default: true)

  /// Confirm before closing a terminal (closing kills its shell and any running process, no undo).
  static let confirmOnCloseTerminal = Key<Bool>("confirmOnCloseTerminal", default: true)

  /// Open a fresh shell terminal in a newly created workroom, once any setup script has run and its
  /// dialog is dismissed. Off by default, so the existing behaviour is unchanged (a created workroom
  /// shows the empty state unless a run command auto-runs). Consulted once at create time; the run
  /// command's auto-run is independent — when both fire the run command is tab #1 and this shell is
  /// tab #2 (see `AppStore.ensureInitialTerminal`).
  static let openTerminalOnCreate = Key<Bool>("openTerminalOnWorkroomCreate", default: false)

  /// Whether the global ⌘§ show/hide hotkey is registered (issue #13).
  static let globalHotkey = Key<Bool>("globalHotkeyEnabled", default: true)

  /// Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  static let filePathEditor = Key<String>("filePathEditorBundleID", default: "")

  /// Bundle id of the last editor picked from the toolbar "Open in…" menu; "" = none yet.
  static let lastEditor = Key<String>("openInEditorBundleID", default: "")

  /// Whether the right-hand notifications inspector is open.
  static let showNotifications = Key<Bool>("showNotificationsInspector", default: false)

  /// The docked right inspector's remembered column width. `.inspector` resets to its `ideal`
  /// width every time it's re-shown, so we feed this back as the ideal — hiding and re-showing
  /// (and relaunching) restores the user's last width instead of snapping back to 300. Written
  /// from the live width measurement, clamped to the `.inspectorColumnWidth` min/max range.
  static let inspectorWidth = Key<Double>("inspector.width", default: 300)

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

  /// Per-workroom inspector layout (issue #24): each workroom remembers which of its three
  /// sections (Changes / Pull Request / Notifications) are collapsed and the relative heights of
  /// the panes, keyed by the workroom's `targetIDString`. Replaces the earlier global per-section
  /// collapse flags — the inspector's shape is now per-workroom.
  static let inspectorPaneStates = Key<[String: InspectorPaneState]>(
    "inspector.paneStates", default: [:])

  /// Collapse state of the two jj Changes-panel lists (Working Copy `@` / Parent Commit `@-`). The
  /// working copy is expanded and the parent collapsed by default. Global (not per-workroom) for v1
  /// — a possible follow-up is to scope these per workroom like `inspectorPaneStates`.
  static let changesWorkingCopyCollapsed = Key<Bool>(
    "changes.workingCopyCollapsed", default: false)
  static let changesParentCommitCollapsed = Key<Bool>(
    "changes.parentCommitCollapsed", default: true)
}

/// One workroom's persisted inspector layout: the collapse state and relative pane heights of the
/// three sections, ordered as `InspectorSectionKind.allCases` (Changes, Pull Request,
/// Notifications). `weights` are relative (renormalised among the expanded panes at layout time),
/// so they survive inspector-width/height changes; equal weights == the three-equal-sections
/// default.
struct InspectorPaneState: Codable, Defaults.Serializable, Equatable {
  var collapsed: [Bool]
  var weights: [Double]

  static let `default` = InspectorPaneState(
    collapsed: [false, false, false], weights: [1, 1, 1])
}
