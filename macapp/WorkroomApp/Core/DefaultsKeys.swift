import Defaults
import Foundation

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

  /// Keep ordinary workroom shells running after quit and reattach them on relaunch.
  /// On by default; turn off to restore in-process PTYs that die with the app.
  static let backgroundSessions = Key<Bool>("backgroundSessions", default: true)

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

  /// The selected top-level section in the right activity bar (the vertical icon rail), so it reopens
  /// where you left it. Stored as the bare raw string via `ActivitySection: PreferRawRepresentable`;
  /// a stored value matching no case falls back to `.changes`. Which *pane* the inspector shows;
  /// whether the pane is visible at all is `showInspector`.
  static let activeInspectorSection = Key<ActivitySection>(
    "inspector.activeSection", default: .changes)

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

  /// Whether the Projects sidebar column is shown, mirroring `showInspector`. Persisted so closing
  /// it survives a relaunch — previously session-only (reset to visible on every launch).
  static let sidebarVisible = Key<Bool>("sidebar.visible", default: true)

  /// Whether the notifications menu bar item is shown (issue #33). On by default.
  static let showMenuBarItem = Key<Bool>("showMenuBarItem", default: true)

  /// Load remote author/reviewer avatars — Gravatar (by commit-author email) and
  /// `github.com/<login>.png`. On by default. Off ⇒ only the coloured initials chip renders and NO
  /// avatar image request is made, so opening an untrusted repo's History never beacons the viewer's
  /// IP + an author-email hash to gravatar.com. A privacy control (issue #59 review); the initials
  /// fallback is always the same one used for unknown/404 avatars, so nothing else changes.
  static let loadRemoteAvatars = Key<Bool>("loadRemoteAvatars", default: true)

  /// The persisted selected sidebar target as a `TerminalTarget.ID` string, or nil (issue #14).
  static let sidebarSelection = Key<String?>("sidebar.selectionTargetID", default: nil)

  /// The last-viewed pane in the Settings window (⌘,), so it reopens where you left it (macOS
  /// System Settings behaviour). Stored as the bare raw string via `SettingsPane:
  /// PreferRawRepresentable`; a stored value matching no case falls back to `.general`.
  static let settingsSelectedPane = Key<SettingsPane>("settings.selectedPane", default: .general)

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
  /// encoding as `sidebarSelection`). Terminals now DO survive a relaunch (issue #46), but this stays
  /// an ordering hint applied to whatever is currently active — stale ids resolve away harmlessly.
  static let workroomTabOrder = Key<[String]>("workroomsView.tabOrder", default: [])

  /// Trigger modifiers for the two quick switchers (issue #132): ⌥Tab steps open workrooms across
  /// every window, ⌃Tab steps the current workroom's panes. Retunable because a global hotkey grabber
  /// beats our local key monitor and cannot be detected — AltTab, HyperSwitch and Contexts all take
  /// ⌥Tab by default via a CGEvent tap, so for those users the default is unreachable and a different
  /// modifier is the only fix. No Settings UI yet; `SwitcherModifier` owns the offered set.
  static let switcherWorkroomModifier = Key<SwitcherModifier>(
    "switcher.workroomModifier", default: .option)
  static let switcherPaneModifier = Key<SwitcherModifier>(
    "switcher.paneModifier", default: .control)

  /// When Workroom itself last fetched a project, keyed by the project's absolute path (fetch always
  /// runs at the project root, so this is per-project, never per-workroom). Path-keyed map for the
  /// same reason as `runCommands`.
  ///
  /// **Exists because of a jj asymmetry, not for convenience.** git writes `FETCH_HEAD` on *every*
  /// fetch, so its mtime is a complete record and this map adds nothing for a git project. jj's fetch
  /// is invisible: it passes `--no-write-fetch-head`, and a fetch that brings nothing prints
  /// "Nothing changed." and records **no operation at all** (verified, jj 0.43) — so the op-log scan
  /// alone would mean "last fetch that changed something", and a user clicking Fetch with nothing new
  /// would watch a stale timestamp not move.
  ///
  /// `RemoteStateModel` therefore reports `max(backend evidence, this)`. The backend still wins when
  /// it's newer, which is what keeps a `jj git fetch` run in the user's own terminal visible.
  static let vcsLastFetch = Key<[String: Date]>("vcs.lastFetch", default: [:])

  /// Global inspector layout (issue #24): which of the inspector's sections are collapsed and the
  /// relative heights of the panes, ordered as `InspectorSectionKind.allCases` — Changes, Files, Pull
  /// Request, History. That is NOT the on-screen order (the Changes pane stacks Changes → History →
  /// Pull Request); it's the canonical `storeIndex` order, and the vector is four unnamed bools, so
  /// the two must not be confused. Shared across ALL workrooms and windows — switching the selected
  /// workroom changes the inspector's *content* but never its section collapse/size (a single global
  /// shape, not per-workroom). A stored layout whose entry count doesn't match the current section
  /// count is discarded to the default on load. (Was a per-workroom map keyed by `targetIDString`; a
  /// new key string means old per-workroom data is simply ignored.)
  ///
  /// `.v2` because History moved *into* the Changes stack: the entry count didn't change (History
  /// already held index 3 as a solo pane), so the count check couldn't catch it, yet the stored
  /// weights are meaningless for the new stack — a machine that had dragged the Changes/Pull Request
  /// divider carries a never-dragged weight of 1 for History and would open it squeezed to its floor.
  /// The rename discards those once, so the three sections start at equal heights.
  static let inspectorLayout = Key<InspectorPaneState>(
    "inspector.layout.v2", default: .default)

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

  /// Diff viewer layout (issue #66): `.unified` (default) or `.sideBySide`. Read by `DiffViewer` at
  /// view-construct time, so the choice applies to newly opened diff tabs (a narrow pane falls back
  /// to unified regardless). Stored as the bare raw string via `DiffViewMode: PreferRawRepresentable`.
  static let diffViewMode = Key<DiffViewMode>("diffViewMode", default: .unified)

  /// Per-workroom display label (issue #41), keyed by the workroom's `targetIDString`
  /// ("wr|<project>|<name>", via `TerminalTarget.workroomID`). A label is a display-only alias —
  /// the real workroom name and its Git/JJ workspace are unchanged. Absence of a key means no
  /// label. Invariant: stored values are always trimmed and non-empty (normalised at the write
  /// boundary in `AppStore.setWorkroomLabel`); a cleared label removes the key rather than storing
  /// "". A single project-scoped map (mirrors `runCommands`): `Defaults` keys
  /// are static, so per-workroom keys aren't an option, and the project-scoped id keeps same-named
  /// workrooms in different projects from colliding. The key *string* `workroomLabels` is a
  /// stored-data contract — keep it byte-for-byte stable once shipped.
  static let workroomLabels = Key<[String: String]>("workroomLabels", default: [:])

  /// The split "Merge" button's chosen strategy (issue #88): create a merge commit (default),
  /// squash, or rebase. Global (not per-project) so the choice persists across projects and
  /// restarts. Stored as the bare raw string via `PRMergeMethod: PreferRawRepresentable`.
  static let prMergeMethod = Key<PRMergeMethod>("prMergeMethod", default: .merge)

  /// The release channel for Sparkle auto-updates (issue #91): stable (default), pre, or nightly.
  /// Drives `SPUUpdaterDelegate.allowedChannels(for:)`, read live so switching the Settings picker
  /// takes effect on the next check. Independent of the Go CLI's own `channel` config: the app is
  /// Sparkle-managed, while the standalone CLI self-updates via `workroom update --channel`. Stored
  /// as the bare raw string via `ReleaseChannel: PreferRawRepresentable`.
  static let releaseChannel = Key<ReleaseChannel>("releaseChannel", default: .stable)
}

/// The global persisted inspector layout: the collapse state and relative pane heights of the
/// sections, ordered as `InspectorSectionKind.allCases` (Changes, Files, Pull Request, History —
/// `storeIndex` order, not display order). `weights` are relative (renormalised among the expanded panes at layout time), so they survive
/// inspector-width/height changes; equal weights == the equal-sections default. A layout whose entry
/// count doesn't match the current section count (e.g. a pre-Files 3-entry layout, or a pre-#118
/// 4-entry layout that still had Notifications) is discarded to this default on load.
struct InspectorPaneState: Codable, Defaults.Serializable, Equatable {
  var collapsed: [Bool]
  var weights: [Double]

  static let `default` = InspectorPaneState(
    collapsed: [false, false, false, false], weights: [1, 1, 1, 1])
}
