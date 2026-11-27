import Foundation
import WorkroomDomain

/// The sidebar's Open Tabs view (#819): this window's workroom tabs, each unfolding to its tabs. The
/// section keeps no list of its own. Its rows are read from what the title bar reads
/// (`displayedWorkroomTargets()`) and what each target's tab strip reads (`terminals.tabs(for:)`),
/// with each chip's own presentation (`workroomTabPresentation`, `workroomTabMarks`,
/// `RunCommandController.runState(ofTab:in:)`), so the section, the title bar and the strip cannot
/// disagree. Fold state is the one thing it adds.
extension AppStore {

  /// The Open Tabs view's rows, in title-bar order, each holding its tabs in strip order. A folded
  /// row holds only `showing`, when it is one of its tabs: its placeholder while a drag lifts it,
  /// which the list passes in. Its other tabs draw nothing, so their rows (unread counts, run
  /// state, diagnoses) are not built.
  func openTabsRows(showing: OpenTabsItem? = nil) -> [OpenTabsRow] {
    displayedWorkroomTargets().map { openTabsRow($0.sid, $0.target, showing: showing) }
  }

  /// `sid`'s row. `unfolded`: every tab is built whatever its fold, as a grouping that shows no
  /// row of its own for it needs (Project, None: `openTabsLayout`).
  func openTabsRow(
    _ sid: SidebarID, _ target: TerminalTarget, showing: OpenTabsItem?, unfolded: Bool = false
  ) -> OpenTabsRow {
    let isSelected = sid == selectedTargetID
    let isFolded = isOpenRowFolded(sid)
    let tabs = terminals.tabs(for: target)
    let stripTabs =
      TerminalPanes.showsTabStrip(tabCount: tabs.count, for: target.id) ? tabs : []
    let built =
      isFolded && !unfolded
      ? stripTabs.filter { showing == .tab($0.id, in: sid) } : stripTabs
    return OpenTabsRow(
      model: OpenTabsWorkroomRowModel(
        sid: sid, target: target,
        presentation: workroomTabPresentation(sid: sid, target: target),
        marks: workroomTabMarks(sid: sid, target: target),
        isSelected: isSelected, isFolded: isFolded, tabCount: stripTabs.count),
      tabs: openTabsTabRows(built, sid: sid, target: target, isSelected: isSelected))
  }

  /// The rows of `tabs`, `target`'s tabs as its strip shows them.
  private func openTabsTabRows(
    _ tabs: [TerminalTab], sid: SidebarID, target: TerminalTarget, isSelected: Bool
  ) -> [OpenTabsTabRow] {
    guard !tabs.isEmpty else { return [] }
    let activeID = terminals.activeTab(for: target)?.id
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
      return OpenTabsTabRow(
        model: OpenTabsTabRowModel(
          sid: sid, target: target, tabID: tab.id, title: title,
          glyph: tab.content.glyph ?? "terminal", tool: tab.recognizedTool,
          isPreview: tab.isPreview, indicator: tab.indicator, programStatus: tab.programStatus,
          hasUnread: notifications.count(tab: tab.id) > 0,
          runState: runCommand.runState(ofTab: tab.id, in: target.id),
          hasDiagnosis: terminals.codingAgentManager.banners[tab.id] != nil,
          isFocused: isFocused, isPoppedOut: terminals.detachedTabIDs.contains(tab.id)),
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
    focusWorkroomMember(sid)
  }

  /// An Open row's "+": a new terminal in its group, root or workroom, selected as ⌘T's would be,
  /// with ⌘T's guards. A standalone terminal is one terminal, so its row has no "+".
  func newTerminalInOpenRow(_ sid: SidebarID) {
    switch sid {
    case .terminalGroup: newTerminalInGroup(sid)
    case .standalone: return
    default:
      selectWorkroomTab(sid)
      newTerminalInSelectedTarget()
    }
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

  /// Move workroom tabs `sids` together, in their title-bar order, to `place` in the title bar, as
  /// a grouped Open list's reorder does (`OpenRowReflow.titleBarMove`). Returns whether the order
  /// changed.
  @discardableResult
  func moveWorkroomTabs(_ sids: [SidebarID], to place: OpenRowReflow.TitleBarPlace) -> Bool {
    let current = displayedWorkroomTargets().map(\.sid)
    let moving = current.filter(Set(sids).contains)
    guard !moving.isEmpty else { return false }
    var rest = current.filter { !moving.contains($0) }
    let at: Int
    switch place {
    case .before(let sid):
      guard let index = rest.firstIndex(of: sid) else { return false }
      at = index
    case .after(let sid):
      guard let index = rest.firstIndex(of: sid) else { return false }
      at = index + 1
    case .end:
      at = rest.count
    }
    rest.insert(contentsOf: moving, at: at)
    guard rest != current else { return false }
    workroomTabOrder = rest.compactMap(\.targetID)
    return true
  }

  /// Move tab `tabID` to `index` in `sid`'s strip, as a strip reorder does.
  func moveOpenTab(_ tabID: TerminalTab.ID, toIndex index: Int, in sid: SidebarID) {
    guard let target = target(for: sid) else { return }
    terminals.moveTab(tabID, toIndex: index, for: target)
  }

  /// Tab `tabID`'s row under `sid`'s let go among workroom `into`'s tab rows: it joins `into`,
  /// just before its tab `before` (nil: after its last), as a drop on that tab's row does. Whether
  /// it moved.
  @discardableResult
  func moveOpenTab(
    _ tabID: TerminalTab.ID, of sid: SidebarID, into: SidebarID, before: TerminalTab.ID?
  ) async -> Bool {
    let zone: PaneDropZone = before.map { .terminalRow($0, in: into) } ?? .target(into)
    return await dropTerminals(.terminal(tabID, of: sid), on: zone)
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

/// A workroom tab's row in the Open Tabs view: what its title-bar chip shows, and its tabs.
struct OpenTabsRow: Identifiable {
  /// What its own row draws, which that row's equality gate compares whole.
  let model: OpenTabsWorkroomRowModel
  /// The tabs its strip shows, in strip order. Empty for a standalone terminal's one terminal,
  /// which shows no strip: the row itself is that terminal. Folded, only a lifted tab's
  /// (`AppStore.openTabsRows(showing:)`); `model.tabCount` counts them all.
  let tabs: [OpenTabsTabRow]

  var id: SidebarID { sid }
  var sid: SidebarID { model.sid }
  var target: TerminalTarget { model.target }
  var isSelected: Bool { model.isSelected }
  var isFolded: Bool { model.isFolded }
  var canFold: Bool { model.canFold }
}

/// What a workroom tab's Open row draws: its chip's presentation and marks, its place in the window
/// and how many tabs it folds, never the tabs themselves, whose rows are their own.
struct OpenTabsWorkroomRowModel: Equatable {
  let sid: SidebarID
  let target: TerminalTarget
  let presentation: WorkroomTabPresentation
  let marks: WorkroomTabMarks
  /// The window's selected target, as the title bar's selected chip.
  let isSelected: Bool
  let isFolded: Bool
  /// How many tab rows it has under it.
  let tabCount: Int

  /// Whether the disclosure chevron can fold it: not with nothing in it.
  var canFold: Bool { tabCount > 0 }
}

/// One tab's row under its workroom: what its strip chip shows.
struct OpenTabsTabRow: Identifiable {
  /// What the row draws, which its equality gate compares whole.
  let model: OpenTabsTabRowModel
  /// The tab's record, outside the model: its title is read through `TabTitleReader` from
  /// `tab.content`, as the strip's chip reads it, since a terminal's changes many times a second.
  let tab: TerminalTab

  var id: TerminalTab.ID { model.tabID }
  var sid: SidebarID { model.sid }
  var target: TerminalTarget { model.target }
  var isFocused: Bool { model.isFocused }
}

/// What a tab's Open row draws of it and of the window, comparable without reading its live title.
struct OpenTabsTabRowModel: Equatable {
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
  /// Popped out into a window of its own (issue #172): its slot shows a placeholder.
  var isPoppedOut = false
  /// Where it lives, shown after its title when no workroom row above says so: the Project and
  /// None groupings (`OpenTabsGrouping`).
  var context: OpenTabsTabContext?
}

/// A tab row's workroom, said after its title in a grouping with no workroom rows: the workroom's
/// name in Project, with its project's in None, or its terminal group's name.
struct OpenTabsTabContext: Equatable {
  enum Name: Equatable {
    case text(String)
    /// A project root's, which is the branch its root is on, as the Projects view's root row
    /// names it (`SidebarRootLabel`).
    case root(projectPath: String)
  }

  /// The project's name, before the workroom's: in None only.
  let project: String?
  let name: Name

  /// It in words, for a tooltip or VoiceOver: a root's branch isn't read here, so it is "root".
  var spoken: String {
    let name =
      switch name {
      case .text(let text): text
      case .root: "root"
      }
    return project.map { "\($0) / \(name)" } ?? name
  }
}
