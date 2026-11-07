import SwiftUI
import WorkroomVCS

/// What a pane's views ask of the window hosting them: its tabs' flows (new, close, content tabs,
/// Investigate), the run-tab menu's queries, the Quick Terminal's "Move to Workroom" choices and the
/// toasts. Queries and actions only, so a host need not be a whole window's `AppStore`.
///
/// The pane views read it from the environment (`\.paneHost`), since `@EnvironmentObject` needs a
/// concrete type. A host that is `@Observable` keeps its views' Observation as it was: a property
/// read through the protocol registers in the property's own getter, as a read through the class
/// does.
@MainActor
protocol PaneHost: AnyObject, Sendable {
  // MARK: Panes

  /// The window's panes. The pane views already hold them as a parameter; the detached-sessions
  /// button reads them through the host.
  var terminals: TerminalPanes { get }
  /// The targets whose host is being asked for their layout, which open no terminal meanwhile.
  var waitingForHostLayout: Set<TerminalTarget.ID> { get }
  func ensureInitialTerminal(for target: TerminalTarget)
  func newTerminal(in target: TerminalTarget)
  func whenHostLayoutRestored(_ target: TerminalTarget, _ open: @escaping (TerminalTarget) -> Void)
  func togglePaneWindow(_ tabID: TerminalTab.ID, targetID: TerminalTarget.ID)

  // MARK: Closing tabs

  func requestCloseTerminalTab(_ tabID: TerminalTab.ID, for target: TerminalTarget)
  func requestCloseOtherTerminalTabs(_ keepID: TerminalTab.ID, for target: TerminalTarget)
  func requestCloseAllTerminalTabs(for target: TerminalTarget)

  // MARK: Content tabs

  /// The find model the window's file, diff and changeset panes share.
  var contentFind: FileFindModel { get }
  /// Diffs and file contents with no repository behind them (`AppServices.cannedDiffs`).
  var cannedDiffs: AppServices.CannedDiffs? { get }
  /// A repository on this Mac read directly (`AppServices.vcsReader`).
  var vcsReader: (@Sendable (URL) throws -> LocalVCSProviding)? { get }
  func openFilePreview(path: String, for target: TerminalTarget)
  func openDiffTabFile(_ descriptor: DiffDescriptor, for target: TerminalTarget)
  func openFileInEditor(path: String)
  func selectChangesetFile(_ path: String?, tab tabID: TerminalTab.ID, in target: TerminalTarget)

  // MARK: Status bar and coding agent

  func branchLabel(for target: TerminalTarget) -> String?
  /// An Investigate tab for a diagnosis (`AppStore.startInvestigate`).
  @discardableResult
  func investigate(
    _ bannerState: CodingAgentBannerState, in target: TerminalTarget,
    surface: GhosttySurfaceView?
  ) -> TerminalTab

  // MARK: The run tab's menu

  func runTabID(for targetID: TerminalTarget.ID) -> TerminalTab.ID?
  func isRunBlocked(_ targetID: TerminalTarget.ID) -> Bool
  /// Whether `target`'s project has a run command configured.
  func hasRunCommand(for target: TerminalTarget) -> Bool
  func isRunCommandRunning(for targetID: TerminalTarget.ID) -> Bool
  func runOrFocusRunCommand(for target: TerminalTarget)
  func restartRunCommand(for target: TerminalTarget)
  func stopRunCommand(for target: TerminalTarget)

  // MARK: The Quick Terminal

  func quickTerminalPaneWorkroomChoices(
    _ tabID: TerminalTab.ID, of target: TerminalTarget, windows: [AppStore]
  ) -> [PaneWorkroomGroup]

  // MARK: Toasts

  var toasts: [WorkroomNotification] { get }
  func dismissToast(_ id: UUID)
  var runToastItems: [RunCommandController.RunToastItem] { get }
  func openRunToast(for targetID: TerminalTarget.ID)
  var vcsToolWarnings: [VCSToolVersions.ToolWarning] { get }
  func dismissToolWarning(tool: String)
  func notificationSource(forTargetID id: TerminalTarget.ID) -> String
}

private struct PaneHostKey: EnvironmentKey {
  static var defaultValue: (any PaneHost)? { nil }
}

extension EnvironmentValues {
  /// The window hosting the panes below. Every root that renders pane views injects one
  /// (`View.paneHost(_:)`); reading it with none traps, as a missing `@EnvironmentObject` does, so a
  /// root that forgot fails where it renders instead of leaving its buttons doing nothing.
  ///
  /// Read-only, with the injection going through `injectedPaneHost`: a write through a writable key
  /// path reads the property first, so a trapping getter on a writable one traps on every injection.
  var paneHost: any PaneHost {
    guard let host = injectedPaneHost else {
      preconditionFailure("No pane host: inject one with .paneHost(_:) at this tree's root")
    }
    return host
  }

  fileprivate var injectedPaneHost: (any PaneHost)? {
    get { self[PaneHostKey.self] }
    set { self[PaneHostKey.self] = newValue }
  }
}

extension View {
  /// Gives the pane views below `host` as the window hosting them.
  func paneHost(_ host: any PaneHost) -> some View {
    environment(\.injectedPaneHost, host)
  }
}
