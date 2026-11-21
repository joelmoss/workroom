import AppKit
import WorkroomDomain

/// Where a terminal's tab dragged inside its window lands: a sidebar row or title-bar tab
/// (`target`), or the Terminals heading, which makes it a standalone terminal (#660).
enum PaneDropZone: Hashable {
  case target(SidebarID)
  case standalone
}

/// Moving any terminal anywhere (#660, ADR 0077): the Terminals section's places a pane can move
/// into in this window (Standalone, New Terminal Group…), and the drag of a tab onto a sidebar row,
/// a title-bar tab or the Terminals heading. Every route ends in `PaneMove.move`.
extension AppStore {
  /// Move to → Standalone: `source`'s pane `tabID` becomes a standalone terminal of its own in this
  /// window, its row just below `target`'s when that is in the Terminals section. Nothing is left
  /// behind when it can't move.
  @discardableResult
  func movePaneToStandalone(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore
  ) async -> Bool {
    if case .standalone = target.id { return false }
    guard PaneMove.sourceRefusal(tabID, of: target, source: source) == nil else { return false }
    return await movePane(
      tabID, of: target, source: source, notifications: notifications,
      intoNewRow: terminalsSection.addStandalone(after: target.id))
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

  /// Why this window's tab `tabID` in `target` can't move at all, or nil when it can: only a
  /// terminal moves, and a workroom's run tab stays its run's, beside `PaneMove.sourceRefusal`'s
  /// reasons.
  func paneMoveRefusal(ofTab tabID: TerminalTab.ID, in target: TerminalTarget) -> String? {
    guard case .terminal = terminals.tab(tabID, for: target)?.content else {
      return "Only a terminal moves."
    }
    if runTabID(for: target.id) == tabID {
      return "A run command's terminal stays in its workroom."
    }
    return PaneMove.sourceRefusal(tabID, of: target, source: terminals)
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

  /// Whether this window's tab `tabID` in `target`, let go over `zone`, moves there.
  func canDropPane(_ tabID: TerminalTab.ID, of target: TerminalTarget, on zone: PaneDropZone)
    -> Bool
  {
    guard paneMoveRefusal(ofTab: tabID, in: target) == nil else { return false }
    switch zone {
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
  private var quickTerminalPanel: QuickTerminalHost? {
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

  /// Moves this window's tab `tabID` in `target` to `zone`, when it can go there.
  @discardableResult
  func dropPane(_ tabID: TerminalTab.ID, of target: TerminalTarget, on zone: PaneDropZone) async
    -> Bool
  {
    guard canDropPane(tabID, of: target, on: zone) else { return false }
    switch zone {
    case .standalone:
      return await movePaneToStandalone(
        tabID, of: target, source: terminals, notifications: notifications)
    case .target(let sid):
      guard let into = sid.targetID else { return false }
      if into == .quickTerminal, let panel = quickTerminalPanel {
        return await PaneMove.move(
          tabID, of: target, source: terminals, notifications: notifications, to: panel,
          into: into)
      }
      if paneMoveTarget(sid) == nil {
        return await groupPane(tabID, of: target, onto: into)
      }
      return await PaneMove.move(
        tabID, of: target, source: terminals, notifications: notifications, to: self, into: into)
    }
  }

  /// This window's tab `tabID` in `target`, dropped on standalone terminal `destination`: an
  /// unnamed group of the two in `destination`'s place, its terminal first (#659). A standalone
  /// terminal's own tab groups as dropping its row does; any other is moved into `destination`
  /// once that is a group, which goes back to the standalone terminal it was when the tab can't
  /// follow. Queued with the section's other regroups.
  private func groupPane(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, onto destination: TargetID
  )
    async -> Bool
  {
    let section = terminalsSection
    if case .standalone = target.id, section.contains(target.id) {
      return await section.enqueueRegroup {
        await section.groupStandalone(target.id, onto: destination) != nil
      }.value
    }
    return await section.enqueueRegroup { [weak self] in
      guard case .standalone(let standalone) = destination,
        let group = await section.convertToGroup(destination)
      else { return false }
      guard let self else { return false }
      let moved = await PaneMove.move(
        tabID, of: target, source: self.terminals, notifications: self.notifications, to: self,
        into: group)
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
  /// The drop zone under `screenPoint`: a title-bar tab, else a sidebar row or the Terminals
  /// heading this window shows there.
  func paneDropZone(at screenPoint: CGPoint) -> PaneDropZone? {
    if let point = workroomTabRowPoint(screenPoint),
      let sid = workroomTabFrames.first(where: { $0.value.contains(point) })?.key
    {
      return .target(sid)
    }
    return sidebarDropZone { $0.contains(screenPoint) }
  }

  /// The sidebar zone one of whose visible views `hit` takes, given its rect on screen. A zone can
  /// be drawn twice (the sidebar column and the edge-reveal sidebar): any visible one.
  private func sidebarDropZone(_ hit: (CGRect) -> Bool) -> PaneDropZone? {
    guard let window = hostWindow else { return nil }
    return paneDropZoneViews.first { _, boxes in
      boxes.contains { box in
        guard let view = box.view, view.window === window, !view.isHiddenOrHasHiddenAncestor
        else { return false }
        // Kept within its height: a marker in a sidebar pane's sticky header (#652) reports a
        // visible rect as tall as its pane, which would take the drops meant for the rows below.
        // Not its width: a row's reaches across the List's, past the row's own insets.
        let shown = view.visibleRect
        let visible = shown.intersection(
          CGRect(x: shown.minX, y: view.bounds.minY, width: shown.width, height: view.bounds.height)
        )
        guard !visible.isEmpty else { return false }
        return hit(window.convertToScreen(view.convert(visible, to: nil)))
      }
    }?.key
  }

  /// This window's tab `tabID` in `target` is dragged to `screenPoint` (nil: the drag ended or left
  /// every zone). Highlights the zone it would move to, shows "not allowed" over one that refuses
  /// it, and says whether it is over a zone at all, so the tab strip stops previewing its own drop.
  @discardableResult
  func paneDragMoved(_ tabID: TerminalTab.ID, of target: TerminalTarget, to screenPoint: CGPoint?)
    -> Bool
  {
    let zone = screenPoint.flatMap(paneDropZone(at:))
    let accepts = zone.map { canDropPane(tabID, of: target, on: $0) } ?? false
    let shown = accepts ? zone : nil
    if incomingPaneDrop != shown { incomingPaneDrop = shown }
    let refusing = zone != nil && !accepts
    if refusing {
      NSCursor.operationNotAllowed.set()
    } else if paneDragRefusing {
      NSCursor.arrow.set()
    }
    paneDragRefusing = refusing
    return zone != nil
  }

  /// This window's tab `tabID` in `target` is let go at `screenPoint`: over a zone, it moves there
  /// when the zone takes it, and is refused otherwise. Whether it was over a zone.
  func paneDragEnded(_ tabID: TerminalTab.ID, of target: TerminalTarget, at screenPoint: CGPoint)
    -> Bool
  {
    let zone = paneDropZone(at: screenPoint)
    paneDragMoved(tabID, of: target, to: nil)
    guard let zone else { return false }
    Task { await dropPane(tabID, of: target, on: zone) }
    return true
  }
}

// MARK: Dropping a standalone terminal's row on another's

/// A standalone terminal's sidebar row dragged onto another's makes an unnamed group of the two
/// (#659). The List's own drag still reorders the section: a row let go over the middle of another
/// standalone terminal's row groups, and one let go nearer either edge goes between them. The drop
/// zones are the tab drag's (#660), so the row taking it is highlighted the same way.
extension AppStore {
  /// The middle half of a row's height: a row let go there drops on it, not beside it.
  nonisolated static func groupBand(of row: CGRect) -> CGRect {
    row.insetBy(dx: 0, dy: row.height / 4)
  }

  /// Whether standalone terminal `dragged`'s row, let go on `destination`'s, groups the two.
  func canDropRow(_ dragged: SidebarID, onto destination: SidebarID) -> Bool {
    guard case .standalone = dragged, case .standalone = destination, dragged != destination,
      let from = dragged.targetID, let onto = destination.targetID
    else { return false }
    return terminalsSection.contains(from) && terminalsSection.contains(onto)
  }

  /// Drops standalone terminal `dragged`'s row on `destination`'s (`dropStandalone`), when it can.
  @discardableResult
  func dropRow(_ dragged: SidebarID, onto destination: SidebarID) -> Bool {
    guard canDropRow(dragged, onto: destination) else { return false }
    dropStandalone(dragged, onto: destination)
    return true
  }

  /// The standalone terminal row `dragged` would group with, let go at `screenPoint`: the one
  /// whose middle is under it, in this window's sidebar.
  func rowDropDestination(_ dragged: SidebarID, at screenPoint: CGPoint) -> SidebarID? {
    let zone = sidebarDropZone { Self.groupBand(of: $0).contains(screenPoint) }
    guard case .target(let sid) = zone, canDropRow(dragged, onto: sid) else { return nil }
    return sid
  }
}
