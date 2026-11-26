import AppKit
import Combine
import DaemonConnection
import Defaults
import Foundation
import WorkroomDomain
import WorkroomVCS

/// What hosts the Quick Terminal's panes: its tabs, their close flow, Investigate sessions and
/// notifications, the panes popped out of it, and the window's find and modals. Its one target is
/// the built-in terminal group (ADR 0077), no project, so it holds none of a workroom window's
/// owners (projects, VCS status, run commands, creates and deletes); the members that answer only
/// for a workroom say so where they answer nothing.
///
/// Never registered with `WindowRegistry` as a window, or counted as one (ADR 0064). It registers
/// with the app's Terminals section as a holder instead, so the group's terminals are counted and
/// raised there. Its layout is saved as its own entry in `session.json`. Its notifications join the
/// app's one list (ADR 0064), named live from the app's projects.
@MainActor
@Observable
final class QuickTerminalHost: PaneHost, PaneNotifierHost, PaneDropZoneHost {
  let terminals: TerminalPanes
  /// Its Investigate tabs, and the graceful close a run-command tab's "press any key" goes through.
  let runCommand: RunCommandController
  /// The terminal-tab close and its confirm.
  let closeFlow: TabCloseFlow
  /// This window's modal presentations and the error sheet's contents.
  let modals = ModalState()
  /// The find its file, diff and changeset panes share.
  let contentFind = FileFindModel()
  /// The app's one notification list (ADR 0064).
  let notifications: NotificationCenterStore
  /// What it reaches outside the app (ADR 0022). Tests stand fakes in its members.
  @ObservationIgnored var services = AppServices.current

  /// The Quick Terminal's window, once it has one.
  @ObservationIgnored weak var hostWindow: NSWindow?
  /// Where a terminal drag from a window over this panel would drop, highlighted on its pane tabs
  /// while it hovers (#652): set by that window's drag session, which has none of its own here.
  var incomingPaneDrop: PaneDropZone?
  /// Its pane tabs' drop zones' views (`PaneDropZoneMarker`), which a window's drag measures at its
  /// start (`AppStore.terminalDropZones`). A registry, not state: nothing renders from it.
  @ObservationIgnored var paneDropZoneViews: [PaneDropZone: [PaneDropZoneMarker.Box]] = [:]
  /// Called when a target's last tab closes: the controller hides the window on it.
  @ObservationIgnored var onTargetEmptied: ((TerminalTarget.ID) -> Void)?
  /// Slides the panel in, focused on the tab given when it has it: a row click, a move into it or
  /// a notification. Set by the controller.
  @ObservationIgnored var onReveal: ((TerminalTab.ID?) -> Void)?
  /// Its panes popped out into windows of their own (issue #172), as a window's are.
  @ObservationIgnored let detachedPanes = DetachedPaneWindows()
  /// The app's Terminals section, whose built-in group this host holds.
  @ObservationIgnored let section: TerminalsSection
  /// Marks the saved session dirty on any pane change, as a window's store does (issue #46): a
  /// close, a pop-out or a dock included, so no event below marks it again.
  @ObservationIgnored private var sessionObservation: AnyCancellable?
  /// Its one target, the built-in group's, always on screen in its window with no selection to say
  /// so: its panes count as seen and focused as a selected workroom's do (#573). Resolved live, so
  /// a new tab starts in the group's starting folder as it is now.
  var target: TerminalTarget { QuickTerminalController.target(in: section) }

  /// Its notifications and toast queue. Lazy only because its records' origin is this host's
  /// identity, which init can't name until every stored property is set.
  @ObservationIgnored private(set) lazy var paneNotifier = PaneNotifier(
    host: self, terminals: terminals, notifications: notifications)

  init(notifications: NotificationCenterStore, section: TerminalsSection = .shared) {
    self.notifications = notifications
    self.section = section
    let terminals = TerminalPanes()
    self.terminals = terminals
    let runCommand = RunCommandController(terminals: terminals)
    self.runCommand = runCommand
    self.closeFlow = TabCloseFlow(terminals: terminals, runCommand: runCommand)
    terminals.onEvent = { [weak self] event in self?.handleTerminalEvent(event) }
    // `paneWillChange` fires before the change lands, so the coordinator schedules its capture.
    sessionObservation = terminals.paneWillChange.sink { _ in
      SavedLayoutCoordinator.shared.markDirty()
    }
    section.register(self)
    section.quickTerminalHolder = self
  }

  /// Everything its `TerminalPanes` reports, handled inline as a window's store handles it.
  private func handleTerminalEvent(_ event: TerminalPanes.Event) {
    switch event {
    case .activity(let targetID, let tabID, let activity):
      paneNotifier.handleActivity(targetID: targetID, tabID: tabID, activity: activity)
    // Find is tied to the focused content pane: a focus change ends it.
    case .focusChanged:
      if contentFind.isOpen { contentFind.close() }
    case .tabsRemoved(let targetID, let ids):
      // A popped-out pane's window goes with it (idempotent when its dock already closed it).
      for id in ids { detachedPanes.close(tabID: id) }
      // A closed pane's waiting requests stop counting.
      WindowRegistry.shared.recomputeBadge()
      if terminals.tabCount(forTargetID: targetID) == 0 { onTargetEmptied?(targetID) }
    // Effective focus is the one authority for reading a terminal's notifications (#358).
    case .terminalSeen(_, let tabID):
      notifications.dismiss(tab: tabID)
    // An Investigate tab's exit ends its session (#146). It has no run tab whose exit ends a run.
    case .childExited(_, let tabID, _):
      runCommand.investigateTabs.removeValue(forKey: tabID)
    // An Investigate tab closes at once; `closingRunTab` is the one route either kind takes.
    case .closeRequested(let target, let tabID):
      runCommand.closingRunTab(tabID, for: target.id) { [weak self] in
        self?.terminals.closeTab(tabID, for: target)
      }
    // A pane's right-click New Terminal, split or Close Terminal (#583), here as its ⌘T, ⌘D and ⌘W
    // are (`QuickTerminalController.perform`), on the pane clicked.
    case .paneCommandRequested(let target, let tabID, let command):
      switch command {
      case .newTerminal: newTerminal(in: target)
      case .split(let edge): terminals.splitTab(tabID, on: edge, for: target)
      case .close: requestCloseTerminalTab(tabID, for: target)
      }
    // No navigation history, workroom split or selection to follow a content change, a pane count
    // or a surface focus. Its saved layout follows `paneWillChange`, which every pane change sends.
    // And no inspector to follow a folder change: the Quick Terminal never feeds one (#803).
    case .tabContentChanged, .paneCountChanged, .surfaceFocused, .cwdChanged, .commandFinished:
      break
    // Pop-out panes (issue #172), as a window's store opens and closes them.
    case .paneDetached(_, let tabID, let screenPoint, let byDrag):
      // The slot, read before the window mounts the surface: it still shows the pane.
      let source = DetachedPaneWindows.PopOutSource.slot(
        of: tabID, surface: terminals.surface(of: tabID), byDrag: byDrag, pointer: screenPoint,
        setInFlight: { [weak terminals = self.terminals] in terminals?.setInFlight(tabID, $0) })
      openDetachedPane(tabID, origin: screenPoint, frame: nil, popOut: source)
      // Its last docked pane left: the panel hides, as when its last terminal closes.
      if !hasDockedTab { onTargetEmptied?(target.id) }
    case .paneDocked(let tabID):
      detachedPanes.close(tabID: tabID)
    case .paneRaiseRequested(let tabID):
      raiseDetachedPane(tabID)
    case .paneWindowToggleRequested(let targetID, let tabID):
      togglePaneWindow(tabID, targetID: targetID)
    // Its panes are this Mac's, so no host can fail to end one.
    case .remoteCloseFailed:
      break
    // No run command, and no saved session to bring a run tab back from.
    case .runTabRestored, .runStatus, .runSessionGone:
      break
    }
  }

  // MARK: PaneHost: panes

  /// No host keeps its layout.
  var waitingForHostLayout: Set<TerminalTarget.ID> { [] }

  /// A project's first tab; the controller opens this target's own.
  func ensureInitialTerminal(for target: TerminalTarget) {}

  func newTerminal(in target: TerminalTarget) { _ = terminals.addTab(for: target) }

  /// No host layout to wait for.
  func whenHostLayoutRestored(
    _ target: TerminalTarget, _ open: @escaping (TerminalTarget) -> Void
  ) {
    open(target)
  }

  /// Whether the panel itself shows a terminal: one not popped out into a window of its own.
  var hasDockedTab: Bool {
    terminals.allTabs(for: target).contains { !terminals.detachedTabIDs.contains($0.id) }
  }

  /// A pane's Move to New Window / Move Back to Quick Terminal.
  func togglePaneWindow(_ tabID: TerminalTab.ID, targetID: TerminalTarget.ID) {
    guard targetID == target.id else { return }
    if terminals.detachedTabIDs.contains(tabID) {
      dockPane(tabID)
    } else {
      terminals.detachPane(tabID, for: target, at: NSEvent.mouseLocation)
    }
  }

  /// Raises its pane `tabID`'s own window and returns true, or returns false when the pane isn't
  /// popped out, as a window's store does (`AppStore.raiseDetachedPane`).
  @discardableResult
  func raiseDetachedPane(_ tabID: TerminalTab.ID) -> Bool {
    guard let window = detachedPanes.window(for: tabID) else { return false }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return true
  }

  /// Docks a popped-out pane back into the panel, and slides the panel in on it. Its window pulls
  /// back into its slot when the panel shows it, else it docks in place
  /// (`DetachedPaneWindows.dock`).
  func dockPane(_ tabID: TerminalTab.ID) {
    let target = target
    detachedPanes.dock(
      tabID, into: PaneSlot.current(of: tabID, surface: nil),
      setInFlight: { [weak terminals = self.terminals] in terminals?.setInFlight(tabID, $0) },
      then: { [weak self] in
        self?.terminals.dockPane(tabID, for: target)
        self?.onReveal?(tabID)
      })
  }

  /// Rebuilds restored popped-out pane `tabID`'s window at its saved `frame`, and says whether it is
  /// open, as a window's store does (`AppStore.reopenDetachedPane`).
  func reopenDetachedPane(_ tabID: TerminalTab.ID, frame: NSRect, in target: TerminalTarget) -> Bool {
    openDetachedPane(tabID, origin: nil, frame: frame)
    return detachedPanes.window(for: tabID) != nil
  }

  /// Builds and shows a popped-out pane's window, as a window's store does.
  private func openDetachedPane(
    _ tabID: TerminalTab.ID, origin: CGPoint?, frame: NSRect?,
    popOut: DetachedPaneWindows.PopOutSource? = nil
  ) {
    let target = target
    guard let tab = terminals.tab(tabID, for: target) else { return }
    let surface = terminals.surface(of: tabID)
    let terminals = terminals
    detachedPanes.open(
      tabID: tabID, title: tab.title, project: target.title, workroom: nil,
      glyph: TerminalGroup.glyph, origin: origin, frame: frame, popOut: popOut,
      onCloseTab: { [weak self] in self?.requestCloseTerminalTab(tabID, for: target) },
      onDock: { [weak self] in self?.dockPane(tabID) },
      content: {
        DetachedPaneView(
          tabID: tabID, content: tab.content, surface: surface, target: target,
          panes: terminals,
          onTitleChange: { [weak self] title in
            self?.detachedPanes.setTitle(
              title, project: target.title, workroom: nil, glyph: TerminalGroup.glyph, for: tabID)
          }
        )
        .quickTerminalPaneEnvironment(host: self)
      })
  }

  // MARK: PaneHost: closing tabs

  func requestCloseTerminalTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    closeFlow.requestClose(tabID, for: target)
  }

  func requestCloseOtherTerminalTabs(_ keepID: TerminalTab.ID, for target: TerminalTarget) {
    closeFlow.requestCloseOthers(keeping: keepID, for: target)
  }

  func requestCloseAllTerminalTabs(for target: TerminalTarget) {
    closeFlow.requestCloseAll(for: target)
  }

  // MARK: PaneHost: content tabs

  var cannedDiffs: AppServices.CannedDiffs? { services.cannedDiffs }
  var vcsReader: (@Sendable (URL) throws -> LocalVCSProviding)? { services.vcsReader }

  func openFilePreview(path: String, root: String?, for target: TerminalTarget) {
    _ = terminals.openFilePreview(
      FileDescriptor(path: path, isPreview: true, root: root), for: target)
  }

  func openDiffTabFile(_ descriptor: DiffDescriptor, for target: TerminalTarget) {
    AppStore.openWorkroomFile(relativePath: descriptor.path, for: target)
  }

  /// The Files inspector's ⌘-click, which acts on a window's selected workroom; it has none.
  func openFileInEditor(path: String, root: String?) {}

  func selectChangesetFile(_ path: String?, tab tabID: TerminalTab.ID, in target: TerminalTarget) {
    terminals.setChangesetSelectedPath(path, forTab: tabID, in: target)
  }

  // MARK: PaneHost: status bar and coding agent

  /// A workroom's branch; each pane reads its own (`readsPaneBranches`).
  func branchLabel(for target: TerminalTarget) -> String? { nil }

  @discardableResult
  func investigate(
    _ bannerState: CodingAgentBannerState, in target: TerminalTarget,
    surface: GhosttySurfaceView?
  ) -> TerminalTab {
    runCommand.startInvestigate(bannerState: bannerState, target: target, surface: surface)
  }

  // MARK: PaneHost: the run tab's menu

  func runTabID(for targetID: TerminalTarget.ID) -> TerminalTab.ID? {
    runCommand.runTabID(for: targetID)
  }

  /// Only a workroom's create blocks its run.
  func isRunBlocked(_ targetID: TerminalTarget.ID) -> Bool { false }

  /// A run command is a project's.
  func hasRunCommand(for target: TerminalTarget) -> Bool { false }

  func isRunCommandRunning(for targetID: TerminalTarget.ID) -> Bool {
    runCommand.isRunCommandRunning(for: targetID)
  }

  /// A run command is a project's, so there is none to start.
  func runOrFocusRunCommand(for target: TerminalTarget) {}

  /// A run command is a project's, so there is none to restart.
  func restartRunCommand(for target: TerminalTarget) {}

  func stopRunCommand(for target: TerminalTarget) { runCommand.stopRunCommand(for: target) }

  // MARK: PaneHost: the Quick Terminal

  /// "Move to…" for its pane `tabID`, over every workroom open in `windows`. Standalone and the
  /// groups make or join it in the window in front: the key one, else the last active (this panel
  /// is key while its menu is open).
  func paneMoveChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget,
    windows: [AppStore] = WindowRegistry.shared.allStores
  ) -> [PaneWorkroomGroup] {
    paneMoveChoices(tabID, of: target, windows: windows, front: WindowRegistry.shared.frontStore)
  }

  /// The same, with the window in front given: a test's.
  func paneMoveChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, windows: [AppStore], front: AppStore?
  ) -> [PaneWorkroomGroup] {
    PaneMove.choices(
      tabID, of: target, source: terminals, notifications: notifications, windows: windows,
      front: front, quickTerminal: self)
  }

  /// Its panel has no sidebar or title-bar tabs: a pane dragged out of it goes through
  /// `QuickTerminalPaneDrag`.
  func paneDragMoved(_ tabID: TerminalTab.ID, of target: TerminalTarget, to screenPoint: CGPoint?)
    -> Bool
  { false }

  func paneDragEnded(_ tabID: TerminalTab.ID, of target: TerminalTarget, at screenPoint: CGPoint)
    -> Bool
  { false }

  // MARK: PaneHost: toasts

  /// A run's toast is a project's run command's.
  var runToastItems: [RunCommandController.RunToastItem] { [] }
  /// A run's toast is a project's run command's.
  func openRunToast(for targetID: TerminalTarget.ID) {}
  /// The VCS tool check runs when a window's projects load.
  var vcsToolWarnings: [VCSToolVersions.ToolWarning] { [] }
  /// The VCS tool check runs when a window's projects load.
  func dismissToolWarning(tool: String) {}

  /// The origin line of an ordinary notification, named from the app's projects as they are now.
  func notificationSource(forTargetID id: TerminalTarget.ID) -> String {
    AppStore.notificationSource(forTargetID: id, in: ProjectStore.shared.projects)
  }

  // MARK: NotifyingHost

  var systemNotifier: SystemNotifying { services.notifier }

  /// The program-status session of the focused terminal, for ⇧⌘M. Only with keyboard focus in it.
  var focusedTerminalSession: UUID? { terminals.focusedTerminalSession(in: target) }

  /// A terminal's own name: its target is no workroom to say it is in.
  func terminalPlace(targetID: TerminalTarget.ID, tabID: TerminalTab.ID) -> String {
    terminals.defaultTitle(ofTab: tabID, inTarget: targetID) ?? "A terminal"
  }

  func targetName(_ targetID: TerminalTarget.ID) -> String? {
    targetID == target.id ? "Quick Terminal" : nil
  }

  // MARK: PaneNotifierHost

  var isHostWindowKey: Bool { hostWindow?.isKeyWindow == true }

  var primaryTargetID: TerminalTarget.ID? { target.id }

  /// Its target is its window's only one.
  func onScreenTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget? {
    target.id == targetID ? target : nil
  }

  /// Whether its pane `tabID`'s own window is key, while it is popped out.
  func detachedWindowIsKey(forTab tabID: TerminalTab.ID) -> Bool? {
    detachedPanes.window(for: tabID)?.isKeyWindow
  }

  /// The origin line under an alert's title: its target's name.
  func placeSource(targetID: TerminalTarget.ID) -> String {
    targetID == target.id ? "Quick Terminal" : ""
  }
}

// MARK: - A holder of the built-in group's terminals

extension QuickTerminalHost: TerminalsSectionHolder {
  func terminalTitles(forTargetID targetID: TargetID) -> [TerminalTitle] {
    terminals.terminalTitles(forTargetID: targetID)
  }

  func holdsTerminals(forTargetID targetID: TargetID) -> Bool {
    terminals.tabCount(forTargetID: targetID) > 0
  }

  /// The built-in group is never deleted, and this host holds no other, so it releases nothing.
  func releaseTerminals(of group: TargetID, after anchor: TargetID) async -> TargetID { anchor }

  // `retagTerminals` and `rehomeTerminals` keep the protocol's refusing defaults: the built-in
  // group never forms or dissolves (#659), and this host holds no other target to regroup.

  /// Slides the panel in, on its focused terminal: its row's click, from any window.
  func revealTerminals(forTargetID targetID: TargetID) {
    guard targetID == target.id else { return }
    onReveal?(nil)
  }

  /// Slides the panel in on terminal `tabID`, focused (or brings its own window forward when it is
  /// popped out): one of its terminals' rows clicked in a window's sidebar, or its waiting mark.
  func revealTerminal(_ tabID: TerminalTab.ID, inTarget targetID: TargetID) {
    guard targetID == target.id else { return }
    onReveal?(tabID)
  }

  /// What `session.json` keeps of it: its panes, their split and focus, and where popped-out ones
  /// are. Nil when it has none.
  func captureSession() -> TargetSession? {
    let target = target
    guard let captured = terminals.sessionCapture(forTargetID: target.id) else { return nil }
    var keysByTabID: [TerminalTab.ID: String] = [:]
    var tabs: [TabSession] = []
    for tab in captured.tabs {
      guard tabs.count < SessionLimits.maxTabsPerTarget else { break }
      let key = tab.id.uuidString
      guard var session = TabSession(key: key, tab: tab) else { continue }
      if let frame = detachedPanes.frame(for: tab.id) {
        session.detachedFrame = NSStringFromRect(frame)
      }
      keysByTabID[tab.id] = key
      tabs.append(session)
    }
    guard !tabs.isEmpty else { return nil }
    let splits = captured.splits.compactMap { layout in
      LayoutNode<String>.capture(layout) { keysByTabID[$0] }
    }
    return TargetSession(
      targetID: target.id.encoded, tabs: tabs, splits: splits,
      focusedKey: captured.focused.flatMap { keysByTabID[$0] }, terminalCounter: captured.counter)
  }
}

/// The Quick Terminal's panel as `workroom new` and `workroom close` see it (#693): its one
/// group, on screen while the panel shows.
extension QuickTerminalHost: TerminalRequestHolder {
  func terminalTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget? {
    targetID == target.id ? target : nil
  }

  func isShowingTarget(_ targetID: TerminalTarget.ID) -> Bool {
    targetID == target.id && hostWindow?.isVisible == true
  }

  var isKeyHolder: Bool { hostWindow?.isKeyWindow == true }

  func showRequestedSession(
    _ session: UUID, label: String?, caller: TerminalTab.ID, in target: TerminalTarget,
    split edge: PaneEdge?, unplaced: @escaping () -> Void
  ) {
    guard terminals.tab(caller, for: target) != nil else { return unplaced() }
    openRequestedPane(session, label: label, in: target, beside: edge.map { _ in caller }, on: edge)
  }

  func closeRequestedTab(_ tabID: TerminalTab.ID, in target: TerminalTarget) {
    closeFlow.performClose([tabID], for: target)
  }
}
