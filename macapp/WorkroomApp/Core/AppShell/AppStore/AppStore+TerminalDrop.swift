import AppKit
import WorkroomDomain

/// Anything dragged that is terminals (#652): a terminal's own handle (a pane tab, or a terminal's
/// row under a group, the Quick Terminal or a workroom), or a standalone terminal's or group's
/// whole handle (its sidebar row, title-bar tab, or a group's title bar in a split), which means
/// all of its terminals, in order. A workroom's row or tab is never one: workrooms don't merge.
enum TerminalDragSource: Hashable {
  /// Tab `tab` of `owner`'s target: a workroom, root, standalone terminal or group.
  case terminal(TerminalTab.ID, of: SidebarID)
  /// A standalone terminal's or a group's row, title-bar tab or title bar.
  case entry(SidebarID)
}

/// What a terminal drag let go over a destination (`PaneDropZone`) does, decided before anything
/// moves so the highlight and the drop agree (`AppStore.terminalDrop`).
enum TerminalDrop: Equatable {
  /// Tab `tab` of `owner` moves into `into`, at its end or just before `before`; onto a standalone
  /// terminal the two become an unnamed group (#659).
  case move(TerminalTab.ID, of: SidebarID, into: SidebarID, before: TerminalTab.ID?)
  /// Tab `tab` moves within its own target's tabs, just before `before` (nil: to the end).
  case reorder(TerminalTab.ID, in: SidebarID, before: TerminalTab.ID?)
  /// Tab `tab` of a group or workroom becomes a standalone terminal (the Terminals heading), or,
  /// let go in the title bar's empty space, one whose title-bar tab goes just before
  /// `titleBarBefore`'s (nil: last) (#652).
  case standalone(TerminalTab.ID, of: SidebarID, titleBarBefore: SidebarID?? = .none)
  /// Standalone terminal `sid`'s title-bar tab moves just before `before`'s (nil: last): its pane
  /// let go in the title bar's empty space, where it already is one.
  case reorderTitleBar(SidebarID, before: SidebarID?)
  /// Every terminal of group `group` moves into container `into`, in order, at its end or just
  /// before `before`, and the emptied group goes.
  case moveGroup(SidebarID, into: SidebarID, before: TerminalTab.ID?)
  /// Standalone terminal `standalone` joins dragged group `group`, at its end: the group keeps its
  /// name.
  case takeIn(standalone: SidebarID, group: SidebarID)
}

/// One rule set for every terminal drag (#652): each surface maps its pointer to a source and a
/// destination zone, asks `terminalDrop` what that does (nil: refused, no highlight), and lets
/// `performTerminalDrop` do it with the move primitives, so every terminal keeps its session.
extension AppStore {
  /// What `source` let go over `zone` does in this window, or nil when it is refused.
  func terminalDrop(_ source: TerminalDragSource, on zone: PaneDropZone) -> TerminalDrop? {
    switch source {
    case .terminal(let tab, let owner):
      return terminalDrop(tab, of: owner, on: zone)
    case .entry(let sid):
      switch sid {
      case .standalone:
        guard let held = standaloneTerminal(sid) else { return nil }
        if case .target(let other) = zone, case .standalone = other {
          return canDropRow(.standalone(sid), onto: other)
            ? .move(held.tab.id, of: sid, into: other, before: nil) : nil
        }
        return held.holder.terminalDrop(held.tab.id, of: sid, on: zone)
      case .terminalGroup:
        return groupDrop(sid, on: zone)
      default:
        return nil
      }
    }
  }

  /// The name the drag ghost (`DragGhost`) carries for `source`: its tab's or its target's title.
  func ghostTitle(of source: TerminalDragSource) -> String? {
    switch source {
    case .terminal(let tab, let owner):
      guard let (target, from) = terminalHome(of: owner) else { return nil }
      return (from?.terminals ?? terminals).tab(tab, for: target)?.title
    case .entry(let sid):
      return target(for: sid)?.title ?? sid.ghostTitle
    }
  }

  /// Whether `source` let go over `zone` does anything.
  func canDropTerminals(_ source: TerminalDragSource, on zone: PaneDropZone) -> Bool {
    terminalDrop(source, on: zone) != nil
  }

  /// Does what `source` let go over `zone` does, when it isn't refused. Whether it did.
  @discardableResult
  func dropTerminals(_ source: TerminalDragSource, on zone: PaneDropZone) async -> Bool {
    guard let drop = terminalDrop(source, on: zone) else { return false }
    if case .entry(let sid) = source, case .standalone = sid,
      let held = standaloneTerminal(sid), held.holder !== self
    {
      return await held.holder.performTerminalDrop(drop)
    }
    return await performTerminalDrop(drop)
  }

  // MARK: Deciding

  /// The container a drop on `zone` lands in, and the tab it lands before (nil: the end). A pane
  /// tab's after-half is before the tab after it.
  private func landing(_ zone: PaneDropZone) -> (into: SidebarID, before: TerminalTab.ID?)? {
    switch zone {
    case .standalone, .titleBarGap: return nil
    case .target(let sid): return (sid, nil)
    case .terminalRow(let tab, let container):
      return landing(.tab(tab, in: container, after: false))
    case .tab(let tab, let container, let after):
      if case .standalone = container { return (container, nil) }
      guard after else { return (container, tab) }
      let order = tabOrder(of: container)
      guard let index = order.firstIndex(of: tab), index + 1 < order.count else {
        return (container, nil)
      }
      return (container, order[index + 1])
    }
  }

  /// Tab `tab` of `owner` let go over `zone`.
  private func terminalDrop(_ tab: TerminalTab.ID, of owner: SidebarID, on zone: PaneDropZone)
    -> TerminalDrop?
  {
    guard let (target, source) = terminalHome(of: owner) else { return nil }
    if case .standalone = zone {
      return canDropPane(tab, of: target, on: .standalone, source: source)
        ? .standalone(tab, of: owner) : nil
    }
    if case .titleBarGap(let before) = zone {
      guard owner.isStandaloneTerminal else {
        return canDropPane(tab, of: target, on: .standalone, source: source)
          ? .standalone(tab, of: owner, titleBarBefore: .some(before)) : nil
      }
      // Already a standalone terminal: only its title-bar tab moves, unless it is there already.
      let order = titleBarOrder
      guard let index = order.firstIndex(of: owner) else { return nil }
      let next = index + 1 < order.count ? order[index + 1] : nil
      if before == owner || before == next { return nil }
      return .reorderTitleBar(owner, before: before)
    }
    guard let (into, before) = landing(zone) else { return nil }
    if into == owner {
      // Its own container's row, tab or title bar: it is already there.
      guard zone.container != zone, !owner.isStandaloneTerminal,
        paneMoveRefusal(ofTab: tab, in: target, source: source) == nil
      else { return nil }
      let order = tabOrder(of: owner)
      guard let index = order.firstIndex(of: tab) else { return nil }
      // Let go just before itself or the tab after it, or at the end when it is last: no move.
      let next = index + 1 < order.count ? order[index + 1] : nil
      if before == tab || before == next { return nil }
      return .reorder(tab, in: owner, before: before)
    }
    guard canDropPane(tab, of: target, on: .target(into), source: source) else { return nil }
    return .move(tab, of: owner, into: into, before: before)
  }

  /// Group `group`'s whole handle let go over `zone`.
  private func groupDrop(_ group: SidebarID, on zone: PaneDropZone) -> TerminalDrop? {
    guard let groupID = group.targetID, let held = terminalsSection.group(groupID),
      !held.isBuiltIn, let (into, before) = landing(zone), into != group
    else { return nil }
    switch into {
    case .standalone:
      return canDropRow(.standalone(into), onto: group)
        ? .takeIn(standalone: into, group: group) : nil
    case .terminalGroup:
      if into.targetID == .quickTerminal { break }
      guard let intoID = into.targetID, terminalsSection.canMergeGroup(groupID, into: intoID)
      else { return nil }
      return .moveGroup(group, into: into, before: before)
    default:
      break
    }
    // Into a workroom, a root or the Quick Terminal: each of this window's terminals moves as a
    // pane would, and every one of them must be able to.
    guard let target = target(for: group) else { return nil }
    let tabs = terminals.allTabs(for: target).map(\.id)
    guard !tabs.isEmpty,
      tabs.allSatisfy({ canDropPane($0, of: target, on: .target(into)) })
    else { return nil }
    return .moveGroup(group, into: into, before: before)
  }

  /// `sid`'s target, and whose panes its terminals are when not this window's (the Quick
  /// Terminal's panel).
  func terminalHome(of sid: SidebarID) -> (TerminalTarget, PaneDropSource?)? {
    if sid.targetID == .quickTerminal { return groupTerminal(in: sid) }
    guard let target = target(for: sid) else { return nil }
    return (target, nil)
  }

  /// The tabs of `sid`'s target in strip order, wherever they are held.
  private func tabOrder(of sid: SidebarID) -> [TerminalTab.ID] {
    if sid.targetID == .quickTerminal {
      guard let panel = terminalsSection.quickTerminalHolder as? QuickTerminalHost else {
        return []
      }
      return panel.terminals.tabs(for: panel.target).map(\.id)
    }
    guard let target = target(for: sid) else { return [] }
    return terminals.tabs(for: target).map(\.id)
  }

  // MARK: Doing

  /// Does `drop`, decided by `terminalDrop` in this window. Whether it did.
  @discardableResult
  func performTerminalDrop(_ drop: TerminalDrop) async -> Bool {
    switch drop {
    case .move(let tab, let owner, let into, let before):
      if case .standalone = owner, case .standalone = into {
        dropStandalone(owner, onto: into)
        return true
      }
      guard let (target, source) = terminalHome(of: owner) else { return false }
      guard await dropPane(tab, of: target, on: .target(into), source: source) else {
        return false
      }
      if let before { place([tab], before: before, in: into) }
      return true
    case .reorder(let tab, let sid, let before):
      guard let (target, source) = terminalHome(of: sid) else { return false }
      let panes = source?.terminals ?? terminals
      if let before {
        panes.moveTab(tab, before: before, for: target)
      } else {
        panes.moveTab(tab, toIndex: panes.tabs(for: target).count, for: target)
      }
      if source == nil { markSessionDirty() } else { SavedLayoutCoordinator.shared.markDirty() }
      return true
    case .standalone(let tab, let owner, let titleBarBefore):
      guard case .some(let before) = titleBarBefore else {
        return await dropPane(tab, of: owner, on: .standalone)
      }
      return await dropPane(tab, of: owner, on: .titleBarGap(before: before))
    case .reorderTitleBar(let sid, let before):
      guard let id = sid.targetID else { return false }
      placeTitleBarTab(id, before: before)
      return true
    case .takeIn(let standalone, let group):
      return await dropRow(.standalone(standalone), onto: group)
    case .moveGroup(let group, let into, let before):
      return await moveGroup(group, into: into, before: before)
    }
  }

  /// `dropPane` for `owner`'s tab.
  private func dropPane(_ tab: TerminalTab.ID, of owner: SidebarID, on zone: PaneDropZone)
    async -> Bool
  {
    guard let (target, source) = terminalHome(of: owner) else { return false }
    return await dropPane(tab, of: target, on: zone, source: source)
  }

  /// Every terminal of group `group` into `into`, in order, at its end or before `before`.
  private func moveGroup(_ group: SidebarID, into: SidebarID, before: TerminalTab.ID?) async
    -> Bool
  {
    guard let groupID = group.targetID, let target = target(for: group) else { return false }
    let tabs = terminals.allTabs(for: target).map(\.id)
    let section = terminalsSection
    let moved: Bool
    if case .terminalGroup = into, into.targetID != .quickTerminal, let intoID = into.targetID {
      moved = await section.enqueueRegroup { await section.mergeGroup(groupID, into: intoID) }
        .value
    } else {
      let panel = into.targetID == .quickTerminal ? quickTerminalPanel : nil
      guard let intoID = into.targetID else { return false }
      // One regroup, so the group isn't settled (dissolved or deleted) until all have gone.
      moved = await section.enqueueRegroup { [weak self] in
        guard let self else { return false }
        var any = false
        for tab in tabs {
          let ok: Bool
          if let panel {
            ok = await PaneMove.move(
              tab, of: target, source: terminals, notifications: notifications, to: panel,
              into: intoID)
          } else {
            ok = await PaneMove.move(
              tab, of: target, source: terminals, notifications: notifications, to: self,
              into: intoID)
          }
          any = any || ok
        }
        return any
      }.value
    }
    if moved, let before { place(tabs, before: before, in: into) }
    return moved
  }

  /// Puts `tabs`, now in `into`, just before `before`, in order.
  private func place(_ tabs: [TerminalTab.ID], before: TerminalTab.ID, in into: SidebarID) {
    if into.targetID == .quickTerminal, let panel = quickTerminalPanel {
      for tab in tabs { panel.terminals.moveTab(tab, before: before, for: panel.target) }
      SavedLayoutCoordinator.shared.markDirty()
    } else if let target = target(for: into) {
      for tab in tabs { terminals.moveTab(tab, before: before, for: target) }
      markSessionDirty()
    }
  }
}
