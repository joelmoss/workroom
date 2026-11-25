import Foundation
import WorkroomDomain

/// The sidebar's Open section (#819): this window's workroom tabs, each unfolding to its tabs. The
/// section keeps no list of its own. Its rows are read from what the title bar reads
/// (`displayedWorkroomTargets()`) and what each target's tab strip reads (`terminals.tabs(for:)`),
/// with each chip's own presentation (`workroomTabPresentation`, `workroomTabMarks`,
/// `RunCommandController.runState(ofTab:in:)`), so the section, the title bar and the strip cannot
/// disagree. Fold state is the one thing it adds.
extension AppStore {

  /// The Open section's rows, in title-bar order, each holding its tabs in strip order.
  func openSectionRows() -> [OpenSectionRow] {
    let visibleSplit = resolvedSplitLeaves().map { Set($0.map(\.sid)) } ?? []
    return displayedWorkroomTargets().map { sid, target in
      let isSelected = sid == selectedTargetID
      return OpenSectionRow(
        sid: sid, target: target,
        presentation: workroomTabPresentation(sid: sid, target: target),
        marks: workroomTabMarks(sid: sid, target: target),
        isSelected: isSelected,
        isVisibleInSplit: !isSelected && visibleSplit.contains(sid),
        isFolded: isOpenRowFolded(sid),
        tabs: openSectionTabRows(sid: sid, target: target, isSelected: isSelected))
    }
  }

  /// `target`'s tabs as its strip shows them, or none where it shows no strip.
  private func openSectionTabRows(
    sid: SidebarID, target: TerminalTarget, isSelected: Bool
  ) -> [OpenSectionTabRow] {
    let tabs = terminals.tabs(for: target)
    guard TerminalPanes.showsTabStrip(tabCount: tabs.count, for: target.id) else { return [] }
    let activeID = terminals.activeTab(for: target)?.id
    // The tabs on screen in this target's panes, when the target itself is on screen.
    let shown: Set<TerminalTab.ID> =
      onScreenTarget(forID: target.id) == nil
      ? [] : Set(terminals.split(for: target)?.tabIDs ?? activeID.map { [$0] } ?? [])
    return tabs.map { tab in
      let isActive = tab.id == activeID
      let isFocused = isActive && isSelected
      return OpenSectionTabRow(
        sid: sid, target: target, tab: tab,
        hasUnread: notifications.count(tab: tab.id) > 0,
        runState: runCommand.runState(ofTab: tab.id, in: target.id),
        hasDiagnosis: terminals.codingAgentManager.banners[tab.id] != nil,
        isActive: isActive, isFocused: isFocused,
        isVisibleInSplit: !isFocused && shown.contains(tab.id))
    }
  }

  // MARK: Fold state

  /// Whether `sid`'s row hides its tabs. Selecting a target unfolds its row, and it stays
  /// unfolded unless folded by hand until it is next selected; any other row is folded until it is
  /// unfolded by hand.
  func isOpenRowFolded(_ sid: SidebarID) -> Bool {
    guard let id = sid.targetID else { return false }
    if sid == selectedTargetID { return foldedSelectedOpenTarget == id }
    return !unfoldedOpenTargets.contains(id)
  }

  /// Fold or unfold `sid`'s row by hand. The selected row folds too, until it is next selected.
  func setOpenRow(_ sid: SidebarID, folded: Bool) {
    guard let id = sid.targetID else { return }
    if sid == selectedTargetID { foldedSelectedOpenTarget = folded ? id : nil }
    if folded { unfoldedOpenTargets.remove(id) } else { unfoldedOpenTargets.insert(id) }
  }

  /// The row's disclosure chevron.
  func toggleOpenRowFold(_ sid: SidebarID) {
    setOpenRow(sid, folded: !isOpenRowFolded(sid))
  }

  // MARK: Actions

  /// Select a workroom tab, as its title-bar chip or Open row does: the target and the project
  /// context together. Selecting the current one is a no-op, not a republish.
  func selectWorkroomTab(_ sid: SidebarID) {
    guard selectedTargetID != sid else { return }
    selectedTargetID = sid
    selectedProjectID = Self.projectPath(of: sid)
  }

  /// Select tab `tabID` and its workroom, as a sidebar terminal row does.
  func selectOpenTab(_ tabID: TerminalTab.ID, in sid: SidebarID) {
    revealTerminal(tabID, at: sid)
  }

  /// Keep a preview tab, as a second click on its strip chip does.
  func promoteOpenTab(_ tabID: TerminalTab.ID, in sid: SidebarID) {
    guard let target = target(for: sid) else { return }
    terminals.persist(tabID, for: target)
  }

  /// Move workroom tab `sid` to `index` among the displayed tabs, as a title-bar reorder does.
  /// Returns whether it moved.
  @discardableResult
  func moveWorkroomTab(_ sid: SidebarID, toIndex index: Int) -> Bool {
    var sids = displayedWorkroomTargets().map(\.sid)
    guard let from = sids.firstIndex(of: sid), sids.indices.contains(index), index != from
    else { return false }
    sids.insert(sids.remove(at: from), at: index)
    workroomTabOrder = sids.compactMap(\.targetID)
    return true
  }

  /// Move tab `tabID` to `index` in `sid`'s strip, as a strip reorder does.
  func moveOpenTab(_ tabID: TerminalTab.ID, toIndex index: Int, in sid: SidebarID) {
    guard let target = target(for: sid) else { return }
    terminals.moveTab(tabID, toIndex: index, for: target)
  }
}

/// A workroom tab's row in the Open section: what its title-bar chip shows, and its tabs.
struct OpenSectionRow: Identifiable {
  let sid: SidebarID
  let target: TerminalTarget
  let presentation: WorkroomTabPresentation
  let marks: WorkroomTabMarks
  /// The window's selected target, as the title bar's selected chip.
  let isSelected: Bool
  /// On screen beside the selection, in the visible workroom split.
  let isVisibleInSplit: Bool
  let isFolded: Bool
  /// The tabs its strip shows, in strip order. Empty for a standalone terminal's one terminal,
  /// which shows no strip: the row itself is that terminal.
  let tabs: [OpenSectionTabRow]

  var id: SidebarID { sid }
  /// Whether the disclosure chevron can fold it: not with nothing in it.
  var canFold: Bool { !tabs.isEmpty }
}

/// One tab's row under its workroom: what its strip chip shows.
struct OpenSectionTabRow: Identifiable {
  let sid: SidebarID
  let target: TerminalTarget
  /// The tab's record. Its title is read through `TabTitleReader` from `tab.content`, as the
  /// strip's chip reads it, since a terminal's changes many times a second.
  let tab: TerminalTab
  let hasUnread: Bool
  /// Only the run tab has one.
  let runState: TabRunState?
  /// A coding-agent diagnosis is available (the ✦ badge).
  let hasDiagnosis: Bool
  /// The strip's active tab for its target.
  let isActive: Bool
  /// The active tab of the selected target: the one with focus.
  let isFocused: Bool
  /// On screen in another pane of a split, not focused.
  let isVisibleInSplit: Bool

  var id: TerminalTab.ID { tab.id }
  var title: String { tab.title }
}
