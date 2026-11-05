import Foundation
import WorkroomDomain
import WorkroomVCS

/// Back/forward navigation history (issue #26): recording the on-screen location, stepping through
/// it, and applying a location. Moved out of `AppStore.swift` as is. Coupling points left on
/// `AppStore`: the `history` and `isNavigatingHistory` state, `selectedTargetID`/`selectedProjectID`,
/// and `terminals`; `AppStore` calls `withHistorySuppressed`, `recordCurrentLocation` and
/// `applyLocation(target:tab:recordHistory:)` from outside this file.
extension AppStore {
  // MARK: Navigation history (issue #26)

  /// Whether back/forward can move. Cursor-based (D2): liveness is validated when stepping, so a
  /// button can be enabled yet no-op in the rare case where every entry that way is dead.
  var canGoBack: Bool { history.canGoBack }
  var canGoForward: Bool { history.canGoForward }

  /// Record the on-screen location (selected target + its focused tab) into history. No-op while
  /// replaying (guarded at the call sites) and when there's no focused terminal yet — so a switch to
  /// a never-visited target records nothing until its first terminal exists, and the later
  /// `addTab`→`.focusChanged` records the real first entry (no `(target, nil)` ghost).
  func recordCurrentLocation() {
    guard let sid = selectedTargetID, let target = selectedTarget, target.opensTerminals,
      let tab = terminals.focusedTab(for: target)
    else { return }
    history.record(Self.location(target: sid, tab: tab))
  }

  /// Build a `NavLocation` from a focused tab: which tab, *what it was showing* (identity), and the
  /// descriptor needed to put it back. Every content kind is captured — a diff and a file used to
  /// record a bare path and nothing at all respectively, which is why back/forward could not reinstate
  /// them.
  private static func location(target sid: SidebarID, tab: TerminalTab) -> NavLocation {
    var selectedPath: String? = nil
    if case .changeset(let d) = tab.content { selectedPath = d.selectedPath }
    return NavLocation(
      target: sid, tab: tab.id, contentID: FocusedTabSelection(content: tab.content),
      selectedPath: selectedPath, payload: NavPayload(tab.content))
  }

  /// Run `body` with history recording suppressed, reinstating the *previous* value afterwards rather
  /// than clearing the flag outright.
  ///
  /// Nothing nests today: `applyLocation(_:)`'s two suppressed regions are sequential, so `wasNavigating`
  /// is `false` at all three call sites. Save-and-reinstate is the cheap insurance that keeps it that
  /// way — a bare `defer { isNavigatingHistory = false }` inside a future nested region would reopen
  /// recording halfway through the outer one and replay would silently record itself, which no
  /// assertion outside `testReplayAppendsNothing` would catch.
  func withHistorySuppressed(_ body: () -> Void) {
    let wasNavigating = isNavigatingHistory
    isNavigatingHistory = true
    defer { isNavigatingHistory = wasNavigating }
    body()
  }

  /// Go back one step, skipping entries whose target/tab no longer exist (D2). No-op when there's no
  /// live earlier location.
  func navigateBack() {
    if let loc = history.step(-1, isLive: isLive) { applyLocation(loc) }
  }

  /// Go forward one step (mirrors `navigateBack`).
  func navigateForward() {
    if let loc = history.step(+1, isLive: isLive) { applyLocation(loc) }
  }

  /// The single primitive for "go to (target, tab)": used by back/forward replay and by
  /// `openTerminal` (notification / ⇧⌘N). Sets the selection + focuses the tab with history recording
  /// suppressed (the `didSet`/`.focusChanged` seams no-op via `isNavigatingHistory`), then records
  /// exactly one entry when `recordHistory` is true — so a jump never leaves a phantom intermediate
  /// entry. `tab` is optional (an old notification may carry none / a stale id); it resolves to the
  /// requested tab when it still exists, else the target's current focused tab.
  func applyLocation(target sid: SidebarID, tab tabID: TerminalTab.ID?, recordHistory: Bool) {
    withHistorySuppressed {
      selectedProjectID = Self.projectPath(of: sid)
      selectedTargetID = sid
      guard let target = selectedTarget, target.opensTerminals else { return }
      let resolved =
        tabID.flatMap { id in terminals.allTabs(for: target).contains { $0.id == id } ? id : nil }
        ?? terminals.focusedTab(for: target)?.id
      guard let resolved else { return }
      terminals.focus(resolved, for: target)
      if recordHistory, let tab = terminals.tab(resolved, for: target) {
        history.record(Self.location(target: sid, tab: tab))
      }
    }
  }

  /// Back/forward replay of a full `NavLocation`: select the workroom, focus the tab, then put the
  /// recorded content back on screen.
  ///
  /// **Replay never creates a tab** — back ignores anything that was closed, and nothing is reopened.
  /// It always has somewhere to land, because `isLive` guarantees `loc.tab` still exists and a content
  /// tab can always be retargeted back to what it was showing:
  ///
  /// ```
  ///   applyLocation(loc)
  ///     │ select loc.target, focus loc.tab  (suppressed, so nothing re-records)
  ///     ├── payload == nil ─▶ a terminal ─▶ done: the focus above IS the whole replay
  ///     └── payload != nil ─▶
  ///           ├─ 1. loc.tab already shows it     ─▶ nothing to re-open, it is already there
  ///           ├─ 2. another live tab shows it     ─▶ focus that tab, rather than render the same
  ///           │                                      content twice (the ⌘D twin / a pinned copy)
  ///           └─ 3. else                          ─▶ retarget loc.tab IN PLACE, pin and all
  ///         then: reinstate the in-commit file selection, and refresh a working-copy diff's change
  ///         kind (the recorded payload's is a record-time value)
  /// ```
  ///
  /// Step 3 retargets a *pinned* `loc.tab` too. Restoring a tab's own earlier content is not the same as
  /// dropping unrelated content on it, which is what Keep Open protects against — and the alternative
  /// was worse: `persist` removes the preview slot, so requiring one stranded every entry browsed before
  /// a pin and left the Back chevron enabled-but-dead (one double-click re-armed the original bug).
  ///
  /// Not idempotent across a round trip when a ⌘D twin is involved: step 2 can focus the pinned anchor
  /// while the twin keeps whatever step 3 last put in it, so Back-then-Forward may leave a split
  /// arranged differently than it started. Content is always right; pane *placement* is not restored.
  private func applyLocation(_ loc: NavLocation) {
    applyLocation(target: loc.target, tab: loc.tab, recordHistory: false)
    guard let payload = loc.payload, let target = selectedTarget, target.opensTerminals else {
      return
    }
    withHistorySuppressed {
      let landing = payload

      let landedTab: TerminalTab.ID
      if let recorded = terminals.tab(loc.tab, for: target), landing.matchesTab(recorded.content) {
        landedTab = recorded.id  // 1 — already showing it
      } else if let other = terminals.allTabs(for: target).first(where: {
        landing.matchesTab($0.content)
      }) {
        terminals.focus(other.id, for: target)
        landedTab = other.id  // 2 — a different tab has it
      } else {
        terminals.setContent(landing, forTab: loc.tab, in: target)  // 3 — retarget in place
        landedTab = loc.tab
      }

      if case .changeset = landing {
        terminals.setChangesetSelectedPath(loc.selectedPath, forTab: landedTab, in: target)
      }
      // A recorded payload carries the change kind the file had when it was recorded, so step 3 writes a
      // stale one back. Settle it from live status, through the same path the sweep uses — replay is not
      // a special case, it just arrives at an already-refreshed tab a moment sooner.
      refreshOpenDiffChangeKinds(for: loc.target, status: workroomStatuses[loc.target])
    }
  }

  /// A payload with a working-copy `.diff`'s change kind refreshed from live status; everything else
  /// returned untouched. `nonisolated` + pure so the freshness rule is unit-testable without a store.
  ///
  /// The live change kind for a diff, or nil when there is nothing fresher to say than what the
  /// descriptor already carries. `nonisolated` + pure so the freshness rule is unit-testable without a
  /// store.
  ///
  /// Needed because `DiffDescriptor.change` is not inert: `DiffViewer` paints it as the header letter
  /// and the tab strip disables "Open file in…" when it is `.deleted`. A record-time value could offer
  /// to open a file that has since been deleted, or refuse one that has since come back.
  nonisolated static func liveChangeKind(
    for descriptor: DiffDescriptor, in status: WorkroomStatus?
  ) -> ChangedFile.Change? {
    switch descriptor.source {
    case .gitWorktree:
      break  // the working copy drifts under us — refresh it
    case .commit:
      return nil  // a commit's own diff is immutable; there is nothing fresher to read
    }
    // No entry ⇒ status has not loaded, or the file is no longer changed: keep what we have and let
    // the pane report.
    return status?.changedFiles?.first { $0.path == descriptor.path }?.change
  }

  /// Point every open working-copy diff tab of `sid` at the freshest change kind. Called from
  /// `mergeLocalStatus` (where a sweep lands) and after a back/forward landing.
  ///
  /// This is why the descriptor's `change` can be trusted by whoever renders it: the value is refreshed
  /// at the source rather than re-derived per surface, so `DiffViewer` and the tab strip need no status
  /// of their own — neither has to observe the sweep's high-frequency publisher (WORKROOM-2B).
  func refreshOpenDiffChangeKinds(for sid: SidebarID, status: WorkroomStatus?) {
    guard let target = target(for: sid) else { return }
    // `allTabs`: this refreshes MODEL state, so a detached diff pane must be swept too — otherwise
    // it keeps whatever change kind it had when it was popped out.
    for tab in terminals.allTabs(for: target) {
      guard case .diff(let descriptor) = tab.content,
        let live = Self.liveChangeKind(for: descriptor, in: status)
      else { continue }
      terminals.refreshDiffChangeKind(live, forTab: tab.id, in: target.id)
    }
  }

  /// Whether a recorded location is still reachable — the mechanism behind "back ignores what was
  /// closed". `step(_:isLive:)` skips every entry this rejects.
  ///
  /// Deliberately structural, and deliberately the SAME question `prune` asks: does the recorded tab
  /// still exist? Content needs no extra condition, because replay can always retarget that tab back to
  /// what it was showing (`applyLocation` step 3). An earlier version also demanded a landing spot — a
  /// matching tab or a free preview slot — which made this predicate disagree with `prune`: pinning a
  /// tab silently stranded every entry browsed before it while `canGoBack` (a raw cursor read) stayed
  /// true, so the chevron lit up and did nothing. Two predicates, one question.
  ///
  /// Does NOT ask whether the file or commit still exists on disk: that needs I/O inside a predicate run
  /// per candidate while stepping, and the pane already renders its own "Diff unavailable" /
  /// "Changeset unavailable" state.
  private func isLive(_ loc: NavLocation) -> Bool {
    guard let target = target(for: loc.target), target.opensTerminals else { return false }
    // `allTabs`: a detached pane is still reachable (its own window, ⌃⌘O), so its history entries
    // are live.
    return terminals.allTabs(for: target).contains { $0.id == loc.tab }
  }
}
