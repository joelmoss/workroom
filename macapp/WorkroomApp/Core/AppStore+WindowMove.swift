import AppKit
import WorkroomDomain

/// A workroom on its way from one window to another (issue #444): everything the window it leaves
/// knew about it that the window it joins must go on knowing. The terminals themselves travel live,
/// with their surfaces, inside `sessions`.
struct WorkroomHandOff {
  let sid: SidebarID
  var sessions: TerminalSessions.TargetHandOff
  let run: RunCommandController.HandOff
  let notifications: [WorkroomNotification]
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

extension AppStore {
  /// Whether `sid`'s workroom can move to another window: it has terminals here, no create is still
  /// setting it up (#444 Q18), and it is not this window's only workroom, which would only leave an
  /// empty window behind. Every route asks this: the drags and every menu item.
  func canMoveWorkroom(_ sid: SidebarID) -> Bool {
    guard let target = target(for: sid) else { return false }
    // Not while its host is still asked for its layout: that answer restores into this window.
    return terminals.tabCount(forTargetID: target.id) > 0 && !isCreationBlocking(target.id)
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
    destination.adoptWorkroom(handOff, at: index)
    markSessionDirty()
  }

  /// Lift the workroom out of this window. Its run bookkeeping goes first: the `.tabsRemoved` the
  /// sessions fire would otherwise clear it as for a closed run tab.
  private func takeWorkroom(_ sid: SidebarID, target: TerminalTarget) -> WorkroomHandOff? {
    let run = runCommand.takeHandOff(for: target.id)
    let notes = notifications.take(target: target.id)
    // A torn-off pane's window belongs to this window, so it closes here and the destination opens
    // its own at the same frame.
    var frames: [TerminalTab.ID: NSRect] = [:]
    for tab in terminals.allTabs(for: target) where terminals.detachedTabIDs.contains(tab.id) {
      frames[tab.id] = detachedPanes.frame(for: tab.id) ?? .zero
      detachedPanes.close(tabID: tab.id)
    }
    guard var sessions = terminals.handOff(target) else {
      runCommand.adopt(run, for: target.id)
      notifications.adopt(notes)
      return nil
    }
    for id in sessions.detached.keys { sessions.detached[id] = frames[id] ?? .zero }
    WindowRegistry.shared.recomputeBadge()
    return WorkroomHandOff(sid: sid, sessions: sessions, run: run, notifications: notes)
  }

  /// Take in a workroom another window handed over, select it and bring this window forward. Into a
  /// window that already shows the workroom, its terminals join this window's own, and of two run
  /// tabs the running one stays (#444 Q12).
  private func adoptWorkroom(_ handOff: WorkroomHandOff, at index: Int?) {
    let target = handOff.sessions.target
    let id = target.id
    var run = handOff.run
    var closing: TerminalTab.ID?
    if let own = runStates[id]?.tab, let moved = run.state?.tab {
      if run.state?.isRunning == true {
        // Only one window runs a workroom's command (#70), so this one's is stopped: it goes now,
        // and its `.tabsRemoved` clears its state before the moved run's is taken in.
        closingRunTab(own, for: id) { [weak self] in self?.terminals.closeTab(own, for: target) }
      } else {
        closing = moved
        run = RunCommandController.HandOff(investigateTabs: run.investigateTabs)
      }
    }
    terminals.adopt(handOff.sessions)
    runCommand.adopt(run, for: id)
    notifications.adopt(handOff.notifications)
    resumeAdoptedRun(for: target)
    if let closing { terminals.closeTab(closing, for: target) }
    placeWorkroomTab(id, at: index)
    selectedTargetID = handOff.sid
    selectedProjectID = Self.projectPath(of: handOff.sid)
    refreshSelectionHasTabs()
    WindowRegistry.shared.recomputeBadge()
    markSessionDirty()
    NSApp.activate(ignoringOtherApps: true)
    hostWindow?.makeKeyAndOrderFront(nil)
  }

  /// Where a workroom dropped at `screenPoint` lands among this window's workroom tabs: the slot under
  /// the cursor over the tab bar, or nil (the end) anywhere else over the window (#444 Q21).
  func incomingWorkroomSlot(at screenPoint: CGPoint) -> Int? {
    guard let run = workroomTabRun, let window = run.window else { return nil }
    let row = window.convertToScreen(run.convert(run.bounds, to: nil))
    return Self.workroomTabSlot(
      at: CGPoint(x: screenPoint.x - row.minX, y: row.maxY - screenPoint.y),
      frames: displayedWorkroomTargets().compactMap { workroomTabFrames[$0.sid] })
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
  private func placeWorkroomTab(_ targetID: TerminalTarget.ID, at index: Int?) {
    var order = displayedWorkroomTargets().map(\.target.id).filter { $0 != targetID }
    order.insert(targetID, at: min(max(index ?? order.count, 0), order.count))
    workroomTabOrder = order
  }
}
