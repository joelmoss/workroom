import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

/// Identifies a selectable row in the project → (root | workroom) sidebar tree. Workroom
/// names can repeat across projects, and the root is per project, so both carry their
/// project path. The selected *terminal target* is one of these.
enum SidebarID: Hashable {
  case project(String)
  case root(project: String)
  case workroom(project: String, name: String)

  /// Whether this id is scoped to the given project path — its row, its root, or one of its
  /// workrooms. Used to clear selection when a whole project is deleted.
  func belongsToProject(_ path: String) -> Bool {
    switch self {
    case .project(let p), .root(project: let p), .workroom(project: let p, name: _):
      return p == path
    }
  }
}

/// Which command-palette dialog is showing (issue #94). A single `@Published` `ActivePicker?` on the
/// store drives both presenters, so raising one dialog automatically dismisses the other.
enum ActivePicker {
  case new
  case open
}

/// A workroom queued for deletion, awaiting the user's confirmation. Held on the store so
/// both the sidebar's delete affordances and the Delete menu command (⌘⌫) raise the same
/// confirmation prompt.
struct PendingWorkroomDeletion {
  let workroom: Workroom
  let project: Project
}

/// A workroom (or root) target awaiting close confirmation. "Closing" tears down all of the
/// target's terminal tabs — its chip leaves the tab bar — but leaves the workroom itself (its
/// directory/worktree) intact; that's the distinction from `PendingWorkroomDeletion`. Held on the
/// store so the tab bar's "Close" context-menu item raises one shared confirmation prompt.
struct PendingWorkroomClose {
  let target: TerminalTarget
  /// The chip's display name (workroom name, or the project name for a root) — used in the prompt.
  let name: String
}

/// A project queued for deletion, awaiting the user's type-the-name confirmation. Held on
/// the store (and `Identifiable` so it drives a `.sheet(item:)`) so the sidebar's Delete
/// Project affordance and the confirm sheet share one piece of state. `id` is the project
/// path, so re-targeting a different project rebuilds the sheet (resetting its typed/toggle
/// `@State`).
struct PendingProjectDeletion: Identifiable {
  let project: Project
  var id: String { project.path }
}

/// A workroom awaiting a display-label edit (issue #41). Held on the store (and `Identifiable` so it
/// drives a `.sheet(item:)`) so the sidebar row's and tab chip's "Set/Edit Label…" items share one
/// piece of state. `id` is the workroom's project-scoped target id, so re-targeting a different
/// workroom rebuilds the sheet (resetting its typed `@State`).
struct PendingWorkroomLabel: Identifiable {
  let workroom: Workroom
  let project: Project
  var id: String { TerminalTarget.workroomID(project: project.path, name: workroom.name) }
}

/// The project-settings sheet's one presentation source (issue #127): used both by the plain
/// "Project Settings…" entry points (hover button / context menu — `showsRunWarning: false`) and
/// by Run invoked with no command configured (`showsRunWarning: true`). Unified into ONE
/// store-level pending state — not one local to `ProjectSidebar` plus a second store-level one —
/// because ⌘R is a global key monitor that can fire while the sheet is already open from the other
/// entry point; two independent `.sheet(item:)` presenters would race (eng review issue #127-eng-1).
struct PendingProjectSettings: Identifiable {
  let project: Project
  var showsRunWarning: Bool = false
  var id: String { project.id }
}

/// App-wide state and actions. A single shared instance is used so the App, views,
/// and menu Commands all act on the same store. All CLI work is awaited (it runs off
/// the main thread inside WorkroomCLI), keeping the UI responsive.
@MainActor
final class AppStore: ObservableObject {
  /// Shared, app-wide project data (issue #70). Holds the project list and everything derived from
  /// it that is identical across windows (root labels, VCS/CI status cache, GitHub-CLI status, busy
  /// set). The properties below proxy through to it, and `init` re-publishes its `objectWillChange`,
  /// so views/menus observing this store still re-render when the shared data changes.
  let projectStore: ProjectStore
  private var projectStoreObservation: AnyCancellable?

  /// Seam over the bundled `workroom` CLI (issue #103). Production uses
  /// `WorkroomCLI.shared`; tests inject a fake to drive mutations without a real
  /// subprocess. Injected like `projectStore` (in the init body, not as a default
  /// arg, which is evaluated nonisolated).
  private let cli: WorkroomCLIProtocol

  /// Seam over the macOS Trash (issue #108): a from-disk project delete moves dirs to the Bin via
  /// `FileManager.trashItem` (Finder "Put Back", no TCC prompt). Injectable so tests assert the
  /// orchestration with a fake recorder instead of polluting the real Trash. Mirrors the
  /// `CommandExecutor` mock seam.
  var trasher: Trashing = SystemTrasher()

  /// The `NSWindow` hosting this store, resolved once the view tree is in a window (issue #70). Weak:
  /// the window outlives the store's need for it, and the registry holds the authoritative mapping.
  weak var hostWindow: NSWindow?
  /// This window's display number — the smallest unused positive integer, assigned by `WindowRegistry`
  /// on registration and freed for reuse when the window closes (issue #70, macOS untitled-doc style).
  /// Backs the `windowTitle` fallback for a window with nothing selected ("Window 1", "Window 2", …).
  /// `@Published` so the title updates the moment the registry assigns it. 0 until registered.
  @Published var windowNumber = 0
  /// Retains the close-guard delegate proxy (the window holds its delegate weakly) for this window's
  /// lifetime (issue #70, A3).
  private var closeGuard: WindowCloseGuard?
  /// Frame size a new window should adopt to match the window that was current when it was opened
  /// (issue #70). Set by `RootWindow.init`; applied once in `attachWindow` before the window shows.
  /// nil for the launch window.
  var pendingInitialWindowSize: CGSize?
  private var didApplyInitialSize = false
  /// True only for the window SwiftUI brings up at launch (`WindowSeed.restore`). Set by
  /// `RootWindow.init`. The What's-New auto-check runs only from this window so a relaunch with
  /// several restored windows doesn't fan out duplicate dialogs.
  var isRestoreWindow = false
  /// Retained `NSWindow` frame-change observers that persist this window's size for the next launch.
  private var frameObservers: [NSObjectProtocol] = []
  /// Retains the `NSWindow.didUpdate` observer that keeps the title out of the title bar (issue #70).
  private var titleVisibilityObserver: NSObjectProtocol?

  deinit {
    for token in frameObservers { NotificationCenter.default.removeObserver(token) }
  }

  /// Only the active (last-key) window writes the shared sidebar prefs to UserDefaults, so multiple
  /// windows don't clobber each other's selection / collapse / tab order; the single restored window
  /// reads them on launch (issue #70, CQ1). `lastActiveStore` is modal-safe (a quit alert / Settings
  /// becoming key never changes it). Defaults to `true` until the first window registers, so the
  /// initial single window persists from the very first edit.
  private var persistsSidebarPrefs: Bool {
    WindowRegistry.shared.lastActiveStore.map { $0 === self } ?? true
  }

  /// The list of configured projects — proxied to the shared `ProjectStore` so every window sees the
  /// same list. (Storage moved out of `AppStore`; the get/set proxy keeps all existing call sites,
  /// incl. `projects[i] = …` / `projects.removeAll`, working unchanged.)
  var projects: [Project] {
    get { projectStore.projects }
    set { projectStore.projects = newValue }
  }
  @Published var selectedProjectID: Project.ID?
  /// The selected terminal target — a `.root` or a `.workroom` (never `.project`), or nil
  /// when nothing is selected (the launch state). `.project` is not a target; clicking a
  /// project toggles its expansion instead. Persisted across launches (issue #14) via `didSet`
  /// and restored in `apply()`.
  @Published var selectedTargetID: SidebarID? {
    didSet {
      if persistsSidebarPrefs {
        Defaults[.sidebarSelection] = Self.targetIDString(for: selectedTargetID)
      }
      // Record the new location for back/forward (issue #26), unless we're replaying history.
      if !isNavigatingHistory { recordCurrentLocation() }
      // Freshen the newly-selected workroom's status (incl. CI) — debounced so arrow-key
      // cycling through rows doesn't fork a probe per row (issue #24).
      scheduleSelectedStatusRefresh()
      // The inspector's section collapse/size is GLOBAL (issue #24) — deliberately NOT reloaded on a
      // workroom switch, so switching workrooms changes only the inspector's content, never its shape.
      // The Files tree is re-pointed lazily by `FilesPanel` (only while that section is shown), not
      // here — so selecting a workroom doesn't list its files unless you're actually browsing them.
      refreshSelectionHasTabs()  // the inspector follows the *active* (tab-having) selection
      // Re-point History the instant the workroom changes (only while it's the visible section,
      // mirroring HistoryPanel's own guard) so the list clears + shows its loader immediately,
      // instead of lingering on the previous workroom's commits until the panel's `.task` catches
      // up. `focus` is idempotent, so the panel's later re-focus to the same root no-ops.
      if selectedTargetID != oldValue, activeInspectorSection == .history {
        commitHistory.focus(inspectorTarget.map { URL(fileURLWithPath: $0.path) })
      }
    }
  }

  /// True while the selected target has ≥1 open tab. The inspector (History / Changes / Pull
  /// Request) reflects the *active* workspace, so closing all tabs of the selected workroom empties
  /// it even though the sidebar row stays selected (the detail pane likewise drops to its "No
  /// terminal" placeholder — this keeps the two in sync). Maintained at selection changes + the tab
  /// add/remove hooks: a plain `terminals.tabCount` read in a view wouldn't re-render on a tab close,
  /// because AppStore doesn't forward `terminals`' `objectWillChange` (only `ProjectStore`'s).
  @Published private(set) var selectionHasTabs = false
  /// Project paths the user has collapsed in the sidebar (issue #14). Held here as `@Published`
  /// rather than read via `@Default` in the view: a `@Default` change does not reliably re-evaluate
  /// the sidebar's `List` until some *other* state changes (e.g. the pointer moving over a row), so
  /// expand/collapse appeared to "stick" until you moved the mouse. `@Published` fires
  /// `objectWillChange` synchronously, so the tree updates on the click itself. Persisted via `didSet`.
  @Published var collapsedProjects: Set<String> = Defaults[.collapsedProjects] {
    didSet { if persistsSidebarPrefs { Defaults[.collapsedProjects] = collapsedProjects } }
  }
  /// Remembered workroom tab-bar order (issue #23), as `TerminalTarget.ID` strings. `@Published`
  /// (not read via `@Default` in the view) because a `@Default` write doesn't reliably re-render the
  /// `NavigationSplitView` detail, so a drag-reorder's write didn't take and the dropped chip snapped
  /// back to its old slot. Persisted via `didSet`; initialised from `Defaults`. Stale ids resolve away
  /// in `orderedWorkroomTargets`, so it's self-healing.
  @Published var workroomTabOrder: [TerminalTarget.ID] = Defaults[.workroomTabOrder] {
    didSet { if persistsSidebarPrefs { Defaults[.workroomTabOrder] = workroomTabOrder } }
  }
  /// Whether the projects sidebar column is visible. The single source of truth for showing the
  /// custom `SidebarColumn` *and* the View ▸ Projects checkmark — a bare AppKit `toggleSidebar` has no
  /// state a menu checkmark can bind to, so it could never show a tick. Session-only (resets to shown
  /// on launch); the dragged width is persisted separately to `Defaults.sidebarWidth`.
  @Published var sidebarVisible: Bool = true
  /// Whether a collapsed sidebar is *temporarily* on screen via edge-hover reveal (issue #56): the
  /// left Projects overlay (`previewingLeft`) and the right inspector overlay (`previewingRight`).
  /// These are observable app state, not view-local, because other surfaces must react: notification
  /// routing flashes the row instead of popping a toast while `previewingRight` (so the revealed
  /// Notifications panel and a toast never co-display — the invariant at `recordNotification`), and
  /// `ToastStack` withholds toasts while it's set. Session-only and deliberately NOT persisted (a
  /// transient hover state). Set by `EdgeRevealSidebar`.
  @Published var previewingLeft: Bool = false
  @Published var previewingRight: Bool = false
  /// The cursor is over the matching sidebar's title-bar *toggle button* while that sidebar is
  /// collapsed — the trigger for the edge-hover reveal (issue #74). The trigger used to be a wide
  /// strip over the toolbar (issue #56), but that strip sat directly above the leftmost workroom
  /// tabs: reaching for a tab tripped the reveal, whose panel then covered the very tab you wanted.
  /// Pinning the trigger to the toggle button itself keeps it clear of the tabs. `hoveringLeftToggle`
  /// is set by the leading sidebar's title-bar toggle (`LeadingTitlebarBar`); the trailing side has no
  /// toggle button (the activity bar is always pinned to that edge), so `hoveringRightToggle` stays
  /// false. Observed by `EdgeRevealSidebar`. Session-only, not persisted (transient hover state).
  @Published var hoveringLeftToggle: Bool = false
  @Published var hoveringRightToggle: Bool = false
  /// The docked Projects sidebar's chosen width, set by `SidebarColumn`'s resize handle on drag-end
  /// (mirrors `dockedInspectorWidth`), so the edge-hover reveal panel (issue #56) matches the user's
  /// width rather than a fixed guess. `nil` until first set this session; both the column and the
  /// reveal fall back to `Defaults.sidebarWidth`. Session-only; not `@Published` — the live drag is
  /// tracked in the column's local state and only committed here once, on drag-end.
  var dockedSidebarWidth: CGFloat?
  /// The docked right inspector's width (issue #56), set by the custom inspector column's resize
  /// handle and read by both the docked card and the right edge-hover reveal. `@Published` so a
  /// resize drag re-renders the inspector live. Safe to publish (unlike `dockedSidebarWidth`):
  /// the inspector is a custom column now, not the native NavigationSplitView one, so nothing writes
  /// this on every layout pass. `nil` until first set this session; falls back to `Defaults`.
  @Published var dockedInspectorWidth: CGFloat?
  /// The workroom-into-workroom split (issue #23 follow-up): two+ workrooms shown side by side, each a
  /// full `TargetTerminalDetail`. `nil` = the single `selectedTarget` (the normal case). Leaves are
  /// `SidebarID`; the focused member IS `selectedTargetID`. Always ≥2 *live* leaves when non-nil (a lone
  /// leaf is "no split", mirroring the terminal-split invariant). Session-only (not persisted, like the
  /// terminal split). All edits go through the helpers in `AppStore+WorkroomSplit.swift`; stale leaves
  /// resolve away in `resolvedSplitLeaves`, so it's self-healing. See that file for the transforms.
  @Published var workroomSplit: PaneLayout<SidebarID>?
  /// Terminal targets whose terminal subtree is *expanded* in the sidebar (issue #30). Inverse
  /// polarity to `collapsedProjects`: terminals are collapsed by default, so the set holds only the
  /// expanded ones (empty = all collapsed). Session-only and deliberately NOT persisted — the
  /// terminals themselves don't survive a relaunch (`TerminalSessions` is in-memory), so a restored
  /// expand flag would point at nothing. Pruned below 2 tabs by the `onTabsRemoved` hook in `init`.
  @Published var expandedTerminalTargets: Set<TerminalTarget.ID> = []
  /// Per-project resolved root branch/bookmark labels, hydrated asynchronously after each
  /// load (see `resolveBranches`). Absent ⇒ the root row shows a dim "root" until resolved.
  var rootRefs: [Project.ID: RootRef] {
    get { projectStore.rootRefs }
    set { projectStore.rootRefs = newValue }
  }
  /// Per-workroom (and per-root) VCS + CI status driving the ambient badges and the Changes
  /// detail panel (issue #24), keyed by `SidebarID`. Resolved app-side (see
  /// `WorkroomStatusResolver`), best-effort/"last checked" — NOT real-time. Ephemeral:
  /// deliberately NOT persisted (operational state, unlike the sidebar prefs above). Hydrated
  /// after each load, on selection, and on focus; see `AppStore+WorkroomStatus.swift`.
  var workroomStatuses: [SidebarID: WorkroomStatus] {
    get { projectStore.workroomStatuses }
    set { projectStore.workroomStatuses = newValue }
  }
  /// Whether the GitHub CLI is usable for the PR/CI probes (machine-global). Optimistic default so
  /// no warning flashes before the first check; refreshed by `refreshGitHubCLI()` and read by the
  /// Pull Request inspector section. Drives a warning + gates the `gh` probes when not available.
  var githubCLIStatus: GitHubCLIStatus {
    get { projectStore.githubCLIStatus }
    set { projectStore.githubCLIStatus = newValue }
  }
  /// When `githubCLIStatus` was last probed (its own short TTL, so we don't re-run `gh auth status`
  /// on every selection).
  var ghStatusCheckedAt: Date? {
    get { projectStore.ghStatusCheckedAt }
    set { projectStore.ghStatusCheckedAt = newValue }
  }
  /// A PR write action (Phase 2b) is running — disables the PR actions menu so it can't double-fire.
  @Published var prActionInFlight = false

  // Inspector section collapse (issue #24). Held on the store rather than as `@Default` in the
  // inspector view: the `.inspector` content doesn't observe `@Default` changes, but it DOES observe
  // this `@EnvironmentObject`. These three are the *live* state for the currently selected workroom;
  // they're the GLOBAL layout, loaded once at launch and persisted on every change to
  // `Defaults[.inspectorLayout]` via `loadInspectorState()` / `persistInspectorState()` — shared
  // across all workrooms, so a workroom switch never changes them.
  @Published var changesSectionCollapsed = false {
    didSet { persistInspectorState() }
  }
  /// Collapse state of the Files section (the repo file tree). Sits second, right under Changes.
  @Published var filesSectionCollapsed = false {
    didSet { persistInspectorState() }
  }
  @Published var prSectionCollapsed = false {
    didSet { persistInspectorState() }
  }
  /// Relative heights of the three inspector panes for the selected workroom (issue #24), ordered as
  /// `InspectorSectionKind.allCases`. Equal == the default three-equal-sections layout; updated when
  /// the user drags a divider (via `updateInspectorSizeWeights`) and persisted per workroom. Not set
  /// directly by the view — the `NSSplitView` reports drag results back through the store.
  @Published var inspectorSizeWeights: [Double] = [1, 1, 1, 1]
  /// The selected top-level section in the right activity bar (issue: activity bar). Drives which
  /// pane the inspector shows (`RightInspector` renders `activeInspectorSection.subSections`). Held
  /// as `@Published` (not read via `@Default` in the bar) so a click re-renders the bar + inspector
  /// synchronously — a bare `@Default` write invalidates asynchronously (the `SettingsView` gotcha).
  /// Persisted per-machine via `didSet`; whether the pane is visible at all is `Defaults[.showInspector]`.
  @Published var activeInspectorSection: ActivitySection = Defaults[.activeInspectorSection] {
    didSet {
      if activeInspectorSection != oldValue {
        if !isolatesInspectorSectionForTesting {
          Defaults[.activeInspectorSection] = activeInspectorSection
        }
        // Entering History with a workroom already selected: point the model now so the pane shows
        // its loader immediately, instead of flashing the `.idle` ("Select a workroom") placeholder
        // until the panel's `.task` catches up. `focus` is idempotent (no-op if already there).
        if activeInspectorSection == .history {
          commitHistory.focus(inspectorTarget.map { URL(fileURLWithPath: $0.path) })
        }
      }
    }
  }
  /// Test seam: keep an `activeInspectorSection` change in THIS store instead of persisting it to the
  /// shared `inspector.activeSection` setting. Same hazard as `confirmOnCloseOverrideForTesting`
  /// (which see for the full account): `-parallel-testing` gives each worker its own host process but
  /// ONE UserDefaults domain, so a class that wants its store on History leaves every store another
  /// worker builds meanwhile starting on History too — and the `selectedTargetID` didSet then focuses
  /// `commitHistory` (a real VCS read on a fixture path) in a test that never asked for History.
  var isolatesInspectorSectionForTesting = false
  /// Test seam: pin whether the inspector pane counts as visible, per store, instead of writing the
  /// shared `showInspector` setting. `nil` (production) reads the real setting.
  ///
  /// The live-History triggers gate on the pane being *visible*, so the tests that drive them have to
  /// control it — and writing the key to do that is the same cross-worker leak as above, one key over.
  /// Those windows were short enough never to have gone red, which is not the same as being safe.
  var inspectorVisibleOverrideForTesting: Bool?
  /// Whether the inspector pane is open: a test's pinned value if there is one, else the setting.
  var inspectorIsVisible: Bool {
    Self.resolveInspectorVisible(override: inspectorVisibleOverrideForTesting)
  }
  /// The override-or-setting half of `inspectorIsVisible`, lifted out as a pure static for the same
  /// reason `resolveConfirmOnClose` is one: once the History classes inject the override, no test
  /// reaches the `Defaults` side, so hard-coding this `true` would leave the suite green while the
  /// live-History refresh quietly started reading VCS behind a closed pane. `nonisolated` because it
  /// touches no actor state — just its argument and a `Defaults` read.
  nonisolated static func resolveInspectorVisible(override: Bool?) -> Bool {
    override ?? Defaults[.showInspector]
  }
  /// The repo file tree behind the inspector's Files section. Re-pointed at the selected target's
  /// directory whenever the selection changes (see `selectedTargetID.didSet`); the `FilesPanel`
  /// observes it. Owned here so it survives inspector re-renders and tracks selection centrally.
  let fileTree = FileTreeModel()
  /// Store-owned commit-history state for the History inspector section (issue #59); re-pointed on
  /// selection by `HistoryPanel`, mirroring `fileTree`. Named `commitHistory` — `history` is the
  /// browser-style `NavigationHistory`. In UI-test fixture mode it reads canned commits (the fake
  /// workroom dirs aren't real repos), so the History → changeset click-through is testable. Assigned
  /// in `init` (not inline) so tests can inject a stub and assert the live-refresh triggers fire —
  /// see the `commitHistory:` init parameter (a `@MainActor` type can't be a nonisolated default arg).
  let commitHistory: HistoryModel
  /// Shared in-file find state for the read-only file viewer (⌘F in a file pane). Only the focused
  /// `PlainFileViewer` feeds + shows it; routed to from `startFindInFocusedPane`.
  let fileFind = FileFindModel()
  /// True while `loadInspectorState` is writing the three collapse flags + weights, so their
  /// `didSet`s don't persist the values straight back (and the load isn't mistaken for a user edit).
  private var isLoadingInspectorState = false

  @Published var errorMessage: String?
  /// Title for the error alert. Nil falls back to the generic title; specific
  /// failures (e.g. teardown) set their own.
  @Published var errorTitle: String?
  @Published var isLoading = false
  /// Project paths with an in-flight create/delete (for per-row progress + disabling).
  var busyProjects: Set<String> {
    get { projectStore.busyProjects }
    set { projectStore.busyProjects = newValue }
  }
  /// Target ids of workrooms whose create is still in flight (issue #116) — must not be deleted while
  /// their setup runs. Shared across windows (see `ProjectStore`).
  var creatingWorkrooms: Set<TerminalTarget.ID> {
    get { projectStore.creatingWorkrooms }
    set { projectStore.creatingWorkrooms = newValue }
  }
  /// Target ids of workrooms with an in-flight optimistic deletion — filtered out of every reload so a
  /// stale `list` can't resurrect them (the create/delete race). Shared across windows.
  var deletingWorkrooms: Set<TerminalTarget.ID> {
    get { projectStore.deletingWorkrooms }
    set { projectStore.deletingWorkrooms = newValue }
  }
  /// Set by the "Add Project" menu command to trigger the sidebar's file importer.
  @Published var requestAddProject = false
  /// Set by the "New Workroom" menu command (⌘N) to raise the project-picker dialog (issue #81).
  /// RootView observes it, presents the sheet, and resets the flag — same idiom as `requestAddProject`.
  @Published var requestNewWorkroomPicker = false
  /// Set by the "Open workroom…" menu command (⌘O, issue #94) to raise the open-existing picker.
  /// RootView observes it, presents the sheet, and resets the flag — same idiom as the two above.
  @Published var requestOpenWorkroomPicker = false
  /// Which command-palette dialog is currently shown (nil = none). Single source of truth so the New
  /// and Open Workroom presenters are mutually exclusive — opening one replaces the other (issue #94).
  @Published var activePicker: ActivePicker?
  /// A workroom awaiting delete confirmation; setting it raises the confirmation prompt.
  @Published var pendingDeletion: PendingWorkroomDeletion?
  /// A target awaiting close confirmation (tab bar "Close"); setting it raises the close prompt.
  @Published var pendingWorkroomClose: PendingWorkroomClose?
  /// A project awaiting type-to-confirm deletion (drives the DeleteProjectSheet). Set by the
  /// project row's context menu; cleared when the sheet's Delete/Cancel resolves.
  @Published var pendingProjectDeletion: PendingProjectDeletion?
  /// A workroom awaiting a display-label edit (drives the WorkroomLabelSheet, issue #41). Set by the
  /// sidebar row's / tab chip's "Set Label…"/"Edit Label…" item; cleared when the sheet resolves.
  @Published var pendingWorkroomLabel: PendingWorkroomLabel?
  /// The project-settings sheet's one presentation source (drives `ProjectSettingsSheet`, issue #7
  /// origin, issue #127 adds the no-command-Run trigger). Set by the project row's hover button /
  /// context menu (`showsRunWarning: false`), or by `runOrFocusRunCommand` when Run is invoked with
  /// no command configured (`showsRunWarning: true`). See `PendingProjectSettings`'s doc comment for
  /// why this is ONE store-level source rather than a sidebar-local `@State` plus a second one.
  @Published var pendingProjectSettings: PendingProjectSettings?
  /// A workroom being created in THIS window (issue #116). Non-nil from the moment the user picks a
  /// project until the setup dialog is dismissed (a setup script ran) or auto-dismisses (no script).
  /// Drives the immediate full-pane setup dialog AND the provisional "Creating…" tab chip — both
  /// appear before the CLI has even reported the (generated) name. Per-window, like selection.
  @Published var creation: WorkroomCreation?

  let terminals = TerminalSessions()
  /// In-memory notification spine driving the badges + inspector (issue #10). Owned here,
  /// mirroring `terminals`; views observe it directly via `@EnvironmentObject`.
  let notifications = NotificationCenterStore()

  /// Bottom-right toast queue (issue #31): the foreground, inspector-*closed* surface for a new
  /// notification. FIFO, capped at `maxToasts` (a new toast beyond the cap pushes the oldest out);
  /// each toast carries the `WorkroomNotification` it mirrors so a tap can route via `openTerminal`.
  /// Rendered by `ToastStack`, overlaid bottom-right in `RootView`.
  @Published var toasts: [WorkroomNotification] = []
  /// Max simultaneously-visible toasts; beyond this the oldest is dropped so a chatty emitter can't
  /// overflow the window (matches the "stack a few, drop oldest" decision).
  private static let maxToasts = 4
  /// Posts native banners. Behind a protocol for testability; the real one wraps
  /// `UNUserNotificationCenter`.
  let systemNotifier: SystemNotifying = SystemNotifier()

  /// Browser-style back/forward history of visited `(target, tab)` locations (issue #26).
  /// `@Published` so toolbar/menu enablement (`canGoBack`/`canGoForward`) re-evaluates when it
  /// changes. Session-only — deliberately not persisted across launches. `private(set)` so unit
  /// tests can inspect it (read-only) while only the store mutates it.
  @Published private(set) var history = NavigationHistory()
  /// True while `navigateBack`/`navigateForward`/`applyLocation` are replaying, so the
  /// `selectedTargetID` didSet and the `terminals.onFocusChange` seam don't re-record the very
  /// location they're navigating to.
  private var isNavigatingHistory = false

  private let resolver = BranchResolver()
  /// The in-flight branch-resolution sweep; cancelled and replaced on each reload so a
  /// slow sweep never writes stale labels over a newer one.
  private var branchTask: Task<Void, Never>?
  /// VCS/CI status resolution (issue #24). `internal` (not `private`) so the
  /// `AppStore+WorkroomStatus.swift` extension can drive them. Tasks are cancelled+replaced
  /// per sweep / per selection so a slow probe never writes stale status over a newer one. `var`
  /// (not `let`) so tests can inject a `WorkroomStatusResolver` with a mock command runner.
  var statusResolver = WorkroomStatusResolver()
  var statusSweepTask: Task<Void, Never>?
  var selectionStatusTask: Task<Void, Never>?
  /// Keeps the selected workroom's local VCS status live (without polling) by watching its directory
  /// for filesystem changes (issue #24 follow-up). Retargeted on selection; see
  /// `updateSelectedWorkroomWatch` / `handleWorkroomFileChange`.
  lazy var workroomFileWatcher = WorkroomFileWatcher { [weak self] paths in
    self?.handleWorkroomFileChange(paths)
  }
  /// The watcher's local-refresh task — cancel-and-replace so the latest filesystem change wins and
  /// at most one probe from THIS lane is in flight. That alone does NOT serialize jj snapshots
  /// overall: the sweep and the selection-refresh lanes (`AppStore+WorkroomStatus.swift`) can still
  /// reach `resolveLocal` concurrently with this one for the same project. Cross-lane (and
  /// cross-window) jj snapshot ordering is `JJSnapshotGate`'s job, threaded through
  /// `WorkroomStatusResolver.resolveLocal`'s `projectRoot` parameter.
  var watchRefreshTask: Task<Void, Never>?
  /// Live root branch/bookmark labels: one filesystem watcher per project, pointed at its VCS
  /// metadata dir (`.git` / `.jj`). A branch switch or bookmark move in the root terminal updates
  /// the sidebar label immediately, instead of waiting for the throttled on-focus reload. Keyed per
  /// project (unlike the single `workroomFileWatcher`) because root labels are global, not
  /// selection-scoped. The watch is naturally quiet — working-tree edits don't touch `.git`/`.jj`,
  /// only VCS operations do — and resolution is read-only + deduped, so it can't loop or churn.
  private var rootBranchWatchers: [Project.ID: WorkroomFileWatcher] = [:]
  /// Per-project re-resolve task (cancel-and-replace) so a burst of metadata writes resolves once.
  private var rootBranchRefreshTasks: [Project.ID: Task<Void, Never>] = [:]
  /// When the project list was last loaded — used to throttle the on-focus refresh.
  private var lastLoadAt: Date = .distantPast
  /// The selection persisted from a previous launch (issue #14), applied once on the first
  /// successful load (see `apply`). Consumed there so a later refresh can't resurrect it.
  private var pendingRestoreSelection: TerminalTarget.ID?
  /// UI-test fixture mode only: whether this window auto-selects the fixture workroom. True for the
  /// launch window, false for a ⌘N window so it stays blank — the fixture analogue of clearing
  /// `pendingRestoreSelection` on the real path (issue #70).
  private var fixtureAutoSelect = true

  /// Production builds one store per window (issue #70), each sharing `ProjectStore.shared`; tests
  /// build an isolated `AppStore()` (own fresh `ProjectStore`), inject `projects`, and drive the real
  /// recording/navigation paths. `init` does no CLI work (only `bootstrap()`/`load()` do).
  init(
    projectStore: ProjectStore? = nil, cli: WorkroomCLIProtocol? = nil,
    commitHistory: HistoryModel? = nil
  ) {
    // Default to a fresh, isolated store (so `AppStore()` in tests never touches the singleton);
    // production passes `.shared`. Constructed here in the main-actor init body, not as a default
    // argument (default args are evaluated nonisolated, which can't call a @MainActor initializer).
    let store = projectStore ?? ProjectStore()
    self.projectStore = store
    self.cli = cli ?? WorkroomCLI.shared
    // `commitHistory` is assigned here (not inline) for the same @MainActor reason: a test injects a
    // stub to observe the live-refresh triggers; production/fixture keep the default.
    self.commitHistory =
      commitHistory
      ?? (UITestFixture.isActive
        ? HistoryModel(resolve: { _ in UITestFixture.vcsProvider })
        : HistoryModel())
    // Re-publish the shared project store's changes so views and menus observing THIS store
    // re-render when the proxied `projects` / `rootRefs` / `workroomStatuses` / … change (issue #70).
    projectStoreObservation = store.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    pendingRestoreSelection = Defaults[.sidebarSelection]
    // Route each terminal's activity (OSC/bell) through the notification spine, gated on
    // focus, and raise a native banner only when the app is backgrounded.
    terminals.activityHandler = { [weak self] targetID, tabID, activity in
      self?.handleActivity(targetID: targetID, tabID: tabID, activity: activity)
    }
    // Record each focused-tab change for back/forward history (issue #26), unless we're replaying.
    terminals.onFocusChange = { [weak self] _, _ in
      guard let self else { return }
      // The in-file find is tied to the focused file pane (the model is shared across panes). Any
      // focused-tab change ends that session: close it so ⌘G can't step a hidden find from a
      // terminal/diff pane, and the bar doesn't reappear pre-filled on the next file (review).
      if self.fileFind.isOpen { self.fileFind.close() }
      // A focus change includes a freshly-added tab appearing → re-enable the inspector.
      self.refreshSelectionHasTabs()
      guard !self.isNavigatingHistory else { return }
      self.recordCurrentLocation()
    }
    // Prune dead entries when tabs are closed/reaped, so canGoBack/Forward stay honest (issue #26).
    // Also collapse a target's sidebar terminal subtree once a close drops it below the 2-tab
    // disclosure threshold (issue #30), so a stale expand flag can't auto-reveal if the count climbs
    // back later — the subtree is meant to be re-opened deliberately.
    terminals.onTabsRemoved = { [weak self] targetID, ids in
      guard let self else { return }
      self.history.prune(removing: Set(ids))
      if self.terminals.tabCount(forTargetID: targetID) < 2 {
        self.expandedTerminalTargets.remove(targetID)
      }
      // If the target's run terminal was closed/reaped, drop its whole run state (issue #7). One
      // assignment clears every phase, so no stop/restart bookkeeping can be left behind to drive a
      // later unexpected respawn or first-press hard kill (review #1).
      if let runTab = self.runStates[targetID]?.tab, ids.contains(runTab) {
        self.runStates[targetID] = nil
        self.runOutcomes[targetID] = nil  // reset the red run icon (issue #79)
        self.clearRunPidFile(for: targetID)  // forget the captured pid (issue #7)
        self.resetRunToast(for: targetID)  // run gone → drop its toast state (issue #67)
      }
      // Closing the last terminal in a co-displayed split pane leaves an empty pane whose only
      // affordance is the remove-from-split ✕ — close it for the user by dropping the now-empty
      // workroom from the split (issue #55). No-op for a solo workroom or a non-member.
      self.autoCloseEmptiedSplitMember(targetID)
      // Then, if the workroom you're *viewing* just lost its last panel, jump to the rightmost
      // remaining tab instead of stranding you on its empty state (issue #80). Runs AFTER the split
      // auto-close, which re-points selection off a split member first — so this only fires for a
      // selected *solo* workroom. No-op for a background close or a delete (selection isn't the
      // emptied target by the time its reap reaches here).
      self.selectFallbackWorkroomAfterEmpty(targetID)
      // After the fallback re-point (or not): if the selected target now has no tabs, the inspector
      // empties (issue: History/Changes/PR stayed on the last workroom after closing all its tabs).
      self.refreshSelectionHasTabs()
    }
    // Mirror the aggregate unread count onto the Dock icon badge (issue #32). Owned here, not in a
    // view: see `NotificationCenterStore.onTotalChange` for why a view-driven badge misses
    // background notifications. `DockBadge` draws into the tile's `contentView` (not `badgeLabel`,
    // which a linked framework suppresses here). Captures no `self`, so there's no retain cycle.
    notifications.onTotalChange = { _ in
      // Combined count across all windows (issue #70) — the registry sums every window's total and
      // updates the menu-bar label + Dock badge, so a second window can't clobber the first's count.
      WindowRegistry.shared.recomputeBadge()
    }
    // A click into a co-displayed split pane's terminal focuses that workroom (issue #23 follow-up),
    // so commands target it. History-suppressed (the routing method) — glancing between panes isn't
    // navigation.
    terminals.onSurfaceFocused = { [weak self] targetID in
      self?.focusWorkroomMemberFromSurface(targetID)
    }
    // Hydrate the (global) inspector section layout once at launch — it's shared across all
    // workrooms, so it's loaded here rather than re-loaded on every selection change (issue #24).
    loadInspectorState()
  }

  /// The last persisted window frame (issue #70), or nil when unset/degenerate.
  private static func savedMainWindowFrame() -> NSRect? {
    let string = Defaults[.mainWindowFrame]
    guard !string.isEmpty else { return nil }
    let frame = NSRectFromString(string)
    return (frame.width > 200 && frame.height > 200) ? frame : nil
  }

  /// Bind this store to its host `NSWindow` once the view tree resolves it (issue #70). Idempotent —
  /// `WindowAccessor` may resolve the same window more than once.
  func attachWindow(_ window: NSWindow) {
    hostWindow = window
    // Keep the title out of the title bar (issue #70). The title we give the window (selected
    // project/workroom, via `navigationTitle` → `windowTitle`) exists only to name it in the Window
    // menu + Mission Control — never to show in the bar. But a non-empty `navigationTitle` re-asserts
    // `titleVisibility = .visible` on every SwiftUI update, and WindowBackgroundThemer's in-update
    // re-hide can lose that race. So set it hidden here (pre-display, killing the open-time flash) and
    // re-hide after every window update cycle: `didUpdate` fires *after* SwiftUI's changes, so this
    // lock always wins. The guard makes the re-hide a no-op once hidden, so it can't loop.
    window.titleVisibility = .hidden
    // Same race, same lock for the window toolbar: `NavigationSplitView` (RootView) auto-injects a
    // sidebar-toggle toolbar item even with the sidebar column forced `.detailOnly`, and SwiftUI owns
    // + re-shows the toolbar on its update cycles (so `.toolbar(removing: .sidebarToggle)` is a no-op).
    // That lone item renders as a stray `»` "more toolbar items" overflow in the title bar AND keeps
    // SwiftUI's `AppKitToolbarItem.updateMenuFormRepresentation` alive — the layout-driven recompute
    // that stacks into the ≥2s macOS-26 AppHangs (see WindowBackgroundThemer). Hiding the toolbar
    // detaches those item views so neither happens; the taller title bar comes from the `.left`
    // accessory, not the toolbar. Re-hide after every update cycle, guarded so it can't loop.
    window.toolbar?.isVisible = false
    if titleVisibilityObserver == nil {
      titleVisibilityObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification, object: window, queue: .main
      ) { [weak window] _ in
        MainActor.assumeIsolated {
          if window?.titleVisibility != .hidden { window?.titleVisibility = .hidden }
          if window?.toolbar?.isVisible == true { window?.toolbar?.isVisible = false }
        }
      }
    }
    // Launch with a single window (issue #70): SwiftUI would otherwise persist + restore every window
    // that was open at quit. We restore the one window's size ourselves (below), so opt out of
    // AppKit's per-window state restoration; extra windows are deliberately not reopened.
    window.isRestorable = false
    // Set the window's size before it's shown (issue #70): `WindowAccessor` resolves it in
    // `viewDidMoveToWindow`, which fires during window setup (pre-display), so SwiftUI's value-based
    // `WindowGroup` (which otherwise opens windows at the minimum content size and doesn't restore the
    // window frame itself) doesn't leave a window opening small. A new window matches the window that
    // was current when it opened; the launch window restores its last frame, else a sensible default.
    if !didApplyInitialSize {
      didApplyInitialSize = true
      if let size = pendingInitialWindowSize {
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
      } else if let frame = Self.savedMainWindowFrame() {
        window.setFrame(frame, display: false)
      } else {
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.center()
      }
    }
    // Persist this window's frame (debounced by AppKit's notifications) so a future launch restores
    // the size you left.
    if frameObservers.isEmpty {
      for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
        let token = NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak window] _ in
          guard let window else { return }
          MainActor.assumeIsolated { Defaults[.mainWindowFrame] = NSStringFromRect(window.frame) }
        }
        frameObservers.append(token)
      }
    }
    // Intercept the window close so a live run command is confirmed + gracefully stopped before the
    // window (and its surfaces) tear down — otherwise closing a window orphans its dev server, the
    // per-window form of issue #7 (issue #70, A3). A forwarding proxy keeps SwiftUI's own delegate.
    if !(window.delegate is WindowCloseGuard) {
      let guardDelegate = WindowCloseGuard(store: self, forwarding: window.delegate)
      closeGuard = guardDelegate
      window.delegate = guardDelegate
    }
  }

  /// Route a terminal surface's first-responder focus up to the workroom selection — but only while a
  /// workroom split is active and the focused surface belongs to one of its members. Sets
  /// `selectedTargetID` with history recording suppressed (issue #23 T3): clicking between co-displayed
  /// panes targets the right workroom for ⌘T/Run/notifications, without flooding ⌘[/⌘] back-forward.
  /// A no-op outside a split (the single selected target is already focused).
  private func focusWorkroomMemberFromSurface(_ targetID: TerminalTarget.ID) {
    guard let split = workroomSplit,
      let sid = Self.sidebarID(forTargetID: targetID, in: projects), split.contains(sid),
      selectedTargetID != sid
    else { return }
    isNavigatingHistory = true
    defer { isNavigatingHistory = false }
    selectedTargetID = sid
    selectedProjectID = Self.projectPath(of: sid)
  }

  var selectedProject: Project? {
    projects.first { $0.id == selectedProjectID }
  }

  /// The selected terminal target resolved against the current project list (nil if it no
  /// longer exists).
  var selectedTarget: TerminalTarget? { selectedTargetID.flatMap(target(for:)) }

  /// The target the inspector reflects: the selection, but only while it has open tabs
  /// (`selectionHasTabs`). `nil` ⇒ the inspector shows its empty state. History/Changes/PR key on
  /// this, not `selectedTargetID`, so they empty when all tabs close.
  var inspectorTargetID: SidebarID? { selectionHasTabs ? selectedTargetID : nil }
  var inspectorTarget: TerminalTarget? { inspectorTargetID.flatMap(target(for:)) }

  /// Recompute `selectionHasTabs` — call after a selection change or a tab add/remove. Guarded so it
  /// only publishes (re-renders the inspector) on an actual transition.
  func refreshSelectionHasTabs() {
    let has = selectedTarget.map { terminals.tabCount(forTargetID: $0.id) > 0 } ?? false
    guard has != selectionHasTabs else { return }
    selectionHasTabs = has
    // A tab opening (or the last one closing) for the selected workroom flips `inspectorTargetID`
    // (nil↔id). Re-point History from here so it loads the instant its target appears, instead of
    // waiting on the panel's own `.task` to re-fire — which doesn't happen reliably across the
    // `NSHostingController`-hosted inspector, so History lagged until an app refocus (`reloadIfStale`)
    // forced a re-render. `focus` is idempotent (no-op when the root is unchanged).
    if activeInspectorSection == .history {
      commitHistory.focus(inspectorTarget.map { URL(fileURLWithPath: $0.path) })
    }
  }

  /// Whether there's a usable editor and a valid selected target to open — drives the ⌘O command and
  /// Go-menu item's enabled state (and matches when the toolbar's open button is meaningful).
  var canOpenInEditor: Bool {
    guard let target = selectedTarget, !target.isMissing else { return false }
    return ExternalEditor.remembered != nil
  }

  /// Open the selected target's directory in the remembered editor (the toolbar's primary open action,
  /// also bound to ⌘O and the Go-menu item). No-op when nothing's selected, the directory is missing,
  /// or no editor is installed.
  func openSelectedInEditor() {
    guard let target = selectedTarget, !target.isMissing, let editor = ExternalEditor.remembered
    else { return }
    editor.open(target.path)
  }

  /// This window's title — the selected project and workroom (issue #70). Hidden from the title bar
  /// (`titleVisibility = .hidden`), so it only feeds the native Window menu's open-window list and
  /// Mission Control, letting you tell windows apart and switch between them. A workroom reads
  /// "<project> — <workroom>"; a project root just the project name; nothing selected falls back to
  /// "Window <n>" (the window's display number).
  var windowTitle: String {
    switch selectedTargetID {
    case .root(let path):
      return projects.first { $0.id == path }?.displayName ?? defaultWindowTitle
    case .workroom(let path, let name):
      guard let project = projects.first(where: { $0.id == path })?.displayName else { return name }
      // Show the workroom's display label when set (issue #41); falls back to the real name.
      return "\(project) — \(displayName(forWorkroom: name, inProject: path))"
    case .project, nil:
      return defaultWindowTitle
    }
  }

  /// Fallback title for a window with nothing selected — "Window <n>", or just "Window" until the
  /// registry has assigned this window its number.
  private var defaultWindowTitle: String {
    windowNumber > 0 ? "Window \(windowNumber)" : "Window"
  }

  /// Resolve any `SidebarID` to its live `TerminalTarget` against the current project list (nil for
  /// `.project` or a since-removed target). Backs `selectedTarget` and the history `isLive` check.
  func target(for sid: SidebarID) -> TerminalTarget? {
    switch sid {
    case .root(let path):
      return projects.first { $0.id == path }?.rootTarget
    case .workroom(let path, let name):
      guard let project = projects.first(where: { $0.id == path }),
        let workroom = project.workrooms.first(where: { $0.id == name })
      else { return nil }
      return workroom.target(inProject: path)
    case .project:
      return nil
    }
  }

  /// The selected workroom, only when a workroom (not a root) is selected. Used by delete,
  /// the setup-log dock, and menu commands that are workroom-specific.
  var selectedWorkroom: Workroom? {
    guard case .workroom(let path, let name) = selectedTargetID,
      let project = projects.first(where: { $0.id == path })
    else { return nil }
    return project.workrooms.first { $0.id == name }
  }

  // MARK: Workroom tab bar (issue #23)

  /// The active workroom tabs shown above the terminal: the remembered order resolved to live targets,
  /// limited to targets that currently have ≥1 terminal (so a tab appears when a workroom gains its
  /// first terminal and disappears when it loses its last). Pairs each tab's `SidebarID` (for
  /// selection) with its `TerminalTarget` (for the chip), dropping any id that no longer resolves
  /// against `projects` (e.g. a deleted workroom).
  ///
  /// `order` defaults to the `@Published workroomTabOrder`, so a view observing the store re-renders
  /// when a drag-reorder rewrites it. Reads `@Published projects` + `terminals.activeTargetIDs`
  /// (`@Published tabsByTarget`) too — so the bar updates as terminals open/close. `order:` is for tests.
  func orderedWorkroomTargets(order: [TerminalTarget.ID]? = nil)
    -> [(sid: SidebarID, target: TerminalTarget)]
  {
    // Include the in-progress creation's target (issue #116): its terminal is withheld during a setup
    // script, so it isn't yet "active" (no terminal), but its chip must still show through setup.
    var active = terminals.activeTargetIDs
    if let creating = creation?.targetID { active.insert(creating) }
    return Self.orderedActiveTargets(
      persisted: order ?? workroomTabOrder, active: active
    )
    .compactMap { tid in
      guard let sid = Self.sidebarID(forTargetID: tid, in: projects), let target = target(for: sid)
      else { return nil }
      return (sid, target)
    }
  }

  /// Switch to the Nth workroom tab — bound to ⌥⌘1–9 (issue #23), the workroom-level counterpart to
  /// ⌘1–9's terminal-tab focus. Returns whether it handled the key, so the AppDelegate monitor consumes
  /// ⌥⌘digit only when there's an Nth tab to switch to (otherwise the key passes through to the
  /// terminal).
  @discardableResult
  func focusWorkroomTab(at index: Int) -> Bool {
    // Index the on-screen order (`displayedWorkroomTargets`, == ordered with no split), so ⌥⌘N maps to
    // the Nth *visible* chip — a split reorders members in the bar, and nav must follow the eye.
    let tabs = displayedWorkroomTargets()
    guard tabs.indices.contains(index) else { return false }
    selectedTargetID = tabs[index].sid
    selectedProjectID = Self.projectPath(of: tabs[index].sid)
    return true
  }

  /// Switch to the next (`forward`) or previous workroom tab, wrapping at the ends — bound to
  /// ⇧⌥⌘→ / ⇧⌥⌘← (issue #29), the workroom-level counterpart to ⌥⌘arrows' terminal-tab cycle. When
  /// the current selection isn't in the bar (e.g. a root with no terminals), enters at the rightmost
  /// tab (forward, →) or the leftmost (back, ←) — spatially matching the arrow, like the on-tab step.
  /// Returns whether it switched, so the AppDelegate monitor
  /// consumes the key in the monitor only when there's a tab to move to (it's a no-op otherwise —
  /// the key is reserved in `isAppShortcut` either way, so it never reaches the terminal).
  @discardableResult
  func cycleWorkroomTab(forward: Bool) -> Bool {
    // Step the on-screen order (`displayedWorkroomTargets`, == ordered with no split): a split pulls its
    // members into a contiguous run in the bar, so the raw `orderedWorkroomTargets` index no longer
    // matches a chip's visual position — ←/→ must move by what's actually on screen.
    let tabs = displayedWorkroomTargets()
    guard !tabs.isEmpty else { return false }
    let next: Int
    if let current = tabs.firstIndex(where: { $0.sid == selectedTargetID }) {
      guard tabs.count > 1 else { return false }
      next = (current + (forward ? 1 : -1) + tabs.count) % tabs.count
    } else {
      // No current tab: forward (→) enters at the rightmost, back (←) at the leftmost.
      next = forward ? tabs.count - 1 : 0
    }
    selectedTargetID = tabs[next].sid
    selectedProjectID = Self.projectPath(of: tabs[next].sid)
    return true
  }

  // MARK: Run command (issue #7)

  /// The lifecycle of a target's run command (issue #7), one value per target. A single state machine
  /// replaces the former parallel sets/maps — every transition is explicit, so the stale-bookkeeping
  /// family of bugs (an orphaned "pending restart" respawning a later run; a "Ctrl-C already sent"
  /// flag hard-killing a fresh run's first Stop) is unrepresentable. Process-based (child-exit), NOT
  /// OSC-9;4 — arbitrary run commands (npm run dev) emit no progress.
  enum RunState: Equatable {
    /// Auto-run queued for a just-created workroom; its pane hasn't mounted, so there's no tab yet.
    /// While armed, `ensureInitialTerminal` starts the run as a backgrounded tab #1, with the always-on
    /// shell opened as the focused tab #2.
    case armed
    /// Process alive in `tab`. `interrupted` = a Ctrl-C was already sent this stop cycle, so the next
    /// Stop escalates to a hard kill (OV-D).
    case running(tab: TerminalTab.ID, interrupted: Bool)
    /// Process alive in `tab`, Ctrl-C sent, awaiting child-exit to close + respawn (graceful restart, C1).
    case restarting(tab: TerminalTab.ID)
    /// Process exited but the pane stays open (`wait_after_command`); `tab` is still present.
    case stopped(tab: TerminalTab.ID)

    /// The run tab id, for any state that has one (everything but `.armed`).
    var tab: TerminalTab.ID? {
      switch self {
      case .running(let tab, _), .restarting(let tab), .stopped(let tab): return tab
      case .armed: return nil
      }
    }
    /// Whether the process is executing (drives the toolbar Run↔Stop/Restart toggle + sidebar dot).
    var isRunning: Bool {
      switch self {
      case .running, .restarting: return true
      case .armed, .stopped: return false
      }
    }
  }

  /// How a run ended — the bit `RunState` doesn't carry (issue #67). The run toast derives its final
  /// status from this: a clean exit reads "Exited", a non-zero exit reads "Failed (exit N)", a
  /// user-initiated Stop reads "Stopped" (you did it — not an error), and a surface that never spawned
  /// reads "Failed to start". Kept as a small side-table next to `runStates` rather than bloating
  /// `RunState.stopped`'s associated values (which the heavily-tested state machine pattern-matches in
  /// many places). `.stoppedByUser` vs `.exited` is decided by the `interrupted` flag the state machine
  /// already tracks. `nil` = the run hasn't ended (starting/running/restarting) — no outcome yet.
  enum RunOutcome: Equatable {
    case exited(code: Int32)  // process exited on its own; code 0 = clean, != 0 = failure
    case stoppedByUser  // a Stop/Restart Ctrl-C drove the exit
    case failedToStart  // the surface never spawned (ghostty_surface_new returned nil)

    /// Whether this outcome is a failure — the single source of truth that drives the red run icon
    /// (issue #79), the native banner, and the toast's failed glyph. A non-zero self-exit or a
    /// failed start; never a clean exit or a user-initiated Stop/Restart/Ctrl-C.
    var isFailure: Bool {
      switch self {
      case .exited(let code): return code != 0
      case .failedToStart: return true
      case .stoppedByUser: return false
      }
    }
  }

  /// Run-STATE is owned here (not on `TerminalSessions`) so the toolbar, sidebar, menu, and RootView
  /// — which all observe this store — react to start/stop/exit from one `@Published` source (OV-A).
  /// `TerminalSessions` only creates/focuses the tab and reports its removal via `onTabsRemoved`.
  @Published private(set) var runStates: [TerminalTarget.ID: RunState] = [:]

  /// Per-target end-of-run outcome for the run toast (issue #67). Set on exit / failed start, cleared
  /// when a fresh run starts for that target. Derived-from, not duplicating, `runStates`.
  @Published private(set) var runOutcomes: [TerminalTarget.ID: RunOutcome] = [:]

  // MARK: Run toast (issue #67) — DERIVED view-model, dismissal, native banner

  /// A live run-status toast, DERIVED from `runStates` + `runOutcomes` (no parallel stored array, so it
  /// can't drift). The bottom-right toast surface renders these above the notification toasts.
  struct RunToastItem: Identifiable, Equatable {
    var id: TerminalTarget.ID { targetID }
    let targetID: TerminalTarget.ID
    let tabID: TerminalTab.ID
    let source: String  // "platform / fix-auth"
    let command: String  // the configured run command, e.g. "npm run dev"
    let status: Status
    enum Status: Equatable {
      case running  // spinner (covers .running(interrupted:) too — still alive)
      case restarting  // spinner, graceful restart in flight
      case exited  // clean exit, code 0
      case failed(code: Int32)  // non-zero exit (a crash)
      case failedToStart  // the surface never spawned
      // Note: a user-initiated stop (Stop/Restart/Ctrl-C) produces NO toast (issue #79), so there's
      // deliberately no `.stopped` case — `runToastItems` returns nil for `.stoppedByUser`.
      var isTerminal: Bool {
        switch self {
        case .running, .restarting: return false
        case .exited, .failed, .failedToStart: return true
        }
      }
    }
  }

  /// Targets whose run toast was explicitly dismissed (✕) or auto-dismissed after a terminal state.
  /// Cleared when a fresh run starts. Open-terminal does NOT add here — it lets the visibility rule
  /// hide the toast while the run is on screen, so it reappears when you navigate away.
  @Published private(set) var dismissedRunToasts: Set<TerminalTarget.ID> = []
  /// Pending auto-dismiss timers, one per target, cancelled on restart so a stale timer can't dismiss
  /// the next run's toast (review: timer cancellation on restart).
  private var runToastDismissWork: [TerminalTarget.ID: DispatchWorkItem] = [:]
  /// How long a terminal-state run toast lingers before auto-dismissing.
  private static let runToastLinger: TimeInterval = 6
  /// Test seam: how a delayed auto-dismiss is scheduled. Production schedules on the main queue; tests
  /// capture the returned `DispatchWorkItem` to fire (or assert cancellation of) it deterministically.
  var scheduleRunToastDismiss: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = {
    delay, body in
    let work = DispatchWorkItem(block: body)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return work
  }

  /// Whether a finished run warrants a native banner: only genuine failures (a non-zero exit or a
  /// failed start), never a clean exit or a user-initiated Stop (Arch #7, issue #67). Pure so the
  /// policy is unit-testable without `NSApp`/`SystemNotifier`; the app-active gate is the (already
  /// tested) `NotificationGate`.
  static func runOutcomeIsBannerWorthy(_ outcome: RunOutcome?) -> Bool {
    outcome?.isFailure ?? false
  }

  /// Whether this target's last run ended in failure — drives the red run icon on the tab chip and
  /// the workroom tab-bar dot (issue #79). Derived from `RunOutcome.isFailure`, the same predicate
  /// the banner uses, so "is a failure" has one definition. Cleared on a fresh start and on close.
  func runFailed(for targetID: TerminalTarget.ID) -> Bool {
    runOutcomes[targetID]?.isFailure ?? false
  }

  /// The run toasts to show right now. Derived each access: a target contributes a toast when it has a
  /// run state with a tab, the user hasn't dismissed it, and its run tab isn't currently on screen
  /// (you don't need a toast for what you're looking at — split-aware via `visibleTabIDs`).
  var runToastItems: [RunToastItem] {
    runStates.compactMap { targetID, state -> RunToastItem? in
      guard let tabID = state.tab else { return nil }  // .armed has no tab → no toast
      guard !dismissedRunToasts.contains(targetID) else { return nil }
      // Map state → toast status. A user-initiated stop (Stop/Restart/Ctrl-C → `.stoppedByUser`, or
      // a stop with no recorded outcome) shows NO toast at all (issue #79): the toast only ever marks
      // a self-exit (success or failure) or a failed start.
      let status: RunToastItem.Status
      switch state {
      case .armed: return nil
      case .running: status = .running
      case .restarting: status = .restarting
      case .stopped:
        switch runOutcomes[targetID] {
        case .exited(let code): status = code == 0 ? .exited : .failed(code: code)
        case .failedToStart: status = .failedToStart
        case .stoppedByUser, .none: return nil  // user-initiated stop/restart/Ctrl-C → no toast
        }
      }
      // Live status (running/restarting) shows ONLY for the SELECTED workroom's backgrounded run:
      // you don't need a "still running" reminder for workrooms you aren't even looking at (issue
      // #73 — one live toast for the run you're in, not one per open workroom with a run), nor for
      // the run tab you're currently watching (split-aware via `visibleTabIDs`). Terminal statuses
      // (a success or failure exit) ALWAYS show — even for a background workroom, so you learn it
      // finished/crashed (issue #79: "show a success/failure toast"); they linger then auto-dismiss.
      if !status.isTerminal {
        guard let target = selectedTarget, target.id == targetID,
          !terminals.visibleTabIDs(for: target).contains(tabID)
        else { return nil }
      }
      let command =
        project(forTargetID: targetID).map {
          runConfig(forProject: $0.path).command.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
      return RunToastItem(
        targetID: targetID, tabID: tabID, source: notificationSource(forTargetID: targetID),
        command: command, status: status)
    }
    .sorted { $0.targetID < $1.targetID }  // stable order across renders
  }

  /// ✕ on the run toast: a real dismiss — it won't reappear for this run (until the next start).
  func dismissRunToast(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    runToastDismissWork[targetID] = nil
    dismissedRunToasts.insert(targetID)
  }

  /// "Open terminal" on the run toast: jump to the run terminal. The toast then hides because its tab
  /// is on screen (visibility rule) — NOT dismissed, so it reappears if you navigate away.
  func openRunToast(for targetID: TerminalTarget.ID) {
    guard let tabID = runStates[targetID]?.tab else { return }
    openTerminal(targetID: targetID, tabID: tabID)
  }

  /// Clear toast dismissal + cancel any pending auto-dismiss for a target — called when a fresh run
  /// starts (so the new run always gets a toast) and when the run goes away (close/reap/delete).
  private func resetRunToast(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    runToastDismissWork[targetID] = nil
    dismissedRunToasts.remove(targetID)
  }

  /// After a run reaches a terminal state, auto-dismiss its toast once the linger elapses (unless the
  /// user already dismissed/opened it, or a restart cancelled the timer).
  private func scheduleRunToastAutoDismiss(for targetID: TerminalTarget.ID) {
    runToastDismissWork[targetID]?.cancel()
    let work = scheduleRunToastDismiss(Self.runToastLinger) { [weak self] in
      guard let self else { return }
      self.dismissedRunToasts.insert(targetID)
      self.runToastDismissWork[targetID] = nil
    }
    runToastDismissWork[targetID] = work
  }

  /// Post a native banner for a backgrounded run that FAILED, but only while the app isn't frontmost —
  /// the in-app toast is invisible then (Arch #7, issue #67). Reuses `NotificationGate` +
  /// `SystemNotifier`; the synthesized notification is NOT added to the inspector history (run status
  /// is transient). A click routes through `openTerminal` via the payload's `userInfo`.
  private func postRunFailureBannerIfBackgrounded(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, title: String, body: String
  ) {
    guard NotificationGate.shouldPostBanner(recorded: true, appActive: NSApp.isActive) else {
      return
    }
    let note = WorkroomNotification(
      id: UUID(), targetID: targetID, tabID: tabID, kind: .osc,
      source: notificationSource(forTargetID: targetID), title: title, body: body, date: Date(),
      count: 1)
    Task { @MainActor in
      if await systemNotifier.ensureAuthorized() { systemNotifier.post(note) }
    }
  }

  /// The owning project of a target by id (mirrors `notificationSource`'s scan) — for the run toast's
  /// command label.
  private func project(forTargetID id: TerminalTarget.ID) -> Project? {
    projects.first { p in
      TerminalTarget.rootID(project: p.path) == id
        || p.workrooms.contains { TerminalTarget.workroomID(project: p.path, name: $0.name) == id }
    }
  }

  /// Whether the target's run command is currently running. Drives the toolbar Run↔Stop/Restart
  /// toggle and the sidebar run dot.
  func isRunCommandRunning(for targetID: TerminalTarget.ID) -> Bool {
    runStates[targetID]?.isRunning ?? false
  }

  /// The target's run terminal tab id (running or stopped-but-open), if any.
  func runTabID(for targetID: TerminalTarget.ID) -> TerminalTab.ID? { runStates[targetID]?.tab }

  /// The run config for a project path (empty if none set). Single read path for the toolbar, menu,
  /// settings sheet, and auto-run. Stored app-side in `Defaults` (GUI-only — the CLI can't hold a
  /// long-running process, so it's deliberately out of the `--json` contract, like branch labels).
  func runConfig(forProject projectPath: String) -> RunConfig {
    Defaults[.runCommands][projectPath] ?? .empty
  }

  /// Whether a project has a non-blank run command configured.
  func hasRunCommand(forProject projectPath: String) -> Bool {
    runConfig(forProject: projectPath).hasCommand
  }

  /// Whether to surface run controls for a target: its project has a command configured AND the target
  /// exists (not a missing directory, where `startRunCommand` silently no-ops). One gate for the
  /// toolbar and the sidebar run buttons, so a new condition lands in a single place (review #9/#14).
  func canRunCommand(for target: TerminalTarget, inProject projectPath: String) -> Bool {
    !target.isMissing && hasRunCommand(forProject: projectPath)
  }

  /// Persist a project's run config. A blank command with auto-run off removes the entry so the map
  /// doesn't accrue dead keys. `objectWillChange` fires so the toolbar/menu re-render `hasRunCommand`
  /// the moment Save commits (those consumers observe this store — issue #7 reactivity, OV-A).
  func setRunConfig(_ config: RunConfig, forProject projectPath: String) {
    objectWillChange.send()
    var map = Defaults[.runCommands]
    if config.hasCommand || config.autoRun {
      map[projectPath] = RunConfig(
        command: config.command.trimmingCharacters(in: .whitespacesAndNewlines),
        autoRun: config.autoRun)
    } else {
      map[projectPath] = nil
    }
    Defaults[.runCommands] = map
  }

  // MARK: Run command — actions (issue #7)

  /// The owning project of a terminal target (root or workroom), by matching the live project list.
  private func project(forTarget target: TerminalTarget) -> Project? {
    projects.first { p in
      p.rootTarget.id == target.id
        || p.workrooms.contains { $0.target(inProject: p.path).id == target.id }
    }
  }

  /// The owning project's root path for `target` — the same per-project key
  /// `AppStore+WorkroomStatus.swift`'s `StatusWorkItem.projectRoot` uses, for callers outside that
  /// extension that also reach a jj-snapshotting call (currently just the Changes panel's
  /// working-copy diff, which needs it to key `JJSnapshotGate`). `nil` only if `target` no longer
  /// matches a live project (e.g. deleted mid-render).
  func projectRoot(forTarget target: TerminalTarget) -> String? {
    project(forTarget: target)?.path
  }

  /// The current branch/bookmark label for a terminal target, for the detail-panel status bar (issue
  /// #49). Reuses the already-resolved sidebar caches — the per-workroom local status (`branchForCI`)
  /// and the project root's `RootRef` — so it adds no new VCS calls. Nil until those resolve, or when
  /// no branch is resolvable (the status bar then just omits the segment).
  func branchLabel(for target: TerminalTarget) -> String? {
    guard let project = project(forTarget: target) else { return nil }
    let sid: SidebarID
    if TerminalTarget.rootID(project: project.path) == target.id {
      sid = .root(project: project.path)
    } else if let workroom = project.workrooms.first(where: {
      TerminalTarget.workroomID(project: project.path, name: $0.name) == target.id
    }) {
      sid = .workroom(project: project.path, name: workroom.name)
    } else {
      return nil
    }
    let status = workroomStatuses[sid]
    if let branch = status?.branchForCI, !branch.isEmpty { return branch }
    // jj: the working copy's own bookmark (`@`) is the label when no CI branch is resolved — matches
    // what the Changes panel shows for a jj workroom.
    if let ref = status?.jjWorkingCopy?.refs.first, !ref.isEmpty { return ref }
    if case .root = sid {
      let label = RootPresentation.make(rootRefs[project.path] ?? .unresolved).label
      return label.isEmpty ? nil : label
    }
    return nil
  }

  /// The bundled run supervisor (issue #7) — the long-lived shell that owns each run command's
  /// process tree inside its terminal (start/stop/restart serialized there, controlled by signals +
  /// a status file). Resolved from `Bundle.main`; the fallback keeps tests (no bundled resource)
  /// building — they assert the invocation's shape, not a real path.
  static func supervisorScriptPath() -> String {
    Bundle.main.resourceURL?.appendingPathComponent("run-supervisor/supervisor.sh").path
      ?? "run-supervisor/supervisor.sh"
  }

  /// The supervisor's status file (it writes `running`/`stopped`/`exited <code>` etc. here, atomically;
  /// the app watches it). Derived from the per-run control-file path so they share one lifecycle.
  static func supervisorStatusPath(forPidPath pidPath: String) -> String {
    (pidPath as NSString).deletingPathExtension + ".status"
  }

  /// Build the libghostty `command` string (A3): launch the run SUPERVISOR as the surface's PTY child
  /// (set once, never replaced). The supervisor owns the user command — it runs it in the user's
  /// login+interactive shell (so it inherits PATH/aliases/version-manager shims), in the tty
  /// FOREGROUND so interactive servers can read the keyboard, and the app drives stop/restart by
  /// signalling the supervisor (its pid lands in `pidPath`) and reading the status file. POSIX `$SHELL`
  /// (zsh/bash/sh/dash/ksh) gets `-lic`; a non-POSIX `$SHELL` (fish/nu/csh) falls back to a login
  /// `/bin/sh -lc`, whose interactive rc won't load — a documented limitation (issue #7, fold #7).
  /// libghostty runs this whole string via `sh -c`, which execs `/bin/sh <supervisor> …`, so the
  /// supervisor becomes the session-leader PTY child (its `kill -INT 0` group-stop stays scoped to the
  /// run's own session).
  private func runCommandLine(_ raw: String, pidPath: String) -> String {
    let shell = ShellEnvironment.loginShell()
    let name = (shell as NSString).lastPathComponent
    let isPOSIX = ["zsh", "bash", "sh", "dash", "ksh"].contains(name)
    let runner = isPOSIX ? shell : "/bin/sh"
    let q = CommandLineInstaller.shellQuoted
    // The child the supervisor runs: the user's login-interactive shell, which `exec`s the command
    // through the runner with `-c` (so compound commands — `cd web && npm run dev`, `FOO=bar rails s`,
    // pipes — work, and the exec keeps the pid stable so the supervisor's `$!` is the live server).
    let innerScript = "exec \(q(runner)) -c \(q(raw))"
    let childOuter =
      isPOSIX ? "\(q(shell)) -lic \(q(innerScript))" : "/bin/sh -lc \(q(innerScript))"
    // config.command = /bin/sh <supervisor> <controlFile> <statusFile> <childArgv…>
    let sup = q(Self.supervisorScriptPath())
    let ctl = q(pidPath)
    let status = q(Self.supervisorStatusPath(forPidPath: pidPath))
    return "/bin/sh \(sup) \(ctl) \(status) \(childOuter)"
  }

  /// Per-target temp file holding the run command's pid (written by the run wrapper, read to resolve
  /// + signal its process group). Generated fresh per start/respawn; cleared when the run exits or
  /// its tab is removed so a reused pid can never be signalled.
  private(set) var runPidFiles: [TerminalTarget.ID: String] = [:]

  /// A fresh per-run pid-file path. Does NOT store it — the caller assigns `runPidFiles[target]`
  /// AFTER the tab is (re)created, because `respawnRunTab` closes the old tab first and that fires
  /// `onTabsRemoved` → `clearRunPidFile`, which would otherwise wipe a path stored too early (the
  /// re-run-can't-be-stopped bug, issue #7).
  private func makeRunPidPath() -> String {
    (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("workroom-run-\(UUID().uuidString).pid")
  }

  /// The supervisor's pid (it `echo $$`s into the control file). Used to signal it (stop/restart/quit).
  private func runPid(for targetID: TerminalTarget.ID) -> pid_t? {
    guard let path = runPidFiles[targetID],
      let raw = try? String(contentsOfFile: path, encoding: .utf8),
      let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
    else { return nil }
    return pid
  }

  /// The run command's SESSION id, captured at launch via `getsid`. A process group isn't enough:
  /// bin/dev-style launchers fork the leaf server into a *different* process group than the launcher,
  /// so a captured group can miss it (issue #7). The SESSION is stable across those forks — every
  /// process the run command spawns stays in the one session `login` created for it (unless it
  /// daemonizes via setsid, which dev servers don't — a typed Ctrl-C stops them, proving it). The
  /// session id stays valid after its leader exits, so it reaps a server that outlived the launcher.
  private var runSessions: [TerminalTarget.ID: pid_t] = [:]

  /// Poll the just-spawned run wrapper's pid file and record its session id while it's still alive, so
  /// a later Stop / child-exit can SIGINT the whole session (issue #7). The launcher lives through the
  /// server's boot, so a brief poll always catches it.
  private func captureRunSession(
    for targetID: TerminalTarget.ID, pidPath: String, attempt: Int = 0
  ) {
    if let raw = try? String(contentsOfFile: pidPath, encoding: .utf8),
      let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
    {
      let sid = getsid(pid)
      if sid > 1 { runSessions[targetID] = sid }
      return
    }
    guard attempt < 30 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.captureRunSession(for: targetID, pidPath: pidPath, attempt: attempt + 1)
    }
  }

  /// Live pids belonging to run session `sid`. macOS `pkill` has no `-s` (session) flag, so we
  /// enumerate every pid (`proc_listallpids`) and keep those whose `getsid` matches — the generic way
  /// to find everything a run command spawned, whatever process group its launcher forked the leaf
  /// server into (issue #7). Returns empty for the app's own session, so a reap can never hit the app
  /// itself or another terminal. Now used only by the forked-free backstop (a leaf that outlived the
  /// supervisor); the supervisor itself owns the normal stop/restart.
  private func runSessionMembers(_ sid: pid_t) -> [pid_t] {
    guard sid > 1, sid != getsid(0) else { return [] }  // never our own (the app's) session
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let bytes = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return [] }
    var members: [pid_t] = []
    for i in 0..<min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count) where pids[i] > 1 {
      if getsid(pids[i]) == sid { members.append(pids[i]) }
    }
    return members
  }

  /// Send `sig` to every process in run session `sid` — a session-scoped signal: SIGINT is a Ctrl-C
  /// (graceful), SIGKILL the last-resort reap when graceful didn't take in time. Guarded (via
  /// `runSessionMembers`) to a run command's own isolated `login` session.
  private func signalRunSession(_ sid: pid_t, _ sig: Int32) {
    for pid in runSessionMembers(sid) { _ = kill(pid, sig) }
  }

  /// Forget (and delete) a target's captured pid file + group once its run has exited/closed, so a
  /// later reuse of that pid/group can't be signalled.
  private func clearRunPidFile(for targetID: TerminalTarget.ID) {
    runSessions[targetID] = nil
    lastRunStatus[targetID] = nil
    if let path = runPidFiles.removeValue(forKey: targetID) {
      try? FileManager.default.removeItem(atPath: path)
      try? FileManager.default.removeItem(atPath: Self.supervisorStatusPath(forPidPath: path))
    }
  }

  // MARK: Run command — supervisor control (issue #7)
  //
  // The run command runs under a long-lived SUPERVISOR (Resources/run-supervisor/supervisor.sh) that
  // is the surface's PTY child. The app controls it by signalling the supervisor's pid (in the
  // control file) and reads run STATE from the status file it writes — start/stop/restart are
  // serialized inside the terminal, so the surface is never freed/respawned for a restart and a
  // relaunch only happens after the previous child fully exits (no "A server is already running").

  /// Test seam: capture supervisor signals (and return whether a live supervisor was "signalled")
  /// without a real process. Production signals the control-file pid via `kill`.
  var signalSupervisorForTesting: ((Int32, TerminalTarget.ID) -> Bool)?

  /// Send `sig` to the target's run supervisor (USR1 = restart, USR2 = stop/keep-pane, TERM = quit →
  /// supervisor exits → surface frees). Returns false when there's no live supervisor to signal, so a
  /// caller can fall back to respawning the surface.
  @discardableResult
  private func signalSupervisor(_ sig: Int32, for targetID: TerminalTarget.ID) -> Bool {
    if let signalSupervisorForTesting { return signalSupervisorForTesting(sig, targetID) }
    guard let pid = runPid(for: targetID) else { return false }
    return kill(pid, sig) == 0
  }

  /// Last status line applied per target, so the poller reacts only to CHANGES (and doesn't re-fire
  /// the auto-dismiss timer each tick). Cleared in `clearRunPidFile`.
  private var lastRunStatus: [TerminalTarget.ID: String] = [:]

  /// Poll the supervisor's status file — the AUTHORITATIVE run state (issue #7) — while the run pane is
  /// open, applying each change. Replaces inferring state from child-exit + an `interrupted` flag (which
  /// caused the Stop-then-Run swallow). Self-terminates once the run tab is gone.
  private func pollRunStatus(for target: TerminalTarget) {
    guard runStates[target.id]?.tab != nil, let ctl = runPidFiles[target.id] else { return }
    let statusPath = Self.supervisorStatusPath(forPidPath: ctl)
    if let raw = try? String(contentsOfFile: statusPath, encoding: .utf8) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !line.isEmpty, lastRunStatus[target.id] != line {
        lastRunStatus[target.id] = line
        applyRunStatus(line, for: target)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.pollRunStatus(for: target)
    }
  }

  /// Test seam: production schedules the status poll on the main queue; tests drive transitions by
  /// calling `applyRunStatus` directly, so they never start the poller.
  /// Apply one status line from the supervisor to `RunState`/`RunOutcome` (issue #7).
  /// Flip the run surface's "stopped — press any key to close" flag (issue #7): while stopped (the
  /// supervisor is parked, processHasExited is false), a key in the run pane closes the tab; cleared
  /// on a (re)start.
  private func setRunStoppedAwaitingClose(
    _ value: Bool, tab: TerminalTab.ID, target: TerminalTarget.ID
  ) {
    terminals.view(forTab: tab, inTarget: target)?.runStoppedAwaitingClose = value
  }

  func applyRunStatus(_ line: String, for target: TerminalTarget) {
    guard let tab = runStates[target.id]?.tab else { return }
    let parts = line.split(separator: " ")
    switch parts.first.map(String.init) ?? "" {
    case "starting", "running":
      runStates[target.id] = .running(tab: tab, interrupted: false)
      runOutcomes[target.id] = nil
      setRunStoppedAwaitingClose(false, tab: tab, target: target.id)
    case "stopping":
      break  // keep the in-flight state (running(interrupted) for a stop, restarting for a restart)
    case "stopped":
      runStates[target.id] = .stopped(tab: tab)
      runOutcomes[target.id] = .stoppedByUser
      scheduleRunToastAutoDismiss(for: target.id)
      setRunStoppedAwaitingClose(true, tab: tab, target: target.id)
    case "exited", "failed":
      let code = parts.count > 1 ? (Int32(parts[1]) ?? 0) : 0
      runStates[target.id] = .stopped(tab: tab)
      setRunStoppedAwaitingClose(true, tab: tab, target: target.id)
      // 130 = SIGINT (typed Ctrl-C / our group stop), 143 = SIGTERM (quit): user-initiated, not a crash.
      if code == 0 {
        runOutcomes[target.id] = .exited(code: 0)
      } else if code == 130 || code == 143 {
        runOutcomes[target.id] = .stoppedByUser
      } else {
        runOutcomes[target.id] = .exited(code: code)
      }
      scheduleRunToastAutoDismiss(for: target.id)
      if Self.runOutcomeIsBannerWorthy(runOutcomes[target.id]) {
        postRunFailureBannerIfBackgrounded(
          targetID: target.id, tabID: tab, title: "Run failed", body: "exited with code \(code)")
        diagnoseRunFailure(target: target, tab: tab, exitCode: code)
      }
    default:
      break
    }
  }

  /// Diagnose a failed Run command with the inline agent (issue #49, A1 + X3). Run tabs `exec` over
  /// the shell so they emit no OSC 133 marks — capture the whole surface instead, and only once the
  /// supervisor's in-band exit trailer has rendered (so the snapshot includes the last output lines,
  /// not whatever had painted when the out-of-band `.status` file landed).
  private func diagnoseRunFailure(target: TerminalTarget, tab: TerminalTab.ID, exitCode: Int32) {
    guard terminals.agentManager.isEnabled,
      case .terminal(let s)? = terminals.tab(tab, for: target)?.content
    else { return }
    let view = s.view
    let command = project(forTarget: target).map { runConfig(forProject: $0.path).command }
    let shell = (ShellEnvironment.loginShell() as NSString).lastPathComponent

    Task { @MainActor in
      var surfaceText = view.readFullSurface() ?? ""
      var tries = 0
      while !RunCaptureSupport.hasRenderedTrailer(surfaceText) && tries < 20 {
        try? await Task.sleep(nanoseconds: 50_000_000)  // up to ~1s for the trailer to render
        surfaceText = view.readFullSurface() ?? ""
        tries += 1
      }
      let failure = FailedCommand(
        command: command,
        cwd: view.lastKnownCwd ?? target.path,
        exitCode: exitCode,
        shell: shell,
        output: RunCaptureSupport.extractOutput(fromSurface: surfaceText) ?? "",
        isRunTab: true,
        isRemote: false)
      terminals.agentManager.commandFinished(tab: tab, target: target.id, failure: failure)
    }
  }

  /// Start the project's run command in `target`'s directory, in a dedicated run terminal. No-op
  /// without a configured command or for a missing target. One run terminal per target (a second start
  /// is a no-op, not a duplicate).
  ///
  /// Issue #67: the run starts in the BACKGROUND by default — `focus` is false, so it doesn't steal the
  /// foreground tab; a toast surfaces its status. `focus: true` is only for auto-run on a freshly
  /// created workroom where the run would be the sole tab (Arch #5) — there we DO show it.
  func startRunCommand(for target: TerminalTarget, focus: Bool = false) {
    guard !target.isMissing, let project = project(forTarget: target) else { return }
    let config = runConfig(forProject: project.path)
    guard config.hasCommand else { return }
    if let existing = runStates[target.id]?.tab {
      // issue #67: a plain start never steals focus — only the auto-run-only-tab case passes focus.
      if focus { terminals.focus(existing, for: target) }
      return
    }
    let pidPath = makeRunPidPath()
    let line = runCommandLine(
      config.command.trimmingCharacters(in: .whitespacesAndNewlines), pidPath: pidPath)
    let tab = terminals.addRunTab(for: target, command: line, cwd: target.path, focus: focus)
    runOutcomes[target.id] = nil  // a fresh run clears the prior outcome (issue #67)
    resetRunToast(for: target.id)  // a new run always gets a fresh toast (clear dismiss + timer)
    // Background start spawns the surface off-window (`addRunTab(focus:false)`); if that failed there's
    // no process — surface the failure rather than a lying "running" toast. (Foreground starts spawn on
    // mount, so the surface is legitimately nil here — skip the check.)
    if !focus, tab.surface?.didSpawnFail == true {
      runOutcomes[target.id] = .failedToStart
      runStates[target.id] = .stopped(tab: tab.id)
      scheduleRunToastAutoDismiss(for: target.id)
      postRunFailureBannerIfBackgrounded(
        targetID: target.id, tabID: tab.id, title: "Run failed to start",
        body: config.command.trimmingCharacters(in: .whitespacesAndNewlines))
      return
    }
    runStates[target.id] = .running(tab: tab.id, interrupted: false)
    runPidFiles[target.id] = pidPath  // after the tab exists, so cleanup can't wipe it
    lastRunStatus[target.id] = nil
    // record the session for the forked-free backstop
    captureRunSession(for: target.id, pidPath: pidPath)
    pollRunStatus(for: target)  // status file drives state from here (issue #7)
    // The surface child here is the SUPERVISOR; its exit means the whole run is over (quit/crash), not
    // a user-command stop. State during run/stop/restart is driven by the status file (above).
    tab.surface?.onChildExited = { [weak self] code in
      self?.markRunExited(for: target, exitCode: code)
    }
    wireRunClose(tab.id, for: target)
  }

  /// The "press any key to close" / wait_after_command close for a run tab MUST go through the graceful
  /// stop (SIGTERM the supervisor + wait for it to fully exit) BEFORE freeing the surface — a raw
  /// `closeTab` frees the surface, which PTY-hangs-up (SIGHUP) the supervisor and can orphan a
  /// still-draining server on its port ("A server is already running" next start; issue #7).
  private func wireRunClose(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    terminals.tab(tabID, for: target)?.surface?.onCloseRequested = { [weak self] in
      guard let self else { return }
      self.closingRunTab(tabID, for: target.id) { [weak self] in
        self?.terminals.closeTab(tabID, for: target)
      }
    }
  }

  /// Respawn the run command in place of `oldTab` (issue #40): the replacement takes the old run tab's
  /// exact slot, so restarting a run command that lives in a split keeps it in the split instead of
  /// pulling it out as a solo pane. Mirrors `startRunCommand`'s state wiring; `respawnRunTab` closes
  /// `oldTab` first so its port frees (SIGHUP) before the new instance binds — the graceful-restart
  /// ordering. If the command was cleared between the restart and here, the old tab is just closed
  /// (state then clears via `onTabsRemoved`), matching the former close-then-no-op behaviour.
  private func respawnRunCommand(replacing oldTab: TerminalTab.ID, for target: TerminalTarget) {
    guard !target.isMissing, let project = project(forTarget: target),
      hasRunCommand(forProject: project.path)
    else {
      terminals.closeTab(oldTab, for: target)
      return
    }
    let config = runConfig(forProject: project.path)
    let pidPath = makeRunPidPath()
    let line = runCommandLine(
      config.command.trimmingCharacters(in: .whitespacesAndNewlines), pidPath: pidPath)
    // Issue #67: a restart PRESERVES focus rather than always backgrounding — if the user was viewing
    // the run tab, the replacement stays focused; if it was already backgrounded, it stays so. Capture
    // this BEFORE `respawnRunTab` closes the old tab (which would move focus to a successor).
    let wasFocused = terminals.focusedTab(for: target)?.id == oldTab
    let tab = terminals.respawnRunTab(
      replacing: oldTab, for: target, command: line, cwd: target.path, focus: wasFocused)
    runOutcomes[target.id] = nil  // a fresh run clears the prior outcome (issue #67)
    resetRunToast(for: target.id)  // restart re-arms the toast + cancels a stale timer
    if !wasFocused, tab.surface?.didSpawnFail == true {
      runOutcomes[target.id] = .failedToStart
      runStates[target.id] = .stopped(tab: tab.id)
      scheduleRunToastAutoDismiss(for: target.id)
      postRunFailureBannerIfBackgrounded(
        targetID: target.id, tabID: tab.id, title: "Run failed to start",
        body: config.command.trimmingCharacters(in: .whitespacesAndNewlines))
      return
    }
    runStates[target.id] = .running(tab: tab.id, interrupted: false)
    runPidFiles[target.id] = pidPath  // after respawnRunTab's closeTab cleanup, so it survives
    lastRunStatus[target.id] = nil
    captureRunSession(for: target.id, pidPath: pidPath)
    pollRunStatus(for: target)
    tab.surface?.onChildExited = { [weak self] code in
      self?.markRunExited(for: target, exitCode: code)
    }
    wireRunClose(tab.id, for: target)
  }

  /// Toggle a specific target's run command from the sidebar: running → stop; otherwise start (or
  /// re-run a stopped-but-open tab). Acts on the given target (not the selection). Issue #67: a start
  /// runs in the background and does NOT navigate to the target — the run toast is the feedback.
  func toggleRunCommand(for target: TerminalTarget) {
    if isRunCommandRunning(for: target.id) {
      stopRunCommand(for: target)
    } else {
      // Issue #67: starting from the sidebar no longer navigates to the workroom — the run goes to the
      // background and the toast is the feedback. Open it from the toast / ⌘R / Go ▸ Run Terminal.
      restartRunCommand(for: target)  // no run tab → start in background; stopped-but-open → re-run
    }
  }

  /// True while the user is typing in a text field (e.g. the Project Settings command field). The
  /// ambient ⌘R / ⇧⌘R / ⌥⌘R act on the sidebar *selection*, so they must not fire behind an editor —
  /// otherwise a run starts on the background workroom while you're editing settings (review #8). A
  /// focused NSTextField makes the window's field editor (an `NSTextView`, an `NSText`) first responder;
  /// the terminal surface is a plain `NSView`, so this stays false when a terminal is focused.
  private var isEditingTextField: Bool { NSApp.keyWindow?.firstResponder is NSText }

  /// ⌘R / toolbar Run = "ensure running" (OV-B): running → focus it; stopped-but-open → re-run;
  /// none → start. Acts on the current selection.
  ///
  /// ```
  /// runOrFocusRunCommand() — per-target run-state machine (issue #127 adds the middle branch)
  ///
  ///         ┌───────────────────┐
  ///         │ .running(_, true) │──restart──▶ respawn (Stop-then-Run: don't just focus a dying
  ///         └───────────────────┘             server)
  ///         ┌───────────────────────────────┐
  ///         │ .running(_,false)/.restarting │──focus tab──▶ (already visible/running)
  ///         └───────────────────────────────┘
  ///         ┌───────────┐
  ///         │ .stopped  │──restart──▶ respawn (re-run a stopped-but-open pane)
  ///         └───────────┘
  ///         ┌──────────────┐
  ///         │ .armed/.none │
  ///         └──────┬───────┘
  ///                │
  ///        ┌───────┴────────┐
  ///        │ owner elsewhere?│──yes──▶ focus owner's window + reveal (single-owner across windows)
  ///        └───────┬────────┘
  ///                │no
  ///        ┌───────┴──────────┐
  ///        │ hasRunCommand?    │──NO───▶  pendingProjectSettings = ⟨project, warning:true⟩  [NEW]
  ///        └───────┬──────────┘          (only if no sheet is already open — see guard below)
  ///                │yes
  ///                ▼
  ///          startRunCommand(for: target)
  /// ```
  func runOrFocusRunCommand() {
    guard !isEditingTextField, let target = selectedTarget, !target.isMissing else { return }
    switch runStates[target.id] {
    case .running(_, true):
      // Stop-then-Run (issue #7): the user stopped it (a Ctrl-C is in flight, the server is draining)
      // and is now asking for it again. Don't just focus a dying server — restart it, which waits out
      // the stop and respawns a fresh run. Otherwise the start is silently swallowed (the pane just
      // focuses) and the user is left with nothing running after a quick Stop→Run.
      restartRunCommand(for: target)
    case .running(let tab, false), .restarting(let tab):
      terminals.focus(tab, for: target)
    case .stopped:
      restartRunCommand(for: target)  // re-run a stopped-but-open tab (close + respawn)
    case .armed, .none:
      // Single-owner across windows (issue #70, OV-2): if another window already runs this
      // workroom's command, focus its run terminal rather than forking a second server on the same
      // port (which the app's own pid/process-group lifecycle would then fight over).
      if let owner = WindowRegistry.shared.runOwner(for: target.id, excluding: self) {
        owner.hostWindow?.makeKeyAndOrderFront(nil)
        owner.revealRunTerminal()
      } else if let project = project(forTarget: target), !hasRunCommand(forProject: project.path) {
        // Issue #127: ⌘R on a target with no run command configured used to silently no-op inside
        // `startRunCommand`'s guard — this is the sole reachable path that could (the toolbar/sidebar
        // Run buttons are hidden whenever `canRunCommand` is false, so they can't be clicked into this
        // state). Surface the settings sheet with a warning instead of doing nothing.
        if pendingProjectSettings == nil {
          pendingProjectSettings = PendingProjectSettings(project: project, showsRunWarning: true)
        }
        // else: a settings sheet is already open (any reason, any project) — intentionally do
        // nothing further, rather than clobber it. This is deliberate and self-contained (issue
        // #127-eng-4, adversarial review): a second ⌘R for a DIFFERENT no-command target while a
        // sheet is already presented would otherwise silently overwrite the pending item, discarding
        // any unsaved typing with no confirmation — and there's genuine, unverified uncertainty about
        // whether SwiftUI's `.sheet(item:)` even refreshes the banner correctly when the identity is
        // unchanged. (Previously this fell through to `startRunCommand`'s own unrelated no-command
        // guard, which happened to produce the same no-op — but only by coincidence, not by design.)
      } else {
        startRunCommand(for: target)
      }
    }
  }

  /// ⇧⌘R / Stop menu: stop the selected target's run command if it's running. No-op otherwise.
  func stopSelectedRunCommand() {
    guard !isEditingTextField, let target = selectedTarget,
      isRunCommandRunning(for: target.id)
    else { return }
    stopRunCommand(for: target)
  }

  /// ⌥⌘R / Restart menu: restart the selected target's run command if it's running. No-op otherwise.
  func restartSelectedRunCommand() {
    guard !isEditingTextField, let target = selectedTarget,
      isRunCommandRunning(for: target.id)
    else { return }
    restartRunCommand(for: target)
  }

  /// Whether any run terminal exists (running or stopped-but-open) — gates Go ▸ Run Terminal.
  var hasAnyRunTerminal: Bool { runStates.values.contains { $0.tab != nil } }

  /// Go ▸ Run Terminal: jump to a run terminal if one exists — select its target and focus the run
  /// tab. Prefers the selected target's run terminal, else any. Pure navigation; never starts a
  /// command (issue #7).
  func revealRunTerminal() {
    let targetID =
      selectedTarget.flatMap { runStates[$0.id]?.tab != nil ? $0.id : nil }
      ?? runStates.first { $0.value.tab != nil }?.key
    guard let targetID, let runTab = runStates[targetID]?.tab,
      let sid = Self.sidebarID(forTargetID: targetID, in: projects), let target = target(for: sid)
    else { return }
    selectedTargetID = sid
    selectedProjectID = Self.projectPath(of: sid)
    terminals.focus(runTab, for: target)
  }

  /// Stop the run command (issue #7): one press tells the SUPERVISOR to stop the child gracefully and
  /// keep the pane (SIGUSR2 — it SIGINTs the child's foreground group, waits for it to fully exit, and
  /// SIGKILLs on a 6s timeout for a process that ignores SIGINT). No second-press hard-kill / surface
  /// free — the supervisor owns the teardown. State flips to `.running(interrupted)` (stop in flight),
  /// then the status file drives it to `.stopped`.
  func stopRunCommand(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, _), .restarting(let tab):
      signalSupervisor(SIGUSR2, for: target.id)
      runStates[target.id] = .running(tab: tab, interrupted: true)
    case .armed, .stopped, .none:
      break  // nothing executing to stop
    }
  }

  /// Restart the run command (issue #7): tell the SUPERVISOR (SIGUSR1) to stop the child, wait for it to
  /// fully exit, then relaunch — all serialized inside the terminal, so the surface/tab/split slot are
  /// untouched and the new instance can't boot into the old one's still-held port/pidfile. Works from
  /// running, in-flight, OR a parked-but-stopped pane; only if the supervisor itself is gone (quit/crash)
  /// do we respawn a fresh surface.
  func restartRunCommand(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, _), .restarting(let tab), .stopped(let tab):
      if signalSupervisor(SIGUSR1, for: target.id) {
        runStates[target.id] = .restarting(tab: tab)  // status: stopping → running
      } else {
        respawnRunCommand(replacing: tab, for: target)  // supervisor gone → fresh surface
      }
    case .armed, .none:
      startRunCommand(for: target)
    }
  }

  /// The surface's PTY child exited — under the supervisor model that's the SUPERVISOR itself, so the
  /// whole run is over (a quit/teardown, or a supervisor crash), not a user-command stop (those are
  /// driven by the status file). Mark terminal; the pane stays open (`wait_after_command`). If the
  /// status file already recorded an outcome (the usual case — the supervisor wrote `exited <code>`
  /// before exiting), keep it; otherwise fall back to libghostty's code. The forked-free backstop
  /// (SIGKILL the captured session) guards against a leaf that outlived the supervisor.
  private func markRunExited(for target: TerminalTarget, exitCode: UInt32) {
    guard let tab = runStates[target.id]?.tab else { return }
    let sid = runSessions[target.id] ?? -1
    // Prefer the supervisor's final status line (authoritative — it wrote `stopped`/`exited <code>`
    // just before exiting) over libghostty's unreliable exit code, in case the poller hadn't read it
    // yet when this child-exit callback fired.
    if runOutcomes[target.id] == nil, let ctl = runPidFiles[target.id],
      let raw = try? String(
        contentsOfFile: Self.supervisorStatusPath(forPidPath: ctl), encoding: .utf8)
    {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !line.isEmpty { applyRunStatus(line, for: target) }
    }
    runStates[target.id] = .stopped(tab: tab)
    if runOutcomes[target.id] == nil {
      runOutcomes[target.id] = .exited(code: Int32(truncatingIfNeeded: exitCode))
      scheduleRunToastAutoDismiss(for: target.id)
      if Self.runOutcomeIsBannerWorthy(runOutcomes[target.id]) {
        postRunFailureBannerIfBackgrounded(
          targetID: target.id, tabID: tab, title: "Run failed",
          body: "exited with code \(exitCode)")
      }
    }
    clearRunPidFile(for: target.id)
    // Backstop: a forked-free leaf (bin/dev/foreman in another pgroup) can outlive the supervisor —
    // SIGKILL the captured session so it can't linger on the port.
    waitForSessionsExit(sid > 1 ? [sid] : [], deadline: Date().addingTimeInterval(6)) {}
  }

  // MARK: Run command — graceful teardown (issue #7, Option B)

  /// The target's run surface if a child process is still alive in it, else nil. Used by the
  /// teardown paths to decide whether a Ctrl-C + wait is needed before freeing it.
  private func liveRunView(for targetID: TerminalTarget.ID) -> GhosttySurfaceView? {
    guard let tabID = runStates[targetID]?.tab,
      let view = terminals.view(forTab: tabID, inTarget: targetID),
      view.hasLiveProcess
    else { return nil }
    return view
  }

  /// Whether any run command still has a live process — gates the quit handler's graceful wait.
  var hasLiveRunCommand: Bool {
    runStates.keys.contains { liveRunView(for: $0) != nil }
  }

  /// Tell each target's SUPERVISOR to quit (SIGTERM — it stops the child gracefully, waits for it,
  /// SIGKILLs on a 6s timeout, then exits), and run `then` once every run surface's child (the
  /// supervisor) has actually exited — or after `timeout` (fallback). Polls `hasLiveProcess` on the
  /// main runloop; NEVER frees a surface itself, so it can't race libghostty's teardown. The session
  /// SIGKILL in `pollUntilExited` is the backstop for a forked-free leaf that outlived the supervisor.
  func gracefullyStopRuns(
    _ targetIDs: [TerminalTarget.ID], timeout: TimeInterval = 6, then: @escaping () -> Void
  ) {
    var views: [GhosttySurfaceView] = []
    var sids: [pid_t] = []
    for id in targetIDs {
      guard let view = liveRunView(for: id) else { continue }
      signalSupervisor(SIGTERM, for: id)  // supervisor stops the child, then exits → surface frees
      views.append(view)
      if let sid = runSessions[id], sid > 1 { sids.append(sid) }
    }
    guard !views.isEmpty else {
      then()
      return
    }
    pollUntilExited(views, sessions: sids, deadline: Date().addingTimeInterval(timeout), then: then)
  }

  /// Wait until both the surfaces' PTY children have exited AND every run session has drained (no live
  /// member), then run `then`. On `deadline` (a graceful Ctrl-C didn't take in time) SIGKILL whatever
  /// remains in those sessions, so a forked-free server is guaranteed dead before the caller frees the
  /// surface / quits — what makes teardown reliable for ANY run command, not just SIGINT-honouring ones
  /// (issue #7). Polling the surface (not just the session) keeps it unit-testable without a real PTY.
  private func pollUntilExited(
    _ views: [GhosttySurfaceView], sessions sids: [pid_t], deadline: Date,
    then: @escaping () -> Void
  ) {
    let surfacesDone = views.allSatisfy { !$0.hasLiveProcess }
    let sessionsDone = sids.allSatisfy { runSessionMembers($0).isEmpty }
    if surfacesDone && sessionsDone {
      then()
      return
    }
    if Date() >= deadline {
      // Last resort — guarantee death before the caller frees the surface.
      for sid in sids { signalRunSession(sid, SIGKILL) }
      then()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.pollUntilExited(views, sessions: sids, deadline: deadline, then: then)
    }
  }

  /// Poll until none of `sids` has a live member — i.e. everything the run command spawned has exited —
  /// then run `then`. On `deadline`, SIGKILL whatever remains so the old server is guaranteed dead
  /// before the caller respawns (the reliable, generic Restart/Stop ordering; issue #7). The empty-set
  /// case completes synchronously, so callers must already be off any libghostty callback stack.
  private func waitForSessionsExit(
    _ sids: [pid_t], deadline: Date, then: @escaping () -> Void
  ) {
    let live = sids.filter { !runSessionMembers($0).isEmpty }
    if live.isEmpty {
      then()
      return
    }
    if Date() >= deadline {
      // Last resort — guarantee death before the caller respawns.
      for sid in live { signalRunSession(sid, SIGKILL) }
      then()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.waitForSessionsExit(sids, deadline: deadline, then: then)
    }
  }

  /// If `tabID` is the target's run command with a live process, Ctrl-C it and wait for it to exit
  /// before running `proceed` (the actual close/teardown); otherwise run `proceed` now. Ordinary
  /// shell tabs (which don't exit on Ctrl-C) and already-exited run tabs fall straight through, so
  /// only a live dev server pays the wait.
  private func closingRunTab(
    _ tabID: TerminalTab.ID, for targetID: TerminalTarget.ID, then proceed: @escaping () -> Void
  ) {
    let isRunTab = runStates[targetID]?.tab == tabID
    let live = liveRunView(for: targetID) != nil
    guard isRunTab, live else {
      proceed()  // not a live run tab → free directly (no supervisor to gracefully stop)
      return
    }
    gracefullyStopRuns([targetID], then: proceed)
  }

  /// SIGINT all live run commands and wait for them to exit (bounded) before `completion`. Called from
  /// the quit handler so dev servers clean up instead of being orphaned by the OS hangup on exit
  /// (SIGHUP). Signals the captured pids directly — never frees a surface.
  func gracefullyStopAllRunCommands(timeout: TimeInterval = 6, completion: @escaping () -> Void) {
    gracefullyStopRuns(Array(runStates.keys), timeout: timeout, then: completion)
  }

  /// Arm a just-created workroom to auto-run its project's command as its first terminal (issue #7).
  /// Called from `createWorkroom`; the run fires from `ensureInitialTerminal` when the pane mounts.
  func armAutoRun(forWorkroom targetID: TerminalTarget.ID) {
    runStates[targetID] = .armed
  }

  /// Ensure a target's terminal pane lands the user in a live terminal when it first appears (called by
  /// the terminals view's `.task`). Two cases, both covered here:
  ///
  ///   1. Auto-run (issue #7): a just-created workroom that armed its project's run command starts it
  ///      as a backgrounded tab #1 (a toast surfaces it), with the always-on shell (below) as the
  ///      focused tab #2. The pane only mounts once any blocking setup dialog is dismissed, so the
  ///      command runs post-setup, as intended.
  ///   2. Always open a terminal: a newly created workroom always opens a shell, and selecting an
  ///      *existing* workroom/root with no open terminals opens one too. `.task(id:)` fires per target
  ///      appearance and `tabCount` is 0 only when the target has no live tabs, so this is idempotent
  ///      across re-mounts (navigating away and back) once a terminal exists.
  ///
  /// Falls back to a plain shell if the armed command can't start (e.g. config cleared between arming
  /// and mount) — the shell below opens regardless.
  func ensureInitialTerminal(for target: TerminalTarget) {
    // Consume the armed intent up front so a later re-mount can't re-fire it, then let startRunCommand
    // (re-)derive the state: it becomes `.running` as a backgrounded tab #1, or a no-op if the config
    // was cleared between arming and mount.
    let isArmed: Bool
    if case .armed = runStates[target.id] { isArmed = true } else { isArmed = false }
    if isArmed {
      runStates[target.id] = nil
      // Background the auto-run (issue #67): the shell below is the focused tab the user lands on.
      startRunCommand(for: target, focus: false)
    }

    // Always land in a shell. When armed, this is the focused tab #2 beside the backgrounded run; for a
    // created or freshly-selected workroom/root with no tabs, it's the only one. `addTab` focuses it.
    if isArmed || terminals.tabCount(forTargetID: target.id) == 0 {
      terminals.addTab(for: target)
    }
  }

  // MARK: Loading

  /// Initial launch: render config-only (instant, no VCS calls), then refresh warnings.
  /// Branch labels hydrate asynchronously off both passes (see `resolveBranches`).
  /// Load this window's view of the projects. `restore` is true only for the window SwiftUI restores
  /// at launch; combined with the one-shot `consumeInitialRestore()` it means exactly one window
  /// reapplies the persisted selection and every other (incl. every ⌘N) window starts blank (#70).
  func bootstrap(restore: Bool = true) async {
    // Exactly one window (the launch window) reapplies the saved selection; every other (incl. ⌘N)
    // window starts blank (issue #70).
    let shouldRestore = restore && projectStore.consumeInitialRestore()
    if UITestFixture.isActive {
      fixtureAutoSelect = shouldRestore
      loadFixture()
      return
    }
    // Drop the saved selection unless this is the one launch window allowed to restore it, so a new
    // window opens with nothing selected (no workroom, no terminal).
    if !shouldRestore {
      pendingRestoreSelection = nil
    }
    if projectStore.projects.isEmpty {
      await load(warnings: "none")
      await load(warnings: "fast")
    } else {
      // Another window already loaded the shared project list — don't refork the CLI (issue #70,
      // OV #2). Just resolve this (possibly blank) window's selection against the existing list.
      apply(projectStore.projects)
    }
  }

  func reload() async {
    await load(warnings: "fast")
  }

  /// Reload only if it's been a while since the last load. Driven by the app regaining
  /// focus, so alt-tabbing back doesn't fork a git/jj process per project every time.
  func reloadIfStale(minInterval: TimeInterval = 4) async {
    guard Date().timeIntervalSince(lastLoadAt) >= minInterval else { return }
    // Background poll (fires on every app activation, incl. waking from sleep). A transient
    // failure here — e.g. the `list` timing out because the just-woken machine is still cold —
    // must NOT pop a modal "Something went wrong"; the next activation just retries.
    await load(warnings: "fast", surfaceErrors: false)
  }

  private func load(warnings: String, surfaceErrors: Bool = true) async {
    // In UI-test fixture mode every load resolves to the same fake projects — never shell out to
    // the CLI (so an on-focus `reloadIfStale` can't replace the fixture with the real config).
    if UITestFixture.isActive {
      loadFixture()
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let response = try await cli.list(warnings: warnings, project: nil)
      apply(response.projects)
      lastLoadAt = Date()
      resolveBranches()
      refreshWorkroomStatuses()
    } catch {
      if surfaceErrors { present(error) }
    }
  }

  /// Load the deterministic UI-test fixture (see `UITestFixture`): inject the fake projects and, on
  /// the first load, auto-select the fixture workroom so a terminal renders immediately — the tests
  /// then drive splits/closes without any fragile sidebar navigation. Branch resolution is skipped
  /// (the temp-dir paths aren't real repos), so no git/jj process is ever spawned. Idempotent: a
  /// later reload re-injects the same projects but preserves whatever the test has since selected.
  private func loadFixture() {
    let fixtures = UITestFixture.projects()
    projects = fixtures
    // Seed a deterministic run command (issue #7) so the run-command UI is exercisable in fixture
    // mode (the lifecycle XCUITest + the manual verify-first probe). The path is a temp dir, so real
    // projects' Defaults are untouched. Prints a marker (proves the command parsed + launched) then
    // sleeps (stays "running" long enough to assert the Stop/Restart state deterministically).
    if let project = fixtures.first {
      // A test can override the seeded command (`-WorkroomUITestRunCommand`) to drive a deterministic
      // failure / success / long-running run for the run-status XCUITests (issue #79). A test can
      // instead opt OUT of any command being seeded (`-WorkroomUITestNoRunCommand`) for the "no run
      // command configured" state (issue #127) — this must EXPLICITLY clear the config (not just skip
      // seeding), since the fixture project's path is deterministic and `Defaults[.runCommands]`
      // persists across launches in the real app's UserDefaults domain: a prior launch that DID seed a
      // command (e.g. a `RunStatusUITests` run) would otherwise leak a stale command into this state
      // (found by review, issue #127).
      if UITestFixture.noRunCommand {
        setRunConfig(.empty, forProject: project.path)
      } else {
        setRunConfig(
          RunConfig(command: UITestFixture.runCommand ?? "echo PROBE_OK; sleep 30", autoRun: false),
          forProject: project.path)
      }
    }
    // The real persisted selection won't resolve against the fixture paths; don't try to restore it.
    pendingRestoreSelection = nil
    // Start every fixture project expanded so the sidebar tree is deterministic regardless of any
    // collapse state a prior UI-test run persisted to the shared defaults (real projects untouched).
    collapsedProjects.subtract(fixtures.map(\.id))
    // Auto-select the fixture workroom only for the restoring (launch) window — a ⌘N window starts
    // blank in fixture mode too, mirroring production (issue #70). `fixtureAutoSelect` is the
    // per-window equivalent of clearing `pendingRestoreSelection` on the real path.
    if fixtureAutoSelect {
      if selectedProjectID == nil { selectedProjectID = fixtures.first?.id }
      if selectedTargetID == nil, let project = fixtures.first,
        let workroom = project.workrooms.first
      {
        selectedTargetID = .workroom(project: project.path, name: workroom.name)
        // Open a terminal for the auto-selected fixture workroom up front (the view's
        // `ensureInitialTerminal` would too on mount) so the UI tests, which assume the fixture
        // workroom has a terminal (and thus a tab), don't race the pane's first appearance.
        let target = workroom.target(inProject: project.path)
        terminals.ensureTab(for: target)
        // Two-tab scenario (drag/reorder XCUITest, issue #23): also open a terminal for the second
        // workroom so the workroom tab bar shows two chips to reorder.
        if UITestFixture.twoTabs, project.workrooms.count > 1 {
          terminals.ensureTab(for: project.workrooms[1].target(inProject: project.path))
        }
        // Terminal-strip overflow scenario (pinned "+" XCUITest, issue #129): `ensureTab` opened the
        // first tab, so add the rest.
        for _ in 1..<UITestFixture.terminalTabs { _ = terminals.addTab(for: target) }
        // Workroom-bar overflow scenario (issue #129): make every seeded workroom an *active target*
        // so the title-bar tab bar shows a chip for each. `ensureTab` only registers a tab; the shell
        // is created by the pane's view when it mounts, and only the selected workroom's does — so
        // this costs N tab models and one terminal, not N terminals.
        if UITestFixture.workroomCount > 1 {
          for workroom in project.workrooms.dropFirst() {
            terminals.ensureTab(for: workroom.target(inProject: project.path))
          }
        }
        // Workroom-split scenario (context-menu XCUITest, issue #112): start already in a
        // root + workroom split so the group title bar renders on launch without a flaky drag.
        // The selected workroom is a member, so `visibleWorkroomLayout` shows the split; open the
        // root's terminal too so its pane mounts.
        if UITestFixture.workroomSplit {
          terminals.ensureTab(for: project.rootTarget)
          workroomSplit = .split(
            id: UUID(), orientation: .horizontal, ratio: 0.5,
            first: .leaf(.root(project: project.path)),
            second: .leaf(.workroom(project: project.path, name: workroom.name)))
        }
        // Seed a representative notification history (the inspector's Notifications panel is otherwise
        // empty in fixture mode) so it gets visual + UI-test coverage. Keyed to the workroom target
        // but synthetic tabs (see `UITestFixture.notifications`) so the window's focus auto-dismiss
        // can't wipe them. First-load only (guarded by the nil selection), so a focus-driven reload
        // never clobbers notifications a test has since dismissed.
        notifications.seedForTesting(UITestFixture.notifications(targetID: target.id))
      }
    }
    // Seed deterministic Changes-inspector status (the fixture paths aren't real repos, so the live
    // probe would only report "unknown"); the resolver sweep is skipped in fixture mode.
    seedFixtureStatuses()
    lastLoadAt = Date()
  }

  private func apply(_ incoming: [Project]) {
    // Inject GUI-only display labels (issue #41) onto the decoded workrooms from
    // `Defaults[.workroomLabels]` — the CLI JSON never carries them — and garbage-collect labels for
    // workrooms that no longer exist (deleted via the CLI or another build). `incoming` is the full
    // configured set (`ListData`/`AllProjects`), so pruning anything not present is safe.
    let fresh0 = enrichLabels(incoming)
    pruneOrphanedLabels(keeping: fresh0)
    // Sort projects alphabetically by display name (issue #62) so the sidebar order is stable and
    // predictable regardless of CLI/config order. Case-insensitive, with the full path as a
    // tie-break so same-named projects in different dirs keep a deterministic order. Done here at the
    // single source of truth so selection defaults (`fresh.first`) and the rendered tree agree.
    let sorted = fresh0.sorted {
      let byName = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
      return byName == .orderedSame ? $0.path < $1.path : byName == .orderedAscending
    }
    // Drop workrooms with an in-flight optimistic deletion (issue #116): a `list` snapshot taken
    // before the teardown persisted still lists them, so without this a concurrent reload would
    // resurrect a just-deleted workroom. Cleared from `deletingWorkrooms` when the teardown ends.
    let fresh = applyingDeletionTombstones(sorted)
    projects = fresh
    // First load after launch: restore last session's selection (issue #14) before it's
    // validated below. Resolved against the live projects, so a since-deleted target — or a
    // restore that loses the race to a user click — resolves to nil and falls through.
    if selectedTargetID == nil, let saved = pendingRestoreSelection {
      selectedTargetID = Self.sidebarID(forTargetID: saved, in: fresh)
    }
    pendingRestoreSelection = nil
    // Keep a project as the New-Workroom context; prefer the (possibly restored) selection's
    // project, else the first.
    if selectedProjectID == nil || !fresh.contains(where: { $0.id == selectedProjectID }) {
      selectedProjectID = Self.projectPath(of: selectedTargetID) ?? fresh.first?.id
    }
    // Keep the selected target only if it still exists. `validatedSelection` can only
    // return the existing selection or nil — it never fabricates one, so a load/refresh
    // can't auto-select a root or workroom the user didn't pick (D4).
    selectedTargetID = Self.validatedSelection(selectedTargetID, in: fresh)
    // Drop any split leaf whose workroom went away on reload (issue #23 follow-up self-heal); collapses
    // to a survivor / dissolves below two, re-pointing selection. Runs after selection is validated so
    // history/notifications/run-toolbar (all keyed on `selectedTargetID`) follow the survivor.
    pruneWorkroomSplitToLiveLeaves()
    // Forget labels for projects that went away.
    let liveIDs = Set(fresh.map(\.id))
    rootRefs = rootRefs.filter { liveIDs.contains($0.key) }
    // Forget VCS/CI status for sidebar ids that went away (mirrors rootRefs pruning, issue #24).
    let liveSidebarIDs = Self.liveSidebarIDs(in: fresh)
    workroomStatuses = workroomStatuses.filter { liveSidebarIDs.contains($0.key) }
    // Drop a pending sheet whose project was deleted from ANOTHER window (issue #127 follow-up,
    // adversarial review): `removeProjectLocally` only clears these for the deleting window's own
    // store, but every window's periodic/on-focus reload comes through here. Without this, a second
    // window's still-open sheet keeps referencing the now-gone project, and Save would silently
    // write `Defaults[.runCommands]` for a deleted path — the same stale-config leak this diff
    // otherwise closes, just via a path this fix didn't originally cover.
    if let pending = pendingProjectSettings, !liveIDs.contains(pending.project.id) {
      pendingProjectSettings = nil
    }
    if let pendingLabel = pendingWorkroomLabel,
      !liveSidebarIDs.contains(
        .workroom(project: pendingLabel.project.path, name: pendingLabel.workroom.name))
    {
      pendingWorkroomLabel = nil
    }
    // Keep the live root-branch watchers in sync with the project set (start new, drop departed).
    updateRootBranchWatches()
  }

  /// Removes workrooms currently tombstoned in `deletingWorkrooms` from an incoming CLI project list,
  /// so a stale `list` snapshot (taken before a delete's teardown persisted) can't resurrect a
  /// just-deleted workroom (issue #116, the create/delete reload race). A no-op when nothing is being
  /// deleted; otherwise rebuilds only the projects that actually contained a tombstoned workroom.
  private func applyingDeletionTombstones(_ projects: [Project]) -> [Project] {
    let tombstoned = deletingWorkrooms
    guard !tombstoned.isEmpty else { return projects }
    return projects.map { project in
      let kept = project.workrooms.filter {
        !tombstoned.contains(TerminalTarget.workroomID(project: project.path, name: $0.name))
      }
      guard kept.count != project.workrooms.count else { return project }
      return Project(path: project.path, vcs: project.vcs, workrooms: kept)
    }
  }

  /// Every `.root`/`.workroom` `SidebarID` present in `projects` — used to prune
  /// `workroomStatuses` on reload so a since-deleted workroom can't leave a stale badge.
  nonisolated static func liveSidebarIDs(in projects: [Project]) -> Set<SidebarID> {
    var ids = Set<SidebarID>()
    for p in projects {
      ids.insert(.root(project: p.id))
      for w in p.workrooms { ids.insert(.workroom(project: p.id, name: w.name)) }
    }
    return ids
  }

  /// Keeps the current selection if it still exists in `projects`, else nil. Never invents
  /// a selection — this is the guarantee behind D4 (a load/refresh must not auto-open a
  /// terminal). Pure + nonisolated so it's directly unit-testable (SelectionTests).
  nonisolated static func validatedSelection(_ current: SidebarID?, in projects: [Project])
    -> SidebarID?
  {
    guard let current else { return nil }
    return targetExists(current, in: projects) ? current : nil
  }

  nonisolated private static func targetExists(_ id: SidebarID, in projects: [Project]) -> Bool {
    switch id {
    case .root(let path):
      return projects.contains { $0.id == path }
    case .workroom(let path, let name):
      return projects.first { $0.id == path }?.workrooms.contains { $0.id == name } ?? false
    case .project:
      return false
    }
  }

  /// Hydrate each project's root branch/bookmark label off the main path. Per project,
  /// concurrent, cancellable: a slow/wedged repo only delays its own label, and a newer
  /// reload cancels this sweep so it can't write stale values. A resolution that comes
  /// back `.none` does not clobber a previously-resolved label (no flash to "root" on
  /// refresh). Project counts are small, so the group runs uncapped.
  private func resolveBranches() {
    branchTask?.cancel()
    let resolver = self.resolver
    let snapshot = projects.map { (id: $0.id, path: $0.path, vcs: $0.vcs) }
    branchTask = Task { [weak self] in
      await withTaskGroup(of: (String, RootRef).self) { group in
        for p in snapshot {
          group.addTask { (p.id, await resolver.resolve(path: p.path, vcs: p.vcs)) }
        }
        for await (id, ref) in group {
          guard !Task.isCancelled, let self else { break }
          if ref.kind == .none, self.rootRefs[id] != nil { continue }  // keep prior label
          self.rootRefs[id] = ref
        }
      }
    }
  }

  /// Reconcile the per-project root-branch watchers with the current project list: ensure a watcher
  /// for each project (pointed at its `.git`/`.jj` metadata dir) and tear down watchers for projects
  /// that went away. Called from `apply` so the watch set tracks the live projects. No-op in fixture
  /// mode (the temp-dir paths aren't real repos — match `resolveBranches`, which skips them too).
  func updateRootBranchWatches() {
    guard !UITestFixture.isActive else {
      for w in rootBranchWatchers.values { w.stop() }
      rootBranchWatchers.removeAll()
      for t in rootBranchRefreshTasks.values { t.cancel() }
      rootBranchRefreshTasks.removeAll()
      return
    }
    let live = Set(projects.map(\.id))
    for id in rootBranchWatchers.keys where !live.contains(id) {
      rootBranchWatchers[id]?.stop()
      rootBranchWatchers[id] = nil
      rootBranchRefreshTasks[id]?.cancel()
      rootBranchRefreshTasks[id] = nil
    }
    for p in projects {
      guard let dir = Self.vcsMetadataDir(path: p.path, vcs: p.vcs) else { continue }
      let id = p.id
      let watcher =
        rootBranchWatchers[id]
        ?? WorkroomFileWatcher { [weak self] _ in self?.handleRootBranchChange(projectID: id) }
      rootBranchWatchers[id] = watcher
      watcher.start(path: dir)
    }
  }

  /// The VCS metadata directory whose changes signal a root branch/bookmark move: `.git` for git,
  /// `.jj` for jj. Watching this — not the project root — keeps the watch quiet (working-tree edits
  /// don't touch it; only VCS operations do). nil for an unknown vcs. `nonisolated` (pure) so it's
  /// directly unit-testable.
  nonisolated static func vcsMetadataDir(path: String, vcs: String) -> String? {
    switch vcs {
    case "git": return (path as NSString).appendingPathComponent(".git")
    case "jj": return (path as NSString).appendingPathComponent(".jj")
    default: return nil
    }
  }

  /// Re-resolve one project's root branch/bookmark after a change under its VCS metadata dir, writing
  /// the label only if it actually changed (so VCS-internal churn that leaves the branch unchanged
  /// doesn't invalidate the sidebar). Cancel-and-replace per project so a write burst resolves once;
  /// `.none` never clobbers a prior label (matches `resolveBranches`).
  func handleRootBranchChange(projectID: Project.ID) {
    guard !UITestFixture.isActive, let p = projects.first(where: { $0.id == projectID })
    else { return }
    // Live History (issue #59 follow-up): this project's VCS metadata dir moved — a commit / bookmark
    // / ref update in the project or one of its workrooms (git worktree refs land in the shared
    // `.git`; jj ops land in the shared `.jj/repo/`, so both surface here even though nothing lands
    // under the workroom dir). If the inspector is *visible* (not merely the active section — that
    // persists while hidden), showing History, and its target belongs to THIS project, repaint the
    // log. Deliberately BEFORE the label-resolve task below and independent of it: a normal commit
    // usually leaves the branch/bookmark label unchanged, so gating this on the label actually
    // changing (the `unchanged → return` at the end) would skip the main case. The read is a
    // read-only `load_at_head` (no working-copy lock, no write), so it can't re-fire this watcher.
    if inspectorIsVisible, activeInspectorSection == .history,
      inspectorTargetID?.belongsToProject(p.path) == true
    {
      commitHistory.refresh()
    }
    let resolver = self.resolver
    rootBranchRefreshTasks[projectID]?.cancel()
    rootBranchRefreshTasks[projectID] = Task { [weak self] in
      let ref = await resolver.resolve(path: p.path, vcs: p.vcs)
      guard let self, !Task.isCancelled else { return }
      if ref.kind == .none, self.rootRefs[projectID] != nil { return }  // keep prior label
      if self.rootRefs[projectID] == ref { return }  // unchanged — don't churn the @Published store
      self.rootRefs[projectID] = ref
    }
  }

  // MARK: Mutations

  /// Registers a project at `path`. With `create`, a non-existent directory is
  /// created and git-initialized by the CLI (issue #103, "Create new directory…");
  /// otherwise `path` must already be a Git/JJ repo ("From existing path…").
  func addProject(_ path: String, create: Bool) async {
    do {
      let canonical = try await cli.addProject(path, create: create)
      await reload()
      // Select the freshly added project (by the canonical path the CLI registered —
      // it resolves symlinks and ~, so it's more reliable than the typed path) and
      // open a terminal on its root, mirroring workroom creation rather than leaving
      // the user on the "Nothing selected" empty state (issue #104). A new project
      // has no workrooms, so the root is the only sensible terminal to open.
      if let match = projects.first(where: { $0.path == canonical }) {
        selectedProjectID = match.id
        selectedTargetID = .root(project: match.path)
      }
    } catch {
      present(error)
    }
  }

  func createWorkroom(in project: Project) async {
    busyProjects.insert(project.path)
    defer { busyProjects.remove(project.path) }

    let session = ScriptLogSession(
      title: "Setting up new workroom in \(project.displayName)", phase: "setup")
    // Show the creating slot immediately — before the CLI has even reported the (generated) name — so
    // the window shows progress from the first click, not just the sidebar spinner (issue #116). Until
    // the name arrives the detail shows the loader (`isCreationFocused` is unconditionally true
    // pre-name); once the workroom exists we land on it and — for a setup script — swap to its dialog.
    creation = WorkroomCreation(session: session, project: project)
    selectedProjectID = project.id

    do {
      let created = try await cli.create(
        project: project.path,
        onLog: { text in
          DispatchQueue.main.async { session.append(text) }
        },
        onReady: { name, _, setup in
          // The workroom now exists: land on it (the provisional chip becomes the real named chip, and
          // the detail moves from the loader to the new workroom's slot). A setup script shows its
          // dialog there; a no-setup workroom keeps the loader until the create completes.
          DispatchQueue.main.async {
            Task { @MainActor in
              await self.landOnCreatedWorkroom(name: name, project: project, setup: setup)
            }
          }
        }
      )
      session.finish()
      // Land now if the early "created" event never arrived (older CLI) — no setup flag to read.
      if creation?.targetID == nil {
        await landOnCreatedWorkroom(name: created.name, project: project, setup: false)
      } else {
        await reload()  // reflect the finished setup script's tree
      }
      // Setup (if any) has finished, so the worktree is no longer being written — allow deletion again
      // (issue #116), and re-arm the (create-suppressed) watcher + run one status probe now that the
      // tree has settled. Unlike the failure path — where the `selectedTargetID` assignment fires the
      // probe via its `didSet` — nothing re-selects here, so call it explicitly.
      if let id = creation?.targetID {
        creatingWorkrooms.remove(id)
        scheduleSelectedStatusRefresh()
      }
      // No setup script → there was never a dialog, just the loader: clear the create so the loader
      // gives way to the new workroom's terminal (issue #116). A setup script instead keeps its dialog
      // up (with a Dismiss button) until the user closes it — dismissing is what mounts the withheld
      // terminal. Auto-run is NOT triggered here: it fires from `ensureInitialTerminal` when the
      // terminal pane first mounts, which for a setup script is after dismissal (issue #7).
      if creation?.hasSetup != true {
        creation = nil
      }
    } catch {
      // Even on (partial) failure, reload so a "created but setup failed" workroom shows up.
      await reload()
      if let name = creation?.name, let id = creation?.targetID {
        // The workroom exists but setup failed. Disarm the auto-run armed in `onReady` (before setup
        // ran) so dismissing the failure doesn't launch the command against a half-set-up tree —
        // auto-run is a success-path action (issue #7, review finding). Force `hasSetup` so the detail
        // shows the setup dialog (with a Dismiss button + the failure message), not the loader, until
        // it's closed. Re-assert selection (idempotent with `onReady`) so the failure is on screen even
        // if the `onReady` land lost the race to this catch.
        if case .armed = runStates[id] { runStates[id] = nil }
        creatingWorkrooms.remove(id)  // setup failed — the workroom can now be deleted (issue #116)
        creation?.hasSetup = true
        selectedProjectID = project.id
        // Assigning `selectedTargetID` here fires its `didSet` → `scheduleSelectedStatusRefresh()`,
        // which (now that `creatingWorkrooms` no longer holds the id, removed just above) re-arms the
        // watcher + probes the half-written worktree so its local status shows under the failure
        // dialog. Keep the remove-before-assign order, or the create-time gate would swallow this probe.
        selectedTargetID = .workroom(project: project.path, name: name)
        session.finish(failure: errorText(error))
      } else {
        // Failed before the workroom existed — no tab/slot target; clear the create and surface it.
        creation = nil
        present(error)
      }
    }
  }

  /// Lands on a just-created workroom once it exists (issue #116). Reloads FIRST so the workroom
  /// resolves against `projects` (its real tab chip takes over from the provisional one), then — in one
  /// synchronous step, no `await` in between — records its name/target/setup flag, arms auto-run, and
  /// selects it. The reload-then-set order is deliberate: `createWorkroom`'s fallback keys on
  /// `creation?.targetID`, so target id and selection must be set together (never target-set-then-
  /// suspend), or the fallback could fire while selection is still pending. Idempotent — the `onReady`
  /// path and the older-CLI fallback can both call it. The detail then shows the new workroom's slot:
  /// its setup dialog (script) or, once the create clears `creation`, its terminal (no script).
  // `internal` (not `private`) only so `@testable` can drive the late-echo bail path directly — a
  // late `onReady` echo lands here with `creation == nil`, and `onReady` is non-escaping so a fake
  // CLI can't reproduce that timing through `create()`. Not called from outside `AppStore`.
  func landOnCreatedWorkroom(name: String, project: Project, setup: Bool) async {
    // Drop the project row's creating spinner the moment the workroom exists (issue #116) — the
    // creating slot (its loader, then a setup script's dialog) now carries the progress, so the
    // sidebar indicator is redundant. `created` fires as setup begins, so this is the earlier of the
    // two. The `createWorkroom` defer still clears it for a failure before the workroom ever existed.
    busyProjects.remove(project.path)
    // Mark the workroom "creating" BEFORE the first reload (create-time FSEvents storm fix). The
    // reload's status sweep — and any watch/selection work it triggers — must all observe
    // `isCreating`, or they'd probe/watch the worktree the setup script is actively writing (~70
    // FSEvents callbacks/sec → a git/jj probe storm). Also blocks deletion while setup runs against
    // the worktree (issue #116); the create flow clears it once setup finishes.
    let id = TerminalTarget.workroomID(project: project.path, name: name)
    creatingWorkrooms.insert(id)
    await reload()
    // A late `onReady` echo can arrive after the flow already finished and cleared `creation` (a fast
    // no-setup create). Bail before touching selection — and undo the insert above, or a bailed
    // create would leave the workroom permanently suppressed (its dirty dot would never update again).
    guard creation != nil else {
      creatingWorkrooms.remove(id)
      return
    }
    creation?.name = name
    creation?.targetID = id
    creation?.hasSetup = setup
    // Arm auto-run so the workroom's first terminal runs the project command as tab #1 (issue #7). It
    // fires from `ensureInitialTerminal` when the pane mounts — after the setup dialog is dismissed for
    // a setup script, or as soon as the loader clears for a no-setup create — so it runs post-setup.
    let cfg = runConfig(forProject: project.path)
    if cfg.autoRun, cfg.hasCommand { armAutoRun(forWorkroom: id) }
    selectedProjectID = project.id
    selectedTargetID = .workroom(project: project.path, name: name)
  }

  /// Whether the in-progress create (issue #116) is the focused detail — i.e. the detail pane should
  /// show the creating slot (its loader, then, for a setup script, its dialog). Pre-name the loader
  /// unconditionally owns the detail (a brief phase, "loader until the dialog appears"). Once named it
  /// follows selection — the new workroom's own tab — so a setup script blocks ONLY that workroom:
  /// selecting another workroom reveals it while the create keeps running in the background.
  var isCreationFocused: Bool {
    guard let creation else { return false }
    // Derive the sid from the create's own name — not `projects` — so the dialog shows even during a
    // setup script, before that reload has landed the workroom in the project list.
    guard let name = creation.name else { return true }
    return selectedTargetID == .workroom(project: creation.project.path, name: name)
  }

  /// Whether the given target's terminal must stay withheld while its workroom is being created with a
  /// setup script (issue #116) — a safety net for the edge where the creation target is co-displayed as
  /// a non-focused split member (the focused slot is already handled by `isCreationFocused` in the
  /// detail). A no-setup create never blocks — its terminal mounts as soon as the loader clears.
  func isCreationBlocking(_ targetID: TerminalTarget.ID) -> Bool {
    guard let creation, creation.targetID == targetID else { return false }
    return creation.hasSetup
  }

  /// Whether `workroom` has an in-flight create (its setup is running) — the delete affordances
  /// disable while this holds so it can't be torn down mid-setup (issue #116). Shared across windows.
  func isCreatingWorkroom(_ workroom: Workroom, in project: Project) -> Bool {
    creatingWorkrooms.contains(
      TerminalTarget.workroomID(project: project.path, name: workroom.name))
  }

  /// Dismiss the setup dialog after a setup script (or its failure) — the user clicked Dismiss.
  /// Clearing `creation` drops the dialog and lets the withheld terminal mount (issue #116).
  func dismissCreation() {
    creation = nil
  }

  /// Removes the workroom from the sidebar immediately, then runs its teardown (script +
  /// workspace removal) in the background. On success the optimistic removal already
  /// matches reality; on failure we reload (so it reappears if it still exists) and
  /// surface the error.
  func deleteWorkroom(_ workroom: Workroom, in project: Project) {
    let sid = SidebarID.workroom(project: project.path, name: workroom.name)
    let targetID = TerminalTarget.workroomID(project: project.path, name: workroom.name)
    // Don't delete a workroom whose create is still in flight (issue #116) — its setup script is
    // running against the worktree, so tearing it down now would race the script. The delete
    // affordances are disabled while creating; this is the chokepoint that guarantees it.
    guard !creatingWorkrooms.contains(targetID) else { return }
    // Was the deleted workroom the one selected in *this* window? Captured before `detachTarget`
    // mutates selection, so the issue #80 fallback below can re-point only when the delete left us
    // with nothing selected (a solo selected workroom — a split member yields to its survivor).
    let wasSelectedHere = selectedTargetID == sid
    // Optimistic shared-model removal, visible in every window: drop it from the project list and its
    // shared VCS/CI status now (snappy UI). Terminals stay alive for the graceful stop; the reap +
    // VCS teardown follow once the process exits, so a dev server isn't orphaned against a deleted dir.
    // Tombstone it first so a concurrent reload's stale `list` snapshot can't resurrect it (the
    // create/delete race) — `apply` filters tombstoned workrooms until the teardown completes.
    deletingWorkrooms.insert(targetID)
    removeWorkroomLocally(workroom, in: project)
    workroomStatuses[sid] = nil
    // Clear the deleted workroom from EVERY window's split + selection (issue #70, OV #7) — another
    // window may have had it open/selected; "stale-id self-heal" only fixes model lookup, not live
    // surfaces or processes.
    let stores = affectedStores
    for store in stores { store.detachTarget(sid) }
    // If deleting the selected workroom left this window with no selection (the solo case — a split
    // member already yielded to its survivor, so selection is non-nil and we skip), land on the
    // rightmost remaining tab rather than the bare launch state — the same fallback closing the last
    // panel uses (issue #80). `displayedWorkroomTargets` already excludes the just-removed workroom.
    reselectAfterWorkroomDetached(wasSelectedHere: wasSelectedHere)
    // Ctrl-C the run command and reap the surfaces in every window that held this workroom, then run
    // the VCS teardown once — no dev server in any window left running against the deleted directory
    // (issue #7/#70). No live run command anywhere → immediate.
    stopRunsAcrossWindows([targetID], stores: stores) { [weak self] in
      for store in stores { store.reapTargetLocally(targetID) }
      self?.startWorkroomTeardown(workroom, in: project)
    }
  }

  /// Self plus every other window's store, de-duplicated by identity (issue #70). In tests no windows
  /// are registered, so this is just `[self]` and single-window behaviour is unchanged.
  private var affectedStores: [AppStore] {
    var seen: Set<ObjectIdentifier> = [ObjectIdentifier(self)]
    return [self]
      + WindowRegistry.shared.allStores.filter { seen.insert(ObjectIdentifier($0)).inserted }
  }

  /// Per-window: drop a target from this window's split, then clear selection if it pointed there
  /// (issue #70). Used by the delete flows to clean up every window that held the target.
  func detachTarget(_ sid: SidebarID) {
    removeWorkroomSplitMember(sid)
    if selectedTargetID == sid { selectedTargetID = nil }
  }

  /// Gracefully stop `ids`' run commands across the given windows, then run `then` once all have
  /// stopped (issue #7/#70) — so the VCS teardown never deletes a directory a dev server still holds.
  private func stopRunsAcrossWindows(
    _ ids: [TerminalTarget.ID], stores: [AppStore], then: @escaping () -> Void
  ) {
    let group = DispatchGroup()
    for store in stores {
      group.enter()
      store.gracefullyStopRuns(ids) { group.leave() }
    }
    group.notify(queue: .main, execute: then)
  }

  /// Reaps a single terminal target's in-app surface and clears all the per-target state
  /// keyed by its `TerminalTarget.ID`. Extracted from `deleteWorkroom`'s teardown so a
  /// project delete (which reaps a root + every workroom target) reuses the exact same
  /// cleanup — no second, drifting copy. Run only AFTER any live run process has been
  /// gracefully stopped (issue #7), so the dev server isn't orphaned against a deleted dir.
  func reapTargetLocally(_ targetID: TerminalTarget.ID) {
    terminals.reap(targetID)
    // `reap` only fires `onTabsRemoved` (which clears run state) when tabs existed; a target armed
    // for auto-run but deleted before its pane mounted has none, so clear directly too (issue #7).
    runStates[targetID] = nil
    clearRunPidFile(for: targetID)
    runOutcomes[targetID] = nil
    resetRunToast(for: targetID)  // deleted target → drop any run toast state (issue #67)
    // Drop the gone target's notifications and pull any banners it already delivered.
    systemNotifier.withdraw(tabIDs: notifications.removeForTarget(targetID))
  }

  /// Run the VCS teardown (worktree/workspace removal) in the background, surfacing any failure with
  /// its captured output in an alert. Split out of `deleteWorkroom` so the run command can stop first
  /// (issue #7) — the worktree must not be deleted while its dev server still holds the directory.
  private func startWorkroomTeardown(_ workroom: Workroom, in project: Project) {
    let targetID = TerminalTarget.workroomID(project: project.path, name: workroom.name)
    Task {
      let log = ScriptLogSession(title: "Tearing down \(workroom.name)", phase: "teardown")
      do {
        try await cli.delete(name: workroom.name, project: project.path) { text in
          DispatchQueue.main.async { log.append(text) }
        }
        // Teardown persisted (the workroom is gone from config): drop the tombstone. Future `list`
        // snapshots no longer include it, and the optimistic removal already matches (issue #116).
        deletingWorkrooms.remove(targetID)
      } catch {
        // Teardown failed → the workroom still exists. Clear the tombstone BEFORE reloading so the
        // reload's `apply` doesn't filter it out — it must reappear in the sidebar.
        deletingWorkrooms.remove(targetID)
        await reload()
        presentTeardownFailure(workroom, error: error, log: log)
      }
    }
  }

  /// Drops a workroom from the in-memory project list so the sidebar updates instantly. `internal`
  /// so the label-cleanup it performs is a unit-test seam (mirrors `removeProjectLocally`).
  func removeWorkroomLocally(_ workroom: Workroom, in project: Project) {
    guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
    let p = projects[idx]
    projects[idx] = Project(
      path: p.path, vcs: p.vcs, workrooms: p.workrooms.filter { $0.id != workroom.id })
    forgetLabels(forProject: project.path, workroomNames: [workroom.name])
  }

  // MARK: - Workroom labels (issue #41)

  /// Inject each workroom's GUI-only display label from `Defaults[.workroomLabels]` onto the freshly
  /// decoded model. The CLI JSON never carries a label, so this is the one point the app-side store
  /// is merged into `projects`. Pure transform — no side effects — so it's reused by both `apply`
  /// (full reload) and the targeted label mutators below. `internal` so it's a unit-test seam (the
  /// `apply` path that calls it is private).
  func enrichLabels(_ incoming: [Project]) -> [Project] {
    let labels = Defaults[.workroomLabels]
    guard !labels.isEmpty else { return incoming }
    return incoming.map { project in
      Project(
        path: project.path, vcs: project.vcs,
        workrooms: project.workrooms.map { wr in
          var wr = wr
          wr.label = labels[TerminalTarget.workroomID(project: project.path, name: wr.name)]
          return wr
        })
    }
  }

  /// Garbage-collect labels whose workroom no longer exists in `live` (deleted via the CLI or
  /// another build) so the map stays bounded and a recreated same-named workroom can't inherit a
  /// stale label. Safe to run on every load because `apply` always receives the complete configured
  /// set (`ListData`/`AllProjects`). `internal` so it's a unit-test seam.
  func pruneOrphanedLabels(keeping live: [Project]) {
    let labels = Defaults[.workroomLabels]
    guard !labels.isEmpty else { return }
    var liveKeys = Set<String>()
    for project in live {
      for wr in project.workrooms {
        liveKeys.insert(TerminalTarget.workroomID(project: project.path, name: wr.name))
      }
    }
    let pruned = labels.filter { liveKeys.contains($0.key) }
    if pruned.count != labels.count { Defaults[.workroomLabels] = pruned }
  }

  /// Drop the stored labels for the named workrooms of a project (used by the delete paths so an
  /// in-app delete clears the label immediately, not just on the next prune-on-load).
  private func forgetLabels(forProject path: String, workroomNames: [String]) {
    var labels = Defaults[.workroomLabels]
    var changed = false
    for name in workroomNames {
      if labels.removeValue(forKey: TerminalTarget.workroomID(project: path, name: name)) != nil {
        changed = true
      }
    }
    if changed { Defaults[.workroomLabels] = labels }
  }

  /// The name to show for a workroom referenced only by `SidebarID`/name (the tab chip and window
  /// title, which never hold the `Workroom` value). Resolves through the enriched model so there's a
  /// single read path, falling back to the real `name` when the workroom isn't in `projects` yet
  /// (a mid-reload race) — mirroring `windowTitle`'s own fallback.
  func displayName(forWorkroom name: String, inProject path: String) -> String {
    projects.first { $0.id == path }?.workrooms.first { $0.id == name }?.displayName ?? name
  }

  /// Set (or, for a blank value, remove) a workroom's display label (issue #41). Normalises at the
  /// write boundary so the stored value is always trimmed and non-empty — `displayName`'s guard is
  /// then just defense-in-depth. App-only: writes `Defaults` and rebuilds the one affected project in
  /// the shared `projects`, so every window re-renders instantly with no CLI call and without running
  /// the heavyweight `apply` (which would needlessly re-validate selection and prune splits).
  func setWorkroomLabel(_ workroom: Workroom, in project: Project, to raw: String) {
    let key = TerminalTarget.workroomID(project: project.path, name: workroom.name)
    var labels = Defaults[.workroomLabels]
    if let normalized = Workroom.normalizedLabel(raw) {
      labels[key] = normalized
    } else {
      // Blank input means "no label". The sheet disables submit on blank, so this branch is reached
      // only via `removeWorkroomLabel` (or defensively) — removal is the explicit menu action.
      labels[key] = nil
    }
    Defaults[.workroomLabels] = labels
    relabelLocally(workroom.name, in: project.path, to: labels[key])
  }

  /// Remove a workroom's display label, restoring its real name everywhere. Raised by the
  /// "Remove Label" context-menu item.
  func removeWorkroomLabel(_ workroom: Workroom, in project: Project) {
    setWorkroomLabel(workroom, in: project, to: "")
  }

  /// Targeted single-workroom rebuild of the shared `projects` (mirrors `removeWorkroomLocally`):
  /// replace just the one workroom with a copy carrying the new label, leaving sort order, selection,
  /// and splits untouched (a label never changes any of them). `internal` so store tests can drive it.
  func relabelLocally(_ name: String, in projectPath: String, to label: String?) {
    guard let pIdx = projects.firstIndex(where: { $0.id == projectPath }),
      let wIdx = projects[pIdx].workrooms.firstIndex(where: { $0.id == name })
    else { return }
    var workrooms = projects[pIdx].workrooms
    var wr = workrooms[wIdx]
    wr.label = label
    workrooms[wIdx] = wr
    let p = projects[pIdx]
    projects[pIdx] = Project(path: p.path, vcs: p.vcs, workrooms: workrooms)
  }

  /// Teardown failed (it ran in the background): pop an alert carrying the captured
  /// script output so the user can see why.
  private func presentTeardownFailure(_ workroom: Workroom, error: Error, log: ScriptLogSession) {
    let output = log.lines.map(\.text).joined(separator: "\n").trimmingCharacters(
      in: .whitespacesAndNewlines)
    errorTitle = "Teardown of ‘\(workroom.name)’ failed"
    errorMessage = output.isEmpty ? errorText(error) : output
  }

  /// Removes a project from the sidebar immediately, then runs the chosen `scope` in the
  /// background. Mirrors `deleteWorkroom`: optimistic removal + scoped selection/split/status
  /// cleanup, then graceful run-stop → in-app reap → CLI.
  ///
  /// - `.configOnly`: drop from config only; nothing on disk is touched.
  /// - `.workrooms`: also hard-delete every workroom's worktree dir (branches kept) — unchanged.
  /// - `.fromDisk`: the CLI runs teardowns + drops config and returns the directories
  ///   (project root + workrooms); the app then moves them to the **Bin** (issue #108).
  ///
  /// Failure handling differs by phase: if the CLI throws (teardown/guard failure, or a
  /// config-only/workrooms delete failure) the config was NOT changed, so we `reload()` (the
  /// project reappears if it still exists) and surface the error. For `.fromDisk`, once the CLI
  /// returns the config is already dropped — a subsequent Trash failure leaves the project removed
  /// and is reported on its own (we do NOT restore it), listing the dirs left behind.
  func deleteProject(_ project: Project, scope: DeleteProjectScope) {
    let targetIDs = removeProjectLocally(project)
    let stores = affectedStores
    // Clear the project's targets (root + each workroom) from every OTHER window's split + selection
    // too — `removeProjectLocally` only cleaned up this window (issue #70, OV #7).
    let sids =
      [SidebarID.root(project: project.path)]
      + project.workrooms.map { SidebarID.workroom(project: project.path, name: $0.name) }
    for store in stores where store !== self {
      for sid in sids { store.detachTarget(sid) }
    }

    // ALWAYS stop runs in every window BEFORE any disk teardown so no dev server holds a deleted dir
    // (issue #7/#70), then reap each target in every window, then run the CLI teardown once.
    stopRunsAcrossWindows(targetIDs, stores: stores) { [weak self] in
      guard let self else { return }
      for store in stores { for id in targetIDs { store.reapTargetLocally(id) } }
      Task {
        let log =
          scope == .configOnly
          ? nil : ScriptLogSession(title: "Deleting \(project.displayName)", phase: "teardown")
        do {
          let trashPaths = try await self.cli.deleteProject(
            project.path,
            withWorkrooms: scope == .workrooms,
            fromDisk: scope == .fromDisk
          ) { text in DispatchQueue.main.async { log?.append(text) } }
          if scope == .fromDisk {
            // CLI already ran teardowns + dropped config; move the returned dirs to the Bin.
            let failed = self.trashToBin(trashPaths)
            if !failed.isEmpty { self.presentTrashFailure(project, failedPaths: failed) }
          }
        } catch {
          await self.reload()
          self.presentDeleteProjectFailure(project, error: error, log: log)
        }
      }
    }
  }

  /// Moves each path to the Bin via the injected `trasher`, returning the URLs that could NOT be
  /// moved so the caller can tell the user exactly what was left behind. The project is already
  /// out of config by this point (the CLI dropped it), so a partial failure does not restore it.
  /// Internal (not private) so the from-disk trash orchestration is unit-testable with a fake.
  func trashToBin(_ urls: [URL]) -> [URL] {
    var failed: [URL] = []
    for url in urls {
      do { try trasher.trash(url) } catch { failed.append(url) }
    }
    return failed
  }

  /// A from-disk delete dropped the project from config but some directories could not be moved to
  /// the Bin. Report which ones so the user can move them manually (they are not lost).
  func presentTrashFailure(_ project: Project, failedPaths: [URL]) {
    let list = failedPaths.map(\.path).joined(separator: "\n")
    errorTitle = "Some files of ‘\(project.displayName)’ could not be moved to the Bin"
    errorMessage =
      "‘\(project.displayName)’ was removed from Workroom, but these could not be moved to the "
      + "Bin — move them manually:\n\(list)"
  }

  /// Optimistic, synchronous removal of a project from every piece of in-memory state — the
  /// sidebar model, selection (project + target), the workroom split, and statuses. Returns
  /// every `TerminalTarget.ID` the project owns (its root + each workroom) so the caller can
  /// reap them once runs have stopped. Pure model mutation: NO CLI, disk, or config access, so
  /// it is safe to unit-test directly. An in-flight status sweep is already guarded
  /// (`targetExists` checks `projects`), so dropping the project here also stops a slow probe
  /// from repopulating these entries.
  @discardableResult
  func removeProjectLocally(_ project: Project) -> [TerminalTarget.ID] {
    let targetIDs =
      [TerminalTarget.rootID(project: project.path)]
      + project.workrooms.map { TerminalTarget.workroomID(project: project.path, name: $0.name) }

    projects.removeAll { $0.id == project.id }
    if selectedProjectID == project.id { selectedProjectID = nil }
    // Clear selection if it pointed anywhere inside this project (its root or any workroom).
    if let sel = selectedTargetID, sel.belongsToProject(project.path) { selectedTargetID = nil }
    removeWorkroomSplitMember(.root(project: project.path))
    workroomStatuses[.root(project: project.path)] = nil
    for w in project.workrooms {
      removeWorkroomSplitMember(.workroom(project: project.path, name: w.name))
      workroomStatuses[.workroom(project: project.path, name: w.name)] = nil
    }
    // Drop every label belonging to this project's workrooms (issue #41) — prune-on-load is the
    // backstop, but clearing here keeps it immediate and prevents a same-named recreate from
    // inheriting a stale label.
    forgetLabels(forProject: project.path, workroomNames: project.workrooms.map(\.name))
    // Drop any pending sheet targeting this project — otherwise its Save path (e.g.
    // setRunConfig(forProject:)) still fires for the now-deleted path, and a later re-add of the
    // same path would silently inherit the stale config (#127 follow-up).
    if pendingProjectSettings?.project.path == project.path { pendingProjectSettings = nil }
    if pendingWorkroomLabel?.project.path == project.path { pendingWorkroomLabel = nil }
    return targetIDs
  }

  /// Project deletion failed in the background: pop an alert carrying any captured cascade
  /// teardown output. `log` is nil for a config-only delete (no teardown ran), in which case
  /// the error's own message is shown.
  private func presentDeleteProjectFailure(
    _ project: Project, error: Error, log: ScriptLogSession?
  ) {
    let output = (log?.lines.map(\.text).joined(separator: "\n") ?? "").trimmingCharacters(
      in: .whitespacesAndNewlines)
    errorTitle = "Delete of ‘\(project.displayName)’ failed"
    errorMessage = output.isEmpty ? errorText(error) : output
  }

  private func errorText(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  // MARK: Menu-command convenience

  /// Open a new terminal tab in the selected target — root or workroom (⌘T).
  func newTerminalInSelectedTarget() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.addTab(for: target)
  }

  /// Close the active terminal tab in the selected target (⌘W).
  func closeCurrentTerminalTab() {
    guard let target = selectedTarget,
      let active = terminals.activeTab(for: target)
    else { return }
    requestCloseTerminalTab(active.id, for: target)
  }

  /// Set while a close-confirm alert is queued/showing, so a double fire (a fast second ⌘W, or
  /// toolbar/menu/context "Close all" pressed twice before the deferred alert appears) can't stack
  /// modals over a now-stale victim list.
  private var isPresentingCloseConfirm = false

  /// Close a terminal tab, confirming first when `confirmOnCloseTerminal` is on (the default). The
  /// tab-strip ✕ and the ⌘W command both route through here, so the confirmation — and its "Don't
  /// ask me again" suppression — lives in one place (`confirmCloseThen`). Closing a terminal kills
  /// its shell and anything running in it with no undo, so the alert mirrors the quit confirmation.
  func requestCloseTerminalTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let tab = terminals.tabs(for: target).first(where: { $0.id == tabID }) else { return }
    guard closeNeedsConfirm([tab]) else {
      performClose([tabID], for: target)
      return
    }
    confirmCloseThen(count: 1, title: tab.title) { [weak self] in
      self?.performClose([tabID], for: target)
    }
  }

  /// Close every tab in `target` (the tab strip's "Close all" / File ▸ "Close All Tabs"), confirming
  /// once if any has a live process. No-op when the target has no tabs.
  func requestCloseAllTerminalTabs(for target: TerminalTarget) {
    let victims = terminals.tabs(for: target).map(\.id)
    guard !victims.isEmpty else { return }
    requestClose(victims, for: target, keep: nil)
  }

  /// Close a workroom (or root) and all its terminal tabs — the tab bar's "Close" context-menu item,
  /// confirmed first via `pendingWorkroomClose`. Skips the per-tab `closeNeedsConfirm` prompt (the
  /// close-the-whole-workroom confirmation already covered it), then tears every tab down through the
  /// shared `performClose` (graceful run-command stop included). Once the last tab closes the chip
  /// leaves the bar. The workroom's files are untouched — that's `deleteWorkroom`. No-op if empty.
  func closeWorkroom(for target: TerminalTarget) {
    let victims = terminals.tabs(for: target).map(\.id)
    guard !victims.isEmpty else { return }
    performClose(victims, for: target)
  }

  /// The `(workroom, project)` a workroom `SidebarID` points at, or nil for a root/project id or a
  /// since-removed workroom. Lets the tab bar's context menu raise the same delete confirm the
  /// sidebar does without re-deriving the lookup.
  func workroomAndProject(for sid: SidebarID) -> (workroom: Workroom, project: Project)? {
    guard case .workroom(let path, let name) = sid,
      let project = projects.first(where: { $0.id == path }),
      let workroom = project.workrooms.first(where: { $0.id == name })
    else { return nil }
    return (workroom, project)
  }

  /// Close every tab in `target` except `keepID` ("Close others"), confirming once if any victim has
  /// a live process. No-op when there's nothing else to close.
  func requestCloseOtherTerminalTabs(_ keepID: TerminalTab.ID, for target: TerminalTarget) {
    let victims = terminals.tabs(for: target).map(\.id).filter { $0 != keepID }
    guard !victims.isEmpty else { return }
    requestClose(victims, for: target, keep: keepID)
  }

  /// Shared bulk-close core: confirm once (if needed), then `select` the kept tab so focus lands
  /// there, then tear the victims down. Selecting `keep` *before* closing means none of the victims
  /// is focused when it closes, so a victim's `closeTab` never fights the kept-tab selection — and a
  /// later async run-tab close (Ctrl-C + wait) can't steal focus back either (the run tab isn't
  /// focused). `keep == nil` for "Close all" (target ends empty).
  private func requestClose(
    _ victims: [TerminalTab.ID], for target: TerminalTarget, keep: TerminalTab.ID?
  ) {
    let tabs = terminals.tabs(for: target).filter { victims.contains($0.id) }
    let proceed: () -> Void = { [weak self] in
      guard let self else { return }
      if let keep { self.terminals.select(keep, for: target) }
      self.performClose(victims, for: target)
    }
    if closeNeedsConfirm(tabs) {
      confirmCloseThen(count: victims.count, title: nil, then: proceed)
    } else {
      proceed()
    }
  }

  /// Close-all for the selected target (File ▸ "Close All Tabs").
  func closeAllTerminalTabsInSelectedTarget() {
    guard let target = selectedTarget else { return }
    requestCloseAllTerminalTabs(for: target)
  }

  /// Close-others for the selected target's active tab (File ▸ "Close Other Tabs").
  func closeOtherTerminalTabsInSelectedTarget() {
    guard let target = selectedTarget, let active = terminals.activeTab(for: target) else { return }
    requestCloseOtherTerminalTabs(active.id, for: target)
  }

  /// Test seam: pin whether a close prompts, per store, instead of writing the shared
  /// `confirmOnCloseTerminal` setting. `nil` (production) reads the real setting.
  ///
  /// Close-behaviour tests need the confirm **off** (an AppKit modal isn't unit-testable), but the
  /// obvious way to get that — writing the `Defaults` key — is not test-local: `-parallel-testing`
  /// gives each worker its own host process and they all share ONE UserDefaults domain, so one class
  /// flipping the key lands inside another class's body and turns its close into a modal. That was a
  /// roughly 1-in-4 red suite whose victim moved between runs. This override is per-`AppStore`, so it
  /// cannot leak across workers; `ConfirmOnCloseTerminalTests` still asserts on the real key, and is
  /// now its only writer.
  var confirmOnCloseOverrideForTesting: Bool?

  /// Whether closing `tabs` needs the confirm modal: the setting is on, we're not in a UI-test
  /// fixture (those close synchronously so teardown never blocks on an alert — the launch-arg
  /// override can't reliably reach a Defaults Bool), and at least one tab still has a live process
  /// to lose. A content/diff tab has no surface and an exited run tab has nothing running, so a
  /// `?? true` ("has exited") batch of only those never prompts (issue #7).
  private func closeNeedsConfirm(_ tabs: [TerminalTab]) -> Bool {
    Self.resolveConfirmOnClose(override: confirmOnCloseOverrideForTesting)
      && !UITestFixture.isActive
      && tabs.contains { !($0.surface?.processHasExited ?? true) }
  }

  /// The override-or-setting half of `closeNeedsConfirm`, lifted out as a pure static so it can be
  /// pinned without a store.
  ///
  /// It needs its own test because the seam above hid the setting: once every close-behaviour class
  /// injects `confirmOnCloseOverrideForTesting`, NO test reaches the `Defaults` side any more, and
  /// changing this to `?? false` would leave the whole unit suite green while the shipped "Confirm
  /// before closing a terminal" checkbox silently stopped working. Pinning it here rather than
  /// through an `AppStore` is deliberate: `ConfirmOnCloseTerminalTests` is the only writer of the
  /// shared key, and keeping it that way is what makes the parallel workers safe (see the override's
  /// doc above).
  /// `nonisolated` because it touches no actor state — just its argument and a `Defaults` read — so
  /// the test above doesn't have to hop onto the main actor to ask what the setting resolves to.
  nonisolated static func resolveConfirmOnClose(override: Bool?) -> Bool {
    override ?? Defaults[.confirmOnCloseTerminal]
  }

  /// Tear down a set of tabs for a target. Each live run command is stopped gracefully (Ctrl-C +
  /// wait) before its surface is freed, so the dev server exits cleanly rather than being orphaned
  /// by the bare hangup (issue #7); non-run / exited / content tabs close immediately. UI-test
  /// fixture mode closes synchronously (teardown must not block). `closeTab` itself tears down each
  /// surface and closes any detached window, so this never orphans a window or leaks a PTY.
  private func performClose(_ tabIDs: [TerminalTab.ID], for target: TerminalTarget) {
    for id in tabIDs {
      if UITestFixture.isActive {
        terminals.closeTab(id, for: target)
      } else {
        closingRunTab(id, for: target.id) { [weak self] in
          self?.terminals.closeTab(id, for: target)
        }
      }
    }
  }

  /// Confirm closing `count` tab(s), then run `proceed` on confirm. Owns the modal: a window-modal
  /// sheet attached to the key window, the "Don't ask me again" suppression (writes the same
  /// `confirmOnCloseTerminal` key the Settings checkbox and File-menu toggle bind to), and
  /// singular/plural copy. Says "tab(s)", not "terminal", because diff/content tabs close through
  /// here too. Callers decide *whether* a confirm is needed (`closeNeedsConfirm`) — it can't be
  /// inferred from `count`. Guarded against reentrant double fire.
  ///
  /// A *sheet* (not a free-floating `runModal()` alert) is what makes the confirming Return reliable:
  /// the sheet is hosted by a window that's already key, so its default "Close" button owns Return
  /// with no race. The old app-modal alert had to *become* key after `runModal()` spun up, which lost
  /// the keystroke whenever the triggering event (the ⌘W key-equivalent / the ✕'s mouse tracking) was
  /// still draining; deferring the alert one runloop tick narrowed that window but couldn't close it,
  /// so Return was still dropped intermittently (issues #54, #100). We still defer one tick so the
  /// triggering event unwinds before the sheet drops, then fall back to an app-modal alert only when
  /// there's no window to host the sheet.
  private func confirmCloseThen(count: Int, title: String?, then proceed: @escaping () -> Void) {
    guard !isPresentingCloseConfirm else { return }
    isPresentingCloseConfirm = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let alert = NSAlert()
      alert.messageText =
        count == 1 ? "Close ‘\(title ?? "this tab")’?" : "Close \(count) tabs?"
      alert.informativeText =
        count == 1
        ? "Closing this tab stops any process running in it."
        : "Closing these tabs stops any processes running in them."
      alert.addButton(withTitle: "Close")
      alert.addButton(withTitle: "Cancel")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Don't ask me again"
      // Shared resolution for both the sheet and the no-window fallback: clear the reentrancy guard,
      // honour "Don't ask me again", and proceed only on the default Close button.
      let resolve: (NSApplication.ModalResponse) -> Void = { [weak self] response in
        guard let self else { return }
        self.isPresentingCloseConfirm = false
        if alert.suppressionButton?.state == .on {
          Defaults[.confirmOnCloseTerminal] = false
        }
        if response == .alertFirstButtonReturn { proceed() }
      }
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        alert.beginSheetModal(for: window, completionHandler: resolve)
      } else {
        resolve(alert.runModal())
      }
    }
  }

  /// Focus the terminal tab at `index` (0-based, left-to-right across solo + split panes) in the
  /// selected target (⌘1…⌘9). No-ops if there's no tab at that position.
  func focusTerminalTab(at index: Int) {
    guard let target = selectedTarget else { return }
    let tabs = terminals.tabs(for: target)
    guard tabs.indices.contains(index) else { return }
    terminals.select(tabs[index].id, for: target)
  }

  /// Switch to the next (`forward`) or previous terminal tab in the selected target, wrapping at the
  /// ends — bound to ⌥⌘→ / ⌥⌘← (issue #29). Returns whether it switched, so the AppDelegate monitor
  /// consumes the key in the monitor only when there's more than one tab (a no-op otherwise — the
  /// key is reserved in `isAppShortcut` either way, so it never reaches the terminal).
  @discardableResult
  func cycleTerminalTab(forward: Bool) -> Bool {
    guard let target = selectedTarget else { return false }
    let tabs = terminals.tabs(for: target)
    guard tabs.count > 1 else { return false }
    let current =
      terminals.activeTab(for: target).flatMap { active in
        tabs.firstIndex(where: { $0.id == active.id })
      } ?? 0
    let next = (current + (forward ? 1 : -1) + tabs.count) % tabs.count
    terminals.select(tabs[next].id, for: target)
    return true
  }

  // MARK: Diff content tabs (issue #66)

  /// Open a changed file as a diff in the selected workroom's tab strip, in preview mode
  /// (single-click in the Changes panel). `source` is the row's group — git worktree, jj `@`, or jj
  /// `@-` — so the diff resolves against the right revision. No-op if nothing's selected.
  func openDiffPreview(_ file: ChangedFile, source: DiffSource) {
    guard let target = selectedTarget else { return }
    terminals.openDiffPreview(
      DiffDescriptor(path: file.path, change: file.change, source: source, isPreview: true),
      for: target)
  }

  /// Open a changed file as a *persisted* diff tab (double-click in the Changes panel) — skips
  /// preview mode. No-op if nothing's selected.
  func openDiffPersistent(_ file: ChangedFile, source: DiffSource) {
    guard let target = selectedTarget else { return }
    terminals.openDiffPersistent(
      DiffDescriptor(path: file.path, change: file.change, source: source, isPreview: false),
      for: target)
  }

  /// Open a repo file as the selected target's single PREVIEW content tab (single-click in the Files
  /// inspector section), read-only. Shares the preview slot with diffs. No-op if nothing's selected.
  func openFilePreview(path: String) {
    guard let target = selectedTarget else { return }
    terminals.openFilePreview(FileDescriptor(path: path, isPreview: true), for: target)
  }

  /// Open a repo file as a *persisted* content tab (double-click in the Files section). No-op if
  /// nothing's selected.
  func openFilePersistent(path: String) {
    guard let target = selectedTarget else { return }
    terminals.openFilePersistent(FileDescriptor(path: path, isPreview: false), for: target)
  }

  /// Open a commit's changeset detail as the selected target's single PREVIEW content tab
  /// (single-click a History row, issue #59). Shares the preview slot with diffs/files. No-op if
  /// nothing's selected.
  func openChangesetPreview(commitID: String, title: String) {
    guard let target = selectedTarget else { return }
    terminals.openContentPreview(
      ChangesetDescriptor(commitID: commitID, title: title, isPreview: true), for: target)
    // Retargeting the preview tab fires no focus change, so record the commit view explicitly (a
    // dedup collapses the double when a genuine focus change also recorded it).
    if !isNavigatingHistory { recordCurrentLocation() }
  }

  /// Open a commit's changeset detail as a *persisted* content tab (double-click a History row).
  /// No-op if nothing's selected.
  func openChangesetPersistent(commitID: String, title: String) {
    guard let target = selectedTarget else { return }
    terminals.openContentPersistent(
      ChangesetDescriptor(commitID: commitID, title: title, isPreview: false), for: target)
    if !isNavigatingHistory { recordCurrentLocation() }
  }

  /// Select a file within a changeset tab (a tap in the History detail's file list). Updates the tab
  /// so `ChangesetDetailView` shows that file's diff (no reload — its `.task` keys on the commit),
  /// and records a back/forward step, so each in-commit file selection is its own step. Records only
  /// when this changeset is the active (focused) location, to avoid a wrong-tab entry.
  func selectChangesetFile(_ path: String, tab tabID: TerminalTab.ID, in target: TerminalTarget) {
    guard case .changeset(let d)? = terminals.tab(tabID, for: target)?.content,
      d.selectedPath != path
    else { return }
    terminals.setChangesetSelectedPath(path, forTab: tabID, in: target)
    if !isNavigatingHistory, terminals.focusedTab(for: target)?.id == tabID {
      recordCurrentLocation()
    }
  }

  /// Open a repo file in the configured external editor (⌘-click / context menu in the Files
  /// section), reusing the shared editor path. No-op if nothing's selected.
  func openFileInEditor(path: String) {
    guard let target = selectedTarget else { return }
    openWorkroomFile(relativePath: path, for: target)
  }

  /// Open a workroom-relative file in the configured "Open file paths in" editor — the single path
  /// resolution shared by `openDiffTabFile` (#72) and `openChangedFileInEditor` (#93). Reuses
  /// `TerminalLinkOpener`, so it honours `Defaults[.filePathEditor]`; for a folder-capable editor CLI
  /// (VS Code/Zed/Xcode) the file opens *inside* the workroom folder window, while the default-app
  /// fallback just opens the file (no folder/window targeting). Fire-and-forget; a missing file
  /// no-ops in `openFilePath`.
  private func openWorkroomFile(relativePath: String, for target: TerminalTarget) {
    let absPath = (target.path as NSString).appendingPathComponent(relativePath)
    TerminalLinkOpener.openFilePath(absPath, cwd: nil, project: target.path)
  }

  /// Open a diff tab's underlying file in the configured editor (the tab toolbar / context-menu
  /// "Open file in…", issue #72). Caller disables this for a deleted-source diff (the working file
  /// is gone — `DiffDescriptor.change == .deleted`); for a jj `@-` diff it opens the working copy,
  /// which may differ from the displayed parent revision (editing the live file is the useful action).
  func openDiffTabFile(_ descriptor: DiffDescriptor, for target: TerminalTarget) {
    openWorkroomFile(relativePath: descriptor.path, for: target)
  }

  /// Open a changed file's working copy in the configured editor — the Changes-panel row's ⌘-click
  /// and the row context-menu "Open File in …" (issue #93). No-op when nothing's selected or the
  /// file was deleted (no working file to open — see `resolveOpenTarget`).
  func openChangedFileInEditor(_ file: ChangedFile) {
    guard let target = selectedTarget, let rel = Self.resolveOpenTarget(file: file) else { return }
    openWorkroomFile(relativePath: rel, for: target)
  }

  /// Open a changed file's working copy in the in-app viewer as a preview tab — the Changes-panel
  /// hover-toolbar button and the row context-menu "Open File" (issue #117). No-op when nothing's
  /// selected or the file was deleted (no working copy — see `resolveOpenTarget`). Shares the single
  /// preview slot with diffs, so it recycles the row's diff preview (a persisted diff tab is kept).
  func openChangedFileInApp(_ file: ChangedFile) {
    guard let rel = Self.resolveOpenTarget(file: file) else { return }
    openFilePreview(path: rel)
  }

  /// The repo-relative path to open for a changed file, or nil when there's nothing to open (a
  /// deleted source — the working file is gone). `nonisolated` + pure so the open decision is
  /// unit-testable from a synchronous context, without the side-effecting opener (issue #93).
  nonisolated static func resolveOpenTarget(file: ChangedFile) -> String? {
    file.change == .deleted ? nil : file.path
  }

  /// The focused pane's surface for the selected target (the focused tab is the focused pane), or nil
  /// when nothing's selected / no terminal exists. Drives the Go menu's scroll items (issue #42).
  private var focusedSurface: GhosttySurfaceView? {
    guard let target = selectedTarget else { return nil }
    return terminals.focusedTab(for: target)?.surface
  }

  /// Scroll the focused terminal to the top / bottom of its scrollback (issue #42). Driven by the Go
  /// menu's "Scroll to Top"/"Scroll to Bottom" items; ⌘↑/⌘↓ also reach the surface directly.
  func scrollFocusedTerminalToTop() { focusedSurface?.scrollToTop() }
  func scrollFocusedTerminalToBottom() { focusedSurface?.scrollToBottom() }

  /// Open the find bar on the focused pane (⌘F / Edit ▸ Find): the terminal's scrollback search for a
  /// terminal pane, the in-file find for a file pane. A diff pane has no find (no-op).
  func startFindInFocusedPane() {
    guard let target = selectedTarget, let tab = terminals.focusedTab(for: target) else { return }
    switch tab.content {
    case .terminal: focusedSurface?.startSearch()
    case .file: fileFind.open()
    case .diff, .changeset: break
    }
  }

  /// Navigate the focused pane's *active* find to the next/previous match (⌘G / ⇧⌘G), wrapping at the
  /// ends. Tries the terminal search, then the in-file find. Returns `false` (so the key passes
  /// through to the terminal) when neither is open. `@discardableResult` for the menu-button call site.
  @discardableResult
  func navigateFocusedPaneSearch(forward: Bool) -> Bool {
    if let surface = focusedSurface, surface.searchModel.isActive {
      surface.searchModel.navigate(forward ? .next : .previous)
      return true
    }
    // Only when a file pane is actually focused: the find model is shared, so a stale open state
    // must not let ⌘G step a hidden file find from a terminal/diff pane (review). `onFocusChange`
    // already closes it on focus-away; this is the defence-in-depth read-side check.
    if let target = selectedTarget, let tab = terminals.focusedTab(for: target),
      case .file = tab.content, fileFind.isOpen, fileFind.hasMatches
    {
      forward ? fileFind.next() : fileFind.previous()
      return true
    }
    return false
  }

  /// Split the focused pane by opening a new terminal beside it: ⌘D to the right, ⇧⌘D below
  /// (issue #3). The new terminal inherits the focused pane's working directory.
  func splitFocusedRight() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.splitFocusedPane(for: target, orientation: .horizontal)
  }

  func splitFocusedDown() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.splitFocusedPane(for: target, edge: .bottom)
  }

  func splitFocusedLeft() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.splitFocusedPane(for: target, edge: .left)
  }

  func splitFocusedUp() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.splitFocusedPane(for: target, edge: .top)
  }

  /// Resize the focused target's terminal split so every pane is the same size (issue #83). Driven by
  /// View ▸ "Resize Splits Evenly"; the menu item is disabled unless a terminal split is visible.
  func equalizeFocusedSplit() {
    guard let target = selectedTarget else { return }
    terminals.equalizeSplit(for: target)
  }

  /// Move keyboard focus to the adjacent pane in a split (⌃⌘arrows). Returns whether focus moved, so
  /// the key monitor passes the event through to the terminal when there's no pane that way.
  @discardableResult
  func focusPane(_ direction: PaneDirection) -> Bool {
    guard let target = selectedTarget else { return false }
    return terminals.focusAdjacentPane(direction, for: target)
  }

  // MARK: Navigation history (issue #26)

  /// Whether back/forward can move. Cursor-based (D2): liveness is validated when stepping, so a
  /// button can be enabled yet no-op in the rare case where every entry that way is dead.
  var canGoBack: Bool { history.canGoBack }
  var canGoForward: Bool { history.canGoForward }

  /// Record the on-screen location (selected target + its focused tab) into history. No-op while
  /// replaying (guarded at the call sites) and when there's no focused terminal yet — so a switch to
  /// a never-visited target records nothing until its first terminal exists, and the later
  /// `addTab`→`onFocusChange` records the real first entry (no `(target, nil)` ghost).
  private func recordCurrentLocation() {
    guard let sid = selectedTargetID, let target = selectedTarget, !target.isMissing,
      let tab = terminals.focusedTab(for: target)
    else { return }
    history.record(Self.location(target: sid, tab: tab))
  }

  /// Build a `NavLocation` from a focused tab, capturing the content selection (commit + file) so
  /// back/forward can restore not just which tab, but which commit's changeset and which file within
  /// it were on screen (issue: commit browser).
  private static func location(target sid: SidebarID, tab: TerminalTab) -> NavLocation {
    switch tab.content {
    case .changeset(let d):
      return NavLocation(
        target: sid, tab: tab.id, commitID: d.commitID, commitTitle: d.title,
        filePath: d.selectedPath)
    case .diff(let d):
      return NavLocation(target: sid, tab: tab.id, filePath: d.path)
    default:
      return NavLocation(target: sid, tab: tab.id)
    }
  }

  /// Go back one step, skipping entries whose target/tab no longer exist (D2). No-op when there's no
  /// live earlier location.
  func navigateBack() {
    if let loc = history.step(-1, isLive: isLive) { applyLocation(loc, recordHistory: false) }
  }

  /// Go forward one step (mirrors `navigateBack`).
  func navigateForward() {
    if let loc = history.step(+1, isLive: isLive) { applyLocation(loc, recordHistory: false) }
  }

  /// The single primitive for "go to (target, tab)": used by back/forward replay and by
  /// `openTerminal` (notification / ⇧⌘N). Sets the selection + focuses the tab with history recording
  /// suppressed (the `didSet`/`onFocusChange` seams no-op via `isNavigatingHistory`), then records
  /// exactly one entry when `recordHistory` is true — so a jump never leaves a phantom intermediate
  /// entry. `tab` is optional (an old notification may carry none / a stale id); it resolves to the
  /// requested tab when it still exists, else the target's current focused tab.
  private func applyLocation(target sid: SidebarID, tab tabID: TerminalTab.ID?, recordHistory: Bool)
  {
    isNavigatingHistory = true
    defer { isNavigatingHistory = false }
    selectedProjectID = Self.projectPath(of: sid)
    selectedTargetID = sid
    guard let target = selectedTarget, !target.isMissing else { return }
    let resolved =
      tabID.flatMap { id in terminals.tabs(for: target).contains { $0.id == id } ? id : nil }
      ?? terminals.focusedTab(for: target)?.id
    guard let resolved else { return }
    terminals.focus(resolved, for: target)
    if recordHistory, let tab = terminals.tab(resolved, for: target) {
      history.record(Self.location(target: sid, tab: tab))
    }
  }

  /// Back/forward replay of a full `NavLocation`: select + focus its tab, then restore the recorded
  /// content selection. For a changeset, re-establish the recorded commit + file — the preview tab
  /// drifts as you browse (retargets record no focus change), so replay reopens the recorded commit
  /// there; a persisted tab already shows the right commit, so only its file is restored. All under
  /// `isNavigatingHistory`, so nothing re-records.
  private func applyLocation(_ loc: NavLocation, recordHistory: Bool) {
    applyLocation(target: loc.target, tab: loc.tab, recordHistory: recordHistory)
    guard let commitID = loc.commitID, let target = selectedTarget, !target.isMissing else {
      return
    }
    isNavigatingHistory = true
    defer { isNavigatingHistory = false }
    if let focused = terminals.focusedTab(for: target), case .changeset(let d) = focused.content,
      d.commitID == commitID
    {
      terminals.setChangesetSelectedPath(loc.filePath, forTab: focused.id, in: target)
    } else {
      terminals.openContentPreview(
        ChangesetDescriptor(
          commitID: commitID, title: loc.commitTitle ?? commitID, isPreview: true,
          selectedPath: loc.filePath),
        for: target)
    }
  }

  /// Whether a recorded location is still reachable: its target resolves to a live, non-missing
  /// target and the recorded tab still exists there. Skips dead entries (closed tab / deleted
  /// workroom) on back/forward.
  private func isLive(_ loc: NavLocation) -> Bool {
    guard let target = target(for: loc.target), !target.isMissing else { return false }
    return terminals.tabs(for: target).contains { $0.id == loc.tab }
  }

  // MARK: Sidebar terminal subtree (issue #30)

  /// Whether a target's terminal subtree is expanded in the sidebar.
  func isTerminalsExpanded(_ id: TerminalTarget.ID) -> Bool {
    expandedTerminalTargets.contains(id)
  }

  /// Toggle a target's terminal subtree open/closed (the disclosure chevron on its row).
  func toggleTerminals(for id: TerminalTarget.ID) {
    if expandedTerminalTargets.remove(id) == nil { expandedTerminalTargets.insert(id) }
  }

  /// Select a terminal's target and focus that terminal — the action behind tapping a terminal row
  /// in the sidebar subtree. Routes through the same `applyLocation` primitive as back/forward and
  /// notification jumps, so the selection + focus land together and record exactly one history entry.
  func revealTerminal(_ tabID: TerminalTab.ID, at sid: SidebarID) {
    applyLocation(target: sid, tab: tabID, recordHistory: true)
  }

  /// Open an existing root/workroom from the Open Workroom picker (⌘O, issue #94). Brings the app
  /// forward and selects + focuses the target through the same `applyLocation` primitive the
  /// notification path (`openTerminal`) uses — so an already-selected target just refocuses, and a
  /// target with no live tab still selects (the detail pane opens it). `tab: nil` lets
  /// `applyLocation` pick the target's current focused tab.
  func openExisting(_ sid: SidebarID) {
    NSApp.activate(ignoringOtherApps: true)
    applyLocation(target: sid, tab: nil, recordHistory: true)
  }

  // MARK: Notifications

  /// Whether a freshly-active on-screen pane should pulse its border. The *cursor* pane of the
  /// focused workroom never pulses — you're looking at it. A co-displayed NON-selected workroom is
  /// backgrounded/dimmed, so any of its on-screen panes pulses (issue #82). Pure + unit-tested.
  nonisolated static func shouldPulse(isOnScreen: Bool, isSelectedMember: Bool, isCursorTab: Bool)
    -> Bool
  {
    isOnScreen && (isSelectedMember ? !isCursorTab : true)
  }

  /// Whether the user is actively looking at this pane: the app is frontmost (this window is key)
  /// AND it's the cursor tab of the selected workroom. Only this one pane is "seen" — every other
  /// pane (off-screen, a non-cursor split-mate, or a co-displayed non-selected workroom) is unseen
  /// and notifies (issue #89). Pure + unit-tested (mirrors `shouldPulse` / `NotificationGate`).
  nonisolated static func isSeen(appFrontmost: Bool, isSelectedTarget: Bool, isCursorTab: Bool)
    -> Bool
  {
    appFrontmost && isSelectedTarget && isCursorTab
  }

  /// The full per-activity decision, composed from the pure parts so the whole matrix is unit-
  /// testable without `NSApp` (issue #89). Total over all four inputs. `record == false` ⇒ the
  /// event is suppressed (you're looking at that exact pane). `pulse` border-flashes an on-screen
  /// non-cursor pane to locate it (issue #82) — never the cursor pane (`shouldPulse` handles that),
  /// never while backgrounded (those get a banner, not a pulse). The `isOnScreen` guard on `seen`
  /// keeps it total: an off-screen tab always records, even if flagged selected + cursor.
  nonisolated static func activityOutcome(
    appFrontmost: Bool, isOnScreen: Bool, isSelectedMember: Bool, isCursorTab: Bool
  ) -> (pulse: Bool, record: Bool) {
    let seen =
      isOnScreen
      && isSeen(
        appFrontmost: appFrontmost, isSelectedTarget: isSelectedMember, isCursorTab: isCursorTab)
    let pulse =
      appFrontmost && isOnScreen
      && shouldPulse(
        isOnScreen: isOnScreen, isSelectedMember: isSelectedMember, isCursorTab: isCursorTab)
    return (pulse: pulse, record: !seen)
  }

  /// Record a terminal's activity, then surface it: backgrounded ⇒ a native banner; foregrounded ⇒
  /// an in-app toast (inspector closed) or a sidebar row flash (inspector open), plus the arrival
  /// sound (issue #31). `record` drops the event entirely when the user is already looking at that
  /// terminal, so none of these fire for the focused terminal.
  private func handleActivity(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, activity: TerminalActivity
  ) {
    // pane state (frontmost = THIS window is key)  → outcome
    //   selected + cursor                          → SEEN: suppress (you're looking at it)
    //   on-screen, not cursor (split-mate)         → pulse (locator) + notify
    //   off-screen                                 → notify (no pulse)
    //   backgrounded / another window key          → banner (no pulse)
    //
    // `seen` (suppress?) keys on `hostWindow?.isKeyWindow` — is THIS pane the one focused. The
    // banner-vs-in-app routing below keys on `NSApp.isActive` — is the APP frontmost at all. Two
    // different questions, deliberately different vocabulary: a frontmost-but-not-key window still
    // shows an in-app toast, never a banner. (`isKeyWindow` already implies the app is active.)
    // Per-window so a *non-key* window's selected cursor tab still notifies (issue #89, multi-window)
    // instead of being suppressed because some other window holds key.
    let appFrontmost = hostWindow?.isKeyWindow == true
    let onScreen = onScreenTarget(forID: targetID)
    let isSelectedMember = onScreen?.id == selectedTarget?.id
    let isCursorTab = onScreen.map { terminals.focusedTab(for: $0)?.id == tabID } ?? false
    let outcome = Self.activityOutcome(
      appFrontmost: appFrontmost, isOnScreen: onScreen != nil,
      isSelectedMember: isSelectedMember, isCursorTab: isCursorTab)
    if outcome.pulse { terminals.pulsePaneActivity(tabID) }
    guard outcome.record,
      let note = notifications.record(
        targetID: targetID, tabID: tabID, source: notificationSource(forTargetID: targetID),
        activity: activity, focused: false)
    else { return }
    if NotificationGate.shouldPresentInApp(recorded: true, appActive: NSApp.isActive) {
      // App is focused: sound on every arrival, then pop a toast. Notifications now live in the
      // always-visible left-sidebar strip + the title-bar bell badge (issue #118), so the transient
      // toast is the arrival signal regardless of what else is on screen. Previously this flashed the
      // notifications row when the *right* inspector was open/edge-revealed and only toasted otherwise
      // — that gating referenced a surface that no longer shows notifications, so a focused arrival
      // with the inspector open would have silently dropped.
      NotificationSound.play()
      enqueueToast(note)
    } else if NotificationGate.shouldPostBanner(recorded: true, appActive: NSApp.isActive) {
      Task { @MainActor in
        if await systemNotifier.ensureAuthorized() {
          systemNotifier.post(note)
        }
      }
    }
  }

  /// Append a toast for a freshly-recorded notification, dropping the oldest once past the cap
  /// (issue #31). `internal` so the queue behaviour is unit-testable without `NSApp`.
  func enqueueToast(_ note: WorkroomNotification) {
    toasts.append(note)
    if toasts.count > Self.maxToasts {
      toasts.removeFirst(toasts.count - Self.maxToasts)
    }
  }

  /// Remove a toast by id — on tap (after `openTerminal`), on auto-dismiss, or when its underlying
  /// notification is dismissed elsewhere (`ToastStack` prunes those).
  func dismissToast(_ id: UUID) { toasts.removeAll { $0.id == id } }

  /// The on-screen target for `targetID`, ignoring app/window activation (so it's unit-testable): the
  /// selected target, or — when a workroom split is shown — any co-displayed split member. The focused
  /// member is `selectedTarget`, but the *other* members render beside it (issue #23), so their
  /// terminals are equally on screen. `handleActivity` uses this to drive the on-screen border pulse
  /// (issue #82) for a visible non-cursor pane, and to tell an on-screen pane from an off-screen one
  /// when deciding whether the activity is "seen". nil if not shown.
  func onScreenTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget? {
    if let selected = selectedTarget, selected.id == targetID { return selected }
    guard isWorkroomSplitVisible, let leaves = resolvedSplitLeaves() else { return nil }
    return leaves.first { $0.target.id == targetID }?.target
  }

  /// Bring the app forward and select the terminal a notification came from, marking it read.
  /// Reused by both the native-banner click (AppDelegate) and the in-app panel tap. No-ops (and
  /// withdraws any stale banner) when the target/tab no longer exists.
  func openTerminal(targetID: TerminalTarget.ID, tabID: TerminalTab.ID?, notifID: UUID? = nil) {
    NSApp.activate(ignoringOtherApps: true)
    guard let sid = Self.sidebarID(forTargetID: targetID, in: projects) else {
      if let tabID { systemNotifier.withdraw(tabIDs: [tabID]) }
      return
    }
    // Jump to (target, tab) through the shared primitive: it selects the target, re-activates the
    // tab only if it still exists (it may have been closed/reaped since the banner was posted), and
    // records exactly one history entry — no phantom intermediate (issue #26).
    applyLocation(target: sid, tab: tabID, recordHistory: true)
    if let notifID {
      notifications.dismiss(notifID: notifID)
    } else if let tabID {
      notifications.dismiss(tab: tabID)
    }
  }

  /// Jump to the oldest pending notification's terminal and dismiss it (reusing the banner/panel
  /// `openTerminal` path). Since opening dismisses, repeated calls walk the backlog oldest→newest —
  /// the bottom of the inspector panel upward. No-op when there are none.
  func openOldestNotification() {
    guard let oldest = notifications.items.first else { return }
    openTerminal(targetID: oldest.targetID, tabID: oldest.tabID, notifID: oldest.id)
  }

  /// On app refocus, dismiss the notifications for the now-visible terminal (the selected target's
  /// active tab) — you're looking at it. Called from `RootView`'s `didBecomeActive` hook.
  func dismissFocusedTerminalNotifications() {
    guard let target = selectedTarget, let active = terminals.activeTab(for: target) else { return }
    notifications.dismiss(tab: active.id)
  }

  /// On app refocus, pull the History log fresh if the inspector is visible and on History — catches a
  /// commit made in an external terminal while the app was backgrounded (the live per-project metadata
  /// watcher may have been coalesced/idle across deactivation). Same visibility gate as the live
  /// trigger; cheap + cancel-and-replace. Called from `RootView`'s `didBecomeActive` hook.
  func refreshHistoryIfActive() {
    if inspectorIsVisible, activeInspectorSection == .history { commitHistory.refresh() }
  }

  /// Human-readable origin for a notification: the project name, plus the workroom for a
  /// workroom terminal (e.g. "platform" for a root, "platform / fix-auth" for a workroom).
  /// Resolved against the live projects (no string parsing of the id).
  func notificationSource(forTargetID id: TerminalTarget.ID) -> String {
    Self.notificationSource(forTargetID: id, in: projects)
  }

  /// Human-readable origin of a notification: the project name, or "project / workroom" for a
  /// workroom terminal, using the workroom's `displayName` so a set label shows here too (issue #41).
  /// Returns "" when the target isn't in `projects` (deleted) — callers fall back to the snapshot
  /// captured on the record. Pure + `nonisolated` so it's unit-testable, mirroring
  /// `sidebarID(forTargetID:in:)`.
  nonisolated static func notificationSource(
    forTargetID id: TerminalTarget.ID, in projects: [Project]
  )
    -> String
  {
    for p in projects {
      if TerminalTarget.rootID(project: p.path) == id { return p.displayName }
      for w in p.workrooms where TerminalTarget.workroomID(project: p.path, name: w.name) == id {
        return "\(p.displayName) / \(w.displayName)"
      }
    }
    return ""
  }

  /// Reverse a `TerminalTarget.ID` to its `SidebarID` by matching the live projects (robust to
  /// the `wr|project|name` delimiter — no string parsing). Pure + nonisolated so it's directly
  /// unit-testable, mirroring `validatedSelection`.
  nonisolated static func sidebarID(forTargetID id: TerminalTarget.ID, in projects: [Project])
    -> SidebarID?
  {
    for p in projects {
      if TerminalTarget.rootID(project: p.path) == id { return .root(project: p.path) }
      for w in p.workrooms where TerminalTarget.workroomID(project: p.path, name: w.name) == id {
        return .workroom(project: p.path, name: w.name)
      }
    }
    return nil
  }

  /// Encode a selectable target to its `TerminalTarget.ID` string for persistence (issue #14) —
  /// the inverse of `sidebarID(forTargetID:in:)`. `.project`/nil aren't selectable targets.
  // MARK: Global inspector layout (issue #24)

  /// Load the global inspector layout (collapse + pane weights) into the live state, or the default
  /// (all expanded, equal) when none is stored. Called once at launch — the layout is global, so it
  /// is deliberately NOT reloaded on workroom switches. Guarded so the resulting `didSet`s don't
  /// immediately persist the values back.
  func loadInspectorState() {
    let (collapsed, weights) = Self.reconcileInspectorState(
      Defaults[.inspectorLayout], sectionCount: InspectorSectionKind.allCases.count)
    isLoadingInspectorState = true
    changesSectionCollapsed = collapsed[0]
    filesSectionCollapsed = collapsed[1]
    prSectionCollapsed = collapsed[2]
    inspectorSizeWeights = weights
    isLoadingInspectorState = false
  }

  /// Reconcile a persisted inspector layout against the current section count. The count has changed
  /// twice — a Files section was added (3 → 4), then Notifications was removed (4 → 3, issue #118).
  /// Any layout whose element count doesn't match the current section count is discarded to the
  /// all-expanded / equal-weight default rather than mis-mapped onto the new ordering. `nonisolated`
  /// + pure so the migration is unit-testable without an `AppStore` / `Defaults` (issue #24).
  nonisolated static func reconcileInspectorState(
    _ state: InspectorPaneState, sectionCount count: Int
  ) -> (collapsed: [Bool], weights: [Double]) {
    let collapsed =
      state.collapsed.count == count ? state.collapsed : Array(repeating: false, count: count)
    let weights = state.weights.count == count ? state.weights : Array(repeating: 1.0, count: count)
    return (collapsed, weights)
  }

  /// Persist the live inspector layout to the global store. No-op while loading (so a load's `didSet`s
  /// don't write the values straight back).
  func persistInspectorState() {
    guard !isLoadingInspectorState else { return }
    Defaults[.inspectorLayout] = InspectorPaneState(
      collapsed: [
        changesSectionCollapsed, filesSectionCollapsed, prSectionCollapsed, false,
      ],
      weights: inspectorSizeWeights)
  }

  /// Record new pane weights reported by the inspector's `NSSplitView` after a divider drag, and
  /// persist them for the selected workroom.
  func updateInspectorSizeWeights(_ weights: [Double]) {
    guard weights.count == InspectorSectionKind.allCases.count, weights != inspectorSizeWeights
    else { return }
    inspectorSizeWeights = weights
    persistInspectorState()
  }

  /// Apply an activity-bar navigation action through the pure `ActivityBarReducer`. Writes the
  /// resulting pane visibility to `Defaults[.showInspector]` first, then **always** assigns
  /// `activeInspectorSection` (even when it doesn't change): `@Published` fires `objectWillChange`
  /// on every set, so this forces the bar + inspector to re-render synchronously on the click and
  /// read the freshly-written `showInspector` (which, as a bare `@Default`, invalidates async).
  func apply(_ action: ActivityBarReducer.Action) {
    let current = ActivityBarReducer.State(
      active: activeInspectorSection, visible: Defaults[.showInspector])
    let next = ActivityBarReducer.reduce(current, action)
    Defaults[.showInspector] = next.visible
    activeInspectorSection = next.active
  }

  nonisolated static func targetIDString(for id: SidebarID?) -> String? {
    switch id {
    case .root(let path): return TerminalTarget.rootID(project: path)
    case .workroom(let path, let name): return TerminalTarget.workroomID(project: path, name: name)
    case .project, .none: return nil
    }
  }

  /// The owning project path of any sidebar id (used to keep the New-Workroom context on the
  /// restored selection's project).
  nonisolated static func projectPath(of id: SidebarID?) -> String? {
    switch id {
    case .root(let path), .workroom(let path, _), .project(let path): return path
    case .none: return nil
    }
  }

  /// The display order of the workroom tabs (issue #23): the `persisted` order filtered to those still
  /// `active` (have ≥1 terminal), then any newly-active target not yet listed appended in a stable
  /// sorted order. Strictly follows terminal presence — a target with no terminal is never included.
  /// Pure + nonisolated for direct unit testing, mirroring `validatedSelection`.
  nonisolated static func orderedActiveTargets(
    persisted: [TerminalTarget.ID], active: Set<TerminalTarget.ID>
  ) -> [TerminalTarget.ID] {
    var result = persisted.filter { active.contains($0) }
    result.append(contentsOf: active.subtracting(Set(result)).sorted())
    return result
  }

  // MARK: Errors

  private func present(_ error: Error) {
    errorTitle = nil  // generic title
    errorMessage = errorText(error)
  }
}

/// Tracks a create-in-progress for the initiating window (issue #116). `session` streams setup
/// output into the dialog; `name`/`targetID` fill in when the CLI reports the workroom exists (the
/// provisional "Creating…" chip becomes the real named chip); `hasSetup` gates the dialog's
/// dismissal contract — a setup script keeps the Dismiss button and withholds the terminal, while a
/// no-setup create auto-dismisses. A value type: mutating a field republishes `AppStore.creation`.
struct WorkroomCreation {
  let session: ScriptLogSession
  let project: Project
  /// The CLI-generated workroom name, once the "created" event arrives (nil while still creating).
  var name: String?
  /// The mounted target id, once known — added to the workroom-tab active set so the real chip shows
  /// during setup, and matched by `isCreationBlocking` to withhold its terminal.
  var targetID: TerminalTarget.ID?
  /// Whether a setup script is (or was) running — set from the "created" event, and forced true on a
  /// post-create failure so the dialog stays up with a Dismiss button.
  var hasSetup = false
}

/// The live log for one create/delete run. Lines stream in from the CLI's NDJSON
/// stderr (see WorkroomCLI). A plain ObservableObject — all mutations happen on the
/// main thread (the store hops there before appending), so SwiftUI sees them safely.
final class ScriptLogSession: ObservableObject, Identifiable {
  let id = UUID()
  let title: String
  let phase: String
  @Published private(set) var lines: [LogLine] = []
  @Published private(set) var isFinished = false
  @Published private(set) var failureMessage: String?

  init(title: String, phase: String) {
    self.title = title
    self.phase = phase
  }

  func append(_ text: String) {
    lines.append(LogLine(index: lines.count, text: Self.stripANSI(text)))
  }

  func finish(failure: String? = nil) {
    failureMessage = failure
    isFinished = true
  }

  struct LogLine: Identifiable {
    let index: Int
    let text: String
    var id: Int { index }
  }

  /// Strips ANSI SGR/escape sequences (e.g. color codes a setup script emits) so the
  /// log renders as clean text.
  private static let ansiRegex = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*[A-Za-z]")
  static func stripANSI(_ s: String) -> String {
    guard let re = ansiRegex else { return s }
    return re.stringByReplacingMatches(
      in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
  }
}
