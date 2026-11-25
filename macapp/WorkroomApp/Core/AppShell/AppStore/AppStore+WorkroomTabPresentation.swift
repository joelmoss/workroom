import Foundation
import WorkroomDomain
import WorkroomVCS

/// What a workroom tab shows, wherever it is drawn: its title-bar chip (`WorkroomTabChip`) and its
/// Open section row (#819) read these, so the two cannot drift.
extension AppStore {
  func workroomTabPresentation(sid: SidebarID, target: TerminalTarget) -> WorkroomTabPresentation {
    let primaryLabel: String
    var workroomName: String?
    switch sid {
    case .workroom(let project, let name):
      primaryLabel = (project as NSString).lastPathComponent
      // The display label when one is set (issue #41).
      workroomName = displayName(forWorkroom: name, inProject: project)
    case .root(let project), .project(let project), .creation(let project, _):
      primaryLabel = (project as NSString).lastPathComponent
    case .standalone, .terminalGroup:
      // A standalone terminal's tab is its terminal's name, a group's its own (ADR 0077).
      primaryLabel = target.title
    }
    let glyph: String
    switch sid {
    case .root: glyph = "house"
    case .standalone, .terminalGroup: glyph = sid.terminalsGlyph ?? TerminalGroup.glyph
    case .project, .workroom, .creation: glyph = target.workroomGlyph
    }
    var standaloneTitle: TerminalTitle?
    if case .standalone = sid, let id = sid.targetID {
      standaloneTitle = terminalsSection.terminalTitles(of: id).first
    }
    return WorkroomTabPresentation(
      glyph: glyph, primaryLabel: primaryLabel, workroomName: workroomName,
      standaloneTitle: standaloneTitle,
      // Nil while a create's run lasts (#483): it has no terminals to close then.
      closeName: lifecycle.isCreationBlocking(target.id) ? nil : workroomName ?? primaryLabel)
  }

  func workroomTabMarks(sid: SidebarID, target: TerminalTarget) -> WorkroomTabMarks {
    let id = target.id
    let run: WorkroomTabMarks.Run? =
      runCommand.runTabID(for: id) == nil
      ? nil
      : runCommand.isRunCommandRunning(for: id)
        ? .running : runCommand.runFailed(for: id) ? .failed : nil
    // One line at a time: waiting, then a stopped error, then a working command.
    let busy: PaneIndicator =
      terminals.needsAttention(forTargetID: id)
      ? .blocked
      : terminals.hasProgramError(forTargetID: id)
        ? .error
        : terminals.isRunning(forTargetID: id)
          ? .running(failed: terminals.isProgressFailed(forTargetID: id)) : .none
    return WorkroomTabMarks(
      vcs: vcsStatus.workroomStatuses[sid] ?? .unresolved,
      unavailability: target.terminalUnavailability,
      hasUnread: notifications.count(target: id) > 0,
      waitingCount: terminals.blockedTerminalCount(forTargetID: id),
      waitingStale: terminals.isWaitingStale(forTargetID: id),
      reportedError: terminals.isProgressFailed(forTargetID: id)
        || terminals.hasProgramError(forTargetID: id),
      busy: busy, run: run)
  }
}

/// A workroom tab's names and glyph.
struct WorkroomTabPresentation: Equatable {
  /// A house for a project root, a terminal or a group's glyph, else the workroom's.
  let glyph: String
  /// The project name, or a standalone terminal's or group's title.
  let primaryLabel: String
  /// A workroom's own name (its display label), drawn after the project's; nil for anything else.
  let workroomName: String?
  /// A standalone terminal's title in its parts, so its folder can fade; nil for anything else.
  let standaloneTitle: TerminalTitle?
  /// The name Close asks about; nil while a create's run lasts, which nothing closes.
  let closeName: String?

  /// The full, untruncated title.
  var fullTitle: String { WorkroomLabel(project: primaryLabel, workroom: workroomName).full }
}

/// A workroom tab's state marks.
struct WorkroomTabMarks: Equatable {
  enum Run: Equatable { case running, failed }

  /// Tints the glyph with the VCS dirty state.
  let vcs: WorkroomStatus
  /// Why it can't open terminals, shown as a warning.
  let unavailability: TerminalTarget.Unavailability?
  /// Unread notifications: the title takes the accent.
  let hasUnread: Bool
  /// How many of its terminals wait on the user (the blocked glyph).
  let waitingCount: Int
  let waitingStale: Bool
  /// A terminal reported an error (OSC 9;4 ERROR or a stopped program).
  let reportedError: Bool
  /// The one base line it shows: `.blocked`, `.error`, `.running(failed:)` or `.none`.
  let busy: PaneIndicator
  /// The run command's state, when it has a run tab and it is running or failed.
  let run: Run?

  var isWaiting: Bool { waitingCount > 0 }
}
