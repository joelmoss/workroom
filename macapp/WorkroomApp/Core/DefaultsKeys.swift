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

  /// Whether the global ⌘§ show/hide hotkey is registered (issue #13).
  static let globalHotkey = Key<Bool>("globalHotkeyEnabled", default: true)

  /// Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  static let filePathEditor = Key<String>("filePathEditorBundleID", default: "")

  /// Bundle id of the last editor picked from the toolbar "Open in…" menu; "" = none yet.
  static let lastEditor = Key<String>("openInEditorBundleID", default: "")

  /// Whether the right-hand inspector (Changes / Files / Pull Request) is open. The stored key is
  /// still `showNotificationsInspector` for back-compat — the inspector used to carry a Notifications
  /// section (moved to the left sidebar, issue #118), but the persisted user state is preserved.
  static let showInspector = Key<Bool>("showNotificationsInspector", default: false)

  /// Inline terminal agent (issue #49): always on — a failed command can be diagnosed by the local
  /// `claude`/`codex` CLI and a fix suggested in the pane's status bar. (No enable toggle; automatic
  /// vs manual diagnosis is `terminalAgentAutoDiagnose`.)
  /// When on, an eligible failure diagnoses automatically; otherwise the status bar waits for a click.
  /// Set the first time the user accepts the "auto-diagnose next time?" prompt.
  static let terminalAgentAutoDiagnose = Key<Bool>("terminalAgentAutoDiagnose", default: false)
  /// Whether the one-time "auto-diagnose from now on?" prompt has been shown (after the first manual
  /// Diagnose). Prevents re-asking on every manual diagnosis.
  static let terminalAgentAutoDiagnosePrompted = Key<Bool>(
    "terminalAgentAutoDiagnosePrompted", default: false)
  /// Mask common secret shapes in captured output before it's sent to the agent. On by default.
  static let terminalAgentRedactSecrets = Key<Bool>("terminalAgentRedactSecrets", default: true)
  /// Preferred agent backend: "auto" (claude, else codex), "claude", or "codex".
  static let terminalAgentBackend = Key<String>("terminalAgentBackend", default: "auto")
  /// Model for the inline (no-tools) diagnosis. A fast, cheap model is plenty for a bounded
  /// error diagnosis and avoids the user's default (often Opus) running on every failure. Empty =
  /// let the CLI pick its default. (Issue #49 cost optimisation.)
  static let terminalAgentModel = Key<String>(
    "terminalAgentModel", default: "claude-haiku-4-5-20251001")

  /// The docked right inspector's remembered column width. `.inspector` resets to its `ideal`
  /// width every time it's re-shown, so we feed this back as the ideal — hiding and re-showing
  /// (and relaunching) restores the user's last width instead of snapping back to 300. Written
  /// from the live width measurement, clamped to the `.inspectorColumnWidth` min/max range.
  static let inspectorWidth = Key<Double>("inspector.width", default: 300)

  /// The docked Projects sidebar's remembered column width. The sidebar is a custom resizable column
  /// (`SidebarColumn`, not `NavigationSplitView`'s native one), so its width is persisted here and
  /// fed back on launch — mirrors `inspectorWidth`. Clamped to the column's min/max when applied.
  static let sidebarWidth = Key<Double>("sidebar.width", default: 270)

  /// Whether the notifications menu bar item is shown (issue #33). On by default.
  static let showMenuBarItem = Key<Bool>("showMenuBarItem", default: true)

  /// The persisted selected sidebar target as a `TerminalTarget.ID` string, or nil (issue #14).
  static let sidebarSelection = Key<String?>("sidebar.selectionTargetID", default: nil)

  /// The last window's frame as `NSStringFromRect` (issue #70). The launch window restores it so it
  /// reopens at the size you left; empty means "use the default size". The value-based `WindowGroup`
  /// doesn't restore window size itself, so it's managed app-side in `AppStore.attachWindow`.
  static let mainWindowFrame = Key<String>("window.mainFrame", default: "")

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

  /// The app `CFBundleShortVersionString` whose release notes the user has already seen (issue: What's
  /// New). nil on a fresh install / first launch after this feature shipped — recorded silently with
  /// no historical backfill. The What's-New dialog shows only when the running version is newer.
  static let lastSeenVersion = Key<String?>("app.lastSeenVersion", default: nil)

  /// Bounded-retry bookkeeping for the auto What's-New fetch (so a firewalled machine doesn't fire a
  /// doomed GitHub request every launch forever). `whatsNewAttemptVersion` is the version those
  /// attempts were for; the count resets when the running version changes. After
  /// `WhatsNewService.maxAutoAttempts` failures the auto fetch gives up (the menu item still works).
  static let whatsNewAttemptVersion = Key<String?>("app.whatsNewAttemptVersion", default: nil)
  static let whatsNewAttempts = Key<Int>("app.whatsNewAttempts", default: 0)

  /// Collapse state of the two jj Changes-panel lists (Working Copy `@` / Parent Commit `@-`). The
  /// working copy is expanded and the parent collapsed by default. Global (not per-workroom) for v1
  /// — a possible follow-up is to scope these per workroom like `inspectorPaneStates`.
  static let changesWorkingCopyCollapsed = Key<Bool>(
    "changes.workingCopyCollapsed", default: false)
  static let changesParentCommitCollapsed = Key<Bool>(
    "changes.parentCommitCollapsed", default: true)

  /// Diff viewer layout (issue #66): `.unified` (default) or `.sideBySide`. Read by `DiffViewer` at
  /// view-construct time, so the choice applies to newly opened diff tabs (a narrow pane falls back
  /// to unified regardless). Stored as the bare raw string via `DiffViewMode: PreferRawRepresentable`.
  static let diffViewMode = Key<DiffViewMode>("diffViewMode", default: .unified)

  /// Per-workroom display label (issue #41), keyed by the workroom's `targetIDString`
  /// ("wr|<project>|<name>", via `TerminalTarget.workroomID`). A label is a display-only alias —
  /// the real workroom name and its Git/JJ workspace are unchanged. Absence of a key means no
  /// label. Invariant: stored values are always trimmed and non-empty (normalised at the write
  /// boundary in `AppStore.setWorkroomLabel`); a cleared label removes the key rather than storing
  /// "". A single project-scoped map (mirrors `inspectorPaneStates`/`runCommands`): `Defaults` keys
  /// are static, so per-workroom keys aren't an option, and the project-scoped id keeps same-named
  /// workrooms in different projects from colliding. The key *string* `workroomLabels` is a
  /// stored-data contract — keep it byte-for-byte stable once shipped.
  static let workroomLabels = Key<[String: String]>("workroomLabels", default: [:])
}

/// One workroom's persisted inspector layout: the collapse state and relative pane heights of the
/// sections, ordered as `InspectorSectionKind.allCases` (Changes, Files, Pull Request). `weights`
/// are relative (renormalised among the expanded panes at layout time), so they survive
/// inspector-width/height changes; equal weights == the equal-sections default. A layout whose entry
/// count doesn't match the current section count (e.g. a pre-Files 3-entry layout, or a pre-#118
/// 4-entry layout that still had Notifications) is discarded to this default on load.
struct InspectorPaneState: Codable, Defaults.Serializable, Equatable {
  var collapsed: [Bool]
  var weights: [Double]

  static let `default` = InspectorPaneState(
    collapsed: [false, false, false], weights: [1, 1, 1])
}
