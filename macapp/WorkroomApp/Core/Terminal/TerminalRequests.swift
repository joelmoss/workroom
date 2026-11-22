import DaemonConnection
import Foundation
import HostDrivers
import OSLog
import WorkroomDomain

/// A window, or the Quick Terminal's panel: a holder of terminal tabs that `workroom new` and
/// `workroom close` (#693) can be asked of.
@MainActor
protocol TerminalRequestHolder: AnyObject {
  var terminals: TerminalPanes { get }
  func terminalTarget(forID targetID: TerminalTarget.ID) -> TerminalTarget?
  /// Whether `targetID`'s panes are on screen in this holder: its window is shown and not
  /// minimised, and the target is the one it shows, or beside it in a workroom split.
  func isShowingTarget(_ targetID: TerminalTarget.ID) -> Bool
  /// Whether this holder's window is the key window.
  var isKeyHolder: Bool { get }
  /// Shows session `session` beside the caller's tab `caller`, in `target`, the caller's target
  /// when it was asked: as a split on `edge` when one is given, else as a tab; named `label` when
  /// given. Focus stays where it is. `unplaced` when it can't be shown after all (the caller's tab
  /// has gone, or its standalone terminal couldn't become a group), so it is never dropped.
  func showRequestedSession(
    _ session: UUID, label: String?, caller: TerminalTab.ID, in target: TerminalTarget,
    split edge: PaneEdge?, unplaced: @escaping () -> Void)
  /// Closes tab `tabID` of `target`, whose session `workroom close` ended: no confirmation, as
  /// the shell has already gone, and through the close path every tab takes, so a run tab and a
  /// terminal group are closed as the user's own close would close them.
  func closeRequestedTab(_ tabID: TerminalTab.ID, in target: TerminalTarget)
}

extension TerminalRequestHolder {
  /// The pane `showRequestedSession` opens once its target can take it: a split beside `anchor`
  /// on `edge` when both are given and the anchor can be halved, else a tab at the strip's end;
  /// named `label` when given, as a tab the user renamed is. Focus stays where it was, so the
  /// agent that asked keeps the user's keyboard.
  @discardableResult
  func openRequestedPane(
    _ session: UUID, label: String?, in target: TerminalTarget, beside anchor: TerminalTab.ID?,
    on edge: PaneEdge?
  ) -> TerminalTab {
    let split = anchor.flatMap { anchor in
      edge.flatMap { edge in
        terminals.openSplit(sessionID: session, beside: anchor, on: edge, for: target)
      }
    }
    let tab = split ?? terminals.addTab(for: target, sessionID: session, focus: false)
    // Its session's label, which the daemon has: not told back (#694).
    if let label { terminals.applySessionLabel(label, forTab: tab.id, in: target) }
    // The waiting list counts only sessions an open pane shows.
    WindowRegistry.shared.recomputeBadge()
    return tab
  }
}

/// What this Mac does with a `workroom new` (#693), decided from what the daemon asked
/// (`TerminalOpenRequest`) and where this Mac holds the asking session's pane.
enum TerminalOpenPlan: Equatable {
  /// A split beside the caller's tab, on `edge`, in holder `holder`'s `target`.
  case split(holder: Int, target: TerminalTarget.ID, beside: TerminalTab.ID, edge: PaneEdge)
  /// A tab in holder `holder`'s `target`, the caller's, whose tab is `caller`.
  case tab(holder: Int, target: TerminalTarget.ID, caller: TerminalTab.ID)
  /// Nothing opens here: the session is listed with the detached sessions of its workroom.
  case detached
}

/// One tab of this Mac attached to the session that asked for a `workroom new`.
struct TerminalOpenPlacement: Equatable {
  /// Which holder (window, or the Quick Terminal) holds it, by its place in the holders' list.
  let holder: Int
  let target: TerminalTarget.ID
  let tab: TerminalTab.ID
  /// Whether the tab is on screen: its holder shows its target and the tab is in the visible
  /// layout (its split, or the focused tab).
  let onScreen: Bool
  /// Whether its holder's window is the key window.
  let key: Bool
  /// Whether it is popped out into a window of its own, where no split can go.
  let poppedOut: Bool
}

/// The rule `workroom new` follows on every Mac that hears it (#693): only the Mac the daemon
/// named (`hostname`, its choice of the caller's panes, so every Mac reads the same answer)
/// opens the session, and only when it holds the caller's pane; every other Mac, and that one when
/// it holds none, lists it as detached. Of the caller's tabs here, the one on screen is used, the
/// key window's first; failing that, the first held. It opens as a split beside it when a split
/// was asked and that tab is on screen in its strip, else as a tab of its target.
enum TerminalOpenRule {
  static func plan(
    _ request: TerminalOpenRequest, thisMac: String?, placements: [TerminalOpenPlacement]
  ) -> TerminalOpenPlan {
    guard request.by != nil, let asked = request.hostname, let thisMac, asked == thisMac else {
      return .detached
    }
    let chosen =
      placements.first { $0.onScreen && $0.key }
      ?? placements.first(where: \.onScreen)
      ?? placements.first
    guard let chosen else { return .detached }
    if let split = request.split, chosen.onScreen, !chosen.poppedOut {
      return .split(
        holder: chosen.holder, target: chosen.target, beside: chosen.tab,
        edge: split == .right ? .right : .bottom)
    }
    return .tab(holder: chosen.holder, target: chosen.target, caller: chosen.tab)
  }
}

/// What the app does with the requests `workroom new` and `workroom close` make (#693), heard on
/// each host's terminal API events (`PaneTypingMonitor`'s subscription): opens the new session as
/// a tab or a split where `TerminalOpenRule` says, or reads its workroom's detached list again so
/// it shows there; and closes every tab, in every window, of a session `close` ended.
@MainActor
final class TerminalRequests {
  static let shared = TerminalRequests()

  /// Every holder of tabs: each window's store, then the Quick Terminal's host. A seam for tests.
  var holders: () -> [any TerminalRequestHolder] = {
    let registry = WindowRegistry.shared
    let windows: [any TerminalRequestHolder] = registry.allStores
    guard let quick = registry.quickTerminal?.host else { return windows }
    return windows + [quick]
  }
  /// This Mac's name as its panes' attaches give it to a daemon (#688). A seam for tests.
  var thisMac: () -> String? = { SSHTransport.macHostname }
  /// A test's answer in place of `readDetachedAgain`'s reads; nil reads them.
  var refreshDetached: ((HostID, String?) -> Void)?

  /// Reads the detached list again of every target of `host` tagged `workroom`
  /// (`detachedListTargets`), so a session no pane here shows is offered there at once.
  private func readDetachedAgain(_ host: HostID, _ workroom: String?) {
    if let refreshDetached { return refreshDetached(host, workroom) }
    for (target, owned) in Self.detachedListTargets(
      host: host, workroom: workroom, in: holders())
    {
      Task { await DetachedSessionList.shared.refresh(target, ownedSessionIDs: owned) }
    }
  }

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "terminal-requests")

  /// One request from `host`'s daemon.
  func handle(_ event: TerminalInputEvent, from host: HostID) {
    switch event {
    case .opened(let request): open(request, from: host)
    case .closed(let session): close(session)
    case .input, .labelled, .listed, .lost: break
    }
  }

  /// Where this Mac's holders have tabs attached to `session`, as `TerminalOpenRule` reads them.
  func placements(of session: UUID, in holders: [any TerminalRequestHolder])
    -> [TerminalOpenPlacement]
  {
    holders.enumerated().flatMap { index, holder in
      holder.terminals.attachments(of: session).map { attachment in
        let detached = holder.terminals.detachedTabIDs.contains(attachment.tab)
        let shown =
          holder.terminalTarget(forID: attachment.target).map {
            holder.terminals.visibleTabIDs(for: $0).contains(attachment.tab)
          } ?? false
        return TerminalOpenPlacement(
          holder: index, target: attachment.target, tab: attachment.tab,
          onScreen: shown && (detached || holder.isShowingTarget(attachment.target)),
          key: holder.isKeyHolder, poppedOut: detached)
      }
    }
  }

  private func open(_ request: TerminalOpenRequest, from host: HostID) {
    let holders = holders()
    let placements = request.by.map { placements(of: $0, in: holders) } ?? []
    let plan = TerminalOpenRule.plan(request, thisMac: thisMac(), placements: placements)
    let unplaced = { [weak self] in self?.readDetachedAgain(host, request.workroom) ?? () }
    switch plan {
    case .detached:
      unplaced()
    case .tab(let index, let targetID, let caller):
      guard let target = holders[index].terminalTarget(forID: targetID) else { return unplaced() }
      holders[index].showRequestedSession(
        request.session, label: request.label, caller: caller, in: target, split: nil,
        unplaced: unplaced)
    case .split(let index, let targetID, let anchor, let edge):
      guard let target = holders[index].terminalTarget(forID: targetID) else { return unplaced() }
      holders[index].showRequestedSession(
        request.session, label: request.label, caller: anchor, in: target, split: edge,
        unplaced: unplaced)
    }
    Self.logger.info(
      "new: \(request.session.uuidString, privacy: .public) \(String(describing: plan), privacy: .public)"
    )
  }

  private func close(_ session: UUID) {
    for holder in holders() {
      for attachment in holder.terminals.attachments(of: session) {
        guard let target = holder.terminalTarget(forID: attachment.target) else { continue }
        holder.closeRequestedTab(attachment.tab, in: target)
      }
    }
  }

  /// The targets whose detached lists `refreshDetached` reads again, each with the sessions its
  /// holder's tabs own: every holder's targets on `host` tagged `workroom`; for a session with no
  /// workroom (a `new` from no pane), every one whose list offers such sessions
  /// (`DetachedSessionList.offersUnscoped`).
  static func detachedListTargets(
    host: HostID, workroom: String?, in holders: [any TerminalRequestHolder]
  ) -> [(TerminalTarget, Set<UUID>)] {
    holders.flatMap { holder in
      holder.terminals.activeTargetIDs.compactMap { id -> (TerminalTarget, Set<UUID>)? in
        guard let target = holder.terminalTarget(forID: id), target.hostID == host else {
          return nil
        }
        let listed =
          workroom.map { target.sessionWorkroomKey == $0 }
          ?? DetachedSessionList.offersUnscoped(target)
        guard listed else { return nil }
        return (target, holder.terminals.ownedSessionIDs(for: target))
      }
    }
  }
}
