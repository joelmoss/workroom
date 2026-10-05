import Foundation
import WorkroomSessionProtocol

/// A window's state for the remote workrooms whose layouts their hosts keep (#255,
/// `docs/designs/oq8-cross-machine-reattach.md`).
struct HostLayoutState {
  /// Asked its host, not answered yet: no fresh pane opens meanwhile (D4).
  var fetching: Set<TerminalTarget.ID> = []
  /// Answered, or given up on, this launch: never asked again until the next.
  var fetched: Set<TerminalTarget.ID> = []
  /// Given up on: the host did not answer in time. Its layout was never read this launch, so a
  /// write goes in only if the host still holds the revision this Mac last saw, and is never
  /// retried past a refusal or marked stale: it must not replace a layout this Mac never saw.
  var unanswered: Set<TerminalTarget.ID> = []
  /// Opened while the host was being asked (a tab, a file, a diff), run once its layout is
  /// restored: a tab there first would stop the restore, and its write replace the host's layout.
  var heldOpens: [TerminalTarget.ID: [() -> Void]] = [:]
  /// A new terminal is among `heldOpens`: asking again while waiting opens no second one.
  var heldNewTerminal: Set<TerminalTarget.ID> = []
  /// Showing on screen while its host was asked: opens its first pane once it has answered.
  var waitingForFirstTab: Set<TerminalTarget.ID> = []
  /// The host revision this window last read or wrote.
  var revisions: [TerminalTarget.ID: UInt64] = [:]
  /// This window's layout has not reached the host (`TargetSession.hostLayoutStale`).
  var stale: Set<TerminalTarget.ID> = []
  /// Never written this launch: the host's layout is from a newer build (D5), or the host keeps no
  /// layouts.
  var readOnly: Set<TerminalTarget.ID> = []
  /// The layout as the host last had it, encoded, so an unchanged one is never written again.
  var written: [TerminalTarget.ID: String] = [:]
  /// A write to the host is in flight: the next waits for it rather than race it, and a quit waits
  /// for it (D14).
  var writing: [TerminalTarget.ID: Task<Void, Never>] = [:]
}

/// Which window on this Mac keeps each remote workroom's layout on its host (D10). Two windows can
/// show one workroom; only the first to show it this launch restores the host's layout and writes
/// it, so they never take turns overwriting it. Once that window closes or has no tabs left for the
/// workroom, the next window to open the workroom afresh takes over; one already showing it does
/// not (TODOS).
@MainActor
final class HostLayoutOwners {
  static let shared = HostLayoutOwners()

  private struct Owner {
    weak var store: AppStore?
    let targetID: TerminalTarget.ID
  }
  private var owners: [UUID: Owner] = [:]

  /// Whether `store` keeps `workroom`'s layout, claiming it if nobody else holds it.
  func claim(_ workroom: UUID, targetID: TerminalTarget.ID, by store: AppStore) -> Bool {
    if let owner = owners[workroom], let current = owner.store, current !== store,
      current.hostLayouts.fetching.contains(owner.targetID)
        || current.terminals.tabCount(forTargetID: owner.targetID) > 0
    {
      return false
    }
    owners[workroom] = Owner(store: store, targetID: targetID)
    return true
  }

  func owns(_ workroom: UUID, _ store: AppStore) -> Bool { owners[workroom]?.store === store }
}

extension AppStore {
  /// How long a remote workroom waits for its host's layout before restoring this Mac's own copy
  /// (D4). The connect is inside it, so a host that is slow to answer never blanks the workroom.
  static let hostLayoutTimeout: TimeInterval = 5

  /// Where a host's layouts are read and written: its agent, or a fake in a test.
  nonisolated(unsafe) static var hostLayoutStore:
    @Sendable (HostID) async throws -> HostLayoutStore =
      { try await HostConnectionManager.shared.layouts(host: $0) }

  /// Asks `target`'s host for its layout and sessions, unless this launch has already asked or
  /// another window keeps the workroom's layout, and says whether `target` is now waiting on that
  /// answer: if so, the caller opens no pane, and `applyHostLayout` restores what was chosen.
  ///
  /// Only for a reachable remote workroom with its own id: one recorded before workroom ids has no
  /// key a host could keep its layout under, and restores from this Mac alone.
  @discardableResult
  func fetchHostLayoutIfNeeded(for target: TerminalTarget) -> Bool {
    guard let host = target.remoteHost, let workroom = target.remoteWorkroomID else { return false }
    if hostLayouts.fetching.contains(target.id) { return true }
    guard !hostLayouts.fetched.contains(target.id),
      terminals.tabCount(forTargetID: target.id) == 0,
      HostLayoutOwners.shared.claim(workroom, targetID: target.id, by: self)
    else { return false }
    hostLayouts.fetching.insert(target.id)
    waitingForHostLayout.insert(target.id)
    let held = deferredTargetSessions[target.id]
    let key = workroom.uuidString
    let targetID = target.id
    Task { [weak self] in
      let outcome: Result<(HostLayoutResolution, [SessionDescriptor]), Error>
      do {
        outcome = .success(
          try await withTimeout(seconds: Self.hostLayoutTimeout) {
            try await RemoteHosts.shared.ensureConnected(.remote(host))
            let store = try await Self.hostLayoutStore(.remote(host))
            let resolution = try await HostLayoutSync.resolve(
              held: held, key: key, targetID: targetID, store: store)
            let sessions =
              (try? await HostConnectionManager.shared.sessions(on: .remote(host))) ?? []
            return (resolution, sessions)
          })
      } catch {
        outcome = .failure(error)
      }
      self?.applyHostLayout(
        outcome, for: targetID, host: host, workroom: workroom, held: held, key: key)
    }
    return true
  }

  /// Restores what `fetchHostLayoutIfNeeded` chose, or this Mac's own copy when the host did not
  /// answer in time, has no Layout service, or keeps no layouts, then opens what was held meanwhile.
  private func applyHostLayout(
    _ outcome: Result<(HostLayoutResolution, [SessionDescriptor]), Error>,
    for targetID: TerminalTarget.ID, host: UUID, workroom: UUID, held: TargetSession?, key: String
  ) {
    hostLayouts.fetching.remove(targetID)
    waitingForHostLayout.remove(targetID)
    let heldOpens = hostLayouts.heldOpens.removeValue(forKey: targetID) ?? []
    hostLayouts.heldNewTerminal.remove(targetID)
    // A reload while the host was asked can destroy the workroom's host (`remoteHost` is then
    // nil) or give it another: an answer from the one asked is not the workroom's now. Nothing of
    // it is applied, what was opened meanwhile was for a workroom that has gone, and this Mac's
    // copy stays held, to be restored or asked for again as the workroom now is.
    guard let target = terminalTarget(forID: targetID), target.remoteHost == host,
      target.remoteWorkroomID == workroom
    else {
      hostLayouts.waitingForFirstTab.remove(targetID)
      return
    }
    hostLayouts.fetched.insert(targetID)
    deferredTargetSessions.removeValue(forKey: targetID)
    var session = held
    // What is restored is what the host holds: once it is on screen, that is what `written` is,
    // since a restore mints new tab keys and an earlier encoding would never match a capture.
    var hostHasIt = false
    switch outcome {
    case .success((let resolution, let sessions)):
      hostLayouts.revisions[targetID] = resolution.revision
      if resolution.stale {
        hostLayouts.stale.insert(targetID)
      } else {
        hostLayouts.stale.remove(targetID)
      }
      if resolution.readOnly { hostLayouts.readOnly.insert(targetID) }
      // What the host now holds, as written: an unchanged layout is never written back.
      if !resolution.stale {
        hostLayouts.written[targetID] = resolution.session.flatMap {
          try? HostLayout.encode($0, key: key)
        }
      }
      // A session the layout does not name comes back as a tab (premise 3); the append is an
      // ordinary change, written through with the next save.
      session = HostLayoutSync.appending(
        sessions, key: key, to: resolution.session, targetID: targetID)
      hostHasIt = !resolution.stale && session == resolution.session
    case .failure(let error):
      // Kept as this Mac had them, for the next launch, whatever this one can do.
      hostLayouts.revisions[targetID] = held?.hostRevision
      let keepsNoLayouts: Bool
      switch error {
      case AgentLayoutError.unsupported, VCSError.backendVersion: keepsNoLayouts = true
      default: keepsNoLayouts = false
      }
      if keepsNoLayouts {
        // The host keeps no layouts, or its agent predates them: nothing to write to.
        hostLayouts.readOnly.insert(targetID)
      }
      if held?.hostLayoutStale == true {
        // This Mac's copy is newer than the host's, as far as it knows: it stays marked so, and
        // wins at the next open, where the host's layout is read first.
        hostLayouts.stale.insert(targetID)
      }
      if !keepsNoLayouts {
        // Either way the host's layout was not read: no write may replace it unseen.
        hostLayouts.unanswered.insert(targetID)
        // The host had this copy when this Mac last saw it, unless this Mac's is newer.
        hostHasIt = held?.hostLayoutStale != true
      }
    }
    if terminals.tabCount(forTargetID: targetID) > 0 {
      // Something opened a tab without being held: the host's layout is not on screen, so this
      // window must not write over it this launch.
      hostLayouts.readOnly.insert(targetID)
    } else if let session {
      terminals.restore(session, for: target)
      refreshSelectionHasTabs()
      if hostHasIt,
        let shown = captureWindowSession().targets.first(where: { $0.targetID == targetID })
      {
        hostLayouts.written[targetID] = try? HostLayout.encode(shown, key: key)
      }
    }
    for open in heldOpens { open() }
    markSessionDirty()
    if hostLayouts.waitingForFirstTab.remove(targetID) != nil {
      ensureInitialTerminal(for: target)
      terminals.reconcileOcclusion(for: target)
    }
  }

  /// Writes each remote workroom whose layout this window keeps, and that has changed since its host
  /// last had it, through to the host: the whole snapshot, the last Mac to write winning (D9). Called
  /// after each save. Returns the writes started, for a quit to wait on.
  ///
  /// A workroom whose last tab was closed is written as an empty layout (D11), but only over a
  /// layout the host had: a workroom this Mac opened with nothing, and nothing on the host, is not
  /// "closed", it is about to get its first pane. One whose host answered with a newer build's
  /// layout is never written over (D5), and nothing is written before the host has answered.
  @discardableResult
  func writeHostLayouts() -> [Task<Void, Never>] {
    var started: [Task<Void, Never>] = []
    for (targetID, host, key, layout, blob) in changedHostLayouts()
    where hostLayouts.writing[targetID] == nil {
      let expected = hostLayouts.revisions[targetID] ?? 0
      let attempts = hostLayouts.unanswered.contains(targetID) ? 1 : 3
      let write = Task { [weak self] in
        let result: HostLayoutResolution
        // The service connection can drop while the panes' own links stay up: bring it back.
        try? await RemoteHosts.shared.ensureConnected(.remote(host))
        if let store = try? await Self.hostLayoutStore(.remote(host)) {
          result = await HostLayoutSync.write(
            layout, key: key, expected: expected, store: store, attempts: attempts)
        } else {
          result = HostLayoutResolution(session: layout, revision: expected, stale: true)
        }
        self?.finishHostWrite(result, targetID: targetID, blob: blob)
      }
      hostLayouts.writing[targetID] = write
      started.append(write)
    }
    return started
  }

  /// Each remote workroom whose layout this window keeps and may write, and that has changed since
  /// its host last had it, with what would be written.
  private func changedHostLayouts() -> [(
    targetID: TerminalTarget.ID, host: UUID, key: String, layout: TargetSession, blob: String
  )] {
    guard !hostLayouts.fetched.isEmpty else { return [] }
    let captured = Dictionary(
      captureWindowSession().targets.map { ($0.targetID, $0) },
      uniquingKeysWith: { first, _ in first })
    return hostLayouts.fetched.filter { !hostLayouts.readOnly.contains($0) }.compactMap {
      targetID in
      guard let target = terminalTarget(forID: targetID), let host = target.remoteHost,
        let workroom = target.remoteWorkroomID,
        HostLayoutOwners.shared.owns(workroom, self)
      else { return nil }
      let key = workroom.uuidString
      let layout: TargetSession
      if let current = captured[targetID] {
        layout = current
      } else if hostLayouts.written[targetID] != nil {
        layout = TargetSession(targetID: targetID, tabs: [])
      } else {
        return nil
      }
      guard let blob = try? HostLayout.encode(layout, key: key),
        blob != hostLayouts.written[targetID]
      else { return nil }
      return (targetID, host, key, layout, blob)
    }
  }

  private func finishHostWrite(
    _ result: HostLayoutResolution, targetID: TerminalTarget.ID, blob: String
  ) {
    hostLayouts.writing.removeValue(forKey: targetID)
    if result.readOnly {
      // Another Mac wrote a newer build's layout first: never written over (D5).
      hostLayouts.readOnly.insert(targetID)
      return
    }
    if hostLayouts.unanswered.contains(targetID) {
      // Not written: the host moved past what this Mac saw, or could not be reached. Its layout is
      // left alone, and this Mac's copy is not marked as winning. A refused layout is not sent
      // again until it changes; one that did not reach the host is tried again at the next save.
      guard !result.stale else {
        if result.refused { hostLayouts.written[targetID] = blob }
        // A change saved while this one was in flight was skipped for it, and nothing here marks
        // the session dirty to send it later: send it now. Only one that differs from what was
        // just tried, so a host that cannot be reached is not asked again in a loop.
        if changedHostLayouts().contains(where: { $0.targetID == targetID && $0.blob != blob }) {
          writeHostLayouts()
        }
        return
      }
      hostLayouts.unanswered.remove(targetID)
    }
    hostLayouts.revisions[targetID] = result.revision
    if result.stale {
      hostLayouts.stale.insert(targetID)
    } else {
      hostLayouts.stale.remove(targetID)
      hostLayouts.written[targetID] = blob
    }
    // The revision and stale mark are this Mac's to remember, in session.json.
    markSessionDirty()
  }

  /// At quit (D14): every window's changed layouts go to their hosts, waited on for at most
  /// `budget`, writes already in flight included, and then whatever changed while those were in
  /// flight. A write still in flight then is marked stale, so the session written next keeps it as
  /// this Mac's newer copy, which wins at the next open and is written then.
  static func flushHostLayouts(
    budget: TimeInterval, stores: [AppStore]? = nil
  ) async {
    let stores = stores ?? WindowRegistry.shared.allStores
    guard stores.contains(where: { !$0.hostLayouts.fetched.isEmpty }) else { return }
    _ = try? await withTimeout(seconds: budget) { @MainActor in
      // Every write starts at once; then a workroom whose earlier write was in flight goes again.
      _ = stores.flatMap { $0.writeHostLayouts() }
      for write in stores.flatMap({ $0.hostLayouts.writing.values }) { await write.value }
      guard !Task.isCancelled else { return }
      for write in stores.flatMap({ $0.writeHostLayouts() }) { await write.value }
    }
    // Still in flight, or changed behind one that was and never sent: either way not on the host.
    for store in stores {
      let unsent = Set(store.hostLayouts.writing.keys)
        .union(store.changedHostLayouts().map(\.targetID))
      store.hostLayouts.stale.formUnion(unsent.subtracting(store.hostLayouts.unanswered))
    }
  }

  /// Runs `open` now, or, while `targetID`'s host is being asked for its layout, once that layout
  /// is restored (D4).
  func whenHostLayoutRestored(_ targetID: TerminalTarget.ID, _ open: @escaping () -> Void) {
    guard hostLayouts.fetching.contains(targetID) else { return open() }
    hostLayouts.heldOpens[targetID, default: []].append(open)
  }

  /// A new terminal in `target` (⌘T, New Terminal, +). While its host is asked for its layout, one
  /// is held however often it is asked for: a user clicking again on a pane that has not opened yet
  /// wants that one terminal, not one per click once the host answers.
  func newTerminal(in target: TerminalTarget) {
    if hostLayouts.fetching.contains(target.id) {
      guard hostLayouts.heldNewTerminal.insert(target.id).inserted else { return }
    }
    whenHostLayoutRestored(target.id) { [terminals] in _ = terminals.addTab(for: target) }
  }

  /// `captured` with this window's record of its host's copy, for `session.json`.
  func withHostLayoutState(_ captured: TargetSession) -> TargetSession {
    var target = captured
    target.hostRevision = hostLayouts.revisions[captured.targetID]
    target.hostLayoutStale = hostLayouts.stale.contains(captured.targetID) ? true : nil
    return target
  }
}
