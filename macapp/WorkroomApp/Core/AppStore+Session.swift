import AppKit
import Foundation

/// What one window contributes to the saved session (issue #46). `SessionCoordinator` decides when
/// this runs; `SessionStore` owns the file.
///
/// Capture reads only through existing public queries plus the one new
/// `TerminalSessions.sessionCapture(forTargetID:)`, so the four pane dictionaries stay
/// `@Published private` where they belong.
extension AppStore {
  /// This window's whole restorable state, right now.
  ///
  /// Runs on the main actor and must stay cheap: it is called on every coalesced save, and (via the
  /// ceiling) at a steady cadence while terminals are busy. It walks a few dozen small values and
  /// allocates no views — the expensive part, encoding, happens off the main actor in `SessionStore`.
  func captureWindowSession() -> WindowSession {
    WindowSession(
      windowKey: sessionKey.uuidString,
      frame: hostWindow.map { NSStringFromRect($0.frame) },
      isKey: hostWindow?.isKeyWindow ?? false,
      selectedTargetID: Self.targetIDString(for: selectedTargetID),
      targets: captureTargetSessions(),
      workroomSplits: captureWorkroomSplits(),
      expandedTargets: expandedTerminalTargets.isEmpty
        ? nil : expandedTerminalTargets.sorted())
  }

  /// Every target that currently owns panes, in a stable order so an unchanged layout produces an
  /// unchanged document — which is what lets the coordinator's equality gate drop the write.
  private func captureTargetSessions() -> [TargetSession] {
    terminals.activeTargetIDs.sorted().compactMap { targetID in
      guard let captured = terminals.sessionCapture(forTargetID: targetID) else { return nil }

      // Tabs the bridge refuses (today: run tabs) drop out here, and the split leaf that pointed at
      // one collapses with them — `LayoutNode.capture` applies the same rule `PaneLayout.removingLeaf`
      // does, so a split can never be left addressing a pane that was not written.
      var keysByTabID: [TerminalTab.ID: String] = [:]
      var tabs: [TabSession] = []
      for tab in captured.tabs {
        let key = tab.id.uuidString
        guard let session = TabSession(key: key, tab: tab) else { continue }
        keysByTabID[tab.id] = key
        tabs.append(session)
      }
      guard !tabs.isEmpty else { return nil }

      let split = captured.split.flatMap { layout in
        LayoutNode<String>.capture(layout) { keysByTabID[$0] }
      }
      return TargetSession(
        targetID: targetID, tabs: tabs, split: split,
        focusedKey: captured.focused.flatMap { keysByTabID[$0] },
        terminalCounter: captured.counter)
    }
  }

  /// The workroom-into-workroom split groups, with `SidebarID` leaves reduced to the same target-id
  /// strings `Defaults[.sidebarSelection]` and `workroomTabOrder` already persist — so no new id
  /// format ships, and `AppStore.sidebarID(forTargetID:in:)` resolves them back (dropping any that
  /// no longer exist).
  private func captureWorkroomSplits() -> [LayoutNode<String>] {
    workroomSplits.compactMap { layout in
      LayoutNode<String>.capture(layout) { Self.targetIDString(for: $0) }
    }
  }

  /// Tell the coordinator this window changed. Every dirty source funnels through here so there is
  /// one place to look when asking "what causes a save?".
  func markSessionDirty() {
    SessionCoordinator.shared.markDirty()
  }

  // MARK: Restore

  /// Adopt this window's saved session, once. Called from `attachWindow` — see the comment there for
  /// why not from the view initialiser.
  func claimSessionIfNeeded() {
    guard !didClaimSession else { return }
    didClaimSession = true
    // Every ⌘N window opens blank, matching how the persisted selection already behaves.
    guard claimsSavedSession else { return }
    guard
      let claimed = projectStore.claimSession(for: sessionKey, isLaunchWindow: isRestoreWindow)
    else { return }
    pendingSessionRestore = claimed
    // Keep the window's identity stable across launches: it now owns this session's slot.
    if let key = UUID(uuidString: claimed.windowKey) { sessionKey = key }
    // The session owns selection; `Defaults[.sidebarSelection]` (already loaded into
    // `pendingRestoreSelection`) stays as the cold-start fallback for a launch with no session file.
    // Feeding the session's value through the SAME field means `apply` needs no second branch.
    if let selected = claimed.selectedTargetID { pendingRestoreSelection = selected }
  }

  /// Rehydrate the claimed session at the end of `apply(_:)`. One-shot: `apply` runs twice per
  /// bootstrap (`load("none")` then `load("fast")`), and reloads come through it too.
  func restorePersistedSessionIfPending(in projects: [Project]) {
    guard let session = pendingSessionRestore else { return }
    pendingSessionRestore = nil
    defer { projectStore.finishSessionRestore() }

    var restoredTargetIDs: Set<TerminalTarget.ID> = []
    for saved in session.targets {
      // A target that no longer resolves — its workroom was deleted between launches — is dropped
      // whole, the same self-heal `validatedSelection` and `pruneWorkroomSplitToLiveLeaves` apply.
      guard let sid = Self.sidebarID(forTargetID: saved.targetID, in: projects),
        let target = target(for: sid)
      else { continue }
      guard terminals.restore(saved, for: target) > 0 else { continue }
      restoredTargetIDs.insert(target.id)
    }

    // The workroom-into-workroom split groups (issue #23). A leaf whose workroom is gone collapses,
    // and a group left with fewer than two leaves dissolves — `materialize` enforces that, so a
    // one-workroom "group" can never reach the live model.
    workroomSplits = session.workroomSplits.compactMap { saved in
      saved.materialize { Self.sidebarID(forTargetID: $0, in: projects) }
    }
    // Sidebar terminal-subtree expansion (issue #30). Only for targets that actually came back —
    // an expand flag pointing at nothing would render an empty disclosure.
    expandedTerminalTargets = Set(session.expandedTargets ?? []).intersection(restoredTargetIDs)

    refreshSelectionHasTabs()
  }
}
