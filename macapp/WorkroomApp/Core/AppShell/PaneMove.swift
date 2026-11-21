import AppKit
import WorkroomDomain

/// Somewhere a pane can be moved into: a Workroom window's store, or the Quick Terminal's host.
/// The source side of a move needs only its panes and the app's notification list, so it is no
/// holder; the destination owns the target the pane joins and what is shown once it has.
@MainActor
protocol PaneMoveDestination: AnyObject {
  /// The panes the moved tab is adopted into.
  var terminals: TerminalPanes { get }
  /// What its notifications are keyed by (`NotificationCenterStore.repoint`).
  var paneMoveOrigin: ObjectIdentifier { get }
  /// The target `id` names, when a pane can join it here; nil when it is gone or takes no pane.
  func paneMoveTarget(forID id: TargetID) -> TerminalTarget?
  /// The pane could not be retagged for `target`, so it stays in `place`; say why, here.
  func paneMoveRetagFailed(into target: TerminalTarget, stayingIn place: String)
  /// `target` took the pane: select it, focus it and bring this holder forward.
  func paneDidMove(into target: TerminalTarget)
}

/// A pane moving live from any target to any other: retag its session, hand the tab off, adopt it.
/// Whichever holder either end is, a window or the Quick Terminal. Shared by every Move to… route:
/// the title-bar button, the tab menu, the terminal's right-click menu and a drop.
@MainActor
enum PaneMove {
  /// "Move to…" for `source`'s pane `tabID` in `target`: every workroom open in `windows`, in each
  /// window's tab order, a group per window. The pane's own target is listed disabled.
  static func choices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, windows: [AppStore]
  ) -> [PaneWorkroomGroup] {
    let groups = windows.map { window in
      window.displayedWorkroomTargets().map { workroom in
        let sid = workroom.sid
        let glyph = if case .root = sid { "house" } else { workroom.target.workroomGlyph }
        let into = window.paneMoveTarget(sid)
        let isOwn = window.terminals === source && workroom.target.id == target.id
        return PaneWorkroomChoice(
          title: window.title(for: sid), glyph: glyph, enabled: into != nil && !isOwn
        ) { [weak source, weak notifications, weak window] in
          guard let source, let notifications, let window else { return }
          Task {
            await move(
              tabID, of: target, source: source, notifications: notifications, to: window,
              into: workroom.target.id)
          }
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

  /// Move `source`'s pane `tabID`, in `target`, live into `destination`'s target `targetID` and
  /// focus it. Its session is retagged as that target's; if that fails nothing moves and the
  /// destination says why.
  static func move(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, to destination: any PaneMoveDestination,
    into targetID: TargetID
  ) async {
    guard let into = destination.paneMoveTarget(forID: targetID),
      destination.terminals !== source || into.id != target.id,
      source.tab(tabID, for: target) != nil
    else { return }
    // Nil for a pane with no background session (an Investigate tab's agent): nothing to retag.
    let sessionID = source.sessionID(forTab: tabID, inTarget: target.id)
    let service = source.sessionService
    if let sessionID,
      !(await service.retag(sessionID: sessionID, workroom: into.sessionWorkroomKey))
    {
      let place =
        target.id == QuickTerminalController.targetID ? "the Quick Terminal" : target.title
      destination.paneMoveRetagFailed(into: into, stayingIn: place)
      return
    }
    // Checked again after the wait: the target may have gone, or the window moved on. The shell
    // keeps its old tag then.
    guard destination.paneMoveTarget(forID: targetID)?.id == into.id else {
      if let sessionID {
        _ = await service.retag(sessionID: sessionID, workroom: target.sessionWorkroomKey)
      }
      return
    }
    // Before the hand-off, whose `.tabsRemoved` may close the Quick Terminal and drop what it raised.
    notifications.repoint(tab: tabID, to: into.id, in: destination.paneMoveOrigin)
    // An Investigate pane stays one there (the mark is its tab's), so deleting its workroom asks
    // first (#146), and its exit, which the destination's sessions now raise, ends it there.
    guard let handOff = source.handOffTab(tabID, from: target, to: into) else { return }
    destination.terminals.adopt(handOff)
    destination.paneDidMove(into: into)
  }
}

extension AppStore: PaneMoveDestination {
  var paneMoveOrigin: ObjectIdentifier { ObjectIdentifier(self) }

  func paneMoveTarget(forID id: TargetID) -> TerminalTarget? {
    paneMoveTarget(sidebarID(for: id))?.target
  }

  func paneMoveRetagFailed(into target: TerminalTarget, stayingIn place: String) {
    modals.errorTitle = "Couldn't move the terminal to \(windowTitle)"
    modals.errorMessage =
      "Workroom's background helper couldn't hand the terminal over to \(target.title), so it stays in \(place)."
    // Its alert shows in this window, which may be behind the one the pane is in.
    NSApp.activate(ignoringOtherApps: true)
    hostWindow?.makeKeyAndOrderFront(nil)
  }

  func paneDidMove(into target: TerminalTarget) {
    // A split member's pane: that member becomes the focused workroom, so the pane has the keys.
    if let sid = sidebarID(for: target.id) {
      selectedTargetID = sid
      selectedProjectID = AppStore.projectPath(of: sid)
    }
    refreshSelectionHasTabs()
    WindowRegistry.shared.recomputeBadge()
    markSessionDirty()
    NSApp.activate(ignoringOtherApps: true)
    hostWindow?.makeKeyAndOrderFront(nil)
  }

  /// "Move to…" choices for `tabID`, a pane of this window's `target`, over every workroom open in `windows`.
  func paneMoveChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget,
    windows: [AppStore] = WindowRegistry.shared.allStores
  ) -> [PaneWorkroomGroup] {
    PaneMove.choices(
      tabID, of: target, source: terminals, notifications: notifications, windows: windows)
  }
}

extension QuickTerminalHost: PaneMoveDestination {
  var paneMoveOrigin: ObjectIdentifier { ObjectIdentifier(self) }

  func paneMoveTarget(forID id: TargetID) -> TerminalTarget? { id == target.id ? target : nil }

  func paneMoveRetagFailed(into target: TerminalTarget, stayingIn place: String) {
    modals.errorTitle = "Couldn't move the terminal to \(target.title)"
    modals.errorMessage =
      "Workroom's background helper couldn't hand the terminal over to \(target.title), so it stays in \(place)."
    NSApp.activate(ignoringOtherApps: true)
    hostWindow?.makeKeyAndOrderFront(nil)
  }

  func paneDidMove(into target: TerminalTarget) {
    NSApp.activate(ignoringOtherApps: true)
    hostWindow?.makeKeyAndOrderFront(nil)
  }
}
