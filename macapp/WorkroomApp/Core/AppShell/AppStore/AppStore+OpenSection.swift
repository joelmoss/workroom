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
      let tabs = openSectionTabRows(sid: sid, target: target, isSelected: isSelected)
      return OpenSectionRow(
        model: OpenSectionWorkroomRowModel(
          sid: sid, target: target,
          presentation: workroomTabPresentation(sid: sid, target: target),
          marks: workroomTabMarks(sid: sid, target: target),
          isSelected: isSelected,
          isVisibleInSplit: !isSelected && visibleSplit.contains(sid),
          isFolded: isOpenRowFolded(sid), tabCount: tabs.count),
        tabs: tabs)
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
      let isFocused = tab.id == activeID && isSelected
      let title: SidebarTerminalRowModel.TitleSource =
        if case .terminal(let state) = tab.content {
          .live(
            ObjectIdentifier(state.titleCell), userTitle: state.userTitle,
            defaultName: state.defaultName)
        } else {
          .fixed(tab.title)
        }
      return OpenSectionTabRow(
        model: OpenSectionTabRowModel(
          sid: sid, target: target, tabID: tab.id, title: title,
          glyph: tab.content.glyph ?? "terminal", tool: tab.recognizedTool,
          isPreview: tab.isPreview, indicator: tab.indicator, programStatus: tab.programStatus,
          hasUnread: notifications.count(tab: tab.id) > 0,
          runState: runCommand.runState(ofTab: tab.id, in: target.id),
          hasDiagnosis: terminals.codingAgentManager.banners[tab.id] != nil,
          isFocused: isFocused, isVisibleInSplit: !isFocused && shown.contains(tab.id)),
        tab: tab)
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

  /// A terminal group's Open row's Expand or Collapse, as its old Terminals row offered: nil for
  /// any other row, or one with no tabs to fold.
  func openRowFoldItem(_ sid: SidebarID) -> SidebarFoldItem? {
    guard case .terminalGroup = sid, let target = target(for: sid),
      TerminalPanes.showsTabStrip(tabCount: terminals.tabs(for: target).count, for: target.id)
    else { return nil }
    return SidebarFoldItem(expanded: !isOpenRowFolded(sid))
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

  /// Whether tab `tabID`'s row under `sid`'s can be let go between the workroom tabs' rows, where
  /// it becomes a standalone terminal, as Move to → Standalone Terminal makes it.
  func canMoveOpenTabToStandalone(_ tabID: TerminalTab.ID, in sid: SidebarID) -> Bool {
    !sid.isStandaloneTerminal && canDropTerminals(.terminal(tabID, of: sid), on: .standalone)
  }

  /// Tab `tabID`'s row under `sid`'s let go between workroom tabs `after` and `before` (nil: at
  /// the start, at the end): a standalone terminal there, still running, its tab in that place in
  /// the title bar's order, which the section's is. When the move takes `before` away (the tab's
  /// own group, emptied or dissolved), it goes just after `after`.
  @discardableResult
  func moveOpenTabToStandalone(
    _ tabID: TerminalTab.ID, in sid: SidebarID, after: SidebarID?, before: SidebarID?
  ) async -> Bool {
    guard canMoveOpenTabToStandalone(tabID, in: sid), let (target, source) = terminalHome(of: sid)
    else { return false }
    let from = source ?? PaneDropSource(terminals: terminals, notifications: notifications)
    return await movePaneToStandalone(
      tabID, of: target, source: from.terminals, notifications: from.notifications,
      titleBarBefore: .some(before), titleBarAfter: .some(after))
  }
}

/// A workroom tab's row in the Open section: what its title-bar chip shows, and its tabs.
struct OpenSectionRow: Identifiable {
  /// What its own row draws, which that row's equality gate compares whole.
  let model: OpenSectionWorkroomRowModel
  /// The tabs its strip shows, in strip order. Empty for a standalone terminal's one terminal,
  /// which shows no strip: the row itself is that terminal.
  let tabs: [OpenSectionTabRow]

  var id: SidebarID { sid }
  var sid: SidebarID { model.sid }
  var target: TerminalTarget { model.target }
  var isSelected: Bool { model.isSelected }
  var isVisibleInSplit: Bool { model.isVisibleInSplit }
  var isFolded: Bool { model.isFolded }
  var canFold: Bool { model.canFold }
}

/// What a workroom tab's Open row draws: its chip's presentation and marks, its place in the window
/// and how many tabs it folds, never the tabs themselves, whose rows are their own.
struct OpenSectionWorkroomRowModel: Equatable {
  let sid: SidebarID
  let target: TerminalTarget
  let presentation: WorkroomTabPresentation
  let marks: WorkroomTabMarks
  /// The window's selected target, as the title bar's selected chip.
  let isSelected: Bool
  /// On screen beside the selection, in the visible workroom split.
  let isVisibleInSplit: Bool
  let isFolded: Bool
  /// How many tab rows it has under it.
  let tabCount: Int

  /// Whether the disclosure chevron can fold it: not with nothing in it.
  var canFold: Bool { tabCount > 0 }
}

/// One tab's row under its workroom: what its strip chip shows.
struct OpenSectionTabRow: Identifiable {
  /// What the row draws, which its equality gate compares whole.
  let model: OpenSectionTabRowModel
  /// The tab's record, outside the model: its title is read through `TabTitleReader` from
  /// `tab.content`, as the strip's chip reads it, since a terminal's changes many times a second.
  let tab: TerminalTab

  var id: TerminalTab.ID { model.tabID }
  var sid: SidebarID { model.sid }
  var target: TerminalTarget { model.target }
  var isFocused: Bool { model.isFocused }
  var isVisibleInSplit: Bool { model.isVisibleInSplit }
}

/// What a tab's Open row draws of it and of the window, comparable without reading its live title.
struct OpenSectionTabRowModel: Equatable {
  let sid: SidebarID
  let target: TerminalTarget
  let tabID: TerminalTab.ID
  /// Where its title is read from (`SidebarTerminalRowModel.TitleSource`).
  let title: SidebarTerminalRowModel.TitleSource
  /// Its content's glyph, or a terminal's.
  let glyph: String
  /// The program its chip shows the logo of (#141).
  let tool: RecognizedTool?
  let isPreview: Bool
  let indicator: PaneIndicator
  let programStatus: ProgramStatusRollup?
  let hasUnread: Bool
  /// Only the run tab has one.
  let runState: TabRunState?
  /// A coding-agent diagnosis is available (the ✦ badge).
  let hasDiagnosis: Bool
  /// The active tab of the selected target: the one with focus.
  let isFocused: Bool
  /// On screen in another pane of a split, not focused.
  let isVisibleInSplit: Bool
}
