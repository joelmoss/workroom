import AppKit
import WorkroomDomain

/// Where a terminal's tab dragged inside its window lands: a sidebar row or title-bar tab
/// (`target`), or the Terminals heading, which makes it a standalone terminal (#660).
enum PaneDropZone: Hashable {
  case target(SidebarID)
  case standalone
  /// Pane tab `tab` of `container`'s target: a drop lands in `container` just before it, or,
  /// `after`, just after it (#652).
  case tab(TerminalTab.ID, in: SidebarID, after: Bool)
  /// Terminal `tab`'s sidebar row under `container`'s: a drop lands just above it. A zone of its
  /// own, so its insertion mark and its pane tab's don't both show (#652).
  case terminalRow(TerminalTab.ID, in: SidebarID)
  /// The title bar's tab row on no tab: a terminal let go there becomes standalone, its tab just
  /// before `before`'s (nil: last) (#652).
  case titleBarGap(before: SidebarID?)

  /// The container a drop here joins, for the rules that judge only that.
  var container: Self {
    switch self {
    case .tab(_, let container, _), .terminalRow(_, let container): return .target(container)
    default: return self
    }
  }
}

/// Moving any terminal anywhere (#660, ADR 0077): the Terminals section's places a pane can move
/// into in this window (Standalone, New Terminal Group…), and the drag of a tab onto a sidebar row,
/// a title-bar tab or the Terminals heading. Every route ends in `PaneMove.move`.
extension AppStore {
  /// Move to → Standalone: `source`'s pane `tabID` becomes a standalone terminal of its own in this
  /// window, its row just below `target`'s when that is in the Terminals section, or, given
  /// `placedBefore` (a row let go between the section's rows, #652), just above that row (nil:
  /// at the end). Given `titleBarBefore` (a pane let go in the title bar's empty space, #652), its
  /// title-bar tab goes just before that tab (nil: last). Nothing is left behind when it can't
  /// move.
  @discardableResult
  func movePaneToStandalone(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, placedBefore: TargetID?? = .none,
    titleBarBefore: SidebarID?? = .none
  ) async -> Bool {
    if case .standalone = target.id { return false }
    guard PaneMove.sourceRefusal(tabID, of: target, source: source) == nil else { return false }
    let row = terminalsSection.addStandalone(after: target.id)
    if case .some(let anchor) = placedBefore { terminalsSection.move(row, before: anchor) }
    let moved = await movePane(
      tabID, of: target, source: source, notifications: notifications, intoNewRow: row)
    if moved, case .some(let before) = titleBarBefore { placeTitleBarTab(row, before: before) }
    return moved
  }

  /// The title bar's tabs, left to right.
  var titleBarOrder: [SidebarID] {
    Self.orderedActiveTargets(persisted: workroomTabOrder, active: terminals.activeTargetIDs)
      .compactMap(\.sidebarID)
  }

  /// Puts `id`'s title-bar tab just before `before`'s (nil: last).
  func placeTitleBarTab(_ id: TargetID, before: SidebarID?) {
    var order = Self.orderedActiveTargets(
      persisted: workroomTabOrder, active: terminals.activeTargetIDs.union([id]))
    order.removeAll { $0 == id }
    let index = before?.targetID.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
    order.insert(id, at: index)
    if order != workroomTabOrder { workroomTabOrder = order }
  }

  /// Move to → New Terminal Group…: a group named `name`, just below `target`'s row when that is in
  /// the Terminals section, with `source`'s pane `tabID` moved into it as its first terminal. A
  /// name that trims to nothing makes no group, and nothing is left behind when it can't move.
  @discardableResult
  func movePaneToNewGroup(
    named name: String, _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore
  ) async -> Bool {
    guard TerminalPanes.cleanedName(name) != nil,
      PaneMove.sourceRefusal(tabID, of: target, source: source) == nil
    else { return false }
    return await movePane(
      tabID, of: target, source: source, notifications: notifications,
      intoNewRow: terminalsSection.addGroup(named: name, after: target.id))
  }

  /// Moves the pane into `row`, a row just listed for it (below `target`'s when that is in the
  /// Terminals section: `TerminalsSection.index(after:)` sends any other anchor to the end), and
  /// drops the row again when the pane can't move.
  private func movePane(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, intoNewRow row: TargetID
  ) async -> Bool {
    let moved = await PaneMove.move(
      tabID, of: target, source: source, notifications: notifications, to: self, into: row)
    if !moved { terminalsSection.remove(row) }
    return moved
  }

  /// Why this window's tab `tabID` in `target` (or, given `source`, the Quick Terminal panel's)
  /// can't move at all, or nil when it can: only a terminal moves, and a workroom's run tab stays
  /// its run's, beside `PaneMove.sourceRefusal`'s reasons.
  func paneMoveRefusal(
    ofTab tabID: TerminalTab.ID, in target: TerminalTarget, source: PaneDropSource? = nil
  ) -> String? {
    let panes = source?.terminals ?? terminals
    guard case .terminal = panes.tab(tabID, for: target)?.content else {
      return "Only a terminal moves."
    }
    if source == nil, runTabID(for: target.id) == tabID {
      return "A run command's terminal stays in its workroom."
    }
    return PaneMove.sourceRefusal(tabID, of: target, source: panes)
  }

  /// Standalone terminal `sid`'s terminal and the window holding it: this one, or the one another
  /// window's row menu acts on. Nil while no window holds it.
  func standaloneTerminal(_ sid: SidebarID) -> (
    holder: AppStore, target: TerminalTarget, tab: TerminalTab
  )? {
    guard case .standalone = sid, let id = sid.targetID else { return nil }
    let holder =
      holdsTerminals(forTargetID: id)
      ? self : terminalsSection.holder(of: id, other: self) as? AppStore
    guard let holder, let target = holder.target(for: sid),
      let tab = holder.terminals.allTabs(for: target).first
    else { return nil }
    return (holder, target, tab)
  }

  // MARK: Dropping a tab

  /// Whether this window's tab `tabID` in `target`, let go over `zone`, moves there; given
  /// `source`, a tab of the Quick Terminal's panel, whose row the window lists (#652).
  func canDropPane(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, on zone: PaneDropZone,
    source: PaneDropSource? = nil
  ) -> Bool {
    guard paneMoveRefusal(ofTab: tabID, in: target, source: source) == nil else { return false }
    switch zone {
    case .tab, .terminalRow:
      return canDropPane(tabID, of: target, on: zone.container, source: source)
    case .titleBarGap:
      return canDropPane(tabID, of: target, on: .standalone, source: source)
    case .standalone:
      if case .standalone = target.id { return false }
      return true
    case .target(let sid):
      guard sid.targetID != target.id else { return false }
      if sid.targetID == .quickTerminal { return quickTerminalPanel != nil }
      return paneMoveTarget(sid) != nil || canGroup(onto: sid)
    }
  }

  /// The Quick Terminal's panel, the built-in group's one holder, once it is made. A tab dropped on
  /// the group's row moves into it, never into this window (stories 29, 37).
  var quickTerminalPanel: QuickTerminalHost? {
    if let panel = terminalsSection.quickTerminalHolder as? QuickTerminalHost { return panel }
    // Not made yet (never summoned this launch): the app's controller makes it on the drop.
    guard let controller = WindowRegistry.shared.quickTerminal,
      controller.section === terminalsSection
    else { return nil }
    return controller.ensureHost()
  }

  /// Whether a terminal dropped on standalone terminal `sid`, which has its one terminal, makes an
  /// unnamed group of the two (#659): only the one-terminal rule turns it away as a destination.
  private func canGroup(onto sid: SidebarID) -> Bool {
    guard case .standalone = sid, let target = target(for: sid),
      !terminalsSection.terminalNames(of: target.id).isEmpty
    else { return false }
    return terminalJoinRefusal(target) == nil
  }

  /// Moves this window's tab `tabID` in `target` (or `source`'s) to `zone`, when it can go there.
  @discardableResult
  func dropPane(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, on zone: PaneDropZone,
    source: PaneDropSource? = nil
  ) async -> Bool {
    guard canDropPane(tabID, of: target, on: zone, source: source) else { return false }
    let from = source ?? PaneDropSource(terminals: terminals, notifications: notifications)
    switch zone {
    case .tab, .terminalRow:
      return await dropPane(tabID, of: target, on: zone.container, source: source)
    case .standalone:
      return await movePaneToStandalone(
        tabID, of: target, source: from.terminals, notifications: from.notifications)
    case .titleBarGap(let before):
      return await movePaneToStandalone(
        tabID, of: target, source: from.terminals, notifications: from.notifications,
        titleBarBefore: .some(before))
    case .target(let sid):
      guard let into = sid.targetID else { return false }
      if into == .quickTerminal, let panel = quickTerminalPanel {
        return await PaneMove.move(
          tabID, of: target, source: from.terminals, notifications: from.notifications, to: panel,
          into: into)
      }
      if paneMoveTarget(sid) == nil {
        return await groupPane(tabID, of: target, from: from, onto: into)
      }
      return await PaneMove.move(
        tabID, of: target, source: from.terminals, notifications: from.notifications, to: self,
        into: into)
    }
  }

  /// This window's tab `tabID` in `target`, dropped on standalone terminal `destination`: once the
  /// user names it (`TerminalGroupNaming`; Cancel drops nothing), a group of the two in
  /// `destination`'s place, its terminal first (#659). A standalone
  /// terminal's own tab groups as dropping its row does; any other is moved into `destination`
  /// once that is a group, which goes back to the standalone terminal it was when the tab can't
  /// follow. Queued with the section's other regroups.
  private func groupPane(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, from source: PaneDropSource,
    onto destination: TargetID
  ) async -> Bool {
    guard let name = await TerminalGroupNaming.ask() else { return false }
    let section = terminalsSection
    if case .standalone = target.id, section.contains(target.id) {
      return await section.enqueueRegroup {
        await section.groupStandalone(target.id, onto: destination, named: name) != nil
      }.value
    }
    return await section.enqueueRegroup { [weak self] in
      guard case .standalone(let standalone) = destination,
        let group = await section.convertToGroup(destination, named: name)
      else { return false }
      guard let self else { return false }
      let moved = await PaneMove.move(
        tabID, of: target, source: source.terminals, notifications: source.notifications,
        to: self, into: group)
      if !moved {
        _ = await section.rehome([(group, destination)]) {
          guard section.contains(group) else { return false }
          section.replace(group, with: .standalone(standalone))
          return true
        }
      }
      return moved
    }.value
  }
}

// MARK: Dragging a tab over its window

extension AppStore {
  /// This window's tab `tabID` in `target` is dragged to `screenPoint` (nil: the drag left the
  /// window). Highlights the destination it would drop on (`terminalDrag`), shows "not allowed"
  /// over a sidebar row or title-bar tab that refuses it, and says whether it is over either, so
  /// the tab strip stops previewing its own drop. A pane tab that refuses it is passed through, so
  /// the strip's own reorder and split go on.
  @discardableResult
  func paneDragMoved(_ tabID: TerminalTab.ID, of target: TerminalTarget, to screenPoint: CGPoint?)
    -> Bool
  {
    guard let screenPoint, let owner = target.id.sidebarID else {
      terminalDrag.cancel()
      showPaneDragRefusing(false)
      return false
    }
    let accepts = terminalDrag.moved(.terminal(tabID, of: owner), from: .paneTabs, to: screenPoint)
    let refusing = !accepts && refusesPaneDrag(at: screenPoint)
    showPaneDragRefusing(refusing)
    return accepts || refusing
  }

  /// This window's tab `tabID` in `target` is let go at `screenPoint`: over a destination that
  /// takes it, it drops there; over a sidebar row or title-bar tab that refuses it, nothing
  /// happens. Whether either, so the strip makes no drop of its own.
  func paneDragEnded(_ tabID: TerminalTab.ID, of target: TerminalTarget, at screenPoint: CGPoint)
    -> Bool
  {
    if let owner = target.id.sidebarID, terminalDrag.source != .terminal(tabID, of: owner) {
      terminalDrag.moved(.terminal(tabID, of: owner), from: .paneTabs, to: screenPoint)
    }
    let refusing = refusesPaneDrag(at: screenPoint)
    showPaneDragRefusing(false)
    return terminalDrag.ended(at: screenPoint) || refusing
  }

  /// Whether `screenPoint` is over a sidebar row, the Terminals heading or a title-bar tab that the
  /// dragged tab can't drop on.
  private func refusesPaneDrag(at screenPoint: CGPoint) -> Bool {
    terminalDrag.refuses(at: screenPoint)
  }

  private func showPaneDragRefusing(_ refusing: Bool) {
    if refusing {
      NSCursor.operationNotAllowed.set()
    } else if paneDragRefusing {
      NSCursor.arrow.set()
    }
    paneDragRefusing = refusing
  }
}

// MARK: Dropping a terminal's row on another row

/// Whose panes a dropped tab is in, when they aren't the window's own: the Quick Terminal panel's,
/// whose terminals the window lists under the Quick Terminal's row.
struct PaneDropSource {
  let terminals: TerminalPanes
  let notifications: NotificationCenterStore
}

/// A terminal's row in the Terminals section being dragged: a standalone terminal's, or one of a
/// group's terminals under `group`'s row (the Quick Terminal's are its panel's).
enum SidebarRowDragItem: Hashable {
  case standalone(SidebarID)
  case terminal(TerminalTab.ID, group: SidebarID)
}

/// Any terminal's sidebar row dragged onto another row of the Terminals section (#659, #652): onto
/// a standalone terminal's, the two become an unnamed group; onto a group's row or one of its
/// terminals' rows, it joins that group, the Quick Terminal's among them. The List's own drag still
/// reorders the section: a row let go over another row's middle drops on it, and one let go nearer
/// either edge goes between them (`SidebarTerminalsList.terminalMove`). The drop zones are the tab
/// drag's (#660), so the row taking it is highlighted the same way, and every drop but standalone
/// onto standalone is the tab drop's, the move Move to… makes.
extension AppStore {
  /// The part of a row, on screen, where a row let go drops on it, not beside it: the middle half of
  /// its height. A folded group's row takes its lower quarter too, so all of it below its top
  /// quarter: no terminals' rows are listed under it to take that edge's drops, and between it and
  /// the next row, the List's gap there, a terminal would only reorder. Its top quarter still
  /// reorders above it.
  nonisolated static func groupBand(of row: CGRect, folded: Bool = false) -> CGRect {
    let quarter = row.height / 4
    guard folded else { return row.insetBy(dx: 0, dy: quarter) }
    // Screen coordinates: y grows up, so the row's top quarter is its highest.
    return CGRect(x: row.minX, y: row.minY, width: row.width, height: row.height - quarter)
  }

  /// Whether `dragged`'s row, let go on row `destination` of the Terminals section, drops there.
  func canDropRow(_ dragged: SidebarRowDragItem, onto destination: SidebarID) -> Bool {
    guard destination.isInTerminalsSection else { return false }
    switch dragged {
    case .standalone(let sid):
      if case .standalone = destination {
        guard sid != destination, let from = sid.targetID, let onto = destination.targetID
        else { return false }
        return terminalsSection.contains(from) && terminalsSection.contains(onto)
      }
      guard let (holder, target, tab) = standaloneTerminal(sid) else { return false }
      return holder.canDropPane(tab.id, of: target, on: .target(destination))
    case .terminal(let tabID, let group):
      guard let (target, source) = groupTerminal(in: group) else { return false }
      return canDropPane(tabID, of: target, on: .target(destination), source: source)
    }
  }

  /// Drops `dragged`'s row on `destination`'s, when it can: a standalone terminal onto another
  /// groups the two (`dropStandalone`); any other drop is the tab's (`dropPane`).
  @discardableResult
  func dropRow(_ dragged: SidebarRowDragItem, onto destination: SidebarID) async -> Bool {
    guard canDropRow(dragged, onto: destination) else { return false }
    switch dragged {
    case .standalone(let sid):
      if case .standalone = destination { return await dropStandalone(sid, onto: destination) }
      guard let (holder, target, tab) = standaloneTerminal(sid) else { return false }
      return await holder.dropPane(tab.id, of: target, on: .target(destination))
    case .terminal(let tabID, let group):
      guard let (target, source) = groupTerminal(in: group) else { return false }
      return await dropPane(tabID, of: target, on: .target(destination), source: source)
    }
  }

  /// `dragged`'s row let go just above group `group`'s terminal `tab`'s row, between two of the
  /// group's terminals or above its first (#652): it joins the group there, taking that place in
  /// its tabs' order, the title bar's and the strip's. One of the group's own terminals moves there.
  @discardableResult
  func dropRow(
    _ dragged: SidebarRowDragItem, into group: SidebarID, before tab: TerminalTab.ID
  ) async -> Bool {
    let (id, holder): (TerminalTab.ID, AppStore)
    switch dragged {
    case .terminal(let tabID, let from) where from == group:
      guard let (target, source) = groupTerminal(in: group),
        paneMoveRefusal(ofTab: tabID, in: target, source: source) == nil
      else { return false }
      (source?.terminals ?? terminals).moveTab(tabID, before: tab, for: target)
      if source == nil { markSessionDirty() } else { SavedLayoutCoordinator.shared.markDirty() }
      return true
    case .terminal(let tabID, _):
      (id, holder) = (tabID, self)
    case .standalone(let sid):
      guard let held = standaloneTerminal(sid) else { return false }
      (id, holder) = (held.tab.id, held.holder)
    }
    guard await dropRow(dragged, onto: group) else { return false }
    // Where it now is: the Quick Terminal's panel, or the window that took it into the group.
    if group.targetID == .quickTerminal, let panel = quickTerminalPanel {
      panel.terminals.moveTab(id, before: tab, for: panel.target)
      SavedLayoutCoordinator.shared.markDirty()
    } else if let target = holder.target(for: group) {
      holder.terminals.moveTab(id, before: tab, for: target)
      holder.markSessionDirty()
    }
    return true
  }

  /// A group's terminal row `dragged`, let go between the section's rows, becomes a standalone
  /// terminal just above row `before` (nil: at the end), as Move to → Standalone Terminal makes it.
  @discardableResult
  func dropRowAsStandalone(_ dragged: SidebarRowDragItem, before: TargetID?) async -> Bool {
    guard case .terminal(let tabID, let group) = dragged,
      let (target, source) = groupTerminal(in: group),
      paneMoveRefusal(ofTab: tabID, in: target, source: source) == nil
    else { return false }
    let from = source ?? PaneDropSource(terminals: terminals, notifications: notifications)
    return await movePaneToStandalone(
      tabID, of: target, source: from.terminals, notifications: from.notifications,
      placedBefore: .some(before))
  }

  /// Group `group`'s target, and whose panes its terminals' rows are when not this window's: the
  /// Quick Terminal's panel's.
  func groupTerminal(in group: SidebarID) -> (TerminalTarget, PaneDropSource?)? {
    if group.targetID == .quickTerminal {
      guard let panel = terminalsSection.quickTerminalHolder as? QuickTerminalHost else {
        return nil
      }
      return (
        panel.target,
        PaneDropSource(terminals: panel.terminals, notifications: panel.notifications)
      )
    }
    guard case .terminalGroup = group, let target = target(for: group) else { return nil }
    return (target, nil)
  }
}
