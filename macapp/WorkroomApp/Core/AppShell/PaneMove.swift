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
  /// Rebuild a handed-off popped-out pane's window here (`TerminalPanes.adopt`'s `reopen`).
  func reopenDetachedPane(_ tabID: TerminalTab.ID, frame: NSRect, in target: TerminalTarget) -> Bool
}

/// A pane moving live from any target to any other: retag its session, hand the tab off, adopt it.
/// Whichever holder either end is, a window or the Quick Terminal. Shared by every Move to… route:
/// the title-bar button, the tab menu, the terminal's right-click menu, a standalone terminal's
/// sidebar row and a drop.
@MainActor
enum PaneMove {
  /// "Move to…" for `source`'s pane `tabID` in `target`, in sections: first the Terminals section's
  /// places (Standalone Terminal, the Quick Terminal, the user's terminal groups, New Terminal Group…),
  /// which the pane joins in its own window, else (a Quick Terminal pane) in `front`, the window in
  /// front, else in the first of `windows`; then every workroom open in `windows`, in each window's
  /// tab order, a section per window. The pane's own place is listed checked and disabled, as a
  /// native menu marks where something is now, and every place is
  /// when the pane can't move at all (`refusal`, or `sourceRefusal`), each with why.
  static func choices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, windows: [AppStore], front: AppStore? = nil,
    refusal: String? = nil, quickTerminal: QuickTerminalHost? = nil
  ) -> [PaneWorkroomGroup] {
    let stuck = refusal ?? sourceRefusal(tabID, of: target, source: source)
    let home =
      windows.first { $0.terminals === source } ?? windows.first { $0 === front }
      ?? windows.first
    let section = home.map {
      terminalsChoices(
        tabID, of: target, source: source, notifications: notifications, in: $0,
        quickTerminal: quickTerminal, stuck: stuck)
    }
    let groups = windows.map { window in
      window.displayedWorkroomTargets().filter { !$0.sid.isInTerminalsSection }.map { workroom in
        let sid = workroom.sid
        let glyph = if case .root = sid { "house" } else { workroom.target.workroomGlyph }
        let isOwn = window.terminals === source && workroom.target.id == target.id
        let why = stuck ?? (isOwn ? nil : window.paneMoveRefusal(sid))
        return PaneWorkroomChoice(
          title: window.title(for: sid, separator: WorkroomLabel.separator), glyph: glyph,
          enabled: why == nil && !isOwn, isCurrent: isOwn, help: why,
          move: mover(
            tabID, of: target, source: source, notifications: notifications, to: window,
            into: workroom.target.id))
      }
    }
    let named = groups.filter { !$0.isEmpty }.count > 1
    let workrooms = zip(windows, groups).compactMap { window, choices in
      choices.isEmpty
        ? nil
        : PaneWorkroomGroup(
          header: named ? window.defaultWindowTitle : nil, choices: choices)
    }
    // With no window to join, the Quick Terminal is still a place to go.
    let places =
      section
      ?? quickTerminal.map {
        [
          quickTerminalChoice(
            tabID, of: target, source: source, notifications: notifications, $0, stuck)
        ]
      }
    return (places.map { [PaneWorkroomGroup(header: nil, choices: $0)] } ?? []) + workrooms
  }

  /// The Terminals section's places for the pane, joined in `home`: Standalone Terminal, then the Quick
  /// Terminal (in its own panel), then each terminal group in the section's order, then New
  /// Terminal Group….
  private static func terminalsChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, in home: AppStore, quickTerminal: QuickTerminalHost?,
    stuck: String?
  ) -> [PaneWorkroomChoice] {
    let isStandalone = if case .standalone = target.id { true } else { false }
    var choices = [
      PaneWorkroomChoice(
        title: "Standalone Terminal", glyph: TerminalGroup.standaloneGlyph,
        enabled: stuck == nil && !isStandalone, isCurrent: isStandalone,
        help: stuck ?? (isStandalone ? nil : "A terminal of its own, with its own row and tab")
      ) { [weak source, weak notifications, weak home] in
        guard let source, let notifications, let home else { return }
        Task {
          await home.movePaneToStandalone(
            tabID, of: target, source: source, notifications: notifications)
        }
      }
    ]
    if let quickTerminal {
      choices.append(
        quickTerminalChoice(
          tabID, of: target, source: source, notifications: notifications, quickTerminal, stuck))
    }
    for entry in home.terminalsSection.entries {
      guard case .group = entry, let into = home.target(for: entry.sidebarID) else { continue }
      let isOwn = into.id == target.id && home.terminals === source
      let why = stuck ?? (isOwn ? nil : home.paneMoveRefusal(entry.sidebarID))
      choices.append(
        PaneWorkroomChoice(
          title: into.title, glyph: TerminalGroup.glyph, enabled: why == nil && !isOwn,
          isCurrent: isOwn, help: why,
          move: mover(
            tabID, of: target, source: source, notifications: notifications, to: home,
            into: into.id)))
    }
    choices.append(
      PaneWorkroomChoice(
        title: "New Terminal Group…", glyph: TerminalGroup.newGlyph, enabled: stuck == nil,
        help: stuck ?? "Name a new group and move this terminal into it"
      ) { [weak source, weak notifications, weak home] in
        TerminalGroupNamePrompt.present { name in
          guard let source, let notifications, let home else { return }
          Task {
            await home.movePaneToNewGroup(
              named: name, tabID, of: target, source: source, notifications: notifications)
          }
        }
      })
    return choices
  }

  /// The Quick Terminal's place: its panel's built-in group, listed disabled for its own panes and
  /// for a pane that can't move at all (a terminal on a host among them).
  private static func quickTerminalChoice(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, _ host: QuickTerminalHost, _ stuck: String?
  ) -> PaneWorkroomChoice {
    let isOwn = host.terminals === source
    return PaneWorkroomChoice(
      title: QuickTerminalController.target(in: host.section).title,
      glyph: QuickTerminalController.glyph, enabled: stuck == nil && !isOwn, isCurrent: isOwn,
      help: stuck ?? (isOwn ? nil : "Move this terminal into the Quick Terminal's panel"),
      move: mover(
        tabID, of: target, source: source, notifications: notifications, to: host,
        into: .quickTerminal))
  }

  /// A choice's action: `move` the pane into `destination`'s `targetID`, holding the panes, the
  /// notification list and the destination weakly, so a menu kept open holds none of them alive.
  private static func mover(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, to destination: any PaneMoveDestination,
    into targetID: TargetID
  ) -> () -> Void {
    { [weak source, weak notifications, weak destination] in
      guard let source, let notifications, let destination else { return }
      Task {
        await move(
          tabID, of: target, source: source, notifications: notifications, to: destination,
          into: targetID)
      }
    }
  }

  /// Why `source`'s pane `tabID` in `target` can't move anywhere, or nil when it can. A terminal
  /// on a host stays there; a popped-out pane goes back to its window first.
  static func sourceRefusal(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes
  ) -> String? {
    if target.remoteHost != nil || target.isRemoteWorkroom {
      return "This terminal runs on a host, so it can't move to this Mac."
    }
    if source.detachedTabIDs.contains(tabID) {
      return "Move this terminal back to its main window first."
    }
    return nil
  }

  /// Move `source`'s pane `tabID`, in `target`, live into `destination`'s target `targetID` and
  /// focus it. Its session is retagged as that target's; if that fails nothing moves and the
  /// destination says why. Whether it moved.
  @discardableResult
  static func move(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, source: TerminalPanes,
    notifications: NotificationCenterStore, to destination: any PaneMoveDestination,
    into targetID: TargetID
  ) async -> Bool {
    guard sourceRefusal(tabID, of: target, source: source) == nil,
      let into = destination.paneMoveTarget(forID: targetID),
      destination.terminals !== source || into.id != target.id,
      source.tab(tabID, for: target) != nil
    else { return false }
    // Nil for a pane with no background session (an Investigate tab's agent): nothing to retag.
    let sessionID = source.sessionID(forTab: tabID, inTarget: target.id)
    let service = source.sessionService
    if let sessionID,
      !(await service.retag(sessionID: sessionID, workroom: into.sessionWorkroomKey))
    {
      let place = target.id == .quickTerminal ? "the Quick Terminal" : target.title
      destination.paneMoveRetagFailed(into: into, stayingIn: place)
      return false
    }
    // Checked again after the wait: the target may have gone, or the window moved on. The shell
    // keeps its old tag then.
    guard destination.paneMoveTarget(forID: targetID)?.id == into.id else {
      if let sessionID {
        _ = await service.retag(sessionID: sessionID, workroom: target.sessionWorkroomKey)
      }
      return false
    }
    // Before the hand-off, whose `.tabsRemoved` may close the Quick Terminal and drop what it raised.
    notifications.repoint(tab: tabID, to: into.id, in: destination.paneMoveOrigin)
    // An Investigate pane stays one there (the mark is its tab's), so deleting its workroom asks
    // first (#146), and its exit, which the destination's sessions now raise, ends it there.
    guard let handOff = source.handOffTab(tabID, from: target, to: into) else { return false }
    destination.terminals.adopt(handOff) { destination.reopenDetachedPane($0, frame: $1, in: into) }
    destination.paneDidMove(into: into)
    return true
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

  /// "Move to…" choices for `tabID`, a pane of this window's `target`: the Terminals section's
  /// places, the Quick Terminal among them, and every workroom open in `windows`. A workroom's run
  /// tab stays its run's.
  func paneMoveChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget,
    windows: [AppStore] = WindowRegistry.shared.allStores
  ) -> [PaneWorkroomGroup] {
    paneMoveChoices(
      tabID, of: target, windows: windows,
      quickTerminal: WindowRegistry.shared.quickTerminal?.ensureHost())
  }

  /// The same, with the Quick Terminal's panel given: a test's, or none.
  func paneMoveChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, windows: [AppStore],
    quickTerminal: QuickTerminalHost?
  ) -> [PaneWorkroomGroup] {
    PaneMove.choices(
      tabID, of: target, source: terminals, notifications: notifications, windows: windows,
      refusal: paneMoveRefusal(ofTab: tabID, in: target), quickTerminal: quickTerminal)
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

  /// A pane moved into the panel slides it in, on that pane.
  func paneDidMove(into target: TerminalTarget) {
    SavedLayoutCoordinator.shared.markDirty()
    onReveal?(terminals.activeTab(for: target)?.id)
  }
}
