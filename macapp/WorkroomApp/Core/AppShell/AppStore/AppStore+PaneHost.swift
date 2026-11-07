import Foundation
import WorkroomVCS

/// A window's store hosts its panes. Most of `PaneHost` is the store's own members; these are the
/// ones the pane views used to reach through one of its owners, each making the same reads they did.
extension AppStore: PaneHost {
  var cannedDiffs: AppServices.CannedDiffs? { services.cannedDiffs }
  var vcsReader: (@Sendable (URL) throws -> LocalVCSProviding)? { services.vcsReader }

  @discardableResult
  func investigate(
    _ bannerState: CodingAgentBannerState, in target: TerminalTarget,
    surface: GhosttySurfaceView?
  ) -> TerminalTab {
    runCommand.startInvestigate(bannerState: bannerState, target: target, surface: surface)
  }

  func runTabID(for targetID: TerminalTarget.ID) -> TerminalTab.ID? {
    runCommand.runTabID(for: targetID)
  }

  func isRunBlocked(_ targetID: TerminalTarget.ID) -> Bool { lifecycle.isRunBlocked(targetID) }

  func hasRunCommand(for target: TerminalTarget) -> Bool {
    project(forTargetID: target.id).map { runCommands.hasRunCommand(forProject: $0.path) } ?? false
  }

  func isRunCommandRunning(for targetID: TerminalTarget.ID) -> Bool {
    runCommand.isRunCommandRunning(for: targetID)
  }

  func stopRunCommand(for target: TerminalTarget) { runCommand.stopRunCommand(for: target) }
}
