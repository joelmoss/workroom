import AppKit
import WorkroomDomain

/// A Quick Terminal pane moving live into a workroom open in a Workroom window. The source side is
/// only the panes it leaves and the app's notification list, so whatever hosts the Quick Terminal
/// needs no window store of its own; the destination is a window's store, which owns the workroom.
@MainActor
enum QuickTerminalPaneMove {
  /// "Move to Workroom" for `source`'s pane `tabID` in `target` (the Quick Terminal's): every
  /// workroom open in `windows`, in each window's tab order, a group per window. Shared by the
  /// title-bar button, the tab menu and the terminal's right-click menu.
  static func choices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, windows: [AppStore]
  ) -> [PaneWorkroomGroup] {
    let groups = windows.map { window in
      window.displayedWorkroomTargets().map { workroom in
        let sid = workroom.sid
        let glyph = if case .root = sid { "house" } else { workroom.target.workroomGlyph }
        return PaneWorkroomChoice(
          title: window.title(for: sid), glyph: glyph,
          enabled: window.quickTerminalPaneTarget(sid) != nil
        ) { [weak source, weak notifications, weak window] in
          guard let source, let notifications, let window else { return }
          Task {
            await move(
              tabID, of: target, source: source, notifications: notifications, to: window,
              into: sid)
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

  /// Move `source`'s pane `tabID`, in `target` (the Quick Terminal's), live into `destination`'s
  /// workroom `workroom` and focus it. Its session is retagged as that workroom's first; if that
  /// fails nothing moves and the window says why.
  static func move(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, to destination: AppStore, into workroom: SidebarID
  ) async {
    guard destination.terminals !== source,
      let (sid, into) = destination.quickTerminalPaneTarget(workroom),
      source.tab(tabID, for: target) != nil
    else { return }
    // Nil for a pane with no background session (an Investigate tab's agent): nothing to retag.
    let sessionID = source.sessionID(forTab: tabID, inTarget: target.id)
    let service = source.sessionService
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
    // An Investigate pane stays one there (the mark is its tab's), so deleting its workroom asks
    // first (#146), and its exit, which the destination's sessions now raise, ends it there.
    guard let handOff = source.handOffTab(tabID, from: target, to: into) else { return }
    destination.terminals.adopt(handOff)
    // A split member's pane: that member becomes the focused workroom, so the pane has the keys.
    destination.selectedTargetID = sid
    destination.selectedProjectID = AppStore.projectPath(of: sid)
    destination.refreshSelectionHasTabs()
    WindowRegistry.shared.recomputeBadge()
    destination.markSessionDirty()
    NSApp.activate(ignoringOtherApps: true)
    destination.hostWindow?.makeKeyAndOrderFront(nil)
  }
}
