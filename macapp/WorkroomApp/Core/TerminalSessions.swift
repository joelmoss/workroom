import AppKit

/// One terminal tab: a stable id, the single surface it owns, and the strip title. With splits (issue
/// #3) a tab is still exactly one surface — a "split" composes several tabs into one on-screen layout
/// (see `PaneLayout`), it does not nest surfaces inside a tab. `TerminalTab` stays a value type on
/// purpose: live-title updates mutate a copy and reassign the dict, which is what drives `@Published`
/// (a reference type would not). The surface is a shared reference the tab owns; `teardown(_:)` frees it.
struct TerminalTab: Identifiable {
  let id = UUID()
  /// The 1:1 terminal surface this tab owns.
  let view: GhosttySurfaceView
  /// Shown until the surface reports a title — and again whenever it reports an empty one.
  let defaultTitle: String
  /// The surface's latest non-empty title (OSC 0/2 via shell integration): the running command while
  /// busy, the working directory when idle. Nil until the first report (issue #2).
  var liveTitle: String?

  /// OSC 9;4 progress — the *only* signal that drives `isRunning`, matching how Ghostty and Muxy work
  /// (neither ties "busy" to the title). `true` while the running program reports it's working,
  /// `false`/`nil` when it's idle, done, or never reported any. Reset at `command_finished`; the surface
  /// also clears it via a 15s safety timer, so a program that sets progress but never sends REMOVE (or a
  /// long-idle TUI) can't pin the spinner on (issue #28 follow-up).
  var progressActive: Bool?

  /// What the tab strip displays.
  var title: String { liveTitle ?? defaultTitle }

  /// Whether a command is actively *working* in this terminal (issue #28) — drives the chip underline
  /// and the sidebar spinner. Driven solely by OSC 9;4 progress, like Ghostty/Muxy: a long-lived
  /// foreground program (claude, codex, a dev server) idling at its own prompt reports no progress, so
  /// it no longer spins forever. The command title (`liveTitle`) names the tab only — never "busy".
  var isRunning: Bool { progressActive == true }
}

/// Owns the live terminals for each target (a workroom or a project root) for the app session, so
/// switching targets/tabs hides/shows terminals instead of tearing them down (a dev server in one tab
/// keeps running while you look at another). Keyed on the project-scoped `TerminalTarget.ID`.
///
/// Split model (issue #3) is **single-layout**: per target there is at most ONE `PaneLayout` split (a
/// tree of ≥2 tab ids) plus solo tabs. The content area shows the split when the focused tab belongs to
/// it, otherwise the focused solo tab. The shared tab strip lists every tab; the split's members render
/// as a contiguous bracketed run, ordered by the split tree (`displayedTabIDs`). Cross-relaunch disk
/// persistence is intentionally out of scope.
///
/// ```
///   STRIP:  A  [ B │ C ]  D        focused == C, C ∈ split  →  CONTENT renders the split.
///              └ bracket ┘         focused == A (solo)      →  CONTENT renders just A; split hidden.
/// ```
@MainActor
final class TerminalSessions: ObservableObject {
  /// Every tab for a target, by id — the single source of truth for surfaces/titles.
  @Published private var tabsByTarget: [TerminalTarget.ID: [TerminalTab.ID: TerminalTab]] = [:]
  /// The strip order (loose). The displayed order normalises this so the split's members are a
  /// contiguous run in split-tree order — see `displayedTabIDs`.
  @Published private var orderByTarget: [TerminalTarget.ID: [TerminalTab.ID]] = [:]
  /// The one split layout per target, if any (always ≥2 leaves; a lone tab is "no split").
  @Published private var splitByTarget: [TerminalTarget.ID: TerminalPaneLayout] = [:]
  /// The focused/selected tab per target. Selection = this tab (+ its split, if it's a member).
  @Published private var focusedTabByTarget: [TerminalTarget.ID: TerminalTab.ID] = [:]
  /// Bumped when a *visible but non-focused* pane reports activity (D3): the renderer flashes that
  /// pane's border instead of badging it (you can see it, so no banner/badge — just a glance cue).
  /// Keyed by tab id; the value is an opaque counter the leaf view watches for changes.
  @Published private(set) var activityPulses: [TerminalTab.ID: Int] = [:]
  /// Per-target running counter so tab titles ("Terminal 1", "2", …) stay stable across closes.
  private var counts: [TerminalTarget.ID: Int] = [:]
  /// Set once by `AppStore`: forwards each terminal's notification-worthy activity (OSC) up to the
  /// notification spine. A closure (not a store reference) so sessions stay ignorant of `AppStore`.
  var activityHandler: ((TerminalTarget.ID, TerminalTab.ID, TerminalActivity) -> Void)?
  /// Set once by `AppStore`: fired whenever the focused tab of a target actually changes, so
  /// navigation history (issue #26) can record the new location. A closure (not a store reference),
  /// mirroring `activityHandler`, so sessions stay ignorant of `AppStore`. `tabID` is nil when the
  /// target's focus was cleared (a `reap` passes `notify: false`, so that case never reaches here).
  var onFocusChange: ((TerminalTarget.ID, TerminalTab.ID?) -> Void)?
  /// Set once by `AppStore`: the tabs just removed by a `closeTab` or `reap`, so navigation history
  /// can prune their now-dead entries (issue #26 — honest back/forward enablement).
  var onTabsRemoved: ((TerminalTarget.ID, [TerminalTab.ID]) -> Void)?
  /// Set once by `AppStore`: a surface in this target became first responder (a click into its
  /// terminal). Routes focus up to the *workroom* selection in a workroom split (issue #23 follow-up),
  /// so ⌘T/Run/notifications target the clicked pane's workroom. A closure (not a store reference),
  /// mirroring `onFocusChange`, so sessions stay ignorant of `AppStore`.
  var onSurfaceFocused: ((TerminalTarget.ID) -> Void)?

  /// Factory seam (plan T1): how a surface view is created for a target at a working directory.
  /// Overridable in tests so the lifecycle can be exercised without a real window/shell. The cwd
  /// argument lets a ⌘D split inherit the focused pane's directory.
  var makeView: (TerminalTarget, String, String?) -> GhosttySurfaceView = { _, cwd, command in
    GhosttySurfaceView(workingDirectory: cwd, command: command)
  }

  /// Smallest usable pane edge (points). A split is refused when it would shrink a pane below this; the
  /// renderer applies the same minimum as its divider clamp.
  static let minPaneSize: CGFloat = 120
  /// Divider track thickness (points), shared by the fit guard and the renderer.
  static let dividerThickness: CGFloat = 7

  private var appearanceObserver: NSObjectProtocol?

  init() {
    appearanceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
      queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.async { self?.applyThemeToAll() }
    }
  }

  deinit {
    if let appearanceObserver {
      DistributedNotificationCenter.default().removeObserver(appearanceObserver)
    }
  }

  // MARK: Queries

  /// Tab ids in strip order: the loose order, with the split's members replaced by the split tree's
  /// order as a contiguous block at the earliest member's slot. So the bracket is always one run and
  /// strip order always matches pane order (rearranging panes IS strip reorder).
  func displayedTabIDs(for target: TerminalTarget) -> [TerminalTab.ID] {
    let order = orderByTarget[target.id] ?? []
    guard let split = splitByTarget[target.id] else { return order }
    let members = split.tabIDs
    let memberSet = Set(members)
    guard let anchor = order.firstIndex(where: { memberSet.contains($0) }) else { return order }
    var result: [TerminalTab.ID] = []
    for (i, id) in order.enumerated() {
      if i == anchor { result.append(contentsOf: members) }
      if !memberSet.contains(id) { result.append(id) }
    }
    return result
  }

  func tabs(for target: TerminalTarget) -> [TerminalTab] {
    let dict = tabsByTarget[target.id] ?? [:]
    return displayedTabIDs(for: target).compactMap { dict[$0] }
  }

  /// Number of live tabs for a target id (issue #30 — lets `AppStore` prune the sidebar's
  /// terminal-subtree expand flag when a close drops a target below the 2-tab disclosure threshold).
  func tabCount(forTargetID id: TerminalTarget.ID) -> Int { (tabsByTarget[id] ?? [:]).count }

  /// The set of target ids that currently own at least one terminal — the "active" targets backing
  /// the Workrooms View tab bar (issue #23). Filtered on **non-empty** because `closeTab` leaves an
  /// emptied target as `[:]` (key present) while `reap` removes the key entirely; both must read as
  /// inactive. Reads `@Published tabsByTarget`, so observers re-render as targets gain/lose terminals.
  var activeTargetIDs: Set<TerminalTarget.ID> {
    Set(tabsByTarget.compactMap { $0.value.isEmpty ? nil : $0.key })
  }

  /// Whether any terminal in this target is mid-command (has a live command title, issue #2) — drives
  /// the sidebar's running spinner.
  func isRunning(forTargetID id: TerminalTarget.ID) -> Bool {
    (tabsByTarget[id] ?? [:]).values.contains { $0.isRunning }
  }

  /// The target's split layout, if a split currently exists.
  func split(for target: TerminalTarget) -> TerminalPaneLayout? { splitByTarget[target.id] }

  /// Look up a tab by id (the pane renderer resolves leaves → surfaces through this).
  func tab(_ id: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab? {
    tabsByTarget[target.id]?[id]
  }

  /// The focused tab (selection), falling back to the first tab in strip order.
  func focusedTab(for target: TerminalTarget) -> TerminalTab? {
    let dict = tabsByTarget[target.id] ?? [:]
    if let id = focusedTabByTarget[target.id], let match = dict[id] { return match }
    return displayedTabIDs(for: target).first.flatMap { dict[$0] }
  }

  /// Alias kept so existing call sites/tests read naturally. "The active tab" is the focused pane.
  func activeTab(for target: TerminalTarget) -> TerminalTab? { focusedTab(for: target) }

  /// Whether the content area should render the split (the focused tab belongs to it) vs a solo tab.
  func isSplitVisible(for target: TerminalTarget) -> Bool {
    guard let split = splitByTarget[target.id], let focused = focusedTabByTarget[target.id] else {
      return false
    }
    return split.contains(focused)
  }

  /// The tab ids currently on screen: the split's members when the split is visible, else the focused
  /// solo tab. Drives occlusion.
  func visibleTabIDs(for target: TerminalTarget) -> [TerminalTab.ID] {
    if isSplitVisible(for: target), let split = splitByTarget[target.id] { return split.tabIDs }
    if let focused = focusedTab(for: target) { return [focused.id] }
    return []
  }

  // MARK: Lifecycle

  /// Create the target's first terminal the first time its pane appears. Once opened, an emptied tab
  /// set is left as-is (the user closed them on purpose).
  func ensureTab(for target: TerminalTarget) {
    if orderByTarget[target.id] == nil { addTab(for: target) }
  }

  /// Open a new solo terminal at the end of the strip and focus it (⌘T). Does not touch the split.
  @discardableResult
  func addTab(for target: TerminalTarget) -> TerminalTab {
    let tab = makeTab(for: target, cwd: target.path)
    insert(tab, for: target)
    setFocused(tab.id, for: target.id)
    reconcileOcclusion(for: target)
    return tab
  }

  /// Open the dedicated "run command" terminal (issue #7): a solo tab that launches `command` in
  /// `cwd`, titled "Run" until the program reports its own title, focused like any new tab — through
  /// `setFocused`, so focus observers fire (it is NOT a direct dict write; see the focus-chokepoint
  /// note on `setFocused`). The caller (`AppStore`) owns the run-state and wires `onChildExited`;
  /// this just creates and shows the tab.
  ///
  /// Run-tab lifecycle — one `AppStore.RunState` per target; the pane stays open on exit via
  /// `wait_after_command`:
  /// ```
  ///   armed                       auto-run queued before the workroom's pane exists; consumed on mount
  ///   start (no state / armed) ─▶ spawn surface (command = $SHELL -lic '<cmd>', wait_after_command);
  ///                               focus; state = running
  ///
  ///   running ──────── Run / ⌘R ─────────▶ focus (no respawn)
  ///   running ──────── Stop (1st) ───────▶ Ctrl-C; state = running(interrupted)
  ///   running ──────── Restart ──────────▶ Ctrl-C; state = restarting
  ///   running / running(interrupted) ── child exits ─▶ stopped (pane open)
  ///   running(interrupted) ── Stop (2nd) ─▶ closeTab → ghostty_surface_free (SIGHUP, hard kill)
  ///   restarting ── child exits ─▶ close + respawn (graceful; frees the port); Stop ─▶ running(interrupted)
  ///   stopped ──────── Run / ⌘R / Restart ─▶ close + respawn
  ///   any state ────── close tab (⌘W/✕) / reap ─▶ removed (state cleared via onTabsRemoved)
  /// ```
  @discardableResult
  func addRunTab(for target: TerminalTarget, command: String, cwd: String) -> TerminalTab {
    let tab = makeRunTab(for: target, command: command, cwd: cwd)
    insert(tab, for: target)
    setFocused(tab.id, for: target.id)
    reconcileOcclusion(for: target)
    return tab
  }

  /// Respawn a run tab *in place* (issue #40). The old run tab is closed FIRST — freeing its surface
  /// hangs up the PTY (SIGHUP), releasing any bound port before the replacement spawns, the
  /// graceful-restart ordering `AppStore` depends on — but the new run tab then takes the old one's
  /// exact slot: its position in the split (same neighbour, orientation, ratio) and its place in the
  /// strip order, instead of the split collapsing and the replacement reappearing as a solo pane
  /// outside it. With no split (the run tab was solo) this is just close-then-append, like a plain
  /// `addRunTab`. Returns the new tab so the caller wires run-state + `onChildExited`, as `addRunTab` does.
  @discardableResult
  func respawnRunTab(
    replacing oldID: TerminalTab.ID, for target: TerminalTarget, command: String, cwd: String
  ) -> TerminalTab {
    // Capture the old tab's place BEFORE closing it collapses the split / drops it from the order.
    let priorSplit = splitByTarget[target.id]
    let wasInSplit = priorSplit?.contains(oldID) ?? false
    let orderIndex = orderByTarget[target.id]?.firstIndex(of: oldID)

    closeTab(oldID, for: target)  // frees the port (SIGHUP); collapses the split — restored below

    let tab = makeRunTab(for: target, command: command, cwd: cwd)
    tabsByTarget[target.id, default: [:]][tab.id] = tab
    if let orderIndex {
      var order = orderByTarget[target.id] ?? []
      order.insert(tab.id, at: min(orderIndex, order.count))
      orderByTarget[target.id] = order
    } else {
      orderByTarget[target.id, default: []].append(tab.id)
    }
    // Re-derive the split from the pre-close tree with the new tab in the old leaf's slot — exact for
    // any depth (a 3-pane split keeps both siblings), unlike re-inserting beside a guessed neighbour.
    if wasInSplit, let priorSplit {
      splitByTarget[target.id] = priorSplit.replacingLeaf(oldID, with: tab.id)
    }
    setFocused(tab.id, for: target.id)
    reconcileOcclusion(for: target)
    return tab
  }

  /// Build a run tab (issue #7) without placing it: the surface launches `command` in `cwd`, titled
  /// "Run" until the program reports its own title. "Process exited. Press any key to close"
  /// (wait_after_command) → close this tab on the keypress, without the confirm (the process has
  /// already exited). Only run tabs wire `onCloseRequested`. Shared by `addRunTab` (append + focus) and
  /// `respawnRunTab` (in-place restart, issue #40).
  private func makeRunTab(for target: TerminalTarget, command: String, cwd: String) -> TerminalTab {
    let tab = makeTab(for: target, cwd: cwd, command: command, title: "Run")
    let targetID = target.id
    let tabID = tab.id
    tab.view.onCloseRequested = { [weak self] in
      guard let self, let target = self.target(forID: targetID) else { return }
      self.closeTab(tabID, for: target)
    }
    return tab
  }

  /// Split the focused pane by spawning a new terminal on the trailing side (⌘D right, ⇧⌘D down).
  func splitFocusedPane(for target: TerminalTarget, orientation: SplitOrientation) {
    splitFocusedPane(for: target, edge: orientation == .horizontal ? .right : .bottom)
  }

  /// Split the focused pane by spawning a new terminal on `edge` (right/left/down/up), inheriting the
  /// focused pane's working directory. No-op (refused) if the focused pane is already too small to
  /// halve (D4). If the focused tab is solo, any existing split is dissolved first — at most one split
  /// exists at a time.
  func splitFocusedPane(for target: TerminalTarget, edge: PaneEdge) {
    guard let focused = focusedTab(for: target) else { return }
    guard fits(splitting: focused.view, orientation: edge.orientation) else { return }

    let cwd = focused.view.lastKnownCwd ?? target.path
    let newTab = makeTab(for: target, cwd: cwd)
    tabsByTarget[target.id, default: [:]][newTab.id] = newTab

    if let existing = splitByTarget[target.id], existing.contains(focused.id) {
      // Grow the existing split beside the focused leaf, on the requested side.
      splitByTarget[target.id] = existing.inserting(
        newTab.id, beside: focused.id, orientation: edge.orientation,
        newLeafFirst: edge.placesDroppedFirst, ratio: 0.5)
    } else {
      // Start a fresh split from the focused solo tab; dissolve any other split.
      let new = PaneLayout.leaf(newTab.id)
      let anchor = PaneLayout.leaf(focused.id)
      splitByTarget[target.id] = .split(
        id: UUID(), orientation: edge.orientation, ratio: 0.5,
        first: edge.placesDroppedFirst ? new : anchor,
        second: edge.placesDroppedFirst ? anchor : new)
    }
    // Place the new tab right after the focused one in the loose order (display normalises anyway).
    insertID(newTab.id, after: focused.id, for: target)
    setFocused(newTab.id, for: target.id)
    reconcileOcclusion(for: target)
  }

  /// Drag-and-drop (issue #3): place `movedID` on `edge` of `destID`'s pane. One op covers both
  /// dragging a tab from the strip into a pane AND rearranging an existing pane, since panes are tabs.
  /// Maintains the single-split invariant (starting a split from two solo tabs dissolves any other).
  /// No-op if either tab is missing or `movedID == destID`.
  func moveTabIntoSplit(
    _ movedID: TerminalTab.ID, ontoEdge edge: PaneEdge, of destID: TerminalTab.ID,
    for target: TerminalTarget
  ) {
    guard movedID != destID, tabsByTarget[target.id]?[movedID] != nil,
      tabsByTarget[target.id]?[destID] != nil
    else { return }

    // Base = the current split with `movedID` removed if it was in it; else the existing split when it
    // holds `destID`; else just the destination leaf (a fresh split, dissolving any unrelated one).
    let base: TerminalPaneLayout
    if let split = splitByTarget[target.id], split.contains(movedID) {
      base = split.removingLeaf(movedID) ?? .leaf(destID)
    } else if let split = splitByTarget[target.id], split.contains(destID) {
      base = split
    } else {
      base = .leaf(destID)
    }

    if base.contains(destID) {
      splitByTarget[target.id] = base.inserting(
        movedID, beside: destID, orientation: edge.orientation,
        newLeafFirst: edge.placesDroppedFirst, ratio: 0.5)
    } else {
      let dropped = PaneLayout.leaf(movedID)
      let anchor = PaneLayout.leaf(destID)
      splitByTarget[target.id] = .split(
        id: UUID(), orientation: edge.orientation, ratio: 0.5,
        first: edge.placesDroppedFirst ? dropped : anchor,
        second: edge.placesDroppedFirst ? anchor : dropped)
    }
    insertID(movedID, after: destID, for: target)  // display normalises the contiguous run
    setFocused(movedID, for: target.id)
    reconcileOcclusion(for: target)
  }

  /// Pull a tab out of the split so it's a solo terminal again (drag a chip clear of the group). The
  /// split dissolves if only one member would remain. No-op if the tab isn't in a split.
  func extractFromSplit(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let split = splitByTarget[target.id], split.contains(tabID) else { return }
    if let collapsed = split.removingLeaf(tabID), collapsed.tabIDs.count >= 2 {
      splitByTarget[target.id] = collapsed
    } else {
      splitByTarget[target.id] = nil
    }
    setFocused(tabID, for: target.id)  // show the extracted tab on its own
    reconcileOcclusion(for: target)
  }

  /// Focus a tab (and, if it's a split member, show the split). Single entry point: chip tap, ⌘1–9,
  /// notification routing, neighbour-after-close. `select` is an alias kept for existing call sites.
  func focus(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard tabsByTarget[target.id]?[tabID] != nil else { return }
    guard focusedTabByTarget[target.id] != tabID else { return }
    setFocused(tabID, for: target.id)
    reconcileOcclusion(for: target)
  }

  func select(_ tabID: TerminalTab.ID, for target: TerminalTarget) { focus(tabID, for: target) }

  /// The single write-point for a target's focused tab (issue #26). Centralising the seven former
  /// direct writes means every focus change — `addTab`, splits, drag-into-split, `focus`, and the
  /// close-successor — fires `onFocusChange` so navigation history can record the new location.
  /// `notify: false` is used only by `reap` (the target is being torn down; nothing is focused
  /// afterward, and its history entries are skipped at replay instead). No-op when unchanged.
  private func setFocused(
    _ tabID: TerminalTab.ID?, for targetID: TerminalTarget.ID, notify: Bool = true
  ) {
    guard focusedTabByTarget[targetID] != tabID else { return }
    focusedTabByTarget[targetID] = tabID
    if notify { onFocusChange?(targetID, tabID) }
  }

  /// Move focus to the adjacent pane in `direction` within the visible split (⌃⌘arrows, issue #3).
  /// Returns whether focus actually moved, so the key monitor only swallows the event when it acts.
  @discardableResult
  func focusAdjacentPane(_ direction: PaneDirection, for target: TerminalTarget) -> Bool {
    guard isSplitVisible(for: target), let split = splitByTarget[target.id],
      let focused = focusedTabByTarget[target.id],
      let next = PaneTreeLayout.adjacentPane(to: focused, direction: direction, in: split)
    else { return false }
    focus(next, for: target)
    return true
  }

  /// Reorder (drag-and-drop in the tab bar): move the dragged tab to `index` in the loose strip order,
  /// clamped to bounds. Display normalisation keeps the split's run contiguous regardless.
  func moveTab(_ draggedID: TerminalTab.ID, toIndex index: Int, for target: TerminalTarget) {
    guard var order = orderByTarget[target.id],
      let from = order.firstIndex(of: draggedID)
    else { return }
    order.remove(at: from)
    order.insert(draggedID, at: max(0, min(index, order.count)))
    orderByTarget[target.id] = order
  }

  /// Set the divider ratio of one split node (the view clamps to the points-based minimum first).
  func setRatio(_ ratio: CGFloat, forSplit splitID: UUID, for target: TerminalTarget) {
    guard let split = splitByTarget[target.id] else { return }
    splitByTarget[target.id] = split.settingRatio(ratio, forSplit: splitID)
  }

  /// Close a tab. If it's a split member the split collapses to the surviving sibling subtree (and
  /// dissolves when only one member would remain). Closing the last tab leaves the target with none.
  func closeTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let tab = tabsByTarget[target.id]?[tabID] else { return }
    let wasFocused = focusedTabByTarget[target.id] == tabID

    // Compute the focus successor BEFORE mutating, using the on-screen order.
    let successor = closeSuccessor(of: tabID, for: target)

    teardown(tab)
    tabsByTarget[target.id]?[tabID] = nil
    orderByTarget[target.id]?.removeAll { $0 == tabID }
    activityPulses[tabID] = nil

    if let split = splitByTarget[target.id], split.contains(tabID) {
      if let collapsed = split.removingLeaf(tabID), collapsed.tabIDs.count >= 2 {
        splitByTarget[target.id] = collapsed
      } else {
        splitByTarget[target.id] = nil  // dropped to a lone tab — no split anymore
      }
    }

    if wasFocused { setFocused(successor, for: target.id) }
    reconcileOcclusion(for: target)
    onTabsRemoved?(target.id, [tabID])
  }

  /// Terminate and forget every terminal for a target (on delete / when its directory disappears).
  func reap(_ id: TerminalTarget.ID) {
    let removedIDs = Array((tabsByTarget[id] ?? [:]).keys)
    for tab in (tabsByTarget[id] ?? [:]).values {
      teardown(tab)
      activityPulses[tab.id] = nil
    }
    tabsByTarget[id] = nil
    orderByTarget[id] = nil
    splitByTarget[id] = nil
    setFocused(nil, for: id, notify: false)
    counts[id] = nil
    if !removedIDs.isEmpty { onTabsRemoved?(id, removedIDs) }
  }

  func reapAll() {
    for id in Array(tabsByTarget.keys) { reap(id) }
  }

  /// Re-theme every live terminal — visible and hidden, solo and split alike — to the current
  /// appearance. Driven from `RootView.applyAppearance()` and the system-appearance observer.
  func applyThemeToAll() {
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    GhosttyApp.shared.reloadConfig()
    GhosttyApp.shared.setColorScheme(dark: isDark)
    let config = GhosttyApp.shared.config
    for tabs in tabsByTarget.values {
      for tab in tabs.values {
        if let config { tab.view.updateConfig(config) }
        tab.view.applyColorScheme(isDark: isDark)
      }
    }
  }

  // MARK: Occlusion (A4 / issue #3)

  /// One reconciliation pass: exactly the on-screen tabs render; every other surface for the target is
  /// paused (its shell keeps running — `setVisible(false)` toggles GPU occlusion, not the PTY). Called
  /// from every state change that can alter what's on screen (focus / split / close / move / reap).
  func reconcileOcclusion(for target: TerminalTarget) {
    let visible = Set(visibleTabIDs(for: target))
    for tab in (tabsByTarget[target.id] ?? [:]).values {
      tab.view.setVisible(visible.contains(tab.id))
    }
  }

  /// Flash a visible non-focused pane's border to acknowledge activity without a banner/badge (D3).
  /// Driven from `AppStore.handleActivity`.
  func pulsePaneActivity(_ tabID: TerminalTab.ID) {
    activityPulses[tabID, default: 0] += 1
  }

  // MARK: Live titles (issue #2)

  /// Show a surface-reported command title on its tab; directory/prompt titles are ignored so the
  /// command sticks until `command_finished` clears it.
  private func updateTitle(_ title: String, forTab tabID: TerminalTab.ID, target: TerminalTarget.ID)
  {
    guard var tab = tabsByTarget[target]?[tabID] else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !Self.isDirectoryTitle(trimmed, cwd: tab.view.lastKnownCwd) else {
      return
    }
    guard tab.liveTitle != trimmed else { return }
    tab.liveTitle = trimmed
    tabsByTarget[target]?[tabID] = tab
  }

  /// The shell returned to its prompt (OSC 133 D): drop the finished command's title back to the default
  /// (issue #2) and clear any OSC 9;4 progress, so the indicator stops the moment the command exits.
  private func handleCommandFinished(forTab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard var tab = tabsByTarget[target]?[tabID], tab.liveTitle != nil || tab.progressActive != nil
    else { return }
    tab.liveTitle = nil
    tab.progressActive = nil
    tabsByTarget[target]?[tabID] = tab
  }

  /// Apply an OSC 9;4 progress report (issue #28 follow-up). `active` is false only for the REMOVE state
  /// (the program declared itself idle/done) and true for any live progress (SET / INDETERMINATE / PAUSE
  /// / ERROR). This is the sole driver of `isRunning` — the spinner follows the program's own signal.
  private func updateProgress(
    _ active: Bool, forTab tabID: TerminalTab.ID, target: TerminalTarget.ID
  ) {
    guard var tab = tabsByTarget[target]?[tabID], tab.progressActive != active else { return }
    tab.progressActive = active
    tabsByTarget[target]?[tabID] = tab
  }

  /// Whether `title` is just the working directory (the idle title the shell/prompt sets) rather than a
  /// running command — so the tab strip can ignore it (issue #2). Pure for testability.
  ///
  /// This MUST recognise every form a prompt emits for the cwd: a directory title that slips through is
  /// latched as a `liveTitle` and read as a running command (issue #28), but — being no real command — it
  /// never gets the `command_finished` that would clear it, so the sidebar spinner spins forever. The
  /// shipped zsh integration abbreviates deep paths (`%(4~|…/%3~|%~)` → "…/dir/dir/dir"), and bash's
  /// `PROMPT_DIRTRIM` truncates with ".../", so the full-path match alone isn't enough.
  static func isDirectoryTitle(_ title: String, cwd: String?, home: String = NSHomeDirectory())
    -> Bool
  {
    guard let cwd, !cwd.isEmpty else { return false }
    var path = title
    if let colon = title.firstIndex(of: ":") {
      let prefix = title[..<colon]
      if prefix.contains("@"), !prefix.contains(" ") {
        path = String(title[title.index(after: colon)...])
      }
    }
    let tilde = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd

    // Full directory title (bash `\w`, zsh `%~` when the path is shallow enough to fit untruncated).
    if path == cwd || path == tilde { return true }

    // Truncated directory title: a shell abbreviates a deep path to an ellipsis marker plus a trailing
    // run of the path's own components (zsh "…/macapp/WorkroomApp", bash PROMPT_DIRTRIM ".../a/b"). It's
    // a directory title when, after the marker, it's a path-component suffix of the cwd (or its ~-form).
    for marker in ["…/", ".../"] where path.hasPrefix(marker) {
      let tail = path.dropFirst(marker.count)
      guard !tail.isEmpty else { return false }
      return cwd.hasSuffix("/" + tail) || tilde.hasSuffix("/" + tail)
    }
    return false
  }

  // MARK: Internals

  /// Whether splitting `view` in `orientation` would leave both halves ≥ `minPaneSize` (D4). When the
  /// pane has no laid-out size yet (e.g. in tests, or before first layout) the guard can't evaluate, so
  /// it permits the split and lets the renderer's clamp handle sizing.
  private func fits(splitting view: GhosttySurfaceView, orientation: SplitOrientation) -> Bool {
    let available = orientation == .horizontal ? view.bounds.width : view.bounds.height
    guard available > 0 else { return true }
    return (available - Self.dividerThickness) / 2 >= Self.minPaneSize
  }

  /// The tab to focus after `tabID` is closed: the on-screen neighbour that slides into its slot, else
  /// the new last on-screen tab, else nil.
  private func closeSuccessor(of tabID: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab
    .ID?
  {
    let order = displayedTabIDs(for: target)
    guard let idx = order.firstIndex(of: tabID) else { return order.first { $0 != tabID } }
    let remaining = order.filter { $0 != tabID }
    guard !remaining.isEmpty else { return nil }
    return remaining[min(idx, remaining.count - 1)]
  }

  private func insert(_ tab: TerminalTab, for target: TerminalTarget) {
    tabsByTarget[target.id, default: [:]][tab.id] = tab
    orderByTarget[target.id, default: []].append(tab.id)
  }

  private func insertID(
    _ id: TerminalTab.ID, after other: TerminalTab.ID, for target: TerminalTarget
  ) {
    var order = orderByTarget[target.id] ?? []
    order.removeAll { $0 == id }
    if let i = order.firstIndex(of: other) {
      order.insert(id, at: i + 1)
    } else {
      order.append(id)
    }
    orderByTarget[target.id] = order
  }

  private func makeTab(
    for target: TerminalTarget, cwd: String, command: String? = nil, title: String? = nil
  ) -> TerminalTab {
    let count = (counts[target.id] ?? 0) + 1
    counts[target.id] = count
    let view = makeView(target, cwd, command)
    let tab = TerminalTab(view: view, defaultTitle: title ?? "Terminal \(count)")

    let targetID = target.id
    let tabID = tab.id
    view.onActivity = { [weak self] activity in
      self?.activityHandler?(targetID, tabID, activity)
    }
    view.onTitleChange = { [weak self] title in
      self?.updateTitle(title, forTab: tabID, target: targetID)
    }
    view.onCommandFinished = { [weak self] in
      self?.handleCommandFinished(forTab: tabID, target: targetID)
    }
    view.onProgressReport = { [weak self] active in
      self?.updateProgress(active, forTab: tabID, target: targetID)
    }
    // A pane became first responder (click / programmatic focus): make it the selection (issue #3),
    // and route up to the workroom selection so a click into a co-displayed split pane targets that
    // workroom (issue #23 follow-up).
    view.onFocused = { [weak self] in
      guard let self, let target = self.target(forID: targetID) else { return }
      self.focus(tabID, for: target)
      self.onSurfaceFocused?(targetID)
    }

    let projectPath = target.path
    view.onCmdClickFile = { [weak view] word in
      TerminalLinkOpener.handleCmdClickFile(word, cwd: view?.lastKnownCwd ?? projectPath)
    }
    view.resolveCmdHoverFile = { [weak view] word in
      TerminalLinkOpener.resolvesToFile(word, cwd: view?.lastKnownCwd ?? projectPath)
    }
    view.onOpenURL = { [weak view] url in
      TerminalLinkOpener.handleOpenURL(url, cwd: view?.lastKnownCwd ?? projectPath)
    }
    return tab
  }

  /// Reconstruct a minimal `TerminalTarget` from its id for the `onFocused` callback (which only
  /// carries ids). `focus` keys off the id alone, so a minimal target is sufficient.
  private func target(forID id: TerminalTarget.ID) -> TerminalTarget? {
    guard tabsByTarget[id] != nil else { return nil }
    return TerminalTarget(id: id, title: "", path: "", isMissing: false)
  }

  /// Tear down a tab's surface (clears callbacks before freeing, so no in-flight libghostty callback
  /// touches a dead view).
  private func teardown(_ tab: TerminalTab) { tab.view.tearDown() }
}
