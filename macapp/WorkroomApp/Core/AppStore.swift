import AppKit
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
}

/// A workroom queued for deletion, awaiting the user's confirmation. Held on the store so
/// both the sidebar's delete affordances and the Delete menu command (⌘⌫) raise the same
/// confirmation prompt.
struct PendingWorkroomDeletion {
  let workroom: Workroom
  let project: Project
}

/// App-wide state and actions. A single shared instance is used so the App, views,
/// and menu Commands all act on the same store. All CLI work is awaited (it runs off
/// the main thread inside WorkroomCLI), keeping the UI responsive.
@MainActor
final class AppStore: ObservableObject {
  static let shared = AppStore()

  @Published var projects: [Project] = []
  @Published var selectedProjectID: Project.ID?
  /// The selected terminal target — a `.root` or a `.workroom` (never `.project`), or nil
  /// when nothing is selected (the launch state). `.project` is not a target; clicking a
  /// project toggles its expansion instead. Persisted across launches (issue #14) via `didSet`
  /// and restored in `apply()`.
  @Published var selectedTargetID: SidebarID? {
    didSet {
      Defaults[.sidebarSelection] = Self.targetIDString(for: selectedTargetID)
      // Record the new location for back/forward (issue #26), unless we're replaying history.
      if !isNavigatingHistory { recordCurrentLocation() }
      // Freshen the newly-selected workroom's status (incl. CI) — debounced so arrow-key
      // cycling through rows doesn't fork a probe per row (issue #24).
      scheduleSelectedStatusRefresh()
    }
  }
  /// Project paths the user has collapsed in the sidebar (issue #14). Held here as `@Published`
  /// rather than read via `@Default` in the view: a `@Default` change does not reliably re-evaluate
  /// the sidebar's `List` until some *other* state changes (e.g. the pointer moving over a row), so
  /// expand/collapse appeared to "stick" until you moved the mouse. `@Published` fires
  /// `objectWillChange` synchronously, so the tree updates on the click itself. Persisted via `didSet`.
  @Published var collapsedProjects: Set<String> = Defaults[.collapsedProjects] {
    didSet { Defaults[.collapsedProjects] = collapsedProjects }
  }
  /// Remembered workroom tab-bar order (issue #23), as `TerminalTarget.ID` strings. `@Published`
  /// (not read via `@Default` in the view) because a `@Default` write doesn't reliably re-render the
  /// `NavigationSplitView` detail, so a drag-reorder's write didn't take and the dropped chip snapped
  /// back to its old slot. Persisted via `didSet`; initialised from `Defaults`. Stale ids resolve away
  /// in `orderedWorkroomTargets`, so it's self-healing.
  @Published var workroomTabOrder: [TerminalTarget.ID] = Defaults[.workroomTabOrder] {
    didSet { Defaults[.workroomTabOrder] = workroomTabOrder }
  }
  /// Whether the projects sidebar column is visible. The single source of truth for the
  /// `NavigationSplitView` column visibility *and* the View ▸ Projects checkmark — a bare AppKit
  /// `toggleSidebar` has no state a menu checkmark can bind to, so it could never show a tick.
  /// Session-only (resets to shown on launch); the dragged width is persisted separately by
  /// `SplitViewAutosave`.
  @Published var sidebarVisible: Bool = true
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
  @Published var rootRefs: [Project.ID: RootRef] = [:]
  /// Per-workroom (and per-root) VCS + CI status driving the ambient badges and the Changes
  /// detail panel (issue #24), keyed by `SidebarID`. Resolved app-side (see
  /// `WorkroomStatusResolver`), best-effort/"last checked" — NOT real-time. Ephemeral:
  /// deliberately NOT persisted (operational state, unlike the sidebar prefs above). Hydrated
  /// after each load, on selection, and on focus; see `AppStore+WorkroomStatus.swift`.
  @Published var workroomStatuses: [SidebarID: WorkroomStatus] = [:]
  /// Whether the GitHub CLI is usable for the PR/CI probes (machine-global). Optimistic default so
  /// no warning flashes before the first check; refreshed by `refreshGitHubCLI()` and read by the
  /// Pull Request inspector section. Drives a warning + gates the `gh` probes when not available.
  @Published var githubCLIStatus: GitHubCLIStatus = .available
  /// When `githubCLIStatus` was last probed (its own short TTL, so we don't re-run `gh auth status`
  /// on every selection).
  var ghStatusCheckedAt: Date?
  /// A PR write action (Phase 2b) is running — disables the PR actions menu so it can't double-fire.
  @Published var prActionInFlight = false

  // Inspector section collapse (issue #24). Held on the store rather than as `@Default` in the
  // inspector view: the `.inspector` content doesn't observe `@Default` changes, but it DOES observe
  // this `@EnvironmentObject`. Seeded from — and persisted back to — Defaults via `didSet`.
  @Published var changesSectionCollapsed = Defaults[.changesSectionCollapsed] {
    didSet { Defaults[.changesSectionCollapsed] = changesSectionCollapsed }
  }
  @Published var prSectionCollapsed = Defaults[.prSectionCollapsed] {
    didSet { Defaults[.prSectionCollapsed] = prSectionCollapsed }
  }
  @Published var notificationsSectionCollapsed = Defaults[.notificationsSectionCollapsed] {
    didSet { Defaults[.notificationsSectionCollapsed] = notificationsSectionCollapsed }
  }

  @Published var errorMessage: String?
  /// Title for the error alert. Nil falls back to the generic title; specific
  /// failures (e.g. teardown) set their own.
  @Published var errorTitle: String?
  @Published var isLoading = false
  /// Project paths with an in-flight create/delete (for per-row progress + disabling).
  @Published var busyProjects: Set<String> = []
  /// Set by the "Add Project" menu command to trigger the sidebar's file importer.
  @Published var requestAddProject = false
  /// A workroom awaiting delete confirmation; setting it raises the confirmation prompt.
  @Published var pendingDeletion: PendingWorkroomDeletion?
  /// Setup logs scoped per terminal target (a workroom's target id), rendered under that
  /// workroom's terminal. Kept until the user closes them (or the workroom is deleted) so
  /// the output stays available for review. Keyed on the target id (project-scoped) so
  /// same-named workrooms across projects don't share a log.
  @Published var logs: [TerminalTarget.ID: ScriptLogSession] = [:]

  let terminals = TerminalSessions()
  /// In-memory notification spine driving the badges + inspector (issue #10). Owned here,
  /// mirroring `terminals`; views observe it directly via `@EnvironmentObject`.
  let notifications = NotificationCenterStore()

  /// Bottom-right toast queue (issue #31): the foreground, inspector-*closed* surface for a new
  /// notification. FIFO, capped at `maxToasts` (a new toast beyond the cap pushes the oldest out);
  /// each toast carries the `WorkroomNotification` it mirrors so a tap can route via `openTerminal`.
  /// Rendered by `ToastStack`, overlaid bottom-right in `RootView`.
  @Published var toasts: [WorkroomNotification] = []
  /// The id of a notification to flash in the inspector's Notifications list — set when one arrives
  /// while the inspector is *open* (issue #31). Self-clearing after the flash so a later open can't
  /// re-flash a stale row; read by `NotificationsList`.
  @Published var flashNotifID: UUID?
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
  /// per sweep / per selection so a slow probe never writes stale status over a newer one.
  let statusResolver = WorkroomStatusResolver()
  var statusSweepTask: Task<Void, Never>?
  var selectionStatusTask: Task<Void, Never>?
  /// When the project list was last loaded — used to throttle the on-focus refresh.
  private var lastLoadAt: Date = .distantPast
  /// The selection persisted from a previous launch (issue #14), applied once on the first
  /// successful load (see `apply`). Consumed there so a later refresh can't resurrect it.
  private var pendingRestoreSelection: TerminalTarget.ID?

  /// `internal` (not `private`) so unit tests can build a non-singleton store (`AppStore()`),
  /// inject `projects`, and drive the real recording/navigation paths. Production always uses the
  /// `shared` singleton; `init` does no CLI work (only `bootstrap()`/`load()` do).
  init() {
    pendingRestoreSelection = Defaults[.sidebarSelection]
    // Route each terminal's activity (OSC/bell) through the notification spine, gated on
    // focus, and raise a native banner only when the app is backgrounded.
    terminals.activityHandler = { [weak self] targetID, tabID, activity in
      self?.handleActivity(targetID: targetID, tabID: tabID, activity: activity)
    }
    // Record each focused-tab change for back/forward history (issue #26), unless we're replaying.
    terminals.onFocusChange = { [weak self] _, _ in
      guard let self, !self.isNavigatingHistory else { return }
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
        self.clearRunPidFile(for: targetID)  // forget the captured pid (issue #7)
      }
      // Closing the last terminal in a co-displayed split pane leaves an empty pane whose only
      // affordance is the remove-from-split ✕ — close it for the user by dropping the now-empty
      // workroom from the split (issue #55). No-op for a solo workroom or a non-member.
      self.autoCloseEmptiedSplitMember(targetID)
    }
    // Mirror the aggregate unread count onto the Dock icon badge (issue #32). Owned here, not in a
    // view: see `NotificationCenterStore.onTotalChange` for why a view-driven badge misses
    // background notifications. `DockBadge` draws into the tile's `contentView` (not `badgeLabel`,
    // which a linked framework suppresses here). Captures no `self`, so there's no retain cycle.
    notifications.onTotalChange = { count in
      DockBadge.apply(count)
    }
    // A click into a co-displayed split pane's terminal focuses that workroom (issue #23 follow-up),
    // so commands target it. History-suppressed (the routing method) — glancing between panes isn't
    // navigation.
    terminals.onSurfaceFocused = { [weak self] targetID in
      self?.focusWorkroomMemberFromSurface(targetID)
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
    Self.orderedActiveTargets(
      persisted: order ?? workroomTabOrder, active: terminals.activeTargetIDs
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
    /// While armed, `ensureInitialTerminal` suppresses the default shell so the run tab is tab #1.
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

  /// Run-STATE is owned here (not on `TerminalSessions`) so the toolbar, sidebar, menu, and RootView
  /// — which all observe this store — react to start/stop/exit from one `@Published` source (OV-A).
  /// `TerminalSessions` only creates/focuses the tab and reports its removal via `onTabsRemoved`.
  @Published private(set) var runStates: [TerminalTarget.ID: RunState] = [:]

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

  /// Build the libghostty `command` string (A3): run the user's login+interactive shell so the
  /// command inherits their PATH/aliases/version-manager shims, then `-c` the command. POSIX shells
  /// (zsh/bash/sh/dash/ksh) get `-lic` with POSIX single-quote escaping (shell path quoted too —
  /// Codex #8); a non-POSIX `$SHELL` (fish/nu/csh) falls back to a login `/bin/sh -lc`, whose
  /// interactive rc won't load — a documented limitation (issue #7, fold #7).
  private func runCommandLine(_ raw: String, pidPath: String) -> String {
    let shell = ShellEnvironment.loginShell()
    let name = (shell as NSString).lastPathComponent
    let isPOSIX = ["zsh", "bash", "sh", "dash", "ksh"].contains(name)
    let runner = isPOSIX ? shell : "/bin/sh"
    // Capture the run command's pid so the app can resolve its process group (`getpgid`, in Swift)
    // and SIGINT the whole group — exactly what a typed Ctrl-C does (SIGINT to the PTY's foreground
    // group), the only thing that reliably stops these servers (the synthetic terminal Ctrl-C never
    // reached the PTY from a toolbar/sidebar action; issue #7). The GROUP matters: bin/dev-style
    // launchers fork through bundle/dotenv/rails to a leaf server that can end up a different pid AND
    // outlive the launcher — but it stays in this group, which (captured at launch) the app reaps on
    // child-exit. `exec "$3" -c "$2"` runs the command ($2) via a child shell so compound commands
    // (`cd web && npm run dev`, `FOO=bar rails s`, pipes) work. ($1=pid file, $3=runner shell.)
    let script = "echo $$ > \"$1\"; exec \"$3\" -c \"$2\""
    let quotedScript = CommandLineInstaller.shellQuoted(script)
    let quotedPid = CommandLineInstaller.shellQuoted(pidPath)
    let quotedCommand = CommandLineInstaller.shellQuoted(raw)
    let quotedRunner = CommandLineInstaller.shellQuoted(runner)
    let outer = isPOSIX ? "\(CommandLineInstaller.shellQuoted(shell)) -lic" : "/bin/sh -lc"
    return "\(outer) \(quotedScript) workroom-run \(quotedPid) \(quotedCommand) \(quotedRunner)"
  }

  /// Per-target temp file holding the run command's pid (written by the run wrapper, read to resolve
  /// + signal its process group). Generated fresh per start/respawn; cleared when the run exits or
  /// its tab is removed so a reused pid can never be signalled.
  private var runPidFiles: [TerminalTarget.ID: String] = [:]

  /// A fresh per-run pid-file path. Does NOT store it — the caller assigns `runPidFiles[target]`
  /// AFTER the tab is (re)created, because `respawnRunTab` closes the old tab first and that fires
  /// `onTabsRemoved` → `clearRunPidFile`, which would otherwise wipe a path stored too early (the
  /// re-run-can't-be-stopped bug, issue #7).
  private func makeRunPidPath() -> String {
    (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("workroom-run-\(UUID().uuidString).pid")
  }

  /// The pid the run wrapper captured for a target (its `echo $$`).
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
  /// itself or another terminal.
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

  /// SIGINT every process in session `sid` — a session-scoped Ctrl-C (issue #7).
  private func reapRunSession(_ sid: pid_t) { signalRunSession(sid, SIGINT) }

  /// SIGINT the target's run command — the reliable replacement for the synthetic terminal Ctrl-C
  /// (issue #7), and exactly what a typed Ctrl-C does. Signals the whole SESSION so it catches a leaf
  /// server forked into another process group; used by Stop/Restart and, on child-exit, to reap a
  /// server that outlived the launcher. Refreshes the session from the live pid when possible.
  private func interruptRun(for targetID: TerminalTarget.ID) {
    let pid = runPid(for: targetID)
    if let pid, getsid(pid) > 1 { runSessions[targetID] = getsid(pid) }  // refresh while alive
    // Session-scoped Ctrl-C — stable across bin/dev's forks — plus the captured pid directly (fast path).
    reapRunSession(runSessions[targetID] ?? -1)
    if let pid { _ = kill(pid, SIGINT) }
  }

  /// Forget (and delete) a target's captured pid file + group once its run has exited/closed, so a
  /// later reuse of that pid/group can't be signalled.
  private func clearRunPidFile(for targetID: TerminalTarget.ID) {
    runSessions[targetID] = nil
    if let path = runPidFiles.removeValue(forKey: targetID) {
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  /// Start the project's run command in `target`'s directory, in a dedicated run terminal. No-op
  /// without a configured command or for a missing target. If a run tab already exists it's focused,
  /// not duplicated (one run terminal per target).
  func startRunCommand(for target: TerminalTarget) {
    guard !target.isMissing, let project = project(forTarget: target) else { return }
    let config = runConfig(forProject: project.path)
    guard config.hasCommand else { return }
    if let existing = runStates[target.id]?.tab {
      terminals.focus(existing, for: target)
      return
    }
    let pidPath = makeRunPidPath()
    let line = runCommandLine(
      config.command.trimmingCharacters(in: .whitespacesAndNewlines), pidPath: pidPath)
    let tab = terminals.addRunTab(for: target, command: line, cwd: target.path)
    runStates[target.id] = .running(tab: tab.id, interrupted: false)
    runPidFiles[target.id] = pidPath  // after the tab exists, so cleanup can't wipe it
    captureRunSession(for: target.id, pidPath: pidPath)  // record the session for reliable stop
    // Child-exit flips run-state to stopped; the pane stays open (wait_after_command). The captured
    // `target` value is stable for the workroom's lifetime (a delete reaps everything anyway).
    tab.view.onChildExited = { [weak self] _ in self?.markRunExited(for: target) }
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
    let tab = terminals.respawnRunTab(
      replacing: oldTab, for: target, command: line, cwd: target.path)
    runStates[target.id] = .running(tab: tab.id, interrupted: false)
    runPidFiles[target.id] = pidPath  // after respawnRunTab's closeTab cleanup, so it survives
    captureRunSession(for: target.id, pidPath: pidPath)  // record the session for reliable stop
    tab.view.onChildExited = { [weak self] _ in self?.markRunExited(for: target) }
  }

  /// Toggle a specific target's run command from the sidebar: running → stop; otherwise start (or
  /// re-run a stopped-but-open tab). Acts on the given target (not the selection). On start, also
  /// navigates the detail pane to that target so the just-started run tab is visible — it's already
  /// the focused tab within the target, so selecting the target shows it (issue #7).
  func toggleRunCommand(for target: TerminalTarget) {
    if isRunCommandRunning(for: target.id) {
      stopRunCommand(for: target)
    } else {
      restartRunCommand(for: target)  // no run tab → start; stopped-but-open tab → re-run
      if let sid = Self.sidebarID(forTargetID: target.id, in: projects) {
        selectedTargetID = sid
        selectedProjectID = Self.projectPath(of: sid)
      }
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
  func runOrFocusRunCommand() {
    guard !isEditingTextField, let target = selectedTarget, !target.isMissing else { return }
    switch runStates[target.id] {
    case .running(let tab, _), .restarting(let tab):
      terminals.focus(tab, for: target)
    case .stopped:
      restartRunCommand(for: target)  // re-run a stopped-but-open tab (close + respawn)
    case .armed, .none:
      startRunCommand(for: target)
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

  /// Stop the run command. 1st press: Ctrl-C (graceful SIGINT to the foreground group), recorded on the
  /// state. 2nd press: hard kill by closing the run tab — freeing the surface hangs up the PTY (SIGHUP),
  /// the only reliable kill libghostty exposes (no child PID). For a process that ignores SIGINT (OV-D).
  func stopRunCommand(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, let interrupted):
      if interrupted {
        // 2nd press → close the run tab, but wait for the process to actually exit first (the SIGINT
        // from the 1st press is in flight). A bare close frees the surface mid-shutdown — a PTY hangup
        // (SIGHUP) the dev server ignores — orphaning it on its port + pidfile ("A server is already
        // running" next start). onTabsRemoved clears state on close.
        closingRunTab(tab, for: target.id) { [weak self] in
          self?.terminals.closeTab(tab, for: target)
        }
      } else {
        interruptRun(for: target.id)  // 1st press → SIGINT the run process directly (issue #7)
        runStates[target.id] = .running(tab: tab, interrupted: true)
      }
    case .restarting(let tab):
      // Stop during a graceful restart: drop the respawn intent. The Ctrl-C is already in flight, so
      // on exit the pane just stops; a further Stop (now interrupted) hard-kills a wedged process — so
      // the first Stop after a Restart stays graceful instead of an immediate kill (review #3).
      runStates[target.id] = .running(tab: tab, interrupted: true)
    case .armed, .stopped, .none:
      break  // nothing executing to stop
    }
  }

  /// Restart (C1, graceful — releases the port before the new instance binds). Running: Ctrl-C, then
  /// respawn once the process actually exits (`markRunExited`). Stopped/open: close + start now. Armed
  /// or none: just start.
  func restartRunCommand(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, _):
      interruptRun(for: target.id)  // SIGINT the run process directly (issue #7)
      runStates[target.id] = .restarting(tab: tab)  // await child-exit → close + respawn
    case .restarting:
      break  // already restarting → don't double-send Ctrl-C
    case .stopped(let tab):
      respawnRunCommand(replacing: tab, for: target)  // close + respawn in the old tab's slot (#40)
    case .armed, .none:
      startRunCommand(for: target)
    }
  }

  /// The run command's process exited (child-exit). `.running` → stopped (pane stays open). `.restarting`
  /// → the old process is gone, so close its pane and respawn (C1).
  ///
  /// This runs inside libghostty's child-exit callback (the surface is mid-callback on the stack), so
  /// the restart's close+respawn — which frees the old surface — MUST be deferred to the next runloop
  /// tick; freeing the surface synchronously here is a re-entrant use-after-free that crashes the app.
  /// The deferred guard re-reads the state, so a tab the user closed in between isn't double-closed.
  private func markRunExited(for target: TerminalTarget) {
    switch runStates[target.id] {
    case .running(let tab, _):
      // The PTY child exited — but a server may have forked free of it and still be alive (bin/dev;
      // issue #7). SIGINT the whole session, then wait it out and SIGKILL any straggler, so a forked
      // server can't linger and trip "A server is already running" on the next start.
      let sid = runSessions[target.id] ?? -1
      interruptRun(for: target.id)
      clearRunPidFile(for: target.id)
      runStates[target.id] = .stopped(tab: tab)
      waitForSessionsExit(sid > 1 ? [sid] : [], deadline: Date().addingTimeInterval(6)) {}
    case .restarting:
      // The launcher exited, but the server it forked may still be shutting down (Puma drains its
      // workers, then frees its port + pidfile). Respawning now would boot the new instance into the
      // old one's still-held port/pidfile ("A server is already running"; the intermittent issue #7
      // restart bug). So wait for the whole session to actually exit — SIGKILL on timeout — before
      // respawning. Generic: works for any run command, not just ones that honour SIGINT promptly.
      let sid = runSessions[target.id] ?? -1
      interruptRun(for: target.id)
      // Old launcher pid no longer needed; the respawn captures a fresh one.
      clearRunPidFile(for: target.id)
      // Defer off libghostty's child-exit callback stack first (a synchronous respawn frees the old
      // surface re-entrantly — a use-after-free crash), then do the session wait. Re-read the state at
      // each hop so a tab the user closed in between isn't double-closed (review #1).
      DispatchQueue.main.async { [weak self] in
        guard let self, case .restarting = self.runStates[target.id] else { return }
        self.waitForSessionsExit(sid > 1 ? [sid] : [], deadline: Date().addingTimeInterval(6)) {
          guard case .restarting(let tab) = self.runStates[target.id] else { return }
          self.respawnRunCommand(replacing: tab, for: target)  // new tab keeps the split slot (#40)
        }
      }
    case .armed, .stopped, .none:
      break
    }
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

  /// SIGINT the run process of each given target (issue #7) and run `then` once they've all exited —
  /// or after `timeout`, the fallback where the caller's free then delivers the old SIGHUP (no worse
  /// than before). Polls `processHasExited` on the main runloop; NEVER frees a surface itself, so it
  /// can't race libghostty's teardown (the same reason quit avoids a mass-free). The surfaces are
  /// captured for the wait, keeping them alive to poll. The command stays in the foreground — no
  /// backgrounding — so a dev server's keyboard shortcuts / `binding.pry` keep working.
  private func gracefullyStopRuns(
    _ targetIDs: [TerminalTarget.ID], timeout: TimeInterval = 6, then: @escaping () -> Void
  ) {
    var views: [GhosttySurfaceView] = []
    var sids: [pid_t] = []
    for id in targetIDs {
      guard let view = liveRunView(for: id) else { continue }
      interruptRun(for: id)  // session-scoped Ctrl-C (and the captured pid)
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
    guard runStates[targetID]?.tab == tabID, liveRunView(for: targetID) != nil else {
      proceed()
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

  /// Workrooms just created with the "open a terminal in new workrooms" setting on
  /// (`Defaults[.openTerminalOnCreate]`), pending an initial shell on first pane mount. A one-shot
  /// create-time marker, like an `.armed` run-state: consulted once at create and consumed by
  /// `ensureInitialTerminal`, so selecting an *existing* workroom never spawns a terminal (issue #23).
  private var pendingOpenTerminal: Set<TerminalTarget.ID> = []

  /// Arm a just-created workroom to open a shell terminal once its pane mounts (post-setup), per the
  /// `openTerminalOnCreate` setting. Called from `createWorkroom`, mirroring `armAutoRun`.
  func armOpenTerminal(forWorkroom targetID: TerminalTarget.ID) {
    pendingOpenTerminal.insert(targetID)
  }

  /// Run an armed auto-run command as a target's first terminal when its pane first appears (called by
  /// the terminals view). Only acts when an auto-run was armed for this just-created workroom (issue
  /// #7) — the run command becomes the first tab instead of a default shell. Because the pane only
  /// mounts once any blocking setup dialog is dismissed, this is exactly when the command should run
  /// (post-setup). For any other target this is a no-op: selecting a workroom does NOT auto-create a
  /// terminal (issue #23) — the user opens one with ⌘T. Falls back to a normal tab if the armed
  /// command can't start (e.g. config cleared between arming and mount).
  func ensureInitialTerminal(for target: TerminalTarget) {
    // Both intents are one-shot create-time markers (issue #7 / `openTerminalOnCreate`). Selecting a
    // workroom otherwise does NOT auto-create a terminal — the user opens one with ⌘T (or the empty
    // state's "New Terminal" button) — so an existing, un-marked workroom shows the empty state and
    // gets no tab here. Consume both up front so a later re-mount (navigating away and back) can't
    // re-fire either.
    let isArmed: Bool
    if case .armed = runStates[target.id] { isArmed = true } else { isArmed = false }
    let opensShell = pendingOpenTerminal.remove(target.id) != nil
    guard isArmed || opensShell else { return }

    // Auto-run: start the project's command as the workroom's first tab (post-setup). Consume the
    // armed intent first, then let startRunCommand (re-)derive the state: it becomes `.running` as
    // tab #1, or a no-op if the config was cleared between arming and mount.
    if isArmed {
      runStates[target.id] = nil
      startRunCommand(for: target)
    }

    // "Open a terminal in new workrooms": open a plain shell. Independent of auto-run — when both
    // fire, the run command stays tab #1 and focused (the prominent thing) and this shell is tab #2,
    // available behind it. `addTab` focuses the new shell, so re-focus the run tab afterwards.
    if opensShell {
      terminals.addTab(for: target)
      if isArmed, let runTab = runStates[target.id]?.tab { terminals.focus(runTab, for: target) }
    }

    // An armed run that couldn't start (config cleared after arming) still needs a usable terminal;
    // open one unless the shell above already covered it.
    if isArmed, terminals.tabCount(forTargetID: target.id) == 0 { terminals.ensureTab(for: target) }
  }

  // MARK: Loading

  /// Initial launch: render config-only (instant, no VCS calls), then refresh warnings.
  /// Branch labels hydrate asynchronously off both passes (see `resolveBranches`).
  func bootstrap() async {
    if UITestFixture.isActive {
      loadFixture()
      return
    }
    await load(warnings: "none")
    await load(warnings: "fast")
  }

  func reload() async {
    await load(warnings: "fast")
  }

  /// Reload only if it's been a while since the last load. Driven by the app regaining
  /// focus, so alt-tabbing back doesn't fork a git/jj process per project every time.
  func reloadIfStale(minInterval: TimeInterval = 4) async {
    guard Date().timeIntervalSince(lastLoadAt) >= minInterval else { return }
    await reload()
  }

  private func load(warnings: String) async {
    // In UI-test fixture mode every load resolves to the same fake projects — never shell out to
    // the CLI (so an on-focus `reloadIfStale` can't replace the fixture with the real config).
    if UITestFixture.isActive {
      loadFixture()
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let response = try await WorkroomCLI.shared.list(warnings: warnings)
      apply(response.projects)
      lastLoadAt = Date()
      resolveBranches()
      refreshWorkroomStatuses()
    } catch {
      present(error)
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
      setRunConfig(
        RunConfig(command: "echo PROBE_OK; sleep 30", autoRun: false), forProject: project.path)
    }
    // The real persisted selection won't resolve against the fixture paths; don't try to restore it.
    pendingRestoreSelection = nil
    // Start every fixture project expanded so the sidebar tree is deterministic regardless of any
    // collapse state a prior UI-test run persisted to the shared defaults (real projects untouched).
    collapsedProjects.subtract(fixtures.map(\.id))
    if selectedProjectID == nil { selectedProjectID = fixtures.first?.id }
    if selectedTargetID == nil, let project = fixtures.first,
      let workroom = project.workrooms.first
    {
      selectedTargetID = .workroom(project: project.path, name: workroom.name)
      // Selecting a workroom no longer auto-opens a terminal (issue #23), so explicitly open one here
      // for the UI tests — they assume the fixture workroom has a terminal (and thus a tab) on launch.
      terminals.ensureTab(for: workroom.target(inProject: project.path))
    }
    // Seed deterministic Changes-inspector status (the fixture paths aren't real repos, so the live
    // probe would only report "unknown"); the resolver sweep is skipped in fixture mode.
    seedFixtureStatuses()
    lastLoadAt = Date()
  }

  private func apply(_ fresh: [Project]) {
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

  // MARK: Mutations

  func addProject(_ url: URL) async {
    do {
      try await WorkroomCLI.shared.addProject(url.path)
      await reload()
      // Select the freshly added project as context (no target — the root is one click away).
      if let match = projects.first(where: {
        $0.path == url.path || ($0.path as NSString).lastPathComponent == url.lastPathComponent
      }) {
        selectedProjectID = match.id
        selectedTargetID = nil
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
    // Whether the project has a setup script; reported by the early "created" event.
    // A blocking session shows its log full-pane (no terminal) until the user dismisses.
    var hasSetup = false
    do {
      let created = try await WorkroomCLI.shared.create(
        project: project.path,
        onLog: { text in
          DispatchQueue.main.async { session.append(text) }
        },
        onReady: { name, _, setup in
          // The workroom now exists; mount it and (if a setup script will run) block its
          // terminal behind the streaming setup log so output appears live from the start.
          DispatchQueue.main.async {
            hasSetup = setup
            Task { @MainActor in
              // Pre-arm auto-run BEFORE the workroom is mounted/selected, so its terminal view runs
              // the command as tab #1 instead of a default shell (issue #7, Codex #12). The run fires
              // when that terminal view first mounts: immediately for a no-setup workroom, or only
              // AFTER the user dismisses the blocking setup dialog (the terminal is withheld behind
              // it until then) — so the command runs post-setup, as intended.
              let workroomID = TerminalTarget.workroomID(project: project.path, name: name)
              let cfg = self.runConfig(forProject: project.path)
              if cfg.autoRun, cfg.hasCommand {
                self.armAutoRun(forWorkroom: workroomID)
              }
              // Open-a-terminal-on-create setting: arm a plain shell for first mount, independent of
              // auto-run (fires alongside it — run command tab #1, shell tab #2). Like auto-run, this
              // fires post-setup because the pane is withheld behind the blocking setup dialog.
              if Defaults[.openTerminalOnCreate] {
                self.armOpenTerminal(forWorkroom: workroomID)
              }
              await self.mountSetupLog(session, workroom: name, project: project, blocking: setup)
            }
          }
        }
      )
      session.finish()
      await reload()
      // Mount now if the early "created" event never arrived (older CLI).
      if session.targetID == nil {
        await mountSetupLog(session, workroom: created.name, project: project, blocking: hasSetup)
      }
      // A non-blocking run with no output leaves nothing to dock. A blocking session
      // stays up (even with no output) until the user dismisses it.
      if !session.blocking, session.lines.isEmpty, let id = session.targetID { logs[id] = nil }
      // Auto-run is NOT triggered here: it fires from `ensureInitialTerminal` when the workroom's
      // terminal pane first mounts (issue #7), which is after the setup dialog is dismissed for a
      // blocking setup. Triggering here would also race the `onReady` arming on a fast no-setup create.
    } catch {
      // Even on (partial) failure, reload so a "created but setup failed" workroom shows up.
      await reload()
      if let id = session.targetID {
        // The workroom exists but setup failed. Disarm the auto-run armed in `onReady` (before setup
        // ran) so dismissing the failure dialog doesn't launch the command against a half-set-up tree
        // — auto-run is a success-path action (issue #7, review finding).
        if case .armed = runStates[id] { runStates[id] = nil }
        // Show the failure in its log. Keep it blocking (if a setup script ran) so the failure
        // replaces the terminal until the user dismisses it.
        session.blocking = hasSetup
        logs[id] = session
        selectedProjectID = project.id
        selectedTargetID = targetIDFromLogKey(id, project: project)
        session.finish(failure: errorText(error))
      } else {
        // Failed before the workroom existed — nothing to dock under.
        present(error)
      }
    }
  }

  /// Mounts a just-created workroom (selecting it) and attaches its setup log. When
  /// `blocking` is true the log replaces the terminal full-pane (a setup script is
  /// running); otherwise it docks beneath the terminal. Safe to call more than once.
  private func mountSetupLog(
    _ session: ScriptLogSession, workroom name: String, project: Project, blocking: Bool = false
  ) async {
    let id = TerminalTarget.workroomID(project: project.path, name: name)
    session.targetID = id
    session.blocking = blocking
    logs[id] = session
    await reload()
    selectedProjectID = project.id
    selectedTargetID = .workroom(project: project.path, name: name)
  }

  /// Removes the workroom from the sidebar immediately, then runs its teardown (script +
  /// workspace removal) in the background. On success the optimistic removal already
  /// matches reality; on failure we reload (so it reappears if it still exists) and
  /// surface the error.
  func deleteWorkroom(_ workroom: Workroom, in project: Project) {
    let targetID = TerminalTarget.workroomID(project: project.path, name: workroom.name)
    // Capture the live run surface (if any) BEFORE tearing anything down: we Ctrl-C it and let the
    // dev server exit before reaping the surface + deleting the worktree, so it isn't orphaned by the
    // bare reap (a PTY hangup — SIGHUP — which Puma ignores) and left running against a deleted
    // directory (issue #7).
    // Optimistic: drop it from the sidebar model + selection/split/status now (snappy UI). The
    // terminals stay alive for the graceful stop; reap + VCS teardown follow once the process exits.
    removeWorkroomLocally(workroom, in: project)
    // Drop the deleted workroom from the split first (it re-points selection to a survivor), then fall
    // back to clearing selection if it was the deleted workroom (issue #23 follow-up self-heal).
    removeWorkroomSplitMember(.workroom(project: project.path, name: workroom.name))
    if selectedTargetID == .workroom(project: project.path, name: workroom.name) {
      selectedTargetID = nil
    }
    // Drop the gone workroom's VCS/CI status so a stale badge can't linger (issue #24).
    workroomStatuses[.workroom(project: project.path, name: workroom.name)] = nil

    let finishTeardown = { [weak self] in
      guard let self else { return }
      self.terminals.reap(targetID)
      // `reap` only fires `onTabsRemoved` (which clears run state) when tabs existed; a workroom armed
      // for auto-run but deleted before its pane mounted has none, so clear directly too (issue #7).
      self.runStates[targetID] = nil
      // Same for a created-then-deleted-before-mount workroom marked to open a shell on create.
      self.pendingOpenTerminal.remove(targetID)
      self.clearRunPidFile(for: targetID)
      self.logs[targetID] = nil
      // Drop the gone workroom's notifications and pull any banners it already delivered.
      self.systemNotifier.withdraw(tabIDs: self.notifications.removeForTarget(targetID))
      self.startWorkroomTeardown(workroom, in: project)
    }
    // SIGINT the run process and wait for it to exit before reaping + deleting the worktree (so the
    // dev server isn't left running against a deleted directory); no live run command → immediate.
    gracefullyStopRuns([targetID], then: finishTeardown)
  }

  /// Run the VCS teardown (worktree/workspace removal) in the background, surfacing any failure with
  /// its captured output in an alert. Split out of `deleteWorkroom` so the run command can stop first
  /// (issue #7) — the worktree must not be deleted while its dev server still holds the directory.
  private func startWorkroomTeardown(_ workroom: Workroom, in project: Project) {
    Task {
      let log = ScriptLogSession(title: "Tearing down \(workroom.name)", phase: "teardown")
      do {
        try await WorkroomCLI.shared.delete(name: workroom.name, project: project.path) { text in
          DispatchQueue.main.async { log.append(text) }
        }
      } catch {
        await reload()
        presentTeardownFailure(workroom, error: error, log: log)
      }
    }
  }

  /// Drops a workroom from the in-memory project list so the sidebar updates instantly.
  private func removeWorkroomLocally(_ workroom: Workroom, in project: Project) {
    guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
    let p = projects[idx]
    projects[idx] = Project(
      path: p.path, vcs: p.vcs, workrooms: p.workrooms.filter { $0.id != workroom.id })
  }

  /// Maps a workroom log key ("wr|<project>|<name>") back to its selection id.
  private func targetIDFromLogKey(_ key: TerminalTarget.ID, project: Project) -> SidebarID? {
    let prefix = "wr|\(project.path)|"
    guard key.hasPrefix(prefix) else { return nil }
    return .workroom(project: project.path, name: String(key.dropFirst(prefix.count)))
  }

  /// Teardown failed (it ran in the background): pop an alert carrying the captured
  /// script output so the user can see why.
  private func presentTeardownFailure(_ workroom: Workroom, error: Error, log: ScriptLogSession) {
    let output = log.lines.map(\.text).joined(separator: "\n").trimmingCharacters(
      in: .whitespacesAndNewlines)
    errorTitle = "Teardown of ‘\(workroom.name)’ failed"
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

  /// Close a terminal tab, confirming first when `confirmOnCloseTerminal` is on (the default). The
  /// tab-strip ✕ and the ⌘W command both route through here, so the confirmation — and its "Don't
  /// ask me again" suppression — lives in one place. Closing a terminal kills its shell and anything
  /// running in it with no undo, so the alert mirrors the quit confirmation (same destruction class).
  func requestCloseTerminalTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let tab = terminals.tabs(for: target).first(where: { $0.id == tabID }) else { return }
    // UI-test fixture mode closes without the modal so ⌘W / right-click Close are synchronous and
    // teardown never blocks on an alert (the launch-arg override can't reliably reach a Defaults Bool).
    // Also skip the confirm when the tab's process has already exited (e.g. a stopped/finished run
    // command sitting at "Process exited" via wait_after_command) — there's nothing running to lose
    // (issue #7).
    guard Defaults[.confirmOnCloseTerminal], !UITestFixture.isActive, !tab.view.processHasExited
    else {
      // No confirmation needed: UI tests close synchronously (teardown must not block); everyone
      // else still stops a live run command gracefully first so its dev server isn't orphaned.
      if UITestFixture.isActive {
        terminals.closeTab(tabID, for: target)
      } else {
        closingRunTab(tabID, for: target.id) { [weak self] in
          self?.terminals.closeTab(tabID, for: target)
        }
      }
      return
    }
    let alert = NSAlert()
    alert.messageText = "Close ‘\(tab.title)’?"
    alert.informativeText = "Closing this terminal stops any process running in it."
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask me again"
    let confirmed = alert.runModal() == .alertFirstButtonReturn
    // Ticking the box stops future confirmations whether they Close or Cancel — it means "stop
    // asking". Writes the same key the Settings checkbox and the File ▸ "Confirm Before Closing a
    // Terminal" menu toggle bind to, so both unset the moment the box is ticked.
    if alert.suppressionButton?.state == .on {
      Defaults[.confirmOnCloseTerminal] = false
    }
    if confirmed {
      // Stop a live run command (Ctrl-C + wait) before freeing the surface, so the dev server
      // exits cleanly rather than being orphaned by the bare hangup (issue #7). Non-run / exited
      // tabs close immediately.
      closingRunTab(tabID, for: target.id) { [weak self] in
        self?.terminals.closeTab(tabID, for: target)
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

  /// The focused pane's surface for the selected target (the focused tab is the focused pane), or nil
  /// when nothing's selected / no terminal exists. Drives the Go menu's scroll items (issue #42).
  private var focusedSurface: GhosttySurfaceView? {
    guard let target = selectedTarget else { return nil }
    return terminals.focusedTab(for: target)?.view
  }

  /// Scroll the focused terminal to the top / bottom of its scrollback (issue #42). Driven by the Go
  /// menu's "Scroll to Top"/"Scroll to Bottom" items; ⌘↑/⌘↓ also reach the surface directly.
  func scrollFocusedTerminalToTop() { focusedSurface?.scrollToTop() }
  func scrollFocusedTerminalToBottom() { focusedSurface?.scrollToBottom() }

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
    history.record(NavLocation(target: sid, tab: tab.id))
  }

  /// Go back one step, skipping entries whose target/tab no longer exist (D2). No-op when there's no
  /// live earlier location.
  func navigateBack() {
    if let loc = history.step(-1, isLive: isLive) {
      applyLocation(target: loc.target, tab: loc.tab, recordHistory: false)
    }
  }

  /// Go forward one step (mirrors `navigateBack`).
  func navigateForward() {
    if let loc = history.step(+1, isLive: isLive) {
      applyLocation(target: loc.target, tab: loc.tab, recordHistory: false)
    }
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
    if recordHistory { history.record(NavLocation(target: sid, tab: resolved)) }
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

  // MARK: Notifications

  /// Record a terminal's activity, then surface it: backgrounded ⇒ a native banner; foregrounded ⇒
  /// an in-app toast (inspector closed) or a sidebar row flash (inspector open), plus the arrival
  /// sound (issue #31). `record` drops the event entirely when the user is already looking at that
  /// terminal, so none of these fire for the focused terminal.
  private func handleActivity(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, activity: TerminalActivity
  ) {
    // "Seen" = on screen (the focused solo tab or any pane of the visible split) — those are
    // suppressed (D3). A visible pane that isn't the cursor pane gets a border flash instead of a
    // badge, so split-mates still signal activity without nagging.
    let seen = isFocused(targetID: targetID, tabID: tabID)
    if seen, let target = selectedTarget, target.id == targetID,
      terminals.focusedTab(for: target)?.id != tabID
    {
      terminals.pulsePaneActivity(tabID)
    }
    guard
      let note = notifications.record(
        targetID: targetID, tabID: tabID, source: notificationSource(forTargetID: targetID),
        activity: activity, focused: seen)
    else { return }
    if NotificationGate.shouldPresentInApp(recorded: true, appActive: NSApp.isActive) {
      // App is focused: sound on every arrival, then either flash the row (inspector open) or pop a
      // toast (inspector closed). The two surfaces are exclusive — never both at once.
      NotificationSound.play()
      if Defaults[.showNotifications] {
        flashNotification(note.id)
      } else {
        enqueueToast(note)
      }
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

  /// Flag a notification for a one-shot flash in the open inspector, then clear the flag shortly
  /// after so re-opening the inspector later can't re-flash the same (still-present) row. The row's
  /// own animation runs on appear/change of this id (see `NotificationsList`).
  private func flashNotification(_ id: UUID) {
    flashNotifID = id
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      if self?.flashNotifID == id { self?.flashNotifID = nil }
    }
  }

  /// Whether the user is currently looking at this terminal: the app is frontmost, one of its windows
  /// is key, and the tab is **visible** in the selected target — the focused solo tab, or any pane of
  /// the on-screen split (issue #3, decision D3). A notification's job is to surface the unseen, and an
  /// on-screen pane is seen — so visible panes are suppressed; a visible non-focused pane gets a
  /// per-pane border flash instead (see `handleActivity`). Window-aware so a sheet, a background
  /// window, or a non-frontmost app don't count as focused (issue #10, tension 2).
  func isFocused(targetID: TerminalTarget.ID, tabID: TerminalTab.ID) -> Bool {
    guard NSApp.isActive, NSApp.keyWindow != nil else { return false }
    guard let target = onScreenTarget(forID: targetID) else { return false }
    return terminals.visibleTabIDs(for: target).contains(tabID)
  }

  /// The on-screen target for `targetID`, ignoring app/window activation (so it's unit-testable): the
  /// selected target, or — when a workroom split is shown — any co-displayed split member. The focused
  /// member is `selectedTarget`, but the *other* members render beside it (issue #23), so their
  /// terminals are equally on screen; without this `isFocused` would treat a visible non-selected
  /// member's activity as unseen and post a banner for a pane the user is looking at. nil if not shown.
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

  /// Human-readable origin for a notification: the project name, plus the workroom for a
  /// workroom terminal (e.g. "platform" for a root, "platform / fix-auth" for a workroom).
  /// Resolved against the live projects (no string parsing of the id).
  private func notificationSource(forTargetID id: TerminalTarget.ID) -> String {
    for p in projects {
      if TerminalTarget.rootID(project: p.path) == id { return p.displayName }
      for w in p.workrooms where TerminalTarget.workroomID(project: p.path, name: w.name) == id {
        return "\(p.displayName) / \(w.name)"
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

/// The live log for one create/delete run. Lines stream in from the CLI's NDJSON
/// stderr (see WorkroomCLI). A plain ObservableObject — all mutations happen on the
/// main thread (the store hops there before appending), so SwiftUI sees them safely.
final class ScriptLogSession: ObservableObject, Identifiable {
  let id = UUID()
  let title: String
  let phase: String
  /// The terminal target id this log is docked under, once the CLI reports the workroom
  /// exists. nil while the workroom is still being created.
  var targetID: TerminalTarget.ID?
  /// When true, this session blocks its workroom's terminal: the detail pane shows the
  /// setup log full-pane (no terminal) until the user dismisses it. Set once, before the
  /// session is inserted into the observed `logs` dict, so it must NOT be @Published —
  /// flipping it after mount would create then tear down a terminal (mirrors `targetID`).
  var blocking = false
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
