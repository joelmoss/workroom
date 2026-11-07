import AppKit
import DaemonConnection
import Defaults
import Foundation
import WorkroomVCS

/// What hosts the Quick Terminal's panes: its tabs, their close flow, Investigate sessions and
/// notifications, and the window's find and modals. Its one target is no project, so it holds none
/// of a workroom window's owners (projects, VCS status, run commands, creates and deletes); the
/// members that answer only for a workroom say so where they answer nothing.
///
/// Never registered with `WindowRegistry` as a window: never saved, restored or counted as one. Its
/// notifications join the app's one list (ADR 0064), named live from the app's projects.
@MainActor
@Observable
final class QuickTerminalHost: PaneHost, PaneNotifierHost {
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
  /// Called when a target's last tab closes: the controller closes the window on it.
  @ObservationIgnored var onTargetEmptied: ((TerminalTarget.ID) -> Void)?
  /// Its one target, always on screen in its window with no selection to say so: its panes count as
  /// seen and focused as a selected workroom's do (#573).
  let target: TerminalTarget

  /// Its notifications and toast queue. Lazy only because its records' origin is this host's
  /// identity, which init can't name until every stored property is set.
  @ObservationIgnored private(set) lazy var paneNotifier = PaneNotifier(
    host: self, terminals: terminals, notifications: notifications)

  init(notifications: NotificationCenterStore, target: TerminalTarget) {
    self.notifications = notifications
    self.target = target
    let terminals = TerminalPanes()
    self.terminals = terminals
    let runCommand = RunCommandController(terminals: terminals)
    self.runCommand = runCommand
    self.closeFlow = TabCloseFlow(terminals: terminals, runCommand: runCommand)
    terminals.onEvent = { [weak self] event in self?.handleTerminalEvent(event) }
  }

  /// Everything its `TerminalPanes` reports, handled inline as a window's store handles it.
  private func handleTerminalEvent(_ event: TerminalPanes.Event) {
    switch event {
    case .activity(let targetID, let tabID, let activity):
      paneNotifier.handleActivity(targetID: targetID, tabID: tabID, activity: activity)
    // Find is tied to the focused content pane: a focus change ends it.
    case .focusChanged:
      if contentFind.isOpen { contentFind.close() }
    case .tabsRemoved(let targetID, _):
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
    // No navigation history, workroom split or selection to follow a content change, a pane count
    // or a surface focus.
    case .tabContentChanged, .paneCountChanged, .surfaceFocused:
      break
    // No pane leaves for a window of its own (`allowsDetach` is false).
    case .paneDetached, .paneRestoredDetached, .paneDocked, .paneRaiseRequested,
      .paneWindowToggleRequested:
      break
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

  /// No pane moves to a window of its own (`allowsDetach` is false).
  func togglePaneWindow(_ tabID: TerminalTab.ID, targetID: TerminalTarget.ID) {}

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

  func openFilePreview(path: String, for target: TerminalTarget) {
    _ = terminals.openFilePreview(FileDescriptor(path: path, isPreview: true), for: target)
  }

  func openDiffTabFile(_ descriptor: DiffDescriptor, for target: TerminalTarget) {
    AppStore.openWorkroomFile(relativePath: descriptor.path, for: target)
  }

  /// The Files inspector's ⌘-click, which acts on a window's selected workroom; it has none.
  func openFileInEditor(path: String) {}

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
    runCommand.startInvestigate(
      bannerState: bannerState, target: target, surface: surface,
      codingAgentSetting: Defaults[.terminalCodingAgentBackend])
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

  /// "Move to Workroom" for its pane `tabID`, over every workroom open in `windows`.
  func quickTerminalPaneWorkroomChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget,
    windows: [AppStore] = WindowRegistry.shared.allStores
  ) -> [PaneWorkroomGroup] {
    QuickTerminalPaneMove.choices(
      tabID, of: target, source: terminals, notifications: notifications, windows: windows)
  }

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

  // MARK: PaneNotifierHost

  var isHostWindowKey: Bool { hostWindow?.isKeyWindow == true }

  var primaryTargetID: TerminalTarget.ID? { target.id }

  /// Its target is its window's only one.
  func onScreenTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget? {
    target.id == targetID ? target : nil
  }

  /// No pane is popped out into a window of its own.
  func detachedWindowIsKey(forTab tabID: TerminalTab.ID) -> Bool? { nil }

  /// The origin line under an alert's title: its target's name.
  func placeSource(targetID: TerminalTarget.ID) -> String {
    targetID == target.id ? "Quick Terminal" : ""
  }
}
