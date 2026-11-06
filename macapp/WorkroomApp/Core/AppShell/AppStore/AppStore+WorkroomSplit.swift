import AppKit
import CoreGraphics
import Foundation
import WorkroomDomain

/// Workroom-into-workroom split (issue #23 follow-up). The stored `workroomSplitGroups` lives on
/// `AppStore`; these are the transforms over it. The structural rules (move semantics, collapse,
/// auto-even, the fit check) are `PaneSplitGroups`', shared with `TerminalSessions`' terminal split
/// one level down; what is the workroom split's own is the policy it hands them
/// (`workroomSplitPolicy`: dead leaves pruned, workrooms weighted by their terminals) and every
/// entry's guard on `target(for:) != nil` — which rejects `.project` and any leaf that no longer
/// resolves (so the model can never hold an invalid workroom). The focused split member IS
/// `selectedTargetID`.
///
/// **Many groups, not one.** Like the terminal split (which learned this from here), a window can hold
/// SEVERAL workroom split groups at once — `[main | feature]` and `[docs | review]` both grouped, with
/// solo workrooms alongside. The groups are disjoint (a workroom belongs to at most one) and each holds
/// ≥2 leaves; at most one is *visible*, the one containing the selection. Splitting two solo workrooms
/// therefore leaves existing groups alone instead of replacing them.
extension AppStore {

  /// The split group `sid` belongs to, or nil when it isn't grouped. Groups are disjoint, so this is
  /// the one authority on "which group is this workroom in".
  func workroomSplit(containing sid: SidebarID) -> PaneLayout<SidebarID>? {
    workroomSplitGroups.group(containing: sid)
  }

  /// The visible group: the one containing the selection (nil when nothing is selected or the selected
  /// workroom is solo). Every "is a split on screen" read keys off this — a group whose members are all
  /// unselected persists but isn't displayed.
  var visibleWorkroomSplit: PaneLayout<SidebarID>? {
    selectedTargetID.flatMap { workroomSplit(containing: $0) }
  }

  /// Live `(sid, target)` for each leaf of `group` in tree order, dropping leaves that no longer resolve.
  /// Returns nil when the group has <2 live members (a lone leaf is "no split") — so a deleted workroom
  /// self-heals on read.
  func resolvedSplitLeaves(of group: PaneLayout<SidebarID>) -> [(
    sid: SidebarID, target: TerminalTarget
  )]? {
    let live = group.tabIDs.compactMap { sid in target(for: sid).map { (sid: sid, target: $0) } }
    return live.count >= 2 ? live : nil
  }

  /// Live leaves of the **visible** group (the one holding the selection), or nil when no split is on
  /// screen. This is the read the renderer's on-screen queries use (`onScreenTarget`).
  func resolvedSplitLeaves() -> [(sid: SidebarID, target: TerminalTarget)]? {
    visibleWorkroomSplit.flatMap { resolvedSplitLeaves(of: $0) }
  }

  /// Whether a split is currently *shown*: the selected workroom belongs to a group with ≥2 live
  /// members. Mirrors `TerminalSessions.split(for:)` — groups are persistent state; selecting a
  /// workroom outside every group shows it solo without dissolving anything (the group reappears on
  /// reselect).
  var isWorkroomSplitVisible: Bool {
    guard let group = visibleWorkroomSplit else { return false }
    return resolvedSplitLeaves(of: group) != nil
  }

  /// The layout the detail renders for `selected`: `selected`'s group when it has one, else the workroom
  /// solo (`.leaf`). Mirrors `WorkroomTerminalsView.contentLayout`. No group is discarded when a
  /// workroom outside it is shown — `workroomSplits` persists, so reselecting a member brings it back.
  ///
  /// Prunes leaves whose workroom no longer resolves *before* returning, so the renderer never lays out
  /// a rect (and a divider-to-nowhere) for a dead pane in the frame between an out-of-band deletion and
  /// `pruneWorkroomSplitToLiveLeaves()` running in `apply(_:)`. A lone surviving leaf is "no split".
  func visibleWorkroomLayout(for selected: SidebarID) -> PaneLayout<SidebarID> {
    if let split = workroomSplit(containing: selected) {
      var pruned = split
      for sid in split.tabIDs where target(for: sid) == nil {
        pruned = pruned.removingLeaf(sid) ?? pruned
      }
      if pruned.contains(selected), pruned.tabIDs.count >= 2 {
        return pruned
      }
    }
    return .leaf(selected)
  }

  /// The active workroom tabs in bar order, but with each split group's members pulled into a contiguous
  /// run at that group's earliest member's slot — so grouped workrooms sit together and one bracket can
  /// span each group (`PaneSplitGroups.normalized`, which the terminal strip's order uses too). No
  /// groups ⇒ just `orderedWorkroomTargets()`.
  func displayedWorkroomTargets() -> [(sid: SidebarID, target: TerminalTarget)] {
    let ordered = orderedWorkroomTargets()
    guard !workroomSplitGroups.isEmpty else { return ordered }
    let byID = Dictionary(ordered.map { ($0.sid, $0) }, uniquingKeysWith: { a, _ in a })
    // A member with no chip of its own (no terminal yet) is left out of the bar.
    return workroomSplitGroups.normalized(ordered.map(\.sid)).compactMap { byID[$0] }
  }

  /// `member → group index` for every grouped workroom, so the tab bar can bracket each group's run
  /// (`PaneSplitGroups.groupIndices`). Build it ONCE per render pass and thread it down — it walks
  /// every leaf of every group, and the bar consults it per chip.
  func workroomSplitGroupIndices() -> [SidebarID: Int] {
    workroomSplitGroups.groupIndices
  }

  /// Focus a split member: this is the selection (mirrors `RootView.selectWorkroomTab`). Records nav
  /// history via `selectionDidChange(from:)` — used by *deliberate* actions (drop, remove-reselect). The
  /// incidental click-to-focus path (a surface becoming first responder) routes through a
  /// history-suppressed setter instead (see the focus callback), so co-monitoring glances don't spam ⌘[.
  func focusWorkroomMember(_ sid: SidebarID) {
    selectedTargetID = sid
    selectedProjectID = Self.projectPath(of: sid)
  }

  /// Whether inserting `sid` beside `beside` GROWS the destination group, rather than rearranging
  /// within it. Two members of the same group swapping places leaves the pane count unchanged, which
  /// is why the floor below only applies to a genuine addition — the same
  /// gate `TerminalSessions.moveTabIntoSplit` applies (`PaneSplitGroups.addsMember`).
  func workroomSplitWouldAddMember(_ sid: SidebarID, beside: SidebarID) -> Bool {
    workroomSplitGroups.addsMember(sid, beside: beside)
  }

  /// Whether a drop of `sid` beside `beside` at `edge` will be ACCEPTED — the admissibility half of
  /// `insertWorkroomSplit`, split out so the drop indicator can ask the same question the commit
  /// answers. Drawing the accent band from anything else lets the preview promise a split the drop
  /// then silently refuses.
  ///
  /// `destinationRect` is the destination pane's measured rect; `nil` (no measurement available)
  /// admits the drop, matching `insertWorkroomSplit`'s own default.
  func canInsertWorkroomSplit(
    _ sid: SidebarID, beside: SidebarID, edge: PaneEdge, destinationRect: CGRect?
  ) -> Bool {
    guard workroomSplitWouldAddMember(sid, beside: beside) else { return true }
    // Group-aware once the container has been measured (issue #126): auto-even redistributes the
    // whole group rather than halving the destination pane, so a pane dragged narrow must not veto
    // a split the group has room for. Judged on the tree the commit will store, so the drop
    // indicator, `canOpenAsSplit` and `insertWorkroomSplit` still agree by construction.
    //
    // Over the LIVE tree, not the raw stored one (the policy's `live`). A workroom deleted in another
    // window stays in this window's tree until the next reload prunes it, while the renderer already
    // drops it on read (`visibleWorkroomLayout`) and the commit below prunes it too. Judging the raw
    // tree budgets space for a pane nobody can see and refuses a split the user can plainly make —
    // the "⌘D silently does nothing" papercut, through the ghost door.
    if let admitted = workroomSplitGroups.admits(
      sid, beside: beside, edge: edge, policy: workroomSplitPolicy)
    {
      return admitted
    }
    // Pre-layout fallback: the destination pane's own rect, judged by the anchor-only rule.
    guard let destinationRect else { return true }
    return PaneTreeLayout.canSplit(destinationRect, along: edge.orientation)
  }

  /// Insert `sid` beside `beside` on `edge`. Joins `beside`'s existing group, or seeds a **new** group
  /// from the two of them (leaving any other group untouched — a window holds many groups);
  /// **removes `sid` from its current group first** so dragging an existing pane to a new edge is a
  /// *move*, not a duplicate (`PaneSplitGroups.inserting`, as `TerminalSessions.moveTabIntoSplit`).
  /// Focuses the inserted member. No-op for a self-drop or non-resolving leaf.
  ///
  /// Returns whether a split was actually made. The three drag call sites ignore it (hence
  /// `@discardableResult`); the keyboard/menu callers use it as their single guard, so they never
  /// re-derive this function's reject conditions and can't drift from them.
  @discardableResult
  func insertWorkroomSplit(
    _ sid: SidebarID, beside: SidebarID, edge: PaneEdge, destinationRect: CGRect? = nil
  ) -> Bool {
    // Reject a self-drop, a non-resolving leaf (`.project` / deleted workroom), and a workroom whose
    // directory is gone (`isMissing`) — a missing leaf would render a "Directory not found" pane that
    // can only be backed out of again, so don't let one into the split in the first place (#23).
    // A create's pane is the one unavailable leaf let in (R1, #483): it opens beside its anchor.
    guard sid != beside, let dropped = target(for: sid),
      dropped.opensTerminals || dropped.unavailability == .creating,
      target(for: beside) != nil
    else { return false }
    // Pane floor. Workroom panes are the one place each pane draws its OWN `TerminalTabStrip`, whose
    // diff toolbar alone is ~145pt — which is where `minPaneWidth` (300) came from. Without this a
    // third chip dropped into ~700pt nested a split at `total: 348`, tripping `lengths`' even-split
    // fallback and yielding two 172pt panes. `destinationRect` is the pane's measured rect, threaded
    // from `RootView.workroomChipDropTarget` (the only layer that has the plan); `nil` means an
    // unmeasured caller and keeps the pre-floor behaviour rather than guessing.
    guard canInsertWorkroomSplit(sid, beside: beside, edge: edge, destinationRect: destinationRect)
    else { return false }
    // Leaves whatever group `sid` was in (possibly dissolving it) BEFORE joining `beside`'s, with no
    // selection re-point: `sid` is about to be focused anyway. A cross-group move removes a member
    // from its old group exactly as the ✕ does, so those survivors are evened as the ✕ evens them;
    // the joined group is evened as it will render, without a workroom deleted elsewhere that the
    // next reload's sweep has yet to prune, and weighted like every other even, so a workroom
    // showing two terminals side by side takes two thirds next to one showing one — the same tree
    // `canInsertWorkroomSplit` admitted.
    workroomSplitGroups = workroomSplitGroups.inserting(
      sid, beside: beside, edge: edge, policy: workroomSplitPolicy)
    focusWorkroomMember(sid)
    return true
  }

  /// The rect the anchor pane will occupy RIGHT NOW — derived per call, never remembered. Plans
  /// the anchor's own visible layout into the measured container and returns its slot, exactly the
  /// two steps `RootView.workroomChipDropTarget` runs for a drop. nil before the first layout pass
  /// (no container yet), which `canInsertWorkroomSplit` treats as "unmeasured" and admits.
  ///
  /// Derived rather than cached because the renderer only lays out the CURRENT selection's layout:
  /// a per-pane cache holds no entry for an anchor the user has since navigated away from, which
  /// is precisely the create-then-select-elsewhere path where the floor has to hold.
  func workroomPaneRect(for sid: SidebarID) -> CGRect? {
    guard let space = workroomPaneSpace, target(for: sid) != nil else { return nil }
    let layout = visibleWorkroomLayout(for: sid)
    return PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: space.size)).panes[sid]
  }

  /// Whether a split of `sid` beside the current selection can actually be made — the predicate
  /// behind both the "Open (split right)" menu item's visibility and `openExistingAsSplit`'s guard, so
  /// the affordance can never offer an action the action then refuses.
  ///
  /// Mirrors the drop indicator's contract (`canInsertWorkroomSplit` gates the accent band for the
  /// same reason): a preview must not promise a split the commit declines.
  func canOpenAsSplit(_ sid: SidebarID) -> Bool {
    guard let anchor = selectedTargetID, anchor != sid else { return false }
    // Same rejects `insertWorkroomSplit` applies, asked in advance.
    guard let dropped = target(for: sid), dropped.opensTerminals, target(for: anchor) != nil else {
      return false
    }
    return canInsertWorkroomSplit(
      sid, beside: anchor, edge: .right, destinationRect: workroomPaneRect(for: anchor))
  }

  /// Open `sid` beside the current workroom instead of replacing it (issue #163) — the action
  /// behind ⌥⌘O, ⌥⏎ in the Open picker, and the "Open (split right)" context-menu item.
  ///
  /// **A refused split does NOT fall back to a plain open.** That was the first shape and it was
  /// wrong: `openExisting` REPLACES the selected workroom, so on a window too narrow for the pane
  /// floor (`canSplit` wants ~602pt of pane) ⌥⌘O silently threw away the pane the user was looking
  /// at — moments after the picker's own header and footer promised a split. A missing target was
  /// worse: `insertWorkroomSplit` rejects `isMissing` precisely because a missing leaf can only be
  /// backed out of again (issue #23), and the fallback then full-framed it. So a refusal is a no-op
  /// with a beep, and `canOpenAsSplit` keeps the menu item away in the first place.
  ///
  /// It deliberately does NOT retry on another edge: landing to the right is the whole contract.
  func openExistingAsSplit(_ sid: SidebarID) {
    guard let anchor = selectedTargetID,
      insertWorkroomSplit(
        sid, beside: anchor, edge: .right, destinationRect: workroomPaneRect(for: anchor))
    else {
      // Reachable from the chord even when the menu item is hidden, so say something rather than
      // nothing — and never at the cost of the current pane.
      NSSound.beep()
      return
    }
    // `insertWorkroomSplit` already focused the new member; bring the app forward to show it.
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Remove `sid` from its split group: collapse to the survivor subtree, or dissolve the group (single
  /// view) when fewer than two members remain — re-pointing `selectedTargetID` to a survivor if the
  /// removed member was focused. Other groups are untouched. **Never reaps terminals** (the workroom
  /// keeps running; it just leaves the split). No-op if `sid` isn't a member of any group. The
  /// workroom-level `TerminalSessions.extractFromSplit`.
  func removeWorkroomSplitMember(_ sid: SidebarID) {
    // A running create's pane can't be closed (#483, AC 2); a run that has ended is dropped first.
    guard let group = workroomSplit(containing: sid), creationRun(for: sid)?.isRunning != true
    else { return }
    let wasFocused = selectedTargetID == sid
    // Non-nil for a group (≥2 leaves, so removing one always leaves a subtree); its first leaf is the
    // survivor to land on, whether the group collapses or dissolves. Read it BEFORE the edit.
    let survivor = group.removingLeaf(sid)?.firstTabID
    // The survivors are evened along the axis the member left (issue #126), without pruning:
    // `survivor` was chosen above, and a prune-driven dissolve here would strand the selection on it.
    workroomSplitGroups = workroomSplitGroups.removing(sid, policy: workroomSplitPolicy)
    if wasFocused, let survivor { focusWorkroomMember(survivor) }
  }

  /// When a split member's last terminal is closed, its pane has nothing left but the
  /// remove-from-split ✕ — so close it for the user: drop the now-empty workroom from its group
  /// (collapse to the survivor subtree, or dissolve to the lone survivor, re-pointing selection as
  /// needed). No-op unless the target is empty AND still resolves to a member: a *deleted* workroom is
  /// handled by `pruneWorkroomSplitToLiveLeaves`, and a solo (non-split) workroom keeps its empty
  /// "New Terminal" state (issue #55).
  func autoCloseEmptiedSplitMember(_ targetID: TerminalTarget.ID) {
    guard terminals.tabCount(forTargetID: targetID) == 0,
      let sid = Self.sidebarID(forTargetID: targetID, in: projects)
    else { return }
    removeWorkroomSplitMember(sid)  // guards group membership → no-op for an ungrouped workroom
  }

  /// When the *currently-viewed* workroom loses its last panel (terminal or diff), jump to the
  /// rightmost remaining workroom tab so you aren't stranded on the empty "New Terminal" state of a
  /// workroom whose chip has already left the bar (issue #80) — or, if it was the only workroom open,
  /// clear selection so the window drops to the "no workroom selected" launch state instead of sitting
  /// on the now-empty workroom (`selectFallbackWorkroom`'s no-fallback branch). No-op unless the emptied
  /// target is the selected one — a *background* workroom emptying must never steal focus, and a
  /// *delete* nils (or re-points to a split survivor) selection before its async reap fires
  /// `.tabsRemoved`, so this is a no-op there too. The split-member case is already handled by
  /// `autoCloseEmptiedSplitMember`, which
  /// runs first and moves selection to the survivor — so by here the emptied target is no longer
  /// selected and this no-ops (no double-jump). Called from the `.tabsRemoved` hook AFTER the split
  /// auto-close.
  func selectFallbackWorkroomAfterEmpty(_ targetID: TerminalTarget.ID) {
    guard terminals.tabCount(forTargetID: targetID) == 0,
      let sid = Self.sidebarID(forTargetID: targetID, in: projects),
      selectedTargetID == sid
    else { return }
    selectFallbackWorkroom()
  }

  /// Select the rightmost workroom tab *as the eye sees it* (issue #80). Uses `displayedWorkroomTargets`
  /// — the split-aware on-screen order that `cycleWorkroomTab` / `focusWorkroomTab` also index — so
  /// "rightmost" is the rightmost *chip*, not the last id in raw persisted order (which a split regroups
  /// away from). Clears selection when no other workroom tab is open (`last == nil`): the emptied
  /// workroom was the only one open, so there's nothing to land on — this drops to the "no workroom
  /// selected" launch state (and the inspector closes with it, `RootView.inspectorVisible`) instead of
  /// leaving the caller stranded on the emptied workroom's empty state. A no-op for the delete caller,
  /// whose selection is already nil by the time it calls this. Records nav history via
  /// `focusWorkroomMember` on the non-empty path, matching how the neighbour auto-focused after a close
  /// is a real back/forward step (`NavigationHistory`). Shared by the close-path hook above and
  /// `deleteWorkroom`'s last-workroom re-point.
  func selectFallbackWorkroom() {
    guard let last = displayedWorkroomTargets().last else {
      selectedTargetID = nil
      return
    }
    focusWorkroomMember(last.sid)
  }

  /// The delete-path counterpart to `selectFallbackWorkroomAfterEmpty` (issue #80): after a deleted
  /// workroom is detached from this window, land on the rightmost remaining tab — but only when the
  /// deletion was of the *selected* workroom AND the detach left selection nil. A split member yields
  /// to its survivor inside `detachTarget` (selection is non-nil), so we skip it there; deleting a
  /// non-selected workroom leaves selection untouched. Extracted from `deleteWorkroom` so this
  /// synchronous re-point is unit-testable without `deleteWorkroom`'s async CLI/VCS teardown.
  func reselectAfterWorkroomDetached(wasSelectedHere: Bool) {
    guard wasSelectedHere, selectedTargetID == nil else { return }
    selectFallbackWorkroom()
  }

  /// Set a divider ratio (driven by `WorkroomSplitView`'s divider drag). Split-node ids are unique
  /// across every group, so this addresses exactly one node wherever it lives.
  func setWorkroomSplitRatio(_ ratio: CGFloat, forSplit splitID: UUID) {
    guard let set = workroomSplitGroups.settingRatio(ratio, forSplit: splitID) else { return }
    workroomSplitGroups = set
  }

  /// How many panes `sid` shows across `axis`: its widest row of terminals side by side, or its
  /// tallest column stacked (`maxSlots`), over the group the workroom is showing. Every workroom
  /// even weights its leaves by this, so the terminals across the whole window come out the same
  /// size rather than each workroom getting an equal share, and the fit check gives that widest
  /// row room for every pane in it.
  private var workroomLeafSlots: (SidebarID, SplitOrientation) -> Int {
    { [self] sid, axis in
      target(for: sid).flatMap { terminals.split(for: $0) }?.maxSlots(along: axis) ?? 1
    }
  }

  /// `targetID` now shows a different number of panes along `axis` (nil: both ways), from a split,
  /// a close or a tab switch, so its workroom's weight changed: re-even the workroom split it sits
  /// in along that axis. No-op when auto-even is off, the workroom isn't in
  /// a workroom split, or the even wouldn't leave every terminal at its minimum size.
  func reEvenWorkroomSplit(holding targetID: TerminalTarget.ID, along axis: SplitOrientation?) {
    guard let sid = Self.sidebarID(forTargetID: targetID, in: projects) else { return }
    let evened = workroomSplitGroups.evening(groupOf: sid, along: axis, policy: workroomSplitPolicy)
    // `workroomSplitGroups` is observed: write only a real change, so a no-op even redraws nothing.
    if evened != workroomSplitGroups { workroomSplitGroups = evened }
  }

  /// How every workroom split edit evens and judges a group: when auto-even is on and the window
  /// can honour it, each workroom weighted by its terminals (`workroomLeafSlots`), with leaves whose
  /// workroom no longer resolves left out of the fit check and the joining even. Every automatic
  /// workroom even goes through here, so none can forget the weight.
  ///
  /// The prune (`live`) matters because the renderer drops dead leaves on read
  /// (`visibleWorkroomLayout`) while the stored tree still counts them, so evening or judging the raw
  /// tree budgets space for a pane nobody can see and leaves the visible ones uneven (issue #126).
  /// Shared so the admission guard cannot judge a different tree from the one the mutation writes.
  private var workroomSplitPolicy: PaneSplitPolicy<SidebarID> {
    PaneSplitPolicy(
      space: workroomPaneSpace, autoEven: autoEvenSplits(), leafSlots: workroomLeafSlots,
      live: { [self] group in liveLeavesOnly(group) })
  }

  /// `group` with every leaf whose workroom no longer resolves dropped — what the renderer shows.
  private func liveLeavesOnly(_ group: PaneLayout<SidebarID>) -> PaneLayout<SidebarID> {
    var live = group
    for leaf in group.tabIDs where target(for: leaf) == nil {
      live = live.removingLeaf(leaf) ?? live
    }
    return live
  }

  /// Drop split leaves whose workroom no longer resolves (deleted / reloaded away) from every group,
  /// collapsing or dissolving as needed. Called from `apply(_:)` after the selection is validated, so a
  /// dissolve can re-point selection to a live survivor when the old selection was nilled out.
  ///
  /// `formerSelection` is the selection as it stood BEFORE `apply` validated a dead one away — which is
  /// the only surviving evidence of *which split the user was looking at*. With several groups, a
  /// re-point has to honour that: picking the first survivor in array order lands the user in a group
  /// they were never viewing (both reviewers flagged this), and a former group that merely pruned a leaf
  /// contributes no "survivor" at all yet is exactly where the user should stay. Preference order:
  /// the former group's first live leaf, then any dissolved group's survivor.
  func pruneWorkroomSplitToLiveLeaves(formerSelection: SidebarID? = nil) {
    let policy = workroomSplitPolicy
    let formerGroup = formerSelection.flatMap { sid in
      workroomSplits.firstIndex { $0.contains(sid) }
    }
    var kept: [PaneLayout<SidebarID>] = []
    var survivors: [SidebarID] = []
    var formerGroupSurvivor: SidebarID?
    for (index, group) in workroomSplits.enumerated() {
      let live = group.tabIDs.filter { target(for: $0) != nil }
      if index == formerGroup { formerGroupSurvivor = live.first }
      guard live.count < group.tabIDs.count else {
        kept.append(group)  // nothing dead in this group
        continue
      }
      if live.count >= 2 {
        var pruned = group
        var axes: Set<SplitOrientation> = []
        for sid in group.tabIDs where target(for: sid) == nil {
          if let axis = pruned.axis(around: sid) { axes.insert(axis) }
          pruned = pruned.removingLeaf(sid) ?? pruned
        }
        // This branch has already proven the group lost a leaf, so it is a removal like any other
        // (issue #126): even the survivors rather than leave them budgeted for the workroom that
        // went away, along the axes the dead leaves left (both, when they left different ways).
        // Plain `equalized` — the tree in hand is the pruned one.
        kept.append(
          policy.evened(pruned, along: axes.count == 1 ? axes.first : nil) ?? pruned)
      } else if let survivor = live.first {
        survivors.append(survivor)
      }
    }
    guard kept != workroomSplits else { return }  // nothing dead anywhere
    workroomSplits = kept
    guard selectedTargetID == nil else { return }
    if let survivor = formerGroupSurvivor ?? survivors.first { focusWorkroomMember(survivor) }
  }
}
