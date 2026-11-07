import AppKit
import Combine
import DaemonConnection
import Defaults
import Foundation
import SwiftUI
import WorkroomDomain
import WorkroomVCS

/// One window's state and actions. Production builds one store per window (issue #70); the
/// project data every window shares lives in `ProjectStore.shared`, its VCS status in
/// `VCSStatusService.shared`, and its workrooms' creates and deletes in `WorkroomLifecycle.shared`.
/// All CLI work is awaited (it runs off the main thread inside
/// WorkroomCLI), keeping the UI responsive.
@MainActor
@Observable
// `ObservableObject` stays only so the window root can hold the store in a `@StateObject`, which
// builds it once; a `@State` initial value is re-evaluated on every init of the view struct, and a
// throwaway `AppStore` registers with `WindowRegistry` and subscribes to its terminals. Nothing reads
// its `objectWillChange`: views and the menu commands (`@FocusedValue(AppStore.self)`) observe the
// store through Observation.
final class AppStore: ObservableObject {
  /// Shared, app-wide project data (issue #70). Holds the project list and what is identical across
  /// windows about it. Views take it from the environment and the store's code reads it here.
  let projectStore: ProjectStore
  /// The app's VCS status: every workroom's status, the sweep, and the writes in flight. Views take
  /// it from the environment and the store's code reads it here.
  let vcsStatus: VCSStatusService
  /// The app's workroom creates and deletes: every create's run, what is being created or deleted,
  /// and what either does to every window (ADR 0068). Views take it from the environment and the
  /// store's code reads it here.
  let lifecycle: WorkroomLifecycle
  /// Marks the saved session dirty on any pane change (issue #46). Hooking the publisher rather than
  /// the ~12 structural mutators in `TerminalPanes` is deliberate: a thirteenth mutation cannot be
  /// forgotten. It fires far more often than the session changes (every live title, every activity
  /// pulse), which the coordinator answers with coalescing plus an equality gate — the excluded
  /// fields make that chatter produce an identical document, so it costs a comparison, not a write.
  @ObservationIgnored private var sessionObservation: AnyCancellable?

  /// What this window reaches outside the app (ADR 0022): the process's `AppServices.current`
  /// unless the init was handed others. Tests stand fakes in its members.
  @ObservationIgnored var services: AppServices

  /// The bundled `workroom` CLI (issue #103): `services.cli`, which tests replace by passing
  /// `cli:` to the init, to drive mutations without a real subprocess.
  var cli: WorkroomCLIProtocol { services.cli }

  /// The `NSWindow` hosting this store, resolved once the view tree is in a window (issue #70). Weak:
  /// the window outlives the store's need for it, and the registry holds the authoritative mapping.
  weak var hostWindow: NSWindow?
  /// Called when a target's last tab closes. The Quick Terminal's own store closes its window on it.
  var onTargetEmptied: ((TerminalTarget.ID) -> Void)?
  /// Where this store's in-app toasts go instead of its own `toasts`: the front window, set by
  /// `WindowRegistry` for every window it registers and by the Quick Terminal for its own store.
  var forwardToast: ((WorkroomNotification) -> Void)?
  /// A target always on screen in this store's window, with no selection to say so: the Quick
  /// Terminal's. Its panes count as seen and focused as a selected workroom's do (#573).
  var pinnedTarget: TerminalTarget?
  /// The target this window shows first: its pinned one, else its selection.
  var primaryTarget: TerminalTarget? { pinnedTarget ?? selectedTarget }
  /// This window's display number — the smallest unused positive integer, assigned by `WindowRegistry`
  /// on registration and freed for reuse when the window closes (issue #70, macOS untitled-doc style).
  /// Backs the `windowTitle` fallback for a window with nothing selected ("Window 1", "Window 2", …).
  /// `@Published` so the title updates the moment the registry assigns it. 0 until registered.
  var windowNumber = 0
  /// This window's *identity* for cross-window bookkeeping (issue #132) — minted here and never
  /// reused, unlike `windowNumber`, which is a display number reclaimed by the next new window. Used
  /// by the quick switcher's recency (and its snapshot cache) so a closed window's entries can't
  /// alias onto a fresh one.
  let windowToken = WindowToken()
  /// This window's identity in the saved session (issue #46) — the key its `WindowSession` is stored
  /// under, and the only cross-*launch* window identity the app has. `WindowSeed.launch` mints a fresh
  /// UUID on every access and `windowToken` is per-process, so neither survives a relaunch. Defaults
  /// to the seed's id; a window that adopts a saved session takes that session's key instead, so the
  /// same window keeps the same slot across launches.
  var sessionKey = UUID()
  /// Retains the close-guard delegate proxy (the window holds its delegate weakly) for this window's
  /// lifetime (issue #70, A3).
  private var closeGuard: WindowCloseGuard?
  /// Frame size a new window should adopt to match the window that was current when it was opened
  /// (issue #70). Set by `RootWindow.init`; applied once in `attachWindow` before the window shows.
  /// nil for the launch window.
  var pendingInitialWindowSize: CGSize?
  /// Whether this window opened to take a workroom moved from another (#444), so it takes the
  /// standard size and the drop point rather than the current window's size (`placeHandOffWindow`).
  var opensForHandOff = false
  /// Where that window's top-left goes on screen: where the workroom was dropped. Nil from a menu.
  var pendingInitialWindowTopLeft: CGPoint?
  /// A workroom from another window hovering over this one (#444): where its tab would land among
  /// this window's (nil: at the end) and how wide a gap to open for it.
  var incomingWorkroomDrop: IncomingWorkroomDrop?
  /// The workroom a Quick Terminal pane dragged over this window would join, highlighted while it
  /// hovers (`QuickTerminalPaneDrag`).
  var incomingQuickTerminalPane: SidebarID?
  /// Each workroom tab's frame within its row (`workroomTabRun`), top-left origin, for working out
  /// where a workroom dragged in from another window lands. A measurement, not state: nothing
  /// renders from it.
  @ObservationIgnored var workroomTabFrames: [SidebarID: CGRect] = [:]
  /// The view behind that row, which says where the row is on screen at the moment of a drop. The
  /// tab bar lives in a title-bar accessory, so SwiftUI's own frames are not in the window's space.
  @ObservationIgnored weak var workroomTabRun: NSView?
  private var didApplyInitialSize = false
  /// The saved frame `attachWindow` gave this window, until it shows: SwiftUI places a window over
  /// it afterwards, so `applyRestoredFrame` puts it back.
  @ObservationIgnored var restoredFrame: NSRect?
  /// True only for the launch window: the `.launch` seed, or the first window to attach in the
  /// process (`ProjectStore.takeLaunchRole`). It restores the session and reopens its siblings, and
  /// runs the What's-New auto-check, so a relaunch with several windows doesn't duplicate dialogs.
  var isRestoreWindow = false
  /// Retained `NSWindow` frame-change observers that persist this window's size for the next launch.
  // `nonisolated(unsafe)`: appended on the main actor, read again only in `deinit`.
  @ObservationIgnored nonisolated(unsafe) private var frameObservers: [NSObjectProtocol] = []
  /// Retains the `NSWindow.didUpdate` observer that keeps the title out of the title bar (issue #70).
  @ObservationIgnored private var titleVisibilityObserver: NSObjectProtocol?

  deinit {
    for token in frameObservers { NotificationCenter.default.removeObserver(token) }
    // A closed window no longer holds its workroom's host connected (#356).
    RemoteHosts.shared.reachability.select(nil, in: ObjectIdentifier(self))
  }

  /// Only the active (last-key) window writes the shared sidebar prefs to UserDefaults, so multiple
  /// windows don't clobber each other's selection / collapse / tab order; the single restored window
  /// reads them on launch (issue #70, CQ1). `lastActiveStore` is modal-safe (a quit alert / Settings
  /// becoming key never changes it). Defaults to `true` until the first window registers, so the
  /// initial single window persists from the very first edit.
  ///
  /// Also `false` under `AppEnvironment.current.isFixture`, for the same reason `applyFixtureDefaults` writes
  /// fixture-forced state instead of just reading it: a fixture run that TOGGLES the sidebar (e.g.
  /// `ViewMenuShortcutsUITests`) would otherwise persist that into the real Dev `Defaults` domain —
  /// invisible to the fixture-mode launch that caused it (its own `sidebarVisible` is forced open
  /// regardless), but inherited by the next *non*-fixture launch in the same `xcodebuild test`
  /// invocation (`WorkroomWorkflowUITests.testAppLaunchesWithChrome` uses `fixture: false`), which
  /// reads the real Default straight through. Same hazard, opposite direction, as the read-side one
  /// `sidebarVisible`'s own initializer already guards against.
  private var persistsSidebarPrefs: Bool {
    #if DEBUG
      if AppEnvironment.current.isFixture { return false }
    #endif
    return WindowRegistry.shared.lastActiveStore.map { $0 === self } ?? true
  }

  var selectedProjectID: Project.ID?
  /// The selected terminal target — a `.root` or a `.workroom` (never `.project`), or nil
  /// when nothing is selected (the launch state). `.project` is not a target; clicking a
  /// project toggles its expansion instead. Persisted across launches (issue #14) via `didSet`
  /// and restored in `apply()`.
  var selectedTargetID: SidebarID? {
    didSet { selectionDidChange(from: oldValue) }
  }

  /// Everything that reacts to a change of `selectedTargetID`, in order: the persisted selection,
  /// the session, the quick switcher's recency, back/forward history, status, the inspector, and,
  /// when the target actually changed, the remote host, History, remote state and any pending
  /// remote confirmation. One named place, so a new reaction is added here, not to the `didSet`.
  private func selectionDidChange(from oldValue: SidebarID?) {
    if persistsSidebarPrefs {
      Defaults[.sidebarSelection] = selectedTargetID?.targetID?.encoded
    }
    // The saved session records selection PER WINDOW (issue #46); the Defaults key above is the
    // single-slot cold-start fallback for a launch with no usable session file.
    markSessionDirty()
    // Promote this workroom in the quick switcher's most-recently-used order (issue #132).
    // UNCONDITIONAL, unlike the history record below: `applyLocation` raises `isNavigatingHistory`
    // for its whole body and the switcher commits through it, so a gated write would never record
    // where the switcher just took you — ⌥Tab would flip to the same place forever. Recency means
    // "where did the user end up", which is equally true of a ⌘[ replay.
    SwitcherRecency.shared.recordWorkroom(store: self, sid: selectedTargetID)
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
    if selectedTargetID != oldValue {
      // Opening a container workroom starts its container if it was stopped (#309).
      let selected = selectedWorkroom?.reachableHost.map(HostID.remote)
      RemoteHosts.shared.reachability.select(selected, in: ObjectIdentifier(self))
      if let selected { RemoteHosts.shared.reachability.activate(selected) }
      forwardDeclaredPorts()
      focusHistoryIfShown()
      focusRemoteStateIfShown()
      // A confirmation asking about the OLD workroom's dirty tree is meaningless once the selection
      // moves. `runRemoteAction` re-checks the sid so answering it couldn't misfire anyway, but leaving
      // the dialog up would ask about a workroom the user is no longer looking at.
      if modals.pendingRemoteConfirm != nil { modals.pendingRemoteConfirm = nil }
    }
  }

  /// True while the selected target has ≥1 open tab. The inspector (History / Changes / Pull
  /// Request) reflects the *active* workspace, so closing all tabs of the selected workroom empties
  /// it even though the sidebar row stays selected (the detail pane likewise drops to its "No
  /// terminal" placeholder — this keeps the two in sync). Maintained at selection changes + the tab
  /// add/remove hooks, so the inspector re-renders when the answer flips rather than on every
  /// change to the selected target's tabs, which a `terminals.tabCount` read would observe.
  private(set) var selectionHasTabs = false
  /// Project paths the user has collapsed in the sidebar (issue #14). Held here as `@Published`
  /// rather than read via `@Default` in the view: a `@Default` change does not reliably re-evaluate
  /// the sidebar's `List` until some *other* state changes (e.g. the pointer moving over a row), so
  /// expand/collapse appeared to "stick" until you moved the mouse. `@Published` fires
  /// `objectWillChange` synchronously, so the tree updates on the click itself. Persisted via `didSet`.
  var collapsedProjects: Set<String> = Defaults[.collapsedProjects] {
    didSet { if persistsSidebarPrefs { Defaults[.collapsedProjects] = collapsedProjects } }
  }
  /// Remembered workroom tab-bar order (issue #23), stored as `TargetID.encoded`. `@Published`
  /// (not read via `@Default` in the view) because a `@Default` write doesn't reliably re-render the
  /// `NavigationSplitView` detail, so a drag-reorder's write didn't take and the dropped chip snapped
  /// back to its old slot. Persisted via `didSet`; initialised from `Defaults`. Stale ids resolve away
  /// in `orderedWorkroomTargets`, so it's self-healing.
  var workroomTabOrder: [TerminalTarget.ID] =
    Defaults[.workroomTabOrder].compactMap(TargetID.init(encoded:))
  {
    didSet {
      if persistsSidebarPrefs { Defaults[.workroomTabOrder] = workroomTabOrder.map(\.encoded) }
    }
  }
  /// Whether the projects sidebar column is visible. The single source of truth for showing the
  /// custom `SidebarColumn` *and* the View ▸ Projects checkmark — a bare AppKit `toggleSidebar` has no
  /// state a menu checkmark can bind to, so it could never show a tick. Persisted to
  /// `Defaults.sidebarVisible` (mirrors `showInspector`) so closing it survives a relaunch; the dragged
  /// width is persisted separately to `Defaults.sidebarWidth`. Gated on `persistsSidebarPrefs`, same as
  /// `collapsedProjects`/`workroomTabOrder`/`sidebarSelection`, so a background window can't clobber the
  /// active window's choice.
  ///
  /// Forced open under `AppEnvironment.current.isFixture` (Debug only).
  /// The real persisted value is whatever a PRIOR launch (human or automated) last left it as, and
  /// that's true WITHIN one `xcodebuild test` invocation too: this key is real `Defaults`, not
  /// fixture-isolated, so one sidebar-toggle test's launch persists into the very next test class's
  /// launch. Without this override, `sidebar.visible` flip-flops across the suite depending on run
  /// order and whichever test last toggled it — confirmed by removing this override: the suite then
  /// fails BOTH the tests that need the sidebar open (`WorkroomWorkflowUITests`,
  /// `ViewMenuShortcutsUITests`) and the ones that broke when it's open (see below), never a clean
  /// pass either way.
  var sidebarVisible: Bool = AppStore.initialSidebarVisible {
    didSet { if persistsSidebarPrefs { Defaults[.sidebarVisible] = sidebarVisible } }
  }

  nonisolated private static var initialSidebarVisible: Bool {
    #if DEBUG
      if AppEnvironment.current.isFixture { return true }
    #endif
    return Defaults[.sidebarVisible]
  }

  /// Shows or hides the Projects sidebar (the title-bar button, ⌃⌘S, ⌥⌘S, ⌥⌘B): nothing with no
  /// projects, where it has nothing to list and stays hidden (`RootView.splitView`).
  func toggleSidebar() {
    if !projectStore.projects.isEmpty { sidebarVisible.toggle() }
  }
  /// Whether a collapsed sidebar is *temporarily* on screen via edge-hover reveal (issue #56): the
  /// left Projects overlay (`previewingLeft`) and the right inspector overlay (`previewingRight`).
  /// These are observable app state, not view-local, because other surfaces must react: notification
  /// routing flashes the row instead of popping a toast while `previewingRight` (so the revealed
  /// Notifications panel and a toast never co-display — the invariant at `recordNotification`), and
  /// `ToastStack` withholds toasts while it's set. Session-only and deliberately NOT persisted (a
  /// transient hover state). Set by `EdgeRevealSidebar`.
  var previewingLeft: Bool = false
  var previewingRight: Bool = false
  /// The cursor is over the matching sidebar's title-bar *toggle button* while that sidebar is
  /// collapsed — the trigger for the edge-hover reveal (issue #74). The trigger used to be a wide
  /// strip over the toolbar (issue #56), but that strip sat directly above the leftmost workroom
  /// tabs: reaching for a tab tripped the reveal, whose panel then covered the very tab you wanted.
  /// Pinning the trigger to the toggle button itself keeps it clear of the tabs. `hoveringLeftToggle`
  /// is set by the leading sidebar's title-bar toggle (`LeadingTitlebarBar`); the trailing side has no
  /// toggle button (the activity bar is always pinned to that edge), so `hoveringRightToggle` stays
  /// false. Observed by `EdgeRevealSidebar`. Session-only, not persisted (transient hover state).
  var hoveringLeftToggle: Bool = false
  var hoveringRightToggle: Bool = false
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
  var dockedInspectorWidth: CGFloat?
  /// The workroom-into-workroom split groups (issue #23 follow-up): each entry is two+ workrooms shown
  /// side by side, every one a full `TargetTerminalDetail`. Empty = the single `selectedTarget` (the
  /// normal case). Leaves are `SidebarID`; the focused member IS `selectedTargetID`. **Several groups can
  /// coexist** — grouping two solo workrooms leaves the other groups alone — and they're disjoint (a
  /// workroom is in at most one) with ≥2 leaves each (a lone leaf is "no split", mirroring the
  /// terminal-split invariant). At most one group is *visible*: the one holding the selection.
  /// Persisted with the rest of the session (issue #46) as target-id strings; a group whose leaves no
  /// longer resolve dissolves on restore. All edits go through the helpers in
  /// `AppStore+WorkroomSplit.swift`, over the shared `PaneSplitGroups` rules; stale leaves resolve
  /// away in `resolvedSplitLeaves(of:)`, so it's self-healing. See that file for the transforms.
  var workroomSplitGroups = PaneSplitGroups<SidebarID>() {
    didSet { markSessionDirty() }
  }
  /// `workroomSplitGroups`' trees, for the readers (and the restore and fixture writers) that want
  /// the list itself.
  var workroomSplits: [PaneLayout<SidebarID>] {
    get { workroomSplitGroups.groups }
    set { workroomSplitGroups = PaneSplitGroups(newValue) }
  }
  /// The rect `WorkroomSplitView` lays its panes out in — the detail content inset by the split
  /// renderer's outer gutter and bottom margin. Mirrored here from `RootView.workroomPaneSpace`
  /// (the only layer that measures it) so a NON-drag caller can apply the pane floor: a drag
  /// threads its own measured rect down from the drop resolver, but ⌥⌘O and the "Open (split right)"
  /// menu item have no gesture to carry one.
  ///
  /// Only the CONTAINER is remembered; the anchor's own rect is derived per call in
  /// `workroomPaneRect(for:)`. A per-pane cache was tried and is wrong: the renderer only ever
  /// lays out the *current* selection's layout, so starting a create beside A and then selecting B
  /// leaves no entry for A at landing time and the floor silently stops applying.
  ///
  /// A plain `var`, deliberately NOT `@Published`: it is written from a layout callback, and
  /// publishing there would re-enter layout. Nothing observes it — every reader is an action.
  var workroomPaneSpace: CGRect?

  /// Issue #126's auto-even pref, read live so the Settings toggle applies to the very next split
  /// without a relaunch. Injected rather than read inline so tests can drive both states without
  /// touching `Defaults`, whose domain a parallel test worker shares and wipes cross-process.
  var autoEvenSplits: () -> Bool = { Defaults[.autoResizeSplitsEvenly] }
  /// Terminal targets whose terminal subtree is *expanded* in the sidebar (issue #30). Inverse
  /// polarity to `collapsedProjects`: terminals are collapsed by default, so the set holds only the
  /// expanded ones (empty = all collapsed). Persisted with the session (issue #46) — restored only for
  /// targets whose panes actually came back, since an expand flag pointing at nothing would render an
  /// empty disclosure. Pruned below 2 tabs by the `.tabsRemoved` arm of `handleTerminalEvent`.
  var expandedTerminalTargets: Set<TerminalTarget.ID> = [] {
    didSet { markSessionDirty() }
  }
  /// A PR write action (Phase 2b) is running — disables the PR actions menu so it can't double-fire.
  var prActionInFlight = false

  // Inspector section collapse (issue #24). Held on the store rather than as `@Default` in the
  // inspector view: the `.inspector` content doesn't observe `@Default` changes, but it DOES observe
  // this `@EnvironmentObject`. These are the *live* state for the currently selected workroom;
  // they're the GLOBAL layout, loaded once at launch and persisted on every change to
  // `Defaults[.inspectorLayout]` via `loadInspectorState()` / `persistInspectorState()` — shared
  // across all workrooms, so a workroom switch never changes them.
  var changesSectionCollapsed = false {
    didSet { persistInspectorState() }
  }
  /// Collapse state of the Files section (the repo file tree). Sits second, right under Changes.
  var filesSectionCollapsed = false {
    didSet { persistInspectorState() }
  }
  var prSectionCollapsed = false {
    didSet { persistInspectorState() }
  }
  /// Collapse state of the History section (the commit log) — the middle section of the Changes
  /// stack, between Changes and Pull Request.
  var historySectionCollapsed = false {
    didSet {
      persistInspectorState()
      // Expanding it with a workroom already selected: point the model now (same reason the
      // section-switch didSet does) so the pane shows its loader instead of the `.idle` placeholder
      // until `HistoryPanel`'s `.task` catches up. `focus` is idempotent, so this only does work when
      // the selection MOVED while the section was shut (the selection didSet skips its focus then).
      //
      // `isLoadingInspectorState` guards this the same way it guards the persist above, for the other
      // direction: `loadInspectorState()` runs inside `init` and would otherwise fire a real VCS read
      // from a didSet during construction. It happens to be inert today (`inspectorTarget` is nil until
      // a selection has tabs) — the guard is what stops that accident from becoming load-bearing.
      if !isLoadingInspectorState, !historySectionCollapsed { focusHistoryIfShown() }
    }
  }
  /// Whether the History section is on screen: its pane is the active one and the section isn't
  /// collapsed. The gate for every History load trigger (the eager focuses via `focusHistoryIfShown`,
  /// the live watcher refresh, the app-refocus safety net, and `HistoryPanel`'s own activation task) —
  /// a collapsed or swapped-out section must not run VCS reads for a log nobody can see.
  var historySectionShown: Bool {
    activeInspectorSection.subSections.contains(.history) && !historySectionCollapsed
  }
  /// Point History's model at the inspector's active target, but only when that log is genuinely on
  /// screen: the section shown AND the inspector open.
  ///
  /// The visibility half matters because History lives in the DEFAULT pane now. A `focus` is not a
  /// cheap "point at" — it runs a full page read (`HistoryModel.load` → `LocalVCSProviding.log`, which for
  /// git is a repo open, a 101-commit revwalk, a ref enumeration and an unpushed-range walk), so
  /// without this gate every selection change would read a repo for a pane nobody can see, for every
  /// user, in the shipped default state.
  ///
  /// Nothing has to re-trigger this when the inspector opens: `RootView` builds `InspectorColumn`
  /// inside `if showInspector`, so opening it CONSTRUCTS `HistoryPanel`, whose `.task` calls
  /// `HistoryModel.activate` — the same load, at the moment it's first worth doing.
  private func focusHistoryIfShown() {
    guard inspectorIsVisible, historySectionShown else { return }
    commitHistory.focus(target: inspectorTarget)
  }

  /// Forward the ports the selected container workroom's dev container declares, once a launch
  /// (`PortForwardingModel.forwardDeclared`). On selection, not when the Ports list shows: opening
  /// the workroom is when its dev server is wanted, whatever the inspector is showing. The read
  /// connects the host, as every inspector read does, and selecting it has already started it.
  private func forwardDeclaredPorts() {
    guard let workroom = selectedWorkroom, workroom.isContainer || workroom.isSSH,
      let id = workroom.reachableHost,
      let location = try? RepositoryLocation.remote(host: id, path: workroom.path)
    else { return }
    let model = PortForwardingModel.model(
      for: .remote(id), workroom: workroom.isSSH ? workroom.host?.workroomID : nil)
    guard !model.declared else { return }
    Task {
      await model.forwardDeclared {
        try await DevContainerConfig.read(RepositoryRouter.shared.files(for: location))
      }
    }
  }

  /// Whether the VCS toolbar is on screen. It sits above the section stack rather than inside a
  /// section, so only the activity section matters — not a collapse flag.
  var remoteToolbarShown: Bool { activeInspectorSection == .changes }

  /// Point the toolbar's model at the inspector's active target, but only when it's genuinely visible.
  ///
  /// Same gate, and the same reason, as `focusHistoryIfShown`: a `focus` here is not a cheap pointer
  /// move but two or three `git` processes, so without this every selection change would read a
  /// repo for a toolbar nobody can see.
  private func focusRemoteStateIfShown() {
    guard inspectorIsVisible, remoteToolbarShown else {
      remoteState.focus(nil)
      return
    }
    remoteState.focus(remoteTarget())
  }

  /// The toolbar's target, resolved from the inspector's active target. `nil` when nothing statusable
  /// is selected, or when the target's project has gone away.
  ///
  /// A `.project` row is deliberately not statusable — it's the collapsible header, not a working copy —
  /// so it resolves to nil and the toolbar shows its "no workroom selected" state.
  func remoteTarget() -> RemoteStateModel.Target? {
    guard let sid = inspectorTargetID else { return nil }
    let projectPath: String
    let path: String
    switch sid {
    case .project, .creation:
      return nil
    case .root(let p):
      projectPath = p
      path = p
    case .workroom(let p, let name):
      guard let project = projectStore.project(at: p),
        let workroom = project.workrooms.first(where: { $0.name == name })
      else { return nil }
      if workroom.isRemote {
        // On its host, and its own root there (#253). One this app can't reach has no toolbar
        // target.
        guard let location = workroom.target(inProject: p).remoteLocation else { return nil }
        return RemoteStateModel.Target(
          sid: sid, path: workroom.path, projectRoot: workroom.path, location: location)
      }
      projectPath = p
      path = workroom.path
    }
    guard let project = projectStore.project(at: projectPath) else { return nil }
    return RemoteStateModel.Target(
      sid: sid, path: path, projectRoot: project.path,
      location: RepositoryRouter.shared.localLocation(for: path))
  }

  /// App-refocus safety net, mirroring `refreshHistoryIfActive`: a `git fetch` or a branch change made
  /// in another app while Workroom was backgrounded won't have reached the metadata watcher.
  func refreshRemoteStateIfActive() {
    guard inspectorIsVisible, remoteToolbarShown else { return }
    // NOT forced — `force` is what skips the model's 15s TTL, and app activation is the one caller that
    // has no reason to. `RootView` promises this is "throttled, so rapid alt-tabbing doesn't fork a
    // git process per project" and it wasn't: every activation paid a full read, held back only by
    // `load()`'s 300ms debounce. `refreshHistoryIfActive`, the twin
    // this was modelled on, already calls its model unforced. The metadata watcher is the path that
    // genuinely needs to override the TTL, and it still does.
    remoteState.refresh()
    remoteState.autoFetchIfDue()
  }
  /// Relative heights of the inspector panes (issue #24), ordered as `InspectorSectionKind.allCases`.
  /// Equal == the default equal-sections layout; updated when the user drags a divider (via
  /// `updateInspectorSizeWeights`) and persisted globally, like the collapse flags above. Not set
  /// directly by the view — the `NSSplitView` reports drag results back through the store.
  var inspectorSizeWeights: [Double] = [1, 1, 1, 1]
  /// The selected top-level section in the right activity bar (issue: activity bar). Drives which
  /// pane the inspector shows (`RightInspector` renders `activeInspectorSection.subSections`). Held
  /// on the store (not read via `@Default` in the bar) so a click re-renders the bar + inspector
  /// synchronously — a bare `@Default` write invalidates asynchronously (the `SettingsView` gotcha).
  /// Persisted per-machine via `didSet`; whether the pane is visible at all is `Defaults[.showInspector]`.
  var activeInspectorSection: ActivitySection = Defaults[.activeInspectorSection] {
    didSet {
      if activeInspectorSection != oldValue {
        if !isolatesInspectorSectionForTesting {
          Defaults[.activeInspectorSection] = activeInspectorSection
        }
        // Switching to a pane that stacks History, with a workroom already selected: point the model
        // now so the pane shows its loader immediately, instead of flashing the `.idle` ("Select a
        // workroom") placeholder until the panel's `.task` catches up. `focus` is idempotent (no-op if
        // already there).
        focusHistoryIfShown()
        focusRemoteStateIfShown()
      }
    }
  }
  /// Bumped by every activity-bar click (`apply(_:)`) and View-menu Files toggle, and read by the
  /// views that also read `Defaults[.showInspector]` through `@Default`: that write invalidates them
  /// only asynchronously, and a toggle that keeps the section changes nothing else Observation
  /// tracks, so without this the inspector would open or close only at the next unrelated event.
  var inspectorToggles = 0
  /// Test seam: keep collapse/size changes in THIS store instead of persisting them to the shared
  /// `inspector.layout.v2` setting — the third half of the gate `inspectorVisibleOverrideForTesting`
  /// and `isolatesInspectorSectionForTesting` cover, and the same cross-worker hazard: a class that
  /// needs History expanded (or collapsed) would otherwise leave that value inside whatever unrelated
  /// class runs beside it, since `-parallel-testing` workers share one UserDefaults domain.
  var isolatesInspectorLayoutForTesting = false
  /// Test seam: keep an `activeInspectorSection` change in THIS store instead of persisting it to the
  /// shared `inspector.activeSection` setting. Same hazard as `confirmOnCloseOverrideForTesting`
  /// (which see for the full account): `-parallel-testing` gives each worker its own host process but
  /// ONE UserDefaults domain, so a class that wants its store on History leaves every store another
  /// worker builds meanwhile starting on History too — and the `selectionDidChange(from:)` then focuses
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
  /// directory whenever the selection changes (see `selectionDidChange(from:)`); the `FilesPanel`
  /// observes it. Owned here so it survives inspector re-renders and tracks selection centrally.
  let fileTree = FileTreeModel()
  /// Store-owned commit-history state for the History inspector section (issue #59); re-pointed on
  /// selection by `HistoryPanel`, mirroring `fileTree`. Named `commitHistory` — `history` is the
  /// browser-style `NavigationHistory`. In UI-test fixture mode it reads canned commits (the fake
  /// workroom dirs aren't real repos), so the History → changeset click-through is testable. Assigned
  /// in `init` (not inline) so tests can inject a stub and assert the live-refresh triggers fire —
  /// see the `commitHistory:` init parameter (a `@MainActor` type can't be a nonisolated default arg).
  let commitHistory: HistoryModel
  /// Store-owned state for the VCS toolbar (branch, divergence, last fetch, fetch/push/pull). Third
  /// sibling to `fileTree` and `commitHistory`.
  let remoteState: RemoteStateModel
  /// Shared find state for ⌘F across file/diff/changeset panes — one instance for all three content
  /// kinds (`FileFindModel` has no content-specific logic), so only the focused pane feeds + shows it,
  /// and `.focusChanged`/`startFindInFocusedPane`/`navigateFocusedPaneSearch` each need a single
  /// branch/call rather than one per content kind.
  let contentFind = FileFindModel()
  /// True while `loadInspectorState` is writing the four collapse flags + weights, so their
  /// `didSet`s don't persist the values straight back (and the load isn't mistaken for a user edit).
  var isLoadingInspectorState = false

  /// This window's modal presentations and the error sheet's contents.
  let modals = ModalState()

  /// Tells the user a closed remote pane's session may still be running on its host (#283), unless
  /// something else is on the error sheet. The notice arrives up to a connect and a request timeout
  /// after the close, so it must not replace an error the user is reading, or its details or link;
  /// `PersistentSessionService` has logged the failure either way. Not for a workroom that is gone
  /// or going, which the notice would tell the user to delete.
  func reportRemoteCloseFailure(target: TerminalTarget.ID, title: String) {
    guard modals.errorMessage == nil, !lifecycle.deletingWorkrooms.contains(target),
      sidebarID(for: target) != nil
    else { return }
    modals.errorMessage =
      "Its host didn't confirm the terminal stopped, so whatever was running in it may still be running there. Workroom tries again when it next connects to the host, and deleting the workroom stops it."
    modals.errorTitle = "Couldn't stop the terminal in \(title)"
  }

  var isLoading = false
  /// The step whose log is open in each run's pane in this window (#483, design D9), by run id. Here
  /// rather than in the pane's own state, which goes when the pane's id becomes the workroom's.
  var expandedCreationLogs: [UUID: String] = [:]

  let terminals: TerminalPanes
  /// In-memory notification spine driving the badges + inspector (issue #10); views observe it
  /// directly via `@EnvironmentObject`. Injected, so windows can share one list (ADR 0064).
  let notifications: NotificationCenterStore
  /// The windows holding this window's popped-out panes (issue #172). Owned here so their lifetime
  /// is a subset of this store's: the tabs they host stay in `terminals`, and their surfaces are
  /// released when this store is, so a detached window must never outlive it.
  let detachedPanes = DetachedPaneWindows()

  /// Bottom-right toast queue (issue #31): the foreground, inspector-*closed* surface for a new
  /// notification. FIFO, capped at `maxToasts` (a new toast beyond the cap pushes the oldest out);
  /// each toast carries the `WorkroomNotification` it mirrors so a tap can route via `openTerminal`.
  /// Rendered by `ToastStack`, overlaid bottom-right in `RootView`.
  var toasts: [WorkroomNotification] = []
  /// Max simultaneously-visible toasts; beyond this the oldest is dropped so a chatty emitter can't
  /// overflow the window (matches the "stack a few, drop oldest" decision).
  private static let maxToasts = 4
  /// Whether the app is frontmost, which picks an in-app toast over a banner. A seam so a test can
  /// take the banner path (`ProgramStatusAlertsTests`).
  var isAppActive: () -> Bool = { NSApp.isActive }

  /// Branch names from the VCS toolbar's remote-state read, keyed by `SidebarID`.
  ///
  /// Published by `RemoteStateModel` (the only source of *names*) and read by `branchName(for:)`, which
  /// every branch-showing surface goes through. This is the "one shared cache" half of unifying those
  /// surfaces: the resolver publishes here and no surface calls a provider.
  ///
  /// Cleared from three other places, because the resolver only ever writes the FOCUSED target and so
  /// can't retract anything: `pruneResolvedBranchNameIfDrifted` (a status sweep disagreed),
  /// `removeWorkroomLocally` and `removeProjectLocally` (the target is gone).
  private(set) var resolvedBranchNames: [SidebarID: String] = [:]

  /// Record (or clear) the resolver's branch answer for a target. Names come only from
  /// `RemoteStateModel`; see `resolvedBranchNames` for who clears them.
  func setResolvedBranchName(_ name: String?, for sid: SidebarID) {
    if let name, !name.isEmpty {
      guard resolvedBranchNames[sid] != name else { return }
      resolvedBranchNames[sid] = name
    } else {
      guard resolvedBranchNames[sid] != nil else { return }
      resolvedBranchNames.removeValue(forKey: sid)
    }
  }

  /// Whether the `git` on PATH is new enough for the VCS remote actions (see
  /// `VCSToolVersions`). `nil` until the background probe lands — treated as usable, so a slow probe
  /// never disables a working feature.
  private(set) var vcsToolReport: VCSToolVersions.Report?
  /// Tool warnings the user has dismissed this session, by tool name. The condition is standing (an
  /// old binary doesn't fix itself), so the warning would otherwise reappear on every reload.
  private(set) var dismissedToolWarnings: Set<String> = []

  /// Whether remote actions are permitted. Optimistic before the probe lands and for `.unknown` —
  /// never cry wolf.
  var vcsAllowsRemoteActions: Bool { vcsToolReport?.allowsRemoteActions ?? true }

  /// Undismissed tool warnings, rendered as toasts by `ToastStack`.
  var vcsToolWarnings: [VCSToolVersions.ToolWarning] {
    guard let report = vcsToolReport else { return [] }
    return report.warnings.filter { !dismissedToolWarnings.contains($0.tool) }
  }

  func dismissToolWarning(tool: String) { dismissedToolWarnings.insert(tool) }

  /// Run a VCS remote action for the toolbar's current target, supplying the two facts only the store
  /// knows.
  ///
  /// `setUpstream` for git: a workroom is `git worktree add -b`, so it has no counterpart on the remote
  /// until its first push — that first push is the one that should establish tracking, and later ones
  /// must not keep rewriting `branch.<name>.remote`.
  /// Request a remote action, confirming first when one is needed.
  ///
  /// **The confirmation gate lives HERE, not in the toolbar.** It used to sit in `VCSToolbar.perform`,
  /// which meant the Room menu's ⌥⇧⌘P went straight past it: the button warned before
  /// autostashing a dirty tree and the keyboard shortcut didn't. A safety gate that only one of two
  /// entry points honours isn't a gate, so every caller funnels through this.
  func performRemoteAction(_ action: VCSRemoteAction) {
    guard let target = remoteState.target else { return }
    // A pull rewrites the working copy, and workroom trees are essentially always dirty — `--autostash`
    // will stash and reapply, which is worth saying before it happens.
    if action == .pull, vcsStatus.workroomStatuses[target.sid]?.dirty == true {
      modals.pendingRemoteConfirm = PendingVCSAction(action: action, sid: target.sid)
      return
    }
    runRemoteAction(action, on: target.sid)
  }

  /// Run a confirmed action against the workroom it was confirmed FOR.
  ///
  /// The `sid` is checked rather than trusted: the confirmation dialog is not modal to the sidebar, so
  /// the selection can move while it is open. Re-deriving the target at click time would silently run
  /// the pull against a different workroom than the one the dirty-tree warning described.
  func runRemoteAction(_ action: VCSRemoteAction, on sid: SidebarID) {
    guard let target = remoteState.target, target.sid == sid else { return }
    guard vcsAllowsRemoteActions else { return }
    remoteState.perform(action, setUpstream: remoteState.snapshot?.tracking?.gone == true)
  }

  /// Probe the tool versions, sharing one process-wide probe across windows.
  ///
  /// Called when projects land rather than from `init`. Inert in fixture mode: a UI test's PATH is whatever the runner inherited, and a version toast would
  /// overlay the surfaces under test.
  ///
  /// Also inert under XCTest — `apply` runs in dozens of unit tests, and each would otherwise spawn a
  /// real `git --version` and mutate the process-wide cache. The same reason as the hosted-unit-run
  /// half of the `ShellEnvironment.refresh()` skip in `WorkroomApp.init` (`runsLaunchShellProbe`),
  /// which also skips a `fixture: false` UI launch; this one does not. `VCSToolVersionsTests` drives
  /// the probe directly with a stub runner.
  func refreshVCSToolReport() {
    #if DEBUG
      if AppEnvironment.current.isFixture { return }
    #endif
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    let cache = vcsStatus.vcsToolVersionCache
    Task { [weak self] in
      let report = await cache.report()
      self?.vcsToolReport = report
    }
  }

  /// Browser-style back/forward history of visited `(target, tab)` locations (issue #26).
  /// `@Published` so toolbar/menu enablement (`canGoBack`/`canGoForward`) re-evaluates when it
  /// changes. Session-only — deliberately not persisted across launches. `private(set)` so unit
  /// tests can inspect it (read-only) while only the store mutates it.
  var history = NavigationHistory()
  /// True while `navigateBack`/`navigateForward`/`applyLocation` are replaying, so the
  /// `selectionDidChange(from:)` and the `.focusChanged` event don't re-record the very
  /// location they're navigating to.
  var isNavigatingHistory = false

  /// The selection's status probe (issue #24), cancelled and replaced per selection so a slow probe
  /// never writes stale status over a newer one. `internal` (not `private`) so the
  /// `AppStore+WorkroomStatus.swift` extension can drive it.
  var selectionStatusTask: Task<Void, Never>?
  /// Keeps the selected workroom's local VCS status live (without polling) by watching its directory
  /// for filesystem changes (issue #24 follow-up). Retargeted on selection; see
  /// `updateSelectedWorkroomWatch` / `handleWorkroomFileChange`.
  @ObservationIgnored lazy var workroomFileWatcher = HostFileWatcher {
    [weak self] paths, overflow in
    self?.handleWorkroomFileChange(paths, overflow: overflow)
  }
  /// The watcher's local-refresh task — cancel-and-replace so the latest filesystem change wins and
  /// at most one probe from THIS lane is in flight.
  var watchRefreshTask: Task<Void, Never>?
  /// When the project list was last loaded — used to throttle the on-focus refresh.
  private var lastLoadAt: Date = .distantPast
  private var pendingLoads = 0
  /// The selection persisted from a previous launch (issue #14), applied once on the first
  /// successful load (see `apply`). Consumed there so a later refresh can't resurrect it.
  ///
  /// Seeded from `Defaults[.sidebarSelection]`, and overwritten by a claimed session's own selection
  /// (issue #46) — the session owns selection per window; the Defaults key is the single-slot
  /// cold-start fallback. Internal rather than private so `AppStore+SavedLayout` can do that.
  var pendingRestoreSelection: TerminalTarget.ID?
  /// This window's claimed saved session (issue #46), consumed at the end of `apply`.
  var pendingSessionRestore: WindowSession?
  @ObservationIgnored var hasDisplayedWindow = false
  @ObservationIgnored var pendingSessionRecovery = false
  /// Saved targets held back from the restore (#253): remote workrooms this app couldn't reach
  /// then. Each is written back with every save, and restored whole once its workroom is
  /// reachable and opens its first pane (`restoreDeferredSession`).
  var deferredTargetSessions: [TerminalTarget.ID: TargetSession] = [:]
  /// Each remote workroom's layout as its host keeps it, from this window (#255): see
  /// `AppStore+HostLayout`.
  var hostLayouts = HostLayoutState()
  /// The remote workrooms waiting on their host for their layout (`hostLayouts.fetching`),
  /// published so their empty pane says so rather than offer a terminal that opens only later.
  var waitingForHostLayout: Set<TerminalTarget.ID> = []
  /// One-shot guard: `WindowAccessor` can resolve the same window more than once, and a claim must
  /// never be taken twice.
  var didClaimSession = false
  /// Whether this window may adopt a saved session (issue #46) — the launch window and each sibling
  /// reopened from the session, but never a ⌘N window, which always starts blank.
  var claimsSavedSession = false
  /// UI-test fixture mode only: whether this window auto-selects the fixture workroom. True for the
  /// launch window, false for a ⌘N window so it stays blank — the fixture analogue of clearing
  /// `pendingRestoreSelection` on the real path (issue #70).
  #if DEBUG
    private var fixtureAutoSelect = true
  #endif

  /// Production builds one store per window (issue #70), each sharing `ProjectStore.shared`,
  /// `VCSStatusService.shared`, `RunCommands.shared` and `WorkroomLifecycle.shared`; tests build an
  /// isolated `AppStore()` (own fresh `ProjectStore`, `VCSStatusService`, `RunCommands` and
  /// `WorkroomLifecycle`), inject `projects`, and drive the real recording/navigation paths. Owners
  /// derive downward only: a `lifecycle` brings its own `vcsStatus`, a `vcsStatus` its own
  /// `projectStore`. `init` does no CLI work (only `bootstrap()`/`load()` do).
  init(
    projectStore: ProjectStore? = nil, vcsStatus: VCSStatusService? = nil,
    runCommands: RunCommands? = nil, lifecycle: WorkroomLifecycle? = nil,
    cli: WorkroomCLIProtocol? = nil, commitHistory: HistoryModel? = nil,
    remoteState: RemoteStateModel? = nil, notifications: NotificationCenterStore? = nil
  ) {
    var services = AppServices.current
    if let cli { services.cli = cli }
    self.services = services
    // Default to a fresh, isolated store (so `AppStore()` in tests never touches the singleton);
    // production passes `.shared`. Constructed here in the main-actor init body, not as a default
    // argument (default args are evaluated nonisolated, which can't call a @MainActor initializer).
    // The notification list follows the same rule.
    self.notifications = notifications ?? NotificationCenterStore()
    let store =
      projectStore ?? vcsStatus?.projectStore ?? lifecycle?.projectStore ?? ProjectStore()
    self.projectStore = store
    let status = vcsStatus ?? lifecycle?.vcsStatus ?? VCSStatusService(projectStore: store)
    precondition(status.projectStore === store, "a window's VCS status is over its own projects")
    self.vcsStatus = status
    let lifecycle = lifecycle ?? WorkroomLifecycle(vcsStatus: status)
    precondition(lifecycle.vcsStatus === status, "a window's lifecycle is over its own VCS status")
    self.lifecycle = lifecycle
    // `commitHistory` is assigned here (not inline) for the same @MainActor reason: a test injects a
    // stub to observe the live-refresh triggers; otherwise it reads through the services' reader.
    self.commitHistory = commitHistory ?? HistoryModel(resolve: services.vcsReader)
    // Same seam as `commitHistory` above, built by the services (the fixture's serves seeded state
    // and records actions instead of running git).
    self.remoteState = remoteState ?? services.makeRemoteState()
    let terminals = TerminalPanes()
    self.terminals = terminals
    self.runCommand = RunCommandController(terminals: terminals)
    self.runCommands = runCommands ?? RunCommands()
    // Any pane change marks the saved session dirty (issue #46). `paneWillChange` fires BEFORE the
    // mutation, so the coordinator must always schedule a capture — never take one inline here.
    sessionObservation = terminals.paneWillChange.sink { [weak self] _ in
      self?.markSessionDirty()
    }
    // Wired post-init (the `workroomFileWatcher` idiom) so `RemoteStateModel` needs no `AppStore` to be
    // unit-tested. `onBranchResolved` makes this model the single writer of the shared branch cache
    // every branch-showing surface reads through `branchName(for:)`.
    self.remoteState.onBranchResolved = { [weak self] target, name in
      guard let self,
        self.vcsStatus.selectedStatusWorkItem(for: target.sid)?.location == target.location
      else { return }
      self.setResolvedBranchName(name, for: target.sid)
    }
    self.remoteState.onDidMutate = { [weak self] action, target in
      guard let self,
        self.vcsStatus.selectedStatusWorkItem(for: target.sid)?.location == target.location
      else { return }
      self.handleRemoteMutation(action, on: target.sid, location: target.location)
    }
    // Only the store can name a target, and the model needs the name to attribute a failure that
    // outlived the selection it started from.
    self.remoteState.describeTarget = { [weak self] sid in self?.label(for: sid).full }
    // Cross-window write-in-flight refusal (VCS-foundation eng-review) — see `isWritingProject`'s
    // doc. `canStartWrite` defaults to "never busy" when unwired, so a model built without an
    // `AppStore` (unit tests) behaves as it did before this was added.
    self.remoteState.canStartWrite = { [weak self] root in
      !(self?.vcsStatus.isWritingProject(root) ?? false)
    }
    self.remoteState.writeDidStart = { [weak self] root in
      self?.vcsStatus.beginWrite(projectRoot: root)
    }
    // Captured STRONGLY, not through `self`: `writingProjectRoots` lives on the app-wide
    // `VCSStatusService`, and this release must run even if THIS window's `AppStore` (and its
    // `RemoteStateModel`) is deallocated before the write finishes — e.g. the window closed
    // mid-fetch/push/pull. A release gated on `self` staying alive would leak the counter
    // permanently, refusing every future write for this project, in every window, until relaunch.
    // `RemoteStateModel.perform` already captures this closure's VALUE as a local before its own
    // `Task` starts, for the identical reason on its side of the chain.
    self.remoteState.writeDidFinish = { [vcsStatus = self.vcsStatus] root in
      vcsStatus.endWrite(projectRoot: root)
    }
    pendingRestoreSelection = Defaults[.sidebarSelection].flatMap(TargetID.init(encoded:))
    // Everything `TerminalPanes` reports comes through one synchronous sink, handled in
    // `handleTerminalEvent` (eng review D8).
    terminals.onEvent = { [weak self] event in self?.handleTerminalEvent(event) }
    // A run tab rebuilt from a saved session is a run session of the project's command (#522).
    terminals.runCommandForTarget = { [weak self] target in
      guard let self, let project = self.project(forTargetID: target.id) else { return nil }
      let command = self.runCommands.runConfig(forProject: project.path).command
      return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    runCommand.onSignalUnconfirmed = { [weak self] targetID, reason in
      self?.runSignalUnconfirmed(targetID: targetID, reason: reason)
    }
    runCommand.revealRun = { [weak self] targetID in
      guard let self else { return }
      // Same reason as the notification route: the run terminal may be a detached pane (#172).
      self.window(forTab: self.runCommand.runStates[targetID]?.tab)?.makeKeyAndOrderFront(nil)
      self.revealRunTerminal()
    }
    // Every local status merge, from any window's lane or the sweep, settles this window's caches.
    self.vcsStatus.register(self)
    // Every create and delete, from any window, reaches this window's selection, splits, runs and
    // terminals through the lifecycle.
    self.lifecycle.register(self)
    // Hydrate the (global) inspector section layout once at launch — it's shared across all
    // workrooms, so it's loaded here rather than re-loaded on every selection change (issue #24).
    loadInspectorState()
  }

  /// Everything `TerminalPanes` reports. `onEvent` calls this inline the moment an event happens,
  /// so an event raised inside a sessions method is handled before that method returns: history
  /// suppression and `select`'s promote-then-focus order depend on that (eng review D8).
  /// `.remoteCloseFailed` arrives later, from the remote close's own task.
  private func handleTerminalEvent(_ event: TerminalPanes.Event) {
    switch event {
    // Route each terminal's activity (OSC/bell) through the notification spine, gated on
    // focus, and raise a native banner only when the app is backgrounded.
    case .activity(let targetID, let tabID, let activity):
      handleActivity(targetID: targetID, tabID: tabID, activity: activity)
    // Record each focused-tab change for back/forward history (issue #26), unless we're replaying.
    case .focusChanged:
      // Find is tied to the focused file/diff/changeset pane (the model is shared across all three
      // kinds). Any focused-tab change ends that session: close it so ⌘G can't step a hidden find
      // from a terminal pane, and the bar doesn't reappear pre-filled on the next pane (review).
      if self.contentFind.isOpen { self.contentFind.close() }
      // A focus change includes a freshly-added tab appearing → re-enable the inspector.
      self.refreshSelectionHasTabs()
      guard !self.isNavigatingHistory else { return }
      self.recordCurrentLocation()
    // A tab's content changed underneath an unmoved focus (the shared preview tab being retargeted, or
    // a file selected inside a commit). `.focusChanged` cannot see either, which is why browsing the
    // Changes/Files panels used to record nothing after the first click.
    //
    // Scoped to the on-screen cursor location: a content change in a co-displayed but NON-selected
    // workroom is not where the user is, and `recordCurrentLocation` records the *selected* target's
    // focused tab, so recording here would log the wrong place at the wrong moment.
    case .tabContentChanged(let targetID, let tabID):
      guard !self.isNavigatingHistory else { return }
      guard let selected = self.selectedTarget, selected.id == targetID,
        self.terminals.focusedTab(for: selected)?.id == tabID
      else { return }
      self.recordCurrentLocation()
    // A closed remote pane whose host could not end its session (#283). Not while quitting: the
    // quit has stopped waiting for it, and an alert would hold the quit up instead.
    case .remoteCloseFailed(let target, let title):
      guard !WindowRegistry.shared.isTerminating else { return }
      self.reportRemoteCloseFailure(target: target, title: title)
    // A workroom now shows more or fewer terminals across one axis, so the workroom split it sits
    // in re-evens by pane count: every terminal in the window ends up the same size.
    case .paneCountChanged(let targetID, let axis):
      self.reEvenWorkroomSplit(holding: targetID, along: axis)
    // Prune dead entries when tabs are closed/reaped, so canGoBack/Forward stay honest (issue #26).
    // Also collapse a target's sidebar terminal subtree once a close drops it below the 2-tab
    // disclosure threshold (issue #30), so a stale expand flag can't auto-reveal if the count climbs
    // back later — the subtree is meant to be re-opened deliberately.
    case .tabsRemoved(let targetID, let ids):
      self.history.prune(removing: Set(ids))
      if self.terminals.tabCount(forTargetID: targetID) < 2 {
        self.expandedTerminalTargets.remove(targetID)
      }
      // If the target's run terminal was closed/reaped, drop its whole run state (issue #7, review
      // #1).
      if let runTab = self.runCommand.runStates[targetID]?.tab, ids.contains(runTab) {
        self.runCommand.clearRun(for: targetID)
      }
      // Same idea for a closed/reaped Investigate tab (issue #146) — a second, independent cleanup
      // path from `.childExited`, since a surface doesn't raise that on every teardown.
      for id in ids { self.runCommand.investigateTabs.removeValue(forKey: id) }
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
      // A closed pane's waiting requests stop counting.
      WindowRegistry.shared.recomputeBadge()
      if self.terminals.tabCount(forTargetID: targetID) == 0 { self.onTargetEmptied?(targetID) }
    // A click into a co-displayed split pane's terminal focuses that workroom (issue #23 follow-up),
    // so commands target it. History-suppressed (the routing method) — glancing between panes isn't
    // navigation.
    case .surfaceFocused(let targetID):
      focusWorkroomMemberFromSurface(targetID)
    // Effective focus is the one authority for reading a terminal's notifications (#358).
    case .terminalSeen(_, let tabID):
      notifications.dismiss(tab: tabID)
    // Pop-out panes (issue #172). `detachPane`/`dockPane` own the model half and fire these for the
    // window half, so membership and window are always written together — see `DetachedPaneWindows`
    // for the state machine and for why these windows are NOT in `WindowRegistry`.
    case .paneDetached(let targetID, let tabID, let screenPoint):
      guard let target = self.terminalTarget(forID: targetID),
        let tab = self.terminals.tab(tabID, for: target)
      else { return }
      self.openDetachedPane(tab: tab, target: target, origin: screenPoint, frame: nil)
    case .paneRestoredDetached(let targetID, let tabID, let frame):
      guard let target = self.terminalTarget(forID: targetID),
        let tab = self.terminals.tab(tabID, for: target)
      else { return }
      self.openDetachedPane(tab: tab, target: target, origin: nil, frame: frame)
    case .paneDocked(let tabID):
      detachedPanes.close(tabID: tabID)
    // Something tried to focus a pane that lives in its own window; its window is the honest answer.
    case .paneRaiseRequested(let tabID):
      raiseDetachedPane(tabID)
    case .paneWindowToggleRequested(let targetID, let tabID):
      togglePaneWindow(tabID, targetID: targetID)
    // Run sessions (#522): a run tab back from a saved session, and what its daemon says of it.
    case .runTabRestored(let targetID, let tabID):
      adoptRestoredRun(tab: tabID, targetID: targetID)
    case .runStatus(let targetID, let tabID, let line):
      guard self.runCommand.runStates[targetID]?.tab == tabID,
        let target = self.terminalTarget(forID: targetID)
      else { return }
      applyRunStatus(line, for: target)
    case .runSessionGone(let targetID, let tabID):
      runSessionGone(tab: tabID, targetID: targetID)
    case .childExited(let target, let tabID, let exitCode):
      tabProcessExited(tab: tabID, of: target, exitCode: exitCode)
    // A run tab's "press any key to close" MUST go through the graceful stop (quit the supervisor
    // and wait for it to exit) BEFORE the tab closes: closing ends the run session, whose kill hangs
    // the supervisor up mid-drain ("A server is already running" next start; issue #7). Any other
    // run-command tab (an Investigate tab) closes at once.
    case .closeRequested(let target, let tabID):
      runCommand.closingRunTab(tabID, for: target.id) { [weak self] in
        self?.terminals.closeTab(tabID, for: target)
      }
    }
  }

  /// The last persisted window frame (issue #70), or nil when unset/degenerate.
  private static func savedMainWindowFrame() -> NSRect? {
    let string = Defaults[.mainWindowFrame]
    guard !string.isEmpty else { return nil }
    let frame = NSRectFromString(string)
    return (frame.width > 200 && frame.height > 200) ? frame : nil
  }

  /// A restored frame, moved onto a screen that still exists.
  ///
  /// Restoring a raw frame is not safe (issue #46): unplug the external display a window was on, or
  /// change the resolution, and the window reopens somewhere the user cannot reach it — with no way
  /// back except deleting the saved state. Anything that still overlaps a visible screen is left
  /// exactly as it was; anything that doesn't is shrunk to fit and re-centred on the primary screen.
  static func frameOnAVisibleScreen(_ frame: NSRect) -> NSRect? {
    frameOnAVisibleScreen(frame, screens: NSScreen.screens.map(\.visibleFrame))
  }

  /// The pure core, taking the screens as data so it is unit-testable without a display.
  nonisolated static func frameOnAVisibleScreen(_ frame: NSRect, screens: [NSRect]) -> NSRect? {
    guard frame.width > 200, frame.height > 200 else { return nil }
    guard let primary = screens.first else { return nil }
    // "Reachable" means a real overlap, not a shared edge — a window one pixel onto a screen is not
    // something a user can grab.
    let minimumVisible: CGFloat = 60
    let isReachable = screens.contains { screen in
      let overlap = screen.intersection(frame)
      return !overlap.isNull && overlap.width >= minimumVisible && overlap.height >= minimumVisible
    }
    if isReachable { return frame }

    let size = NSSize(
      width: min(frame.width, primary.width), height: min(frame.height, primary.height))
    return NSRect(
      x: primary.midX - size.width / 2, y: primary.midY - size.height / 2,
      width: size.width, height: size.height)
  }

  /// Under the fixture, gives `window` the test's frame or the fixture's deterministic size and
  /// says so (see `attachWindow` for why). False everywhere else.
  private func fixtureSizes(_ window: NSWindow) -> Bool {
    #if DEBUG
      guard AppEnvironment.current.isFixture else { return false }
      if let frame = UITestFixture.windowFrame {
        window.setFrame(frame, display: false)
      } else {
        window.setContentSize(NSSize(width: 1450, height: 780))
        window.center()
      }
      return true
    #else
      return false
    #endif
  }

  /// Bind this store to its host `NSWindow` once the view tree resolves it (issue #70). Idempotent —
  /// `WindowAccessor` may resolve the same window more than once.
  func attachWindow(_ window: NSWindow) {
    hostWindow = window
    // Adopt this window's saved panes (issue #46) BEFORE anything below reads them. Here rather than
    // in `RootWindow.init` on purpose: SwiftUI can construct a view speculatively or repeatedly, and a
    // discarded init would consume a session no real window ever shows. `attachWindow` runs from
    // `WindowAccessor` in `viewDidMoveToWindow` — a real window exists, and it is still pre-display,
    // which is what the restored frame needs.
    if !didClaimSession, projectStore.takeLaunchRole() {
      isRestoreWindow = true
      claimsSavedSession = true
    }
    claimSessionIfNeeded()
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
    // Opt out of AppKit/SwiftUI window state restoration (issue #70), and KEEP it opted out now that
    // the app restores sessions itself (issue #46) — otherwise an OS-restored window and an
    // app-restored one would both appear.
    //
    // This alone does NOT opt out: with "Close windows when quitting an application" unchecked
    // (`NSQuitAlwaysKeepsWindows` on), SwiftUI still saved one main window per quit and brought it
    // back with its old `WindowSeed`, beside the ones `session.json` reopens. The scene-level
    // `.restorationBehavior(.disabled)` in `WorkroomApp.body` is what keeps it out.
    //
    // The built-in is declined because it is gated on that preference, which ships checked, so it
    // silently does nothing for most users. Panels and frames are restored from `session.json`
    // instead, which behaves the same for everyone.
    window.isRestorable = false
    // Set the window's size before it's shown (issue #70): `WindowAccessor` resolves it in
    // `viewDidMoveToWindow`, which fires during window setup (pre-display), so SwiftUI's value-based
    // `WindowGroup` (which otherwise opens windows at the minimum content size and doesn't restore the
    // window frame itself) doesn't leave a window opening small. A new window matches the window that
    // was current when it opened; the launch window restores its last frame, else a sensible default.
    if !didApplyInitialSize {
      didApplyInitialSize = true
      // Fixture mode gets an explicit test frame or the deterministic default size, ahead of
      // session restore and the `Defaults` fallback below — neither is hermetic (both read persisted
      // state), so a UI test's window geometry otherwise depends on whatever a prior interactive
      // `make app-run` session or an earlier automated run last left behind. Found chasing why
      // several tab-strip overflow tests never overflowed on a wide monitor: the real
      // `Defaults[.mainWindowFrame]` this machine had accumulated was 2469pt wide, plenty of room
      // for tabs these tests need to NOT fit.
      //
      // 1450, not 1200: `UITestFixture.applyFixtureDefaults` always forces the right inspector open
      // (300pt) and, since the sidebarVisible fixture override above, the Projects sidebar too
      // (270pt) — together they leave the detail column ~1200-270-300=630pt wide at 1200, right on
      // `TerminalPanes.fits()`'s floor (2×300pt panes + a 4pt divider = 604pt) with only single-digit
      // points of margin against real layout overhead. That intermittently refused ⌘D/⇧⌘D splits
      // (`SplitPaneUITests`, `TabActionsUITests`, etc.) — not a focus race, confirmed by the "Split
      // Right" menu item reading enabled the whole time; `fits()` was silently declining the split. At
      // 1450 the detail column is ~880pt: comfortably past the 604pt split floor, and still short of
      // the ~1000pt of chip content `TabStripOverflowUITests`/`TabStripScrollIntoViewUITests` need to
      // NOT fit, so overflow still triggers.
      if !fixtureSizes(window) {
        if let restored = pendingSessionRestore?.frame.map(NSRectFromString),
          // The saved session owns per-window frames (issue #46) and wins over both the
          // "match the current window" size and the single-slot `Defaults` key, which can only ever
          // describe one window and is now just the cold-start fallback.
          let frame = Self.frameOnAVisibleScreen(restored)
        {
          window.setFrame(frame, display: false)
          restoredFrame = frame
        } else if opensForHandOff {
          placeHandOffWindow(window)
        } else if let size = pendingInitialWindowSize {
          window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        } else if let frame = Self.savedMainWindowFrame().flatMap(Self.frameOnAVisibleScreen) {
          window.setFrame(frame, display: false)
          restoredFrame = frame
        } else {
          window.setContentSize(Self.newWindowContentSize)
          window.center()
        }
      }
    }
    // Persist this window's frame (debounced by AppKit's notifications) so a future launch restores
    // the size you left.
    if frameObservers.isEmpty {
      for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
        let token = NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self, weak window] _ in
          guard let window else { return }
          MainActor.assumeIsolated {
            // Per-window frames live in the saved session (issue #46); a drag fires this
            // continuously, which the coordinator's coalescing absorbs.
            SavedLayoutCoordinator.shared.markDirty()
            // The `Defaults` key holds ONE frame, so only the active window writes it — three windows
            // were previously racing to be the last mover. It is now the cold-start fallback for a
            // first launch with no session file, not the authority.
            guard self?.persistsSidebarPrefs == true else { return }
            Defaults[.mainWindowFrame] = NSStringFromRect(window.frame)
          }
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

  /// Route a terminal surface's first-responder focus up to the workroom selection — but only while the
  /// split is **on screen** and the focused surface belongs to one of its members. Sets
  /// `selectedTargetID` with history recording suppressed (issue #23 T3): clicking between co-displayed
  /// panes targets the right workroom for ⌘T/Run/notifications, without flooding ⌘[/⌘] back-forward.
  /// A no-op outside a split (the single selected target is already focused).
  ///
  /// `isWorkroomSplitVisible` — not merely "a split exists" — is what makes this safe. The split
  /// PERSISTS while you view a non-member workroom (`visibleWorkroomLayout` shows that one solo), so a
  /// member's surface can still report focus long after the user has selected someone else: the pane's
  /// `applyFocus` claims first responder from a `DispatchQueue.main.async` block holding the *previous*
  /// render's `isFocusedPane`, and that block can drain from a nested run loop (a blocking
  /// `Process.waitUntilExit` on the main thread spins one) before SwiftUI has committed the new layout.
  /// Without this gate that stale claim read as "the user picked this workroom" and yanked the selection
  /// straight back to the split member — so selecting a non-member chip took two clicks. A first
  /// responder change is only ever a *user's* pane choice when the split is actually being displayed.
  /// Scoping to the *visible* group (`visibleWorkroomSplit`) covers the same fault across groups: a
  /// member of some OTHER group is equally off screen, and its stale claim must not select it either.
  private func focusWorkroomMemberFromSurface(_ targetID: TerminalTarget.ID) {
    guard let group = visibleWorkroomSplit, isWorkroomSplitVisible,
      let sid = sidebarID(for: targetID), group.contains(sid),
      selectedTargetID != sid
    else { return }
    withHistorySuppressed {
      selectedTargetID = sid
      selectedProjectID = Self.projectPath(of: sid)
    }
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
    focusHistoryIfShown()
    focusRemoteStateIfShown()
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
  var windowTitle: String { title(for: selectedTargetID) }

  /// `sid` named as `windowTitle` names the selected one: "<project> — <workroom>", or the project
  /// for a root. Also how "Move to Workroom" lists the workrooms open in every window.
  func title(for sid: SidebarID?) -> String {
    switch sid {
    case .root(let path):
      return projectStore.project(at: path)?.displayName ?? defaultWindowTitle
    case .workroom(let path, let name):
      guard let project = projectStore.project(at: path)?.displayName else { return name }
      // Show the workroom's display label when set (issue #41); falls back to the real name.
      return "\(project) — \(displayName(forWorkroom: name, inProject: path))"
    case .creation(let path, _):
      let project = projectStore.project(at: path)?.displayName ?? defaultWindowTitle
      return "\(project) — New workroom"
    case .project, nil:
      return defaultWindowTitle
    }
  }

  /// Fallback title for a window with nothing selected — "Window <n>", or just "Window" until the
  /// registry has assigned this window its number.
  var defaultWindowTitle: String {
    windowNumber > 0 ? "Window \(windowNumber)" : "Window"
  }

  /// Resolve any `SidebarID` to its live `TerminalTarget` against the current project list (nil for
  /// `.project` or a since-removed target), as the lifecycle resolves it for every window. Backs
  /// `selectedTarget` and the history `isLive` check.
  func target(for sid: SidebarID) -> TerminalTarget? {
    lifecycle.target(for: sid)
  }

  /// Resolve a `TerminalTarget.ID` straight to its live target — the id-addressed sibling of
  /// `target(for:)`, for the seams that carry a target id rather than a `SidebarID`.
  func terminalTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget? {
    sidebarID(for: targetID).flatMap { target(for: $0) }
  }

  /// The window that actually shows `tabID` — its own window when it is detached (issue #172), else
  /// this store's main window.
  ///
  /// Every "bring the pane's window forward" path must go through here rather than reaching for
  /// `hostWindow` directly, or a detached pane raises the wrong window (and, worse, retargets this
  /// window's selection on the way). The two such paths are the notification click in `AppDelegate`
  /// and the cross-window Run reveal below.
  func window(forTab tabID: TerminalTab.ID?) -> NSWindow? {
    guard let tabID else { return hostWindow }
    return detachedPanes.window(for: tabID) ?? hostWindow
  }

  /// Raise a detached pane's window and return true, or return false when the tab isn't detached.
  /// The shared first question for every activation path, so none of them navigates first.
  @discardableResult
  func raiseDetachedPane(_ tabID: TerminalTab.ID?) -> Bool {
    guard let tabID, let window = detachedPanes.window(for: tabID) else { return false }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
  }

  /// Build and show a detached pane's window. `frame` restores a saved one (session restore);
  /// otherwise `origin` is the cursor at drop time and the window opens at the standard size.
  func openDetachedPane(
    tab: TerminalTab, target: TerminalTarget, origin: CGPoint?, frame: NSRect?
  ) {
    let tabID = tab.id
    let surface = terminals.surface(of: tabID)
    let location = detachedLocation(for: target)
    detachedPanes.open(
      tabID: tabID, title: tab.title, project: location.project, workroom: location.workroom,
      glyph: target.workroomGlyph, origin: origin, frame: frame,
      onCloseTab: { [weak self] in self?.requestCloseTerminalTab(tabID, for: target) },
      onDock: { [weak self] in self?.dockPane(tabID, for: target) },
      content: {
        DetachedPaneView(
          tabID: tabID, content: tab.content, surface: surface, target: target,
          sessions: terminals, store: self,
          onTitleChange: { [weak self] title in
            guard let self else { return }
            let location = self.detachedLocation(for: target)
            self.detachedPanes.setTitle(
              title, project: location.project, workroom: location.workroom,
              glyph: target.workroomGlyph, for: tabID)
          }
        )
      })
  }

  /// Dock a detached pane from anywhere, given only its tab id — the Window-menu path, which runs
  /// while the DETACHED window is key and so has no focused store of its own to act on.
  ///
  /// Tab ids are unique across windows, so the registry can name the store that owns this one.
  static func dockDetachedPane(_ tabID: TerminalTab.ID) {
    guard let store = WindowRegistry.shared.ownerOf(tabID: tabID),
      let target = store.targetOwning(tabID)
    else { return }
    store.dockPane(tabID, for: target)
  }

  /// A pane's own "Move to New Window" / "Move Back to Main Window" (#444): the right-click menus
  /// of its tab, its terminal, its title bar and its sidebar row, all acting on that pane rather than
  /// the focused one, as the Window menu's item does.
  func togglePaneWindow(_ tabID: TerminalTab.ID, targetID: TerminalTarget.ID) {
    guard let target = terminalTarget(forID: targetID) else { return }
    if terminals.detachedTabIDs.contains(tabID) {
      dockPane(tabID, for: target)
    } else {
      terminals.detachPane(tabID, for: target, at: NSEvent.mouseLocation)
    }
  }

  /// Dock a pane and SHOW it — the inverse of detaching, which raises the window it opens.
  ///
  /// The model half alone is not enough: docking closes the window the user is looking at, and the
  /// pane returns to a workroom that may not be selected, in a window that may be behind everything
  /// or minimised. Detaching is most useful precisely when you then go and do something else in the
  /// origin, so that is the common case, and without this the pane simply appears to vanish.
  func dockPane(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    terminals.dockPane(tabID, for: target)
    if let sid = sidebarID(for: target.id), selectedTargetID != sid {
      selectedTargetID = sid
      selectedProjectID = Self.projectPath(of: sid)
    }
    NSApp.activate(ignoringOtherApps: true)
    hostWindow?.makeKeyAndOrderFront(nil)
  }

  /// The target that owns `tabID`, for the paths that carry only a tab id.
  func targetOwning(_ tabID: TerminalTab.ID) -> TerminalTarget? {
    terminals.activeTargetIDs.compactMap { terminalTarget(forID: $0) }
      .first { terminals.tab(tabID, for: $0) != nil }
  }

  /// Pop the selected workroom's focused pane out into its own window — the View/Window-menu path
  /// (issue #172). No-op when nothing is selected, or when that pane is already detached.
  func detachFocusedPane() {
    guard let target = selectedTarget, let tab = terminals.focusedTab(for: target) else { return }
    terminals.detachPane(tab.id, for: target, at: NSEvent.mouseLocation)
  }

  /// Where a detached pane lives, for the secondary half of its window's title bar: which project,
  /// and which workroom within it. The pane's own name says what it is; this says where it is, which
  /// is precisely what you cannot tell from a window floating on its own.
  ///
  /// `workroom` is nil for a project ROOT target — there is no workroom to name, and the title bar
  /// uses that to pick the house glyph over the cube.
  func detachedLocation(for target: TerminalTarget) -> (project: String, workroom: String?) {
    // `project(forTargetID:)` already matches a target id back to its project (both the `root|` and
    // `wr|` forms); a workroom directory does NOT live under the project path, so matching on paths
    // would miss every workroom.
    guard let project = project(forTargetID: target.id) else { return (target.title, nil) }
    let isRoot = target.id == TargetID.root(project: project.path)
    return (project.displayName, isRoot ? nil : target.title)
  }

  /// The selected workroom, only when a workroom (not a root) is selected. Used by delete,
  /// the setup-log dock, and menu commands that are workroom-specific.
  var selectedWorkroom: Workroom? {
    guard case .workroom(let path, let name) = selectedTargetID,
      let project = projectStore.project(at: path)
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
  /// when a drag-reorder rewrites it. Reads `projectStore.projects` + `terminals.activeTargetIDs`
  /// (observed per target, changing only when a workroom gains its first terminal or loses its
  /// last) too — so the bar updates as terminals open/close.
  /// `order:` is for tests.
  func orderedWorkroomTargets(order: [TerminalTarget.ID]? = nil)
    -> [(sid: SidebarID, target: TerminalTarget)]
  {
    // Include every in-progress creation's target (issue #116): its terminal is withheld during a
    // setup script, so it isn't yet "active" (no terminal), but its chip must still show through setup.
    var active = terminals.activeTargetIDs
    active.formUnion(lifecycle.creationRunForTarget.keys)
    // A run's two ids resolve to one pane until the reload that publishes its name: one chip.
    var seen = Set<SidebarID>()
    return Self.orderedActiveTargets(
      persisted: order ?? workroomTabOrder, active: active
    )
    .compactMap { tid in
      // A create before its name lands (#483) has no workroom yet: its chip is its `.creation` pane.
      guard
        let sid = sidebarID(for: tid)
          ?? lifecycle.creationRun(forTargetID: tid).map(lifecycle.paneID(of:)),
        let target = target(for: sid), seen.insert(sid).inserted
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

  /// Step `index` by `delta` around a list of `count` items, wrapping at both ends. The one wrap rule
  /// for every cycling shortcut — the workroom bar (⇧⌥⌘←/→), the terminal strip (⌥⌘←/→) and the quick
  /// switcher's MRU step (issue #132) all read it, so an off-by-one can only ever exist in one place.
  /// Returns `index` unchanged when `count <= 0`; `delta` may be any sign or magnitude.
  nonisolated static func wrapped(index: Int, by delta: Int, count: Int) -> Int {
    guard count > 0 else { return index }
    return ((index + delta) % count + count) % count
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
      next = Self.wrapped(index: current, by: forward ? 1 : -1, count: tabs.count)
    } else {
      // No current tab: forward (→) enters at the rightmost, back (←) at the leftmost.
      next = forward ? tabs.count - 1 : 0
    }
    selectedTargetID = tabs[next].sid
    selectedProjectID = Self.projectPath(of: tabs[next].sid)
    return true
  }

  // MARK: Run command (issue #7)

  /// The run command's state and its process mechanics (issue #7). Starting a run and applying its
  /// status stay in `AppStore+RunCommand.swift`, since they read the store. Views reach it through
  /// the environment and everything else as `runCommand`; the store does not forward its members.
  let runCommand: RunCommandController
  /// The app's run commands: run config, and what spans windows (the window running a workroom's
  /// command, quit). This window's `runCommand` is registered with it while the window is up.
  let runCommands: RunCommands
  typealias RunState = RunCommandController.RunState
  typealias RunOutcome = RunCommandController.RunOutcome
  typealias RunToastItem = RunCommandController.RunToastItem

  // MARK: Loading

  /// Initial launch: render config-only (instant, no VCS calls), then refresh warnings.
  /// Branch labels hydrate asynchronously off both passes (see `WorkroomLifecycle.resolveBranches`).
  /// Load this window's view of the projects. `restore` is true only for the window SwiftUI restores
  /// at launch; combined with the one-shot `consumeInitialRestore()` it means exactly one window
  /// reapplies the persisted selection and every other (incl. every ⌘N) window starts blank (#70).
  func bootstrap(restore: Bool = true) async {
    let interval = LaunchSignposts.begin("Window bootstrap")
    defer { LaunchSignposts.end("Window bootstrap", interval) }
    // Exactly one window (the launch window) reapplies the saved selection; every other (incl. ⌘N)
    // window starts blank (issue #70).
    let shouldRestore = restore && projectStore.consumeInitialRestore()
    // A window reopened from the saved session (issue #46) restores its OWN selection, which
    // `claimSessionIfNeeded` has already put in `pendingRestoreSelection` from `attachWindow`.
    // `consumeInitialRestore` is app-wide and one-shot, so the launch window consumes it and every
    // sibling arrives here with `shouldRestore == false` — without this, the clear below would wipe
    // what the claim just set and every restored sibling would come back with nothing selected.
    let restoresOwnSession = pendingSessionRestore != nil
    #if DEBUG
      if AppEnvironment.current.isFixture {
        fixtureAutoSelect = shouldRestore || restoresOwnSession
        loadFixture()
        return
      }
    #endif
    // Drop the saved selection unless this window is entitled to one, so a ⌘N window opens with
    // nothing selected (no workroom, no terminal).
    if !shouldRestore && !restoresOwnSession {
      pendingRestoreSelection = nil
    }
    if projectStore.projects.isEmpty {
      await lifecycle.claimProvisionedOnce(cli)
      await load(warnings: "none")
      await load(warnings: "fast")
    } else {
      // Another window already loaded the shared project list — don't refork the CLI (issue #70,
      // OV #2). Just resolve this (possibly blank) window's selection against the existing list.
      await terminals.sessionService.prepareBackend()
      reconcileWindow(with: projectStore.projects)
    }
  }

  /// Reload only if it's been a while since the last load. Driven by the app regaining
  /// focus, so alt-tabbing back doesn't fork a git process per project every time.
  func reloadIfStale(minInterval: TimeInterval = 4) async {
    guard Date().timeIntervalSince(lastLoadAt) >= minInterval else { return }
    // Background poll (fires on every app activation, incl. waking from sleep). A transient
    // failure here — e.g. the `list` timing out because the just-woken machine is still cold —
    // must NOT pop a modal "Something went wrong"; the next activation just retries.
    await load(warnings: "fast", surfaceErrors: false)
  }

  func load(warnings: String, surfaceErrors: Bool = true) async {
    // In UI-test fixture mode every load resolves to the same fake projects — never shell out to
    // the CLI (so an on-focus `reloadIfStale` can't replace the fixture with the real config).
    #if DEBUG
      if AppEnvironment.current.isFixture {
        loadFixture()
        return
      }
    #endif
    var load = projectStore.beginLoad(cli: cli, warnings: warnings)
    let issuedGeneration = load.generation
    pendingLoads += 1
    isLoading = true
    defer {
      pendingLoads -= 1
      isLoading = pendingLoads > 0
    }
    while true {
      let result = await load.task.result
      // A newer read may still be pending. Do not return to mutation callers until it finishes:
      // addProject and create-as-split immediately resolve their new target after awaiting reload.
      if let latest = projectStore.latestLoad, latest.generation != load.generation {
        load = latest
        continue
      }
      // No suspension between checking the generation, publishing, and reconciling this window.
      switch result {
      case .success(let response):
        let registrations: [RepositoryRouter.Registration]
        do {
          registrations = try await projectStore.prepareRepositories(response.projects)
        } catch {
          if let latest = projectStore.latestLoad, latest.generation != load.generation {
            load = latest
            continue
          }
          if surfaceErrors, load.generation == issuedGeneration { present(error) }
          return
        }
        if !response.projects.isEmpty {
          await terminals.sessionService.prepareBackend()
        }
        if let latest = projectStore.latestLoad, latest.generation != load.generation {
          load = latest
          continue
        }
        if projectStore.claimPublication(of: load) {
          projectStore.globalBaseBranch =
            response.baseBranch?.isEmpty == false ? response.baseBranch : nil
          apply(response.projects, registrations: registrations)
          lifecycle.resolveBranches()
          vcsStatus.refreshWorkroomStatuses()
        } else {
          reconcileWindow(with: projectStore.projects)
        }
        lastLoadAt = Date()
      case .failure(let error):
        // Only the issuing caller owns this error's presentation policy and window.
        if surfaceErrors, load.generation == issuedGeneration { present(error) }
      }
      return
    }
  }

  #if DEBUG
    /// Load the deterministic UI-test fixture (see `UITestFixture`): inject the fake projects and, on
    /// the first load, auto-select the fixture workroom so a terminal renders immediately — the tests
    /// then drive splits/closes without any fragile sidebar navigation. Branch resolution is skipped
    /// (the temp-dir paths aren't real repos), so no git process is ever spawned. Idempotent: a
    /// later reload re-injects the same projects but preserves whatever the test has since selected.
    ///
    /// Tombstone-filtered like `apply`'s real-CLI path: `deleteWorkroom`'s teardown script touches the
    /// fixture's temp directory, which the file watcher picks up and reloads mid-teardown — without
    /// filtering, that reload re-injected the just-deleted workroom (and its notifications) straight
    /// back from the unconditionally-canned fixture list a beat after the delete, since fixture mode
    /// never reaches `apply` at all (caught writing the delete-clears-notifications UI test).
    private func loadFixture() {
      let fixtures = applyingDeletionTombstones(UITestFixture.projects())
      projectStore.projects = fixtures
      // A container create mid-download, still unnamed (#309, #483). Once: a reload re-enters here.
      if let pulled = UITestFixture.imagePull, let project = fixtures.first,
        !lifecycle.creationRuns.values.contains(where: { $0.project.path == project.path })
      {
        let run = CreationRun(
          project: project, kind: .container(.docker), splitAnchor: nil, previousSelection: nil)
        run.begin("repository")
        run.begin("image")
        run.pullFraction = pulled
        lifecycle.register(run)
      }
      // Fixture mode never reaches `apply`, so restore has to be released here or saves would stay
      // suspended for the whole run (issue #46). Fixture projects live in a temp directory that a real
      // saved session can't address anyway.
      restorePersistedSessionIfPending(in: fixtures)
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
          runCommands.setRunConfig(.empty, forProject: project.path)
        } else {
          runCommands.setRunConfig(
            RunConfig(
              command: UITestFixture.runCommand ?? "echo PROBE_OK; sleep 30", autoRun: false),
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
          let firstSurface = terminals.tabs(for: target).first.flatMap {
            terminals.surface(of: $0.id)
          }
          if let title = UITestFixture.usageCodingAgentTitle {
            firstSurface?.handleTitleChange(title)
          }
          // Oversized tab title for the pane title bar's truncation tests (issue #150). Same route as
          // the agent title above — a shell-set title latches as `liveTitle`, which is what
          // `TerminalTab.title` (and so the chip and the pane bar) reads first.
          if UITestFixture.longTabTitle {
            firstSurface?.handleTitleChange(UITestFixture.longTabTitleValue)
          }
          // Two-tab scenario (drag/reorder XCUITest, issue #23): also open a terminal for the second
          // workroom so the workroom tab bar shows two chips to reorder.
          if UITestFixture.twoTabs, project.workrooms.count > 1 {
            terminals.ensureTab(for: project.workrooms[1].target(inProject: project.path))
          }
          // Terminal-strip overflow scenario (pinned "+" XCUITest, issue #129): `ensureTab` opened the
          // first tab, so add the rest.
          for _ in 1..<UITestFixture.terminalTabs { _ = terminals.addTab(for: target) }
          // Program status scenario (#358): waiting, stale and failed panes, seeded without a daemon.
          if UITestFixture.programStatus {
            UITestFixture.seedProgramStatus(in: terminals, target: target)
          }
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
            workroomSplits = [
              .split(
                id: UUID(), orientation: .horizontal, ratio: 0.5,
                first: .leaf(.root(project: project.path)),
                second: .leaf(.workroom(project: project.path, name: workroom.name)))
            ]
            // Create-as-split scenario (issue #171): the SELECTED member is mid-setup-script, so its
            // pane draws that create's own dialog while the root pane stays on screen beside it — the
            // whole point of routing a focused create through the split rather than full-frame. The log
            // is left UNFINISHED, which is what a running script looks like (a UI test can't drive a
            // real create; nothing here shells out to the CLI). `creatingWorkrooms` is what the pane's
            // Run gate and `startRunCommand` both read, so seeding it is what makes the absent Run
            // assertable.
            //
            // Two variants: a create on its setup script, and one still on its worktree (#483).
            let hasSetup = !UITestFixture.creatingSplitMemberNoSetup
            if UITestFixture.creatingSplitMember || UITestFixture.creatingSplitMemberNoSetup {
              let run = CreationRun(
                project: project, kind: nil, splitAnchor: nil, previousSelection: nil)
              run.finish("fetch", as: .skipped(reason: "No remote to fetch from"))
              run.begin("worktree")
              if hasSetup {
                run.begin("script")
                run.append("Running setup script…", to: "script")
              }
              run.setName(workroom.name)
              lifecycle.creationRuns[run.id] = run
              lifecycle.creationRunForTarget[target.id] = run.id
              lifecycle.creatingWorkrooms.insert(target.id)
            }
            // Second-group scenario: a window holds SEVERAL split groups, so seed a second one from two
            // more workrooms (needs `-WorkroomUITestWorkroomCount 3`). Both groups persist; the visible
            // one follows the selection, which is why the test can hop between them.
            if UITestFixture.secondWorkroomSplit, project.workrooms.count >= 3 {
              let pair = Array(project.workrooms[1...2])
              for member in pair {
                terminals.ensureTab(for: member.target(inProject: project.path))
              }
              workroomSplits.append(
                .split(
                  id: UUID(), orientation: .horizontal, ratio: 0.5,
                  first: .leaf(.workroom(project: project.path, name: pair[0].name)),
                  second: .leaf(.workroom(project: project.path, name: pair[1].name))))
            }
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
      vcsStatus.seedStatuses()
      lastLoadAt = Date()
    }
  #endif

  private func apply(_ incoming: [Project], registrations: [RepositoryRouter.Registration]) {
    let interval = LaunchSignposts.begin("Publish projects and reconcile window")
    defer { LaunchSignposts.end("Publish projects and reconcile window", interval) }
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
    // Drop projects (#287) and workrooms (issue #116) with an in-flight optimistic deletion: a
    // `list` snapshot taken before the teardown persisted still lists them, so without this a
    // concurrent reload would resurrect them. Cleared from `deletingProjects`/`deletingWorkrooms`
    // when the teardown ends.
    let fresh = applyingDeletionTombstones(sorted)
    // Before publishing, so a remote workroom's panes find its host when they mount (#253).
    // No sweep while a delete is in flight: `fresh` leaves out hosts config still records, and a
    // delete that fails keeps them (#296).
    let deleting = !lifecycle.deletingProjects.isEmpty || !lifecycle.deletingWorkrooms.isEmpty
    RemoteHosts.shared.reachability.adopt(fresh, sweep: !deleting)
    // Older builds' base machines go, once per launch; the same in-flight-delete hold as the sweep.
    if !deleting {
      BaseRetirement.retireOnce(fresh, effects: BaseRetirement.live(cli: cli)) { [weak self] in
        Task { await self?.reload() }
      }
    }
    let acceptedPaths = Set(fresh.flatMap { [$0.path] + $0.workrooms.map(\.path) })
    RepositoryRouter.shared.replaceLocal(
      registrations.filter {
        acceptedPaths.contains($0.localSourcePath ?? $0.location.path)
      })
    RepositoryRouter.shared.replaceRemote(RemoteWorkrooms.registrations(fresh))
    let resolved = selectedWorkroom?.reachableHost
    projectStore.projects = fresh
    // A selection restored before its projects were loaded opened nothing then (#309). Only then:
    // every reload passes here, and opening again on each would restart a container the user
    // stopped.
    if resolved == nil, let host = selectedWorkroom?.reachableHost {
      RemoteHosts.shared.reachability.select(.remote(host), in: ObjectIdentifier(self))
      RemoteHosts.shared.reachability.activate(.remote(host))
      forwardDeclaredPorts()
    }
    // Prune shared caches only when publishing an accepted snapshot.
    let liveIDs = Set(fresh.map(\.id))
    vcsStatus.rootRefs = vcsStatus.rootRefs.filter { liveIDs.contains($0.key) }
    // Keyed on what the sweep probes, not on the sidebar: a workroom that turned remote is no longer
    // refreshed, so its last local status would otherwise tint it and its project's badge forever.
    let probed = Set(vcsStatus.statusWorkItems().map(\.sid))
    vcsStatus.workroomStatuses = vcsStatus.workroomStatuses.filter {
      probed.contains($0.key)
    }
    reconcileWindow(with: fresh)
  }

  /// Shared publication does not update a window's selection, splits, sheets or saved session.
  /// Every successful reload must reconcile its own window, even if another waiter published.
  private func reconcileWindow(with fresh: [Project]) {
    // Tool-version floor (see `VCSToolVersions`). Single-flighted process-wide, so repeat calls on
    // later reloads are free once it has landed.
    refreshVCSToolReport()
    // First load after launch: restore last session's selection (issue #14) before it's
    // validated below. Resolved against the live projects, so a since-deleted target — or a
    // restore that loses the race to a user click — resolves to nil and falls through.
    if selectedTargetID == nil, let saved = pendingRestoreSelection {
      selectedTargetID = Self.validatedSelection(saved.sidebarID, in: fresh)
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
    // Remember what was selected before validation nils a dead one: it's the only record of which split
    // group the user was viewing, and the prune's re-point needs it to land on THAT group's survivor
    // rather than some other group's.
    let formerSelection = selectedTargetID
    // A create's pane lives as long as its run, whatever the list says (#483).
    if selectedTargetID.flatMap(target(for:))?.unavailability != .creating {
      selectedTargetID = Self.validatedSelection(selectedTargetID, in: fresh)
    }
    // Drop any split leaf whose workroom went away on reload (issue #23 follow-up self-heal); collapses
    // to a survivor / dissolves below two, re-pointing selection. Runs after selection is validated so
    // history/notifications/run-toolbar (all keyed on `selectedTargetID`) follow the survivor.
    pruneWorkroomSplitToLiveLeaves(formerSelection: formerSelection)
    let liveSidebarIDs = Self.liveSidebarIDs(in: fresh)
    if let pendingLabel = modals.pendingWorkroomLabel,
      !liveSidebarIDs.contains(
        .workroom(project: pendingLabel.project.path, name: pendingLabel.workroom.name))
    {
      modals.pendingWorkroomLabel = nil
    }
    // Keep the app's root-branch watchers in sync with the project set (start new, drop departed).
    lifecycle.updateRootBranchWatches()
    // Rehydrate this window's panes (issue #46). LAST, and race-free by construction rather than by
    // timing: a pane only mounts once `selectedTargetID` is non-nil AND SwiftUI has rendered, neither
    // of which can happen inside this synchronous main-actor body. By the time
    // `WorkroomTerminalsView`'s `.task` runs `ensureInitialTerminal`, `tabCount != 0`, so its existing
    // guard makes it a no-op and no stray "Terminal 1" appears beside the restored panes.
    restorePersistedSessionIfPending(in: fresh)
    endOrphanedSessionsOnce(in: fresh)
  }

  /// Remove projects and workrooms with an in-flight deletion from the accepted listing. The same
  /// accepted path set filters the already-normalized routing entries before projects are
  /// published.
  private func applyingDeletionTombstones(_ projects: [Project]) -> [Project] {
    let deletingProjects = lifecycle.deletingProjects
    let projects = projects.filter { !deletingProjects.contains($0.path) }
    let tombstoned = lifecycle.deletingWorkrooms
    guard !tombstoned.isEmpty else { return projects }
    return projects.map { project in
      let kept = project.workrooms.filter {
        !tombstoned.contains(TargetID.workroom(project: project.path, name: $0.name))
      }
      guard kept.count != project.workrooms.count else { return project }
      return Project(
        path: project.path, vcs: project.vcs, workrooms: kept, host: project.host,
        baseBranch: project.baseBranch)
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

  /// `id`'s sidebar row while it is still listed, else nil (always nil for a create's pane and the
  /// Quick Terminal, which have no row).
  func sidebarID(for id: TargetID) -> SidebarID? {
    projectStore.sidebarID(for: id)
  }

  nonisolated private static func targetExists(_ id: SidebarID, in projects: [Project]) -> Bool {
    switch id {
    case .root(let path):
      return projects.contains { $0.id == path }
    case .workroom(let path, let name):
      return projects.first { $0.id == path }?.workrooms.contains { $0.id == name } ?? false
    case .project, .creation:
      // A create's pane exists while its run does, which `reconcileWindow` checks itself.
      return false
    }
  }

  /// This window's part of a change under a project's VCS metadata dir, which the app's one watch
  /// (`WorkroomLifecycle.rootBranchDidChange`) hands every window, for a listed project with probed
  /// repositories, before it re-resolves the root label once.
  func handleRootBranchChange(projectID: Project.ID) {
    // Only a visible inspector (not merely the active section — that persists while hidden) whose
    // target belongs to THIS project repaints.
    guard inspectorIsVisible, inspectorTargetID?.belongsToProject(projectID) == true else { return }
    // Live History (issue #59 follow-up): this project's VCS metadata dir moved — a commit / ref
    // update in the project or one of its workrooms (git worktree refs land in the shared `.git`, so
    // they surface here even though nothing lands under the workroom dir). Independent of the label:
    // a normal commit usually leaves the branch label unchanged, so gating this on the label
    // actually changing would skip the main case. The read is read-only, so it can't re-fire this
    // watcher.
    if historySectionShown { commitHistory.refresh() }
    // The VCS toolbar keys on the same writes, and for exactly the same reason: a fetch lands
    // `FETCH_HEAD` + `refs/remotes/*`, a push moves a ref, a commit moves the branch tip — all inside
    // this watched dir, for the project AND every workroom of it. Forced, because the watcher has
    // already coalesced the burst and the toolbar's own TTL would otherwise swallow the update.
    if remoteToolbarShown { remoteState.refresh(force: true) }
  }

  // MARK: Mutations

  /// Registers a project at `path`. With `create`, a non-existent directory is
  /// created and git-initialized by the CLI (issue #103, "Create new directory…");
  /// otherwise `path` must already be a Git repo ("From existing path…").
  ///
  /// Returns the outcome so a caller with its own inline error UI (the onboarding wizard, issue
  /// #151) can react locally, in addition to (not instead of) the alert this always presents on
  /// failure — the sidebar's own Add Project flow relies on that alert and ignores the return value.
  @discardableResult
  func addProject(_ path: String, create: Bool) async -> Result<Void, Error> {
    // Fixture mode never shells out to the real CLI for anything else (`bootstrap`/`load` both
    // short-circuit to `loadFixture()`) — this is the one mutation that didn't follow that rule,
    // which meant a UI test driving the wizard's real Add Project step (issue #151) genuinely
    // registered a project in the developer's own `~/.config/workroom/config.json` (the CLI has no
    // config-path override to isolate against instead). Simulate the same success shape locally.
    #if DEBUG
      if AppEnvironment.current.isFixture {
        let canonical = AddProjectSheetModel.normalize(path)
        if !projectStore.projects.contains(where: { $0.path == canonical }) {
          projectStore.projects.append(Project(path: canonical, vcs: "git", workrooms: []))
        }
        selectedProjectID = canonical
        selectedTargetID = .root(project: canonical)
        return .success(())
      }
    #endif
    do {
      let canonical = try await cli.addProject(path, create: create)
      await reload()
      // Select the freshly added project (by the canonical path the CLI registered —
      // it resolves symlinks and ~, so it's more reliable than the typed path) and
      // open a terminal on its root, mirroring workroom creation rather than leaving
      // the user on the "Nothing selected" empty state (issue #104). A new project
      // has no workrooms, so the root is the only sensible terminal to open.
      guard let match = projectStore.project(at: canonical) else {
        throw NSError(
          domain: "Workroom.AppStore", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "The project was registered, but could not be loaded. Refresh to try again."
          ])
      }
      selectedProjectID = match.id
      selectedTargetID = .root(project: match.path)
      return .success(())
    } catch {
      present(error)
      return .failure(error)
    }
  }

  // MARK: Creates and deletes

  // The flows are the lifecycle's (`WorkroomLifecycle+Create`, `WorkroomLifecycle+Delete`). This
  // window is the `LifecycleWindow` of the ones it asks for, and applies what every create and
  // delete does to it (`handleLifecycleEvent`).

  /// Set the branch a project's new workrooms start from (nil or blank: origin's default branch),
  /// through the CLI, which owns it so `workroom create` in a terminal agrees.
  /// Returns the CLI's error when it refused, which this window shows unless `presentingError` is
  /// false (Settings ▸ Projects shows it by the field).
  @discardableResult
  func setBaseBranch(
    _ branch: String?, forProject projectPath: String, presentingError: Bool = true
  ) async -> String? {
    let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
    var refused: String?
    do {
      try await cli.setBaseBranch(
        project: projectPath, branch: trimmed?.isEmpty == false ? trimmed : nil)
    } catch {
      refused = WorkroomLifecycle.errorText(error)
      if presentingError { present(error) }
    }
    await reload()
    return refused
  }

  func openCreationPane(_ pane: SidebarID, in project: Project, beside anchor: SidebarID?) {
    selectedProjectID = project.id
    let landedInSplit =
      anchor.map {
        insertWorkroomSplit(
          pane, beside: $0, edge: .right, destinationRect: workroomPaneRect(for: $0))
      } ?? false
    if !landedInSplit { selectedTargetID = pane }
  }

  func closeCreationPane(_ pane: SidebarID, returningTo previous: SidebarID?) {
    if workroomSplit(containing: pane) != nil {
      removeWorkroomSplitMember(pane)
    } else if selectedTargetID == pane {
      selectedTargetID = previous.flatMap { target(for: $0) == nil ? nil : $0 }
    }
  }

  /// What a create or delete in any window does to this one (`WorkroomLifecycle.Event`), applied
  /// the moment the lifecycle hands it over.
  func handleLifecycleEvent(_ event: WorkroomLifecycle.Event) {
    switch event {
    case .targetRemoved(let sid):
      detachTarget(sid)
    case .paneReplaced(let old, let new):
      replacePane(old, with: new)
    case .rootBranchChanged(let projectID):
      handleRootBranchChange(projectID: projectID)
    }
  }

  /// Per-window: drop a target from this window's split, then clear selection if it pointed there
  /// (issue #70). A create's pane takes the step whose log this window had open with it. Every
  /// window applies it when the lifecycle removes a target (`.targetRemoved`).
  func detachTarget(_ sid: SidebarID) {
    if case .creation(_, let id) = sid { expandedCreationLogs[id] = nil }
    removeWorkroomSplitMember(sid)
    if selectedTargetID == sid { selectedTargetID = nil }
  }

  /// Puts `new` wherever `old` is in this window: the selection, or its split member. Every window
  /// applies it when the lifecycle swaps a create's pane (`.paneReplaced`).
  func replacePane(_ old: SidebarID, with new: SidebarID) {
    if selectedTargetID == old { withHistorySuppressed { selectedTargetID = new } }
    workroomSplits = workroomSplits.map { $0.contains(old) ? $0.replacingLeaf(old, with: new) : $0 }
  }

  /// Reaps a single terminal target's in-app surface and clears all the per-target state
  /// keyed by its `TerminalTarget.ID`. Extracted from `deleteWorkroom`'s teardown so a
  /// project delete (which reaps a root + every workroom target) reuses the exact same
  /// cleanup — no second, drifting copy. Run only AFTER any live run process has been
  /// gracefully stopped (issue #7), so the dev server isn't orphaned against a deleted dir.
  func reapTargetLocally(_ targetID: TerminalTarget.ID) async {
    await terminals.reap(targetID)
    // `reap` only fires `.tabsRemoved` (which clears run state) when tabs existed; a target armed
    // for auto-run but deleted before its pane mounted has none, so clear directly too (issue #7).
    runCommand.clearRun(for: targetID)
    // Drop the gone target's notifications and pull any banners it already delivered.
    services.notifier.withdraw(tabIDs: notifications.removeForTarget(targetID))
  }

  /// Drops a workroom from the in-memory project list so the sidebar updates instantly. `internal`
  /// so the label-cleanup it performs is a unit-test seam (mirrors `removeProjectLocally`).
  func removeWorkroomLocally(_ workroom: Workroom, in project: Project) {
    guard let idx = projectStore.projects.firstIndex(where: { $0.id == project.id }) else { return }
    let p = projectStore.projects[idx]
    projectStore.projects[idx] = Project(
      path: p.path, vcs: p.vcs, workrooms: p.workrooms.filter { $0.id != workroom.id },
      host: p.host, baseBranch: p.baseBranch)
    forgetLabels(forProject: project.path, workroomNames: [workroom.name])
    // Same reasoning as the label: a per-workroom cache keyed by `SidebarID` with no other pruning,
    // so without this it outlives the workroom and a same-named recreate inherits its branch name.
    setResolvedBranchName(nil, for: .workroom(project: project.path, name: workroom.name))
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
    let targetIDs = project.targetIDs

    projectStore.projects.removeAll { $0.id == project.id }
    if selectedProjectID == project.id { selectedProjectID = nil }
    // Clear selection if it pointed anywhere inside this project (its root or any workroom).
    if let sel = selectedTargetID, sel.belongsToProject(project.path) { selectedTargetID = nil }
    removeWorkroomSplitMember(.root(project: project.path))
    vcsStatus.workroomStatuses[.root(project: project.path)] = nil
    setResolvedBranchName(nil, for: .root(project: project.path))
    for w in project.workrooms {
      removeWorkroomSplitMember(.workroom(project: project.path, name: w.name))
      vcsStatus.workroomStatuses[.workroom(project: project.path, name: w.name)] = nil
      setResolvedBranchName(nil, for: .workroom(project: project.path, name: w.name))
    }
    // Drop the project's create runs as well, named or not, in every window (issue #167, same
    // reasoning as the labels below: a same-named recreate must not inherit stale state). Only ended
    // runs can be here: a running one refuses the delete.
    for run in lifecycle.creationRuns.values where run.project.path == project.path {
      lifecycle.discardCreationRun(run)
    }
    // Drop every label belonging to this project's workrooms (issue #41) — prune-on-load is the
    // backstop, but clearing here keeps it immediate and prevents a same-named recreate from
    // inheriting a stale label.
    forgetLabels(forProject: project.path, workroomNames: project.workrooms.map(\.name))
    // Drop this project's recorded fetch stamp for the same reason the labels go: it is keyed by
    // project ROOT PATH in a persisted dictionary with no other pruning, so without this it survives
    // for the life of the install and a re-add of the same path inherits a stale "last fetched".
    if Defaults[.vcsLastFetch][project.path] != nil {
      var stamps = Defaults[.vcsLastFetch]
      stamps[project.path] = nil
      Defaults[.vcsLastFetch] = stamps
    }
    if modals.pendingWorkroomLabel?.project.path == project.path {
      modals.pendingWorkroomLabel = nil
    }
    return targetIDs
  }

  // MARK: Menu-command convenience

  /// Open a new terminal tab in the selected target — root or workroom (⌘T).
  func newTerminalInSelectedTarget() {
    guard let target = selectedTarget, target.opensTerminals else { return }
    // Never open a shell into a worktree a setup script is still writing (issues #167/#171). The
    // File menu item disables itself on the same predicate (`RootView.terminalInteractionAvailable`),
    // but that is a display rule — this is the chokepoint every caller routes through, the way
    // `startRunCommand` guards the run path rather than trusting its buttons.
    guard !lifecycle.isCreationBlocking(target.id) else { return }
    newTerminal(in: target)
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
    // `tab(_:for:)`, not `tabs(for:)`: the latter is the DISPLAYED list, which since issue #172
    // excludes detached panes — so looking a tab up through it would silently no-op the close button
    // on a popped-out window.
    guard let tab = terminals.tab(tabID, for: target) else { return }
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
    // `allTabs`, not `tabs`: "every tab" includes a pane that is currently in its own window.
    let victims = terminals.allTabs(for: target).map(\.id)
    guard !victims.isEmpty else { return }
    requestClose(victims, for: target, keep: nil)
  }

  /// Close a workroom (or root) and all its terminal tabs — the tab bar's "Close" context-menu item,
  /// confirmed first via `pendingWorkroomClose`. Skips the per-tab `closeNeedsConfirm` prompt (the
  /// close-the-whole-workroom confirmation already covered it), then tears every tab down through the
  /// shared `performClose` (graceful run-command stop included). Once the last tab closes the chip
  /// leaves the bar. The workroom's files are untouched — that's `deleteWorkroom`. No-op if empty.
  func closeWorkroom(for target: TerminalTarget) {
    // `allTabs`: a detached pane left behind here would keep the workroom's chip in the bar forever
    // (`activeTargetIDs` reads the unfiltered dictionary).
    let victims = terminals.allTabs(for: target).map(\.id)
    guard !victims.isEmpty else { return }
    performClose(victims, for: target)
  }

  /// The `(workroom, project)` a workroom `SidebarID` points at, or nil for a root/project id or a
  /// since-removed workroom. Lets the tab bar's context menu raise the same delete confirm the
  /// sidebar does without re-deriving the lookup.
  func workroomAndProject(for sid: SidebarID) -> (workroom: Workroom, project: Project)? {
    guard case .workroom(let path, let name) = sid,
      let project = projectStore.project(at: path),
      let workroom = project.workrooms.first(where: { $0.id == name })
    else { return nil }
    return (workroom, project)
  }

  /// Close every tab in `target` except `keepID` ("Close others"), confirming once if any victim has
  /// a live process. No-op when there's nothing else to close.
  func requestCloseOtherTerminalTabs(_ keepID: TerminalTab.ID, for target: TerminalTarget) {
    let victims = terminals.allTabs(for: target).map(\.id).filter { $0 != keepID }
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
    // `allTabs`: the confirm list must be able to see a detached victim, or a live process could be
    // killed without `closeNeedsConfirm` ever considering it.
    let tabs = terminals.allTabs(for: target).filter { victims.contains($0.id) }
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
    #if DEBUG
      if AppEnvironment.current.isFixture { return false }
    #endif
    return Self.resolveConfirmOnClose(override: confirmOnCloseOverrideForTesting)
      && tabs.contains { !(terminals.surface(of: $0.id)?.processHasExited ?? true) }
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
      #if DEBUG
        if AppEnvironment.current.isFixture {
          terminals.closeTab(id, for: target)
          continue
        }
      #endif
      runCommand.closingRunTab(id, for: target.id) { [weak self] in
        self?.terminals.closeTab(id, for: target)
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
    let next = Self.wrapped(index: current, by: forward ? 1 : -1, count: tabs.count)
    terminals.select(tabs[next].id, for: target)
    return true
  }

  /// The focused pane's surface for the selected target (the focused tab is the focused pane), or nil
  /// when nothing's selected / no terminal exists. Drives the Go menu's scroll items (issue #42).
  private var focusedSurface: GhosttySurfaceView? {
    guard let target = selectedTarget else { return nil }
    return terminals.focusedTab(for: target).flatMap { terminals.surface(of: $0.id) }
  }

  /// Scroll the focused terminal to the top / bottom of its scrollback (issue #42). Driven by the Go
  /// menu's "Scroll to Top"/"Scroll to Bottom" items; ⌘↑/⌘↓ also reach the surface directly.
  func scrollFocusedTerminalToTop() { focusedSurface?.scrollToTop() }
  func scrollFocusedTerminalToBottom() { focusedSurface?.scrollToBottom() }

  /// Open the find bar on the focused pane (⌘F / Edit ▸ Find): the terminal's scrollback search for a
  /// terminal pane, the shared find for a file/diff/changeset pane.
  func startFindInFocusedPane() {
    guard let target = selectedTarget, let tab = terminals.focusedTab(for: target) else { return }
    switch tab.content {
    case .terminal: focusedSurface?.startSearch()
    case .file, .diff, .changeset: contentFind.open()
    }
  }

  /// Navigate the focused pane's *active* find to the next/previous match (⌘G / ⇧⌘G), wrapping at the
  /// ends. Tries the terminal search, then the shared find. Returns `false` (so the key passes
  /// through to the terminal) when neither is open. `@discardableResult` for the menu-button call site.
  @discardableResult
  func navigateFocusedPaneSearch(forward: Bool) -> Bool {
    if let surface = focusedSurface, surface.searchModel.isActive {
      surface.searchModel.navigate(forward ? .next : .previous)
      return true
    }
    // Only when a file/diff/changeset pane is actually focused: the find model is shared, so a stale
    // open state must not let ⌘G step a hidden find from a terminal pane (review). `.focusChanged`
    // already closes it on focus-away; this is the defence-in-depth read-side check.
    if let target = selectedTarget, let tab = terminals.focusedTab(for: target) {
      switch tab.content {
      case .file, .diff, .changeset:
        guard contentFind.isOpen, contentFind.hasMatches else { break }
        forward ? contentFind.next() : contentFind.previous()
        return true
      case .terminal:
        break
      }
    }
    return false
  }

  /// Split the focused pane by opening a new terminal beside it: ⌘D to the right, ⇧⌘D below
  /// (issue #3). The new terminal inherits the focused pane's working directory.
  func splitFocusedRight() {
    guard let target = selectedTarget, target.opensTerminals else { return }
    terminals.splitFocusedPane(for: target, orientation: .horizontal)
  }

  func splitFocusedDown() {
    guard let target = selectedTarget, target.opensTerminals else { return }
    terminals.splitFocusedPane(for: target, edge: .bottom)
  }

  func splitFocusedLeft() {
    guard let target = selectedTarget, target.opensTerminals else { return }
    terminals.splitFocusedPane(for: target, edge: .left)
  }

  func splitFocusedUp() {
    guard let target = selectedTarget, target.opensTerminals else { return }
    terminals.splitFocusedPane(for: target, edge: .top)
  }

  /// Move keyboard focus to the adjacent pane in a split (⌃⌘arrows). Returns whether focus moved, so
  /// the key monitor passes the event through to the terminal when there's no pane that way.
  @discardableResult
  func focusPane(_ direction: PaneDirection) -> Bool {
    guard let target = selectedTarget else { return false }
    return terminals.focusAdjacentPane(direction, for: target)
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

  /// Raise a workroom picker, recording whether the pick should split (issue #163). THE entry
  /// point — every raise site goes through it (the two File-menu pairs and the title bar's + and
  /// open buttons), so `pickerSplits` cannot be left set by one path and read by another.
  func raiseWorkroomPicker(_ kind: ActivePicker, split: Bool = false) {
    modals.pickerSplits = split
    switch kind {
    case .new: modals.requestNewWorkroomPicker = true
    case .open: modals.requestOpenWorkroomPicker = true
    }
  }

  /// Read the pending split intent and clear it. Each raise consumes exactly once, so a cancelled
  /// ⌥⌘N cannot leak "split" into a later plain raise from the title bar's + button.
  func consumePickerSplitIntent() -> Bool {
    defer { modals.pickerSplits = false }
    return modals.pickerSplits
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
  /// testable without `NSApp` (issue #89). Total over all five inputs. `record == false` ⇒ the
  /// event is suppressed (you're looking at that exact pane). `pulse` border-flashes an on-screen
  /// non-cursor pane to locate it (issue #82) — never the cursor pane (`shouldPulse` handles that),
  /// never while backgrounded (those get a banner, not a pulse). The `isOnScreen` guard on `seen`
  /// keeps it total: an off-screen tab always records, even if flagged selected + cursor.
  ///
  /// `detachedWindowKey` is nil for a docked pane and short-circuits everything for a popped-out one
  /// (issue #172): a pane in its own window is not in the origin's layout at all, so the origin's key
  /// state, selection and cursor tab each answer the wrong question — its own window is the whole
  /// answer. Key ⇒ the user is looking straight at it, so the activity is seen. Not key ⇒ as unseen
  /// as an off-screen tab, and never a pulse: a border flash in a window you are not looking at
  /// locates nothing. Without this, output in the pane you are staring at still records unread and
  /// fires the arrival sound + toast.
  nonisolated static func activityOutcome(
    appFrontmost: Bool, isOnScreen: Bool, isSelectedMember: Bool, isCursorTab: Bool,
    detachedWindowKey: Bool? = nil
  ) -> (pulse: Bool, record: Bool) {
    if let detachedWindowKey { return (pulse: false, record: !detachedWindowKey) }
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
    //   detached, its own window key               → SEEN: suppress (issue #172)
    //   detached, its own window not key           → notify (no pulse)
    //
    // `seen` (suppress?) keys on `hostWindow?.isKeyWindow` — is THIS pane the one focused. The
    // banner-vs-in-app routing below keys on `NSApp.isActive` — is the APP frontmost at all. Two
    // different questions, deliberately different vocabulary: a frontmost-but-not-key window still
    // shows an in-app toast, never a banner. (`isKeyWindow` already implies the app is active.)
    // Per-window so a *non-key* window's selected cursor tab still notifies (issue #89, multi-window)
    // instead of being suppressed because some other window holds key.
    let appFrontmost = hostWindow?.isKeyWindow == true
    let onScreen = onScreenTarget(forID: targetID)
    let isSelectedMember = onScreen?.id == primaryTarget?.id
    let isCursorTab = onScreen.map { terminals.focusedTab(for: $0)?.id == tabID } ?? false
    let outcome = Self.activityOutcome(
      appFrontmost: appFrontmost, isOnScreen: onScreen != nil,
      isSelectedMember: isSelectedMember, isCursorTab: isCursorTab,
      detachedWindowKey: detachedPanes.window(for: tabID)?.isKeyWindow)
    if outcome.pulse { terminals.pulsePaneActivity(tabID) }
    let show = { [weak self] () -> (() -> Void)? in
      guard let self, outcome.record,
        let note = self.notifications.record(
          targetID: targetID, tabID: tabID, source: self.notificationSource(forTargetID: targetID),
          activity: activity, focused: false, origin: ObjectIdentifier(self))
      else { return nil }
      self.surface(note)
      return { [weak self] in self?.withdrawNotification(note) }
    }
    // A program's own notification goes through its session's requests, so one request makes one
    // notification (#358, #481): folded into its alert, held for it, or shown.
    if case .osc(let title, let body) = activity,
      let session = terminals.sessionID(forTab: tabID, inTarget: targetID)
    {
      ProgramStatusAlerts.shared.programNotified(
        session: session, title: title, body: body, show: show)
      return
    }
    _ = show()
  }

  /// A program's own notification that a "needs you" alert replaces (#481): its toast, its entry
  /// and its banner, which is keyed by tab.
  private func withdrawNotification(_ note: WorkroomNotification) {
    toasts.removeAll { $0.id == note.id }
    notifications.dismiss(notifID: note.id)
    services.notifier.withdraw(identifiers: [note.tabID.uuidString])
  }

  // MARK: Program status alerts (#358)

  /// Raise the alert for a request a program in `tabID` waits on: "Terminal 2 in fix-auth needs
  /// you" (the terminal's own name, never the title its program set, and its workroom, or project
  /// for a root), the kind sentence, then the program's own words, quoted. `stillWanted` is asked again right before a
  /// banner posts, since asking for permission can take as long as the user takes to answer.
  func raiseNeedsYou(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, episode: String,
    record: ProgramStatusRecord, detail: String? = nil, stillWanted: @escaping () -> Bool
  ) {
    let name = terminalPlace(targetID: targetID, tabID: tabID)
    var body = ProgramStatusPresentation.sentence(record.kind)
    // A report with no message (Codex sends none) takes the program's own notification text.
    if let message = ProgramStatusPresentation.oneLine(record.message)
      ?? detail.flatMap(ProgramStatusPresentation.oneLine)
    {
      body += ": \u{201C}\(message)\u{201D}"
    }
    let note = notifications.recordNeedsYou(
      targetID: targetID, tabID: tabID, source: placeSource(targetID: targetID),
      title: "\(name) needs you", body: body, episode: episode, origin: ObjectIdentifier(self))
    surface(note, stillWanted: stillWanted)
  }

  /// Alert that the program in `tabID` finished its turn while nobody was looking: "Terminal 2 in
  /// fix-auth finished", then what it said. An ordinary notification, so focusing the terminal
  /// dismisses it, and the next finish there replaces it: a session running turns on its own
  /// (`/loop`) leaves one entry, not one per turn.
  func raiseFinished(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, record: ProgramStatusRecord,
    detail: String? = nil
  ) {
    var body = ProgramStatusPresentation.turnFinished
    if let message = ProgramStatusPresentation.oneLine(record.message)
      ?? detail.flatMap(ProgramStatusPresentation.oneLine)
    {
      body += ": \u{201C}\(message)\u{201D}"
    }
    guard
      let note = notifications.record(
        targetID: targetID, tabID: tabID, source: placeSource(targetID: targetID),
        activity: .osc(
          title: "\(terminalPlace(targetID: targetID, tabID: tabID)) finished", body: body),
        focused: false, origin: ObjectIdentifier(self))
    else { return }
    if let earlier = notifications.replaceFinish(of: tabID, with: note.id) {
      notifications.dismiss(notifID: earlier)
      toasts.removeAll { $0.id == earlier }
      // Its banner too: this finish may surface as a toast, which never replaces a banner.
      services.notifier.withdraw(tabIDs: [tabID])
    }
    surface(note)
  }

  /// The origin line under a title that already names the workroom, or a root's project: only a
  /// workroom's project, since "london" under "Terminal 7 in london needs you" said it twice.
  private func placeSource(targetID: TerminalTarget.ID) -> String {
    if targetID == QuickTerminalController.targetID { return "Quick Terminal" }
    let origin = sidebarID(for: targetID).map { label(for: $0) }
    return origin?.workroom == nil ? "" : origin?.project ?? ""
  }

  /// "Terminal 2 in fix-auth": a terminal's own name and where it is, as alerts and the menu bar's
  /// waiting list name it. Just the terminal's name when its target is not a known project's.
  func terminalPlace(targetID: TerminalTarget.ID, tabID: TerminalTab.ID) -> String {
    let name = terminals.defaultTitle(ofTab: tabID, inTarget: targetID) ?? "A terminal"
    guard let sid = sidebarID(for: targetID) else { return name }
    let label = label(for: sid)
    let place = label.workroom ?? label.project
    return place.isEmpty ? name : "\(name) in \(place)"
  }

  /// The program's own text for a request already raised (see `ProgramStatusAlerts.programNotified`).
  func mergeIntoNeedsYou(episode: String, body: String?) {
    notifications.merge(episode: episode, body: body)
  }

  /// The request was answered, or its program ended: its alert and banner go.
  func withdrawNeedsYou(episode: String) {
    toasts.removeAll { $0.episode == episode }
    notifications.dismiss(episode: episode)
    // Even with the entry already read: its banner may still be in Notification Center.
    services.notifier.withdraw(identifiers: [episode])
  }

  /// The program-status session of the terminal focused in this window, for ⇧⌘M. Only with keyboard
  /// focus in it: from an inspector field, ⇧⌘M goes to the selected terminal if it is the one waiting.
  var focusedTerminalSession: UUID? {
    guard let target = primaryTarget, let tab = terminals.focusedTab(for: target),
      terminals.surface(of: tab.id)?.isEffectivelyFocused == true
    else {
      return nil
    }
    return terminals.sessionID(forTab: tab.id, inTarget: target.id)
  }

  /// Tell the user a new workroom doesn't start where they'd expect: its create couldn't fetch, the
  /// base came from a local copy, or the app-wide default didn't fit this project.
  func noticeStaleStart(of id: TerminalTarget.ID, _ warning: String) {
    surface(
      notifications.recordNotice(
        targetID: id, source: notificationSource(forTargetID: id),
        title: "Check where this workroom starts", body: warning, origin: ObjectIdentifier(self)))
  }

  /// Present a recorded notification: an in-app toast and the arrival sound while the app is
  /// frontmost, a native banner otherwise.
  private func surface(_ note: WorkroomNotification, stillWanted: @escaping () -> Bool = { true }) {
    if NotificationGate.shouldPresentInApp(recorded: true, appActive: isAppActive()) {
      // App is focused: request a chime (bursts share one), then pop a toast. Notifications live in the
      // always-visible left-sidebar strip + the title-bar bell badge (issue #118), so the transient
      // toast is the arrival signal regardless of what else is on screen. Previously this flashed the
      // notifications row when the *right* inspector was open/edge-revealed and only toasted otherwise
      // — that gating referenced a surface that no longer shows notifications, so a focused arrival
      // with the inspector open would have silently dropped.
      NotificationSound.play()
      if let forwardToast { forwardToast(note) } else { enqueueToast(note) }
    } else if NotificationGate.shouldPostBanner(recorded: true, appActive: isAppActive()) {
      Task { @MainActor in
        if await services.notifier.ensureAuthorized(), stillWanted(),
          notifications.items.contains(where: { $0.id == note.id })
        {
          services.notifier.post(note)
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
  /// when deciding whether the activity is "seen". nil if not shown. Resolves the visible group ONCE
  /// (`isWorkroomSplitVisible` + `resolvedSplitLeaves()` would each re-walk every group's leaves) — this
  /// runs per activity event per pane.
  func onScreenTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget? {
    if let primary = primaryTarget, primary.id == targetID { return primary }
    guard let group = visibleWorkroomSplit, let leaves = resolvedSplitLeaves(of: group) else {
      return nil
    }
    return leaves.first { $0.target.id == targetID }?.target
  }

  /// Bring the app forward and select the terminal a notification came from, marking it read.
  /// Reused by both the native-banner click (AppDelegate) and the in-app panel tap. No-ops (and
  /// withdraws any stale banner) when the target/tab no longer exists.
  func openTerminal(targetID: TerminalTarget.ID, tabID: TerminalTab.ID?, notifID: UUID? = nil) {
    NSApp.activate(ignoringOtherApps: true)
    // A DETACHED pane (issue #172) is already open in its own window, so raise that and stop. This
    // has to come BEFORE `applyLocation` below: that call selects the workroom in THIS window and
    // records a navigation-history entry for a jump that never happens, and `setFocused`'s detached
    // guard runs too late to undo either — the user would see this window's sidebar move for a pane
    // that is sitting somewhere else entirely.
    if raiseDetachedPane(tabID) {
      notifications.dismiss(notifID: notifID, orTab: tabID)
      return
    }
    guard let sid = sidebarID(for: targetID) else {
      // Its workroom is gone: the row would open nothing, so it goes too (#573).
      if let notifID { notifications.dismiss(notifID: notifID) }
      if let tabID { services.notifier.withdraw(tabIDs: [tabID]) }
      return
    }
    // Jump to (target, tab) through the shared primitive: it selects the target, re-activates the
    // tab only if it still exists (it may have been closed/reaped since the banner was posted), and
    // records exactly one history entry — no phantom intermediate (issue #26).
    applyLocation(target: sid, tab: tabID, recordHistory: true)
    notifications.dismiss(notifID: notifID, orTab: tabID)
  }

  /// Jump to the oldest pending notification's terminal and dismiss it (reusing the banner/panel
  /// `openTerminal` path). Since opening dismisses, repeated calls walk the backlog oldest→newest —
  /// the bottom of the inspector panel upward. No-op when there are none.
  func openOldestNotification() {
    guard let oldest = notifications.items.first else { return }
    WindowRegistry.shared.open(oldest)
  }

  /// On app refocus, dismiss the notifications for the now-visible terminal (the selected target's
  /// active tab) — you're looking at it. Called from `RootView`'s `didBecomeActive` hook.
  ///
  /// Only the key window's, and only while its terminal holds focus (#358): every window hears the
  /// activation, and a window behind the key one, or focus in an inspector field, is not the user
  /// looking at that terminal.
  func dismissFocusedTerminalNotifications() {
    guard hostWindow?.isKeyWindow == true, let target = selectedTarget,
      let active = terminals.activeTab(for: target),
      terminals.surface(of: active.id)?.holdsFirstResponder == true
    else { return }
    notifications.dismiss(tab: active.id)
  }

  /// On app refocus, pull the History log fresh if the inspector is visible and on History — catches a
  /// commit made in an external terminal while the app was backgrounded (the live per-project metadata
  /// watcher may have been coalesced/idle across deactivation). Same visibility gate as the live
  /// trigger; cheap + cancel-and-replace. Called from `RootView`'s `didBecomeActive` hook.
  /// After a successful fetch/push/pull: refresh everything downstream of it.
  ///
  /// The metadata watcher would get here on its own, but its coalesce window is ~1s and these surfaces
  /// should move the moment the action lands.
  ///
  /// The status refresh is also how a pull that exited 0 but left conflicts is detected — the writer
  /// cannot re-read the working copy itself inside the write gate (re-entering it for the same project
  /// root is a documented deadlock). So the read happens HERE, after the gate has released.
  /// `sid` is the workroom the action RAN in, handed over by the model rather than read back off it.
  ///
  /// It used to read `remoteState.target?.sid` here, which is whatever is selected by the time the action
  /// finishes — so a pull in one workroom completing after the user moved to another read the SECOND
  /// workroom's conflict flag and attributed it to the first one's pull.
  private func handleRemoteMutation(
    _ action: VCSRemoteAction, on sid: SidebarID, location: RepositoryLocation?
  ) {
    // A FETCH refreshes nothing here. It moves remote refs and touches neither our working copy nor our
    // CI runs, and the lifecycle's root-branch watch already watches `refs/remotes` and re-reads on
    // its own. This used to run a forced app-wide sweep for every action including the AUTOMATIC fetch, and `force` is the
    // one argument that bypasses the CI TTL (`guard !force else { return true }`), so it admitted every
    // workroom whose local read merely succeeded: one background fetch fanned out into a local probe per
    // workroom of every project plus a `gh` probe and a GitHub round trip each, two at a time.
    guard action != .fetch else { return }
    // One target, debounced, instead of the whole app. The action happened in one workroom.
    scheduleSelectedStatusRefresh()
    if historySectionShown { commitHistory.refresh() }
    guard action == .pull else { return }
    // The refresh above is async; read the conflict flag once it has landed. `noteConflictState` re-checks
    // `sid`, so if the selection moved (and this therefore refreshed a different workroom) it no-ops
    // rather than attributing someone else's conflicts to this pull.
    let refresh = selectionStatusTask
    Task { [weak self] in
      await refresh?.value
      guard let self else { return }
      self.remoteState.noteConflictState(
        self.vcsStatus.workroomStatuses[sid]?.conflicted == true, for: sid, location: location)
    }
  }

  func refreshHistoryIfActive() {
    if inspectorIsVisible, historySectionShown { commitHistory.refresh() }
  }

  /// Human-readable origin for a notification: the project name, plus the workroom for a
  /// workroom terminal (e.g. "platform" for a root, "platform / fix-auth" for a workroom).
  /// Resolved against the live projects (no string parsing of the id).
  func notificationSource(forTargetID id: TerminalTarget.ID) -> String {
    Self.notificationSource(forTargetID: id, in: projectStore.projects)
  }

  /// The display label parts for a sidebar item — the one resolver behind the workroom tab chip's
  /// tooltip, the split pane title bar's, and the quick-switcher rail (issue #132). Formatting lives
  /// on `WorkroomLabel`; this only *resolves*: the project's directory name, the workroom's
  /// label-aware `displayName` (issue #41), and — for a root only — its branch, left nil while the
  /// ref is unresolved so `RootPresentation`'s `"root"` placeholder can't pose as a branch name.
  func label(for sid: SidebarID) -> WorkroomLabel {
    let project = Self.projectPath(of: sid).map { ($0 as NSString).lastPathComponent } ?? ""
    switch sid {
    case .workroom(let path, let name):
      return WorkroomLabel(
        project: project, workroom: displayName(forWorkroom: name, inProject: path))
    case .root(let path):
      let ref = vcsStatus.rootRefs[path] ?? .unresolved
      let branch = ref.kind == .none ? nil : RootPresentation.make(ref).label
      return WorkroomLabel(project: project, branch: branch)
    case .creation(_, let id):
      return WorkroomLabel(
        project: project, workroom: lifecycle.creationRuns[id]?.name ?? "New workroom")
    case .project:
      return WorkroomLabel(project: project)
    }
  }

  /// Human-readable origin of a notification: the project name, or "project / workroom" for a
  /// workroom terminal, using the workroom's `displayName` so a set label shows here too (issue #41).
  /// Returns "" when the target isn't in `projects` (deleted) — callers fall back to the snapshot
  /// captured on the record. Pure + `nonisolated` so it's unit-testable, mirroring
  /// `validatedSelection`.
  nonisolated static func notificationSource(
    forTargetID id: TerminalTarget.ID, in projects: [Project]
  )
    -> String
  {
    let project = projects.first { $0.path == id.projectPath }
    switch id {
    case .quickTerminal: return "Quick Terminal"
    case .root: return project?.displayName ?? ""
    case .workroom(_, let name):
      guard let project, let workroom = project.workrooms.first(where: { $0.name == name })
      else { return "" }
      return WorkroomLabel(project: project.displayName, workroom: workroom.displayName).full
    case .creation: return ""
    }
  }

  /// The owning project path of any sidebar id (used to keep the New-Workroom context on the
  /// restored selection's project).
  nonisolated static func projectPath(of id: SidebarID?) -> String? {
    switch id {
    case .root(let path), .workroom(let path, _), .project(let path), .creation(let path, _):
      return path
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

  func present(_ error: Error) {
    modals.errorTitle = nil  // generic title
    modals.errorMessage = WorkroomLifecycle.errorText(error)
    modals.errorDetails = Self.errorDetails(error)
  }

  /// The technical half of `error`, which the message leaves out: its type and case, and its
  /// domain and code.
  nonisolated static func errorDetails(_ error: Error) -> String {
    let ns = error as NSError
    return "\(String(reflecting: error))\n\(ns.domain) \(ns.code)"
  }
}

/// Each window is the `LifecycleWindow` of the creates and deletes asked from it, and is handed
/// every one's effects.
extension AppStore: LifecycleWindow {}

/// Each window settles what it caches from a status at every merge.
extension AppStore: VCSStatusWindow {}

/// The live log for one create/delete run. Lines stream in from the CLI's NDJSON
/// stderr (see WorkroomCLI). A plain ObservableObject — all mutations happen on the
/// main thread (the store hops there before appending), so SwiftUI sees them safely.
// `@unchecked Sendable`: every mutation happens on the main thread (the note above), and the CLI's
// callbacks hop there before they touch it.
final class ScriptLogSession: ObservableObject, Identifiable, @unchecked Sendable {
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
