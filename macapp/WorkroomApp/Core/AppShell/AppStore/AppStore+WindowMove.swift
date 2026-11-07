import AppKit
import WorkroomDomain

/// A workroom on its way from one window to another (issue #444): everything the window it leaves
/// knew about it that the window it joins must go on knowing. The terminals themselves never
/// travel: they are the app's (`TerminalTabs`), and `sessions` carries only their layout.
struct WorkroomHandOff {
  let sid: SidebarID
  var sessions: TerminalPanes.TargetHandOff
  let run: RunCommands.HandOff
}

/// Moves waiting on a window that has been asked for but does not exist yet (issue #444). The new
/// window carries only the request's id in its `WindowSeed`, and pulls the workroom from the window
/// it is leaving once it is up — so if the new window never appears, nothing ever left the old one.
@MainActor
final class WorkroomHandOffs {
  static let shared = WorkroomHandOffs()

  struct Request {
    weak var origin: AppStore?
    let sid: SidebarID
    /// The new window's top-left, on screen: where the workroom was dropped. Nil from a menu.
    let topLeft: CGPoint?
  }

  private var pending: [UUID: Request] = [:]

  func request(_ request: Request) -> UUID {
    let id = UUID()
    pending[id] = request
    return id
  }

  /// The request `id` names, while it still waits for its window.
  func request(for id: UUID) -> Request? { pending[id] }

  /// The new window is up: move the workroom into it.
  func complete(_ id: UUID, into store: AppStore) {
    guard let request = pending.removeValue(forKey: id), let origin = request.origin else { return }
    origin.moveWorkroom(request.sid, to: store)
  }
}

// MARK: Quick Terminal panes into a window

/// One workroom in a Quick Terminal pane's "Move to Workroom" menu. A class, to ride an
/// `NSMenuItem`'s `representedObject`.
@MainActor
final class PaneWorkroomChoice {
  let title: String
  /// The workroom's glyph, as its tab shows it.
  let glyph: String
  /// False for one on a host, or still being created: a shell on this Mac can't join it.
  let enabled: Bool
  let move: () -> Void

  init(title: String, glyph: String, enabled: Bool, move: @escaping () -> Void) {
    self.title = title
    self.glyph = glyph
    self.enabled = enabled
    self.move = move
  }
}

/// The workrooms open in one Workroom window, for "Move to Workroom". `header` names the window
/// when there is more than one, so two windows' workrooms can be told apart; nil otherwise.
struct PaneWorkroomGroup {
  let header: String?
  let choices: [PaneWorkroomChoice]
}

/// Dragging a Quick Terminal pane out of its window: over a workroom that can take it, its ghost
/// shows and that workroom is highlighted; anywhere else the pointer says it can't drop there.
@MainActor
enum QuickTerminalPaneDrag {
  /// While the pointer shows "not allowed", so `cancel` only puts back a cursor this changed.
  private static var refusing = false

  static func update(title: String, glyph: String?) {
    let hit = destination()
    show(hit)
    refuse(hit == nil)
    if hit != nil {
      DetachedPaneDragPreview.shared.show(title: title, glyph: glyph, at: NSEvent.mouseLocation)
    } else {
      DetachedPaneDragPreview.shared.hide()
    }
  }

  /// The drag came back inside the Quick Terminal, or ended: no ghost, highlight or refusal.
  static func cancel() {
    DetachedPaneDragPreview.shared.hide()
    show(nil)
    refuse(false)
  }

  /// One window at a time highlights the workroom.
  private static func show(_ hit: (window: AppStore, workroom: SidebarID)?) {
    for window in WindowRegistry.shared.allStores {
      let value = window === hit?.window ? hit?.workroom : nil
      if window.incomingQuickTerminalPane != value { window.incomingQuickTerminalPane = value }
    }
  }

  /// Set again on every move while refusing: a window under the pointer can set its own cursor.
  private static func refuse(_ on: Bool) {
    if on {
      NSCursor.operationNotAllowed.set()
    } else if refusing {
      NSCursor.arrow.set()
    }
    refusing = on
  }

  /// The drag was let go outside the Quick Terminal.
  static func end(store: AppStore, tabID: TerminalTab.ID, target: TerminalTarget) {
    defer { cancel() }
    // The workroom under the pointer, when the window shows several side by side.
    guard let (window, workroom) = destination() else { return }
    Task { await store.moveQuickTerminalPane(tabID, of: target, to: window, into: workroom) }
  }

  /// The Workroom window under the pointer and its workroom there, when that can take the pane.
  private static func destination() -> (window: AppStore, workroom: SidebarID)? {
    let point = NSEvent.mouseLocation
    guard let window = WindowRegistry.shared.dropStore(at: point),
      let workroom = window.quickTerminalPaneDestination(at: point)
    else { return nil }
    return (window, workroom)
  }
}

extension AppStore {
  /// The workroom a Quick Terminal pane dropped at `screenPoint` joins: a torn-off pane's own, or
  /// the one whose tab, or whose pane when workrooms are side by side, is there, else the selected
  /// one. Nil unless it can.
  func quickTerminalPaneDestination(at screenPoint: CGPoint) -> SidebarID? {
    // Over one of this window's torn-off panes: that pane's workroom, whatever the main window
    // (perhaps behind it, under the same point) shows.
    if let pane = WindowRegistry.shared.detachedPane(at: screenPoint),
      let paneTarget = terminals.targetID(ofTab: pane)
    {
      return quickTerminalPaneTarget(sidebarID(for: paneTarget))?.sid
    }
    let hit =
      workroomTabRowPoint(screenPoint).flatMap { point in
        workroomTabFrames.first { $0.value.contains(point) }?.key
      } ?? workroom(atScreenPoint: screenPoint)
    return quickTerminalPaneTarget(hit ?? selectedTargetID)?.sid
  }

  /// `screenPoint` in the workroom tab row's space (top-left origin), which the tab frames are in.
  func workroomTabRowPoint(_ screenPoint: CGPoint) -> CGPoint? {
    guard let run = workroomTabRun, let window = run.window else { return nil }
    let row = window.convertToScreen(run.convert(run.bounds, to: nil))
    return CGPoint(x: screenPoint.x - row.minX, y: row.maxY - screenPoint.y)
  }

  /// `sid`'s workroom, when a Quick Terminal pane can join it.
  func quickTerminalPaneTarget(
    _ sid: SidebarID?
  ) -> (sid: SidebarID, target: TerminalTarget)? {
    guard let sid, let target = target(for: sid), target.remoteHost == nil,
      !target.isRemoteWorkroom, target.opensTerminals, !lifecycle.isCreationBlocking(target.id)
    else { return nil }
    return (sid, target)
  }

  /// The workroom this window draws under `screenPoint`, or nil when it is over none of them.
  private func workroom(atScreenPoint screenPoint: CGPoint) -> SidebarID? {
    guard let window = hostWindow, let space = workroomPaneSpace, let selected = selectedTargetID
    else { return nil }
    // SwiftUI's global space for this window: its top-left, title bar included.
    let inWindow = window.convertPoint(fromScreen: screenPoint)
    let global = CGPoint(x: inWindow.x, y: window.frame.height - inWindow.y)
    return Self.workroom(at: global, in: visibleWorkroomLayout(for: selected), space: space)
  }

  /// The pure half of `workroom(atScreenPoint:)`: which of `layout`'s workrooms is drawn at
  /// `global`, laid out in `space` as the split renderer lays them out.
  nonisolated static func workroom(
    at global: CGPoint, in layout: PaneLayout<SidebarID>, space: CGRect
  ) -> SidebarID? {
    let local = CGPoint(x: global.x - space.minX, y: global.y - space.minY)
    let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: space.size))
    return plan.panes.first { $0.value.contains(local) }?.key
  }

  /// "Move to Workroom" for this store's pane `tabID` in `target` (the Quick Terminal's): every
  /// workroom open in `windows`, in each window's tab order, a group per window. Shared by the
  /// title-bar button, the tab menu and the terminal's right-click menu.
  func quickTerminalPaneWorkroomChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget,
    windows: [AppStore] = WindowRegistry.shared.allStores
  ) -> [PaneWorkroomGroup] {
    let groups = windows.map { window in
      window.displayedWorkroomTargets().map { workroom in
        let sid = workroom.sid
        let glyph = if case .root = sid { "house" } else { workroom.target.workroomGlyph }
        return PaneWorkroomChoice(
          title: window.title(for: sid), glyph: glyph,
          enabled: window.quickTerminalPaneTarget(sid) != nil
        ) { [weak self, weak window] in
          guard let self, let window else { return }
          Task { await self.moveQuickTerminalPane(tabID, of: target, to: window, into: sid) }
        }
      }
    }
    let named = groups.filter { !$0.isEmpty }.count > 1
    return zip(windows, groups).compactMap { window, choices in
      choices.isEmpty
        ? nil
        : PaneWorkroomGroup(
          header: named ? window.defaultWindowTitle : nil, choices: choices)
    }
  }

  /// Move this store's pane `tabID`, in `target` (the Quick Terminal's), live into `destination`'s
  /// workroom `workroom` and focus it. Its session is retagged as that workroom's first; if that
  /// fails nothing moves and the window says why.
  func moveQuickTerminalPane(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, to destination: AppStore,
    into workroom: SidebarID
  ) async {
    guard destination !== self,
      let (sid, into) = destination.quickTerminalPaneTarget(workroom),
      terminals.tab(tabID, for: target) != nil
    else { return }
    // Nil for a pane with no background session (an Investigate tab's agent): nothing to retag.
    let sessionID = terminals.sessionID(forTab: tabID, inTarget: target.id)
    let service = terminals.sessionService
    if let sessionID,
      !(await service.retag(sessionID: sessionID, workroom: into.sessionWorkroomKey))
    {
      destination.modals.errorTitle = "Couldn't move the terminal to \(destination.windowTitle)"
      destination.modals.errorMessage =
        "Workroom's background helper couldn't hand the terminal over to \(into.title), so it stays in the Quick Terminal."
      // Its alert shows in that window, which may be behind the Quick Terminal.
      NSApp.activate(ignoringOtherApps: true)
      destination.hostWindow?.makeKeyAndOrderFront(nil)
      return
    }
    // Checked again after the wait: the workroom may have gone, or the window moved on. The shell
    // stays a Quick Terminal one then, so it is ended at quit like the rest.
    guard destination.quickTerminalPaneTarget(sid)?.target.id == into.id else {
      if let sessionID {
        _ = await service.retag(sessionID: sessionID, workroom: target.sessionWorkroomKey)
      }
      return
    }
    // Before the hand-off, whose `.tabsRemoved` may close the Quick Terminal and drop what it raised.
    notifications.repoint(
      tab: tabID, to: into.id, in: ObjectIdentifier(destination))
    // Read before the hand-off, whose `.tabsRemoved` forgets it here.
    let investigating = runCommand.investigateTabs[tabID] != nil
    guard let handOff = terminals.handOffTab(tabID, from: target, to: into) else { return }
    destination.terminals.adopt(handOff)
    if investigating {
      // Still an Investigate session there, so deleting its workroom asks first (#146), and its
      // exit, which the destination's sessions now raise, ends it there.
      destination.runCommand.investigateTabs[tabID] = into.id
    }
    // A split member's pane: that member becomes the focused workroom, so the pane has the keys.
    destination.selectedTargetID = sid
    destination.selectedProjectID = Self.projectPath(of: sid)
    destination.refreshSelectionHasTabs()
    WindowRegistry.shared.recomputeBadge()
    destination.markSessionDirty()
    NSApp.activate(ignoringOtherApps: true)
    destination.hostWindow?.makeKeyAndOrderFront(nil)
  }
}

extension AppStore {
  /// Whether `sid`'s workroom can move to another window: it has terminals here, no create is still
  /// setting it up (#444 Q18), and it is not this window's only workroom, which would only leave an
  /// empty window behind. Every route asks this: the drags and every menu item.
  func canMoveWorkroom(_ sid: SidebarID) -> Bool {
    guard let target = target(for: sid) else { return false }
    // Not while its host is still asked for its layout: that answer restores into this window.
    return terminals.tabCount(forTargetID: target.id) > 0
      && !lifecycle.isCreationBlocking(target.id)
      && !hostLayouts.fetching.contains(target.id)
      && orderedWorkroomTargets().contains { $0.sid != sid }
  }

  /// The size a workroom's new window opens at, whatever window it left: a move is a request for a
  /// window, not for the old one's dimensions, as a torn-off pane's is (`DetachedPaneWindows`).
  /// The same size a first window opens at.
  static let newWindowContentSize = NSSize(width: 1200, height: 780)

  /// Move `sid`'s workroom into a new window, its top-left at `topLeft` on screen (the drop point) or
  /// where AppKit places a new window. The window is opened first and takes the workroom when it is
  /// up (`WorkroomHandOffs`).
  func moveWorkroomToNewWindow(_ sid: SidebarID, at topLeft: CGPoint? = nil) {
    guard canMoveWorkroom(sid), let openWindow = WindowRegistry.shared.openWindow else { return }
    let id = WorkroomHandOffs.shared.request(.init(origin: self, sid: sid, topLeft: topLeft))
    openWindow(WindowSeed(id: UUID(), restore: false, handOff: id))
  }

  /// Move `sid`'s workroom from this window into `destination`, at `index` among its workroom tabs (at
  /// the end when nil). Its terminals keep running, unrestarted, with their scrollback; its run
  /// command, torn-off panes, notifications and host layout go with it (#444).
  func moveWorkroom(_ sid: SidebarID, to destination: AppStore, at index: Int? = nil) {
    guard destination !== self, canMoveWorkroom(sid), let target = target(for: sid),
      let handOff = takeWorkroom(sid, target: target)
    else { return }
    handHostLayout(of: target, to: destination)
    // Its notifications are now the new window's: they go if that one closes, not this one.
    notifications.repoint(
      target: target.id, from: ObjectIdentifier(self), to: ObjectIdentifier(destination))
    destination.adoptWorkroom(handOff, at: index)
    markSessionDirty()
  }

  /// Lift the workroom out of this window. Its run bookkeeping goes first: the `.tabsRemoved` the
  /// sessions fire would otherwise clear it as for a closed run tab.
  private func takeWorkroom(_ sid: SidebarID, target: TerminalTarget) -> WorkroomHandOff? {
    let run = runCommand.takeHandOff(for: target.id)
    // Find belongs to the selected workroom's focused content pane, which is leaving. Its own
    // focus-change close does not fire: the hand-off clears focus without notifying.
    if selectedTargetID == sid, contentFind.isOpen { contentFind.close() }
    // A torn-off pane's window belongs to this window, so it closes here and the destination opens
    // its own at the same frame.
    var frames: [TerminalTab.ID: NSRect] = [:]
    for tab in terminals.allTabs(for: target) where terminals.detachedTabIDs.contains(tab.id) {
      frames[tab.id] = detachedPanes.frame(for: tab.id) ?? .zero
      detachedPanes.close(tabID: tab.id)
    }
    guard var sessions = terminals.handOff(target) else {
      runCommand.adopt(run, for: target.id)
      return nil
    }
    for id in sessions.detached.keys { sessions.detached[id] = frames[id] ?? .zero }
    return WorkroomHandOff(sid: sid, sessions: sessions, run: run)
  }

  /// Take in a workroom another window handed over, select it and bring this window forward. Into a
  /// window that already shows the workroom, its terminals join this window's own, and of two run
  /// tabs the running one stays (#444 Q12).
  private func adoptWorkroom(_ handOff: WorkroomHandOff, at index: Int?) {
    let target = handOff.sessions.target
    let id = target.id
    var run = handOff.run
    var closing: TerminalTab.ID?
    if let own = runCommand.runStates[id]?.tab, let moved = run.state?.tab {
      if run.state?.isRunning == true {
        // Only one window runs a workroom's command (#70), so this one's is stopped, though its
        // supervisor may still be up and its stop then waits on it. Its exit must not land on the
        // run taken in meanwhile, which would mark the moved run ended and kill its session: it
        // does not, as an exit ends a run only from the run's own tab (`tabProcessExited`).
        runCommand.closingRunTab(own, for: id) { [weak self] in
          self?.terminals.closeTab(own, for: target)
        }
      } else {
        closing = moved
        run = RunCommands.HandOff(investigateTabs: run.investigateTabs)
      }
    }
    let wasAt = displayedWorkroomTargets().firstIndex { $0.target.id == id }
    terminals.adopt(handOff.sessions)
    if target.remoteHost == nil, !target.isRemoteWorkroom,
      handOff.sessions.tabIDs.contains(where: {
        guard let view = terminals.surface(of: $0) else { return false }
        return view.attachment.isRestored
          && terminals.sessionID(forTab: $0, inTarget: id) != nil
          && view.surface == nil
      })
    {
      // The old window's paced recovery no longer owns these views. Continue in their new window
      // after it displays, including hidden panes that will not mount with the focused tab.
      scheduleSessionRecoveryAfterDisplay()
    }
    // Its run's exit and close reach this window through the sessions that adopted its tabs.
    runCommand.adopt(run, for: id)
    if let closing { terminals.closeTab(closing, for: target) }
    placeWorkroomTab(id, at: index, wasAt: wasAt)
    selectedTargetID = handOff.sid
    selectedProjectID = Self.projectPath(of: handOff.sid)
    refreshSelectionHasTabs()
    // Its sessions are attached again: a blocked agent the hand-off dropped from the waiting list
    // comes back, with the counts.
    WindowRegistry.shared.recomputeBadge()
    markSessionDirty()
    NSApp.activate(ignoringOtherApps: true)
    hostWindow?.makeKeyAndOrderFront(nil)
  }

  /// Where a workroom dropped at `screenPoint` lands among this window's workroom tabs: the slot under
  /// the cursor over the tab bar, or nil (the end) anywhere else over the window (#444 Q21).
  func incomingWorkroomSlot(at screenPoint: CGPoint) -> Int? {
    guard let point = workroomTabRowPoint(screenPoint) else { return nil }
    let shown = displayedWorkroomTargets()
    let groupOf = workroomSplitGroupIndices()
    return Self.workroomTabSlot(at: point, frames: shown.compactMap { workroomTabFrames[$0.sid] })
      .map { Self.workroomTabSlot($0, outside: shown.map { groupOf[$0.sid] }) }
  }

  /// A slot inside a split group's run of tabs is not one a tab can land in, since the group keeps
  /// its tabs together, so it moves to the group's nearer edge. `groups` is each tab's group, in
  /// order (nil for a tab in none).
  nonisolated static func workroomTabSlot(_ slot: Int, outside groups: [Int?]) -> Int {
    guard slot > 0, slot < groups.count, let group = groups[slot - 1], groups[slot] == group
    else { return slot }
    let start = groups[..<slot].lastIndex { $0 != group }.map { $0 + 1 } ?? 0
    let end = groups[slot...].firstIndex { $0 != group } ?? groups.count
    return slot - start <= end - slot ? start : end
  }

  /// The pure half of `incomingWorkroomSlot`: `point` and `frames` (the tabs in order) share the
  /// tab row's top-left space. Over the row, the number of tabs left of the cursor; off it, nil.
  nonisolated static func workroomTabSlot(at point: CGPoint, frames: [CGRect]) -> Int? {
    guard let top = frames.map(\.minY).min(), let bottom = frames.map(\.maxY).max(),
      (top - 6...bottom + 6).contains(point.y)
    else { return nil }
    return frames.count { $0.midX < point.x }
  }

  /// Size and place a window opened for a moved workroom: the standard size, its top-left where
  /// the workroom was dropped. Run as the window is set up and again once it shows, since SwiftUI
  /// places a new window itself (cascading it off the front one) after the view is in.
  func placeHandOffWindow(_ window: NSWindow) {
    window.setContentSize(Self.newWindowContentSize)
    guard let topLeft = pendingInitialWindowTopLeft else { return window.center() }
    window.setFrameTopLeftPoint(topLeft)
    if let safe = Self.frameOnAVisibleScreen(window.frame) { window.setFrame(safe, display: false) }
  }

  /// Put `targetID`'s workroom tab at `index` among this window's, or at the end.
  /// `index` counts this window's tabs as they stood under the cursor, so in a window that already
  /// showed the workroom (`wasAt`) it counts that tab too: past it, the slot is one less once that
  /// tab is lifted out.
  private func placeWorkroomTab(_ targetID: TerminalTarget.ID, at index: Int?, wasAt: Int?) {
    var order = displayedWorkroomTargets().map(\.target.id).filter { $0 != targetID }
    var slot = index ?? order.count
    if let index, let wasAt, wasAt < index { slot -= 1 }
    order.insert(targetID, at: min(max(slot, 0), order.count))
    workroomTabOrder = order
  }
}
