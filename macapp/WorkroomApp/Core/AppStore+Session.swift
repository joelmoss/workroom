import AppKit
import Defaults
import Foundation
import OSLog

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

  private static let sessionLogger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "session")

  /// Every target that currently owns panes, in a stable order so an unchanged layout produces an
  /// unchanged document — which is what lets the coordinator's equality gate drop the write.
  ///
  /// **The caps are enforced here, not only on read.** `SessionFile.sanitized()` drops anything over
  /// them at restore, so a capture that ignored them would let the app author a file it then
  /// truncates on every single launch — the user losing the same targets forever, silently. Applying
  /// the same limit at both ends means what is written is exactly what comes back, and the drop is
  /// logged the one time it happens rather than being invisible.
  private func captureTargetSessions() -> [TargetSession] {
    let active = terminals.activeTargetIDs.sorted()
    if active.count > SessionLimits.maxTargetsPerWindow {
      let message =
        "session capture is over the target cap — persisting "
        + "\(SessionLimits.maxTargetsPerWindow) of \(active.count)"
      Self.sessionLogger.notice("\(message, privacy: .public)")
    }
    return active.prefix(SessionLimits.maxTargetsPerWindow).compactMap { targetID in
      guard let captured = terminals.sessionCapture(forTargetID: targetID) else { return nil }

      // Tabs the bridge refuses (today: run tabs) drop out here, and the split leaf that pointed at
      // one collapses with them — `LayoutNode.capture` applies the same rule `PaneLayout.removingLeaf`
      // does, so a split can never be left addressing a pane that was not written.
      var keysByTabID: [TerminalTab.ID: String] = [:]
      var tabs: [TabSession] = []
      for tab in captured.tabs {
        guard tabs.count < SessionLimits.maxTabsPerTarget else { break }
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

  /// Write every live pane's scrollback to its sidecar (issue #144). Quit only — reading each
  /// pane's history is far too heavy for a coalesced save.
  ///
  /// The tab key must match what `captureTargetSessions` wrote for the same tab, or the sidecar
  /// belongs to nothing and is pruned the moment it is written.
  ///
  /// **Bounded by a wall-clock budget**, because this runs synchronously on the main thread inside
  /// `applicationShouldTerminate` — and on the SIGTERM path it runs *before* run commands are stopped.
  /// Per-pane cost is bounded in `GhosttySurfaceView.captureScrollback`; this bounds the total, so a
  /// window full of busy panes cannot turn a quit into a spinning beachball. A pane past the deadline
  /// restores with no text (tab keys are re-minted every launch, so there is no older sidecar for it
  /// to fall back on) — losing one pane's history beats hanging the quit for every pane.
  /// `isEnabled` is a parameter rather than a bare `Defaults` read so a test can drive the opt-out
  /// without mutating a shared preference domain (the single-writer constraint parallel test workers
  /// impose — see `SharedPrefDefaultsTests`).
  func captureScrollback(
    into store: SessionStore, isEnabled: Bool = Defaults[.persistScrollback],
    deadline: Date = Date() + 1.5
  ) {
    guard isEnabled else { return }
    var skipped = 0
    for targetID in terminals.activeTargetIDs {
      guard let captured = terminals.sessionCapture(forTargetID: targetID) else { continue }
      for tab in captured.tabs {
        // Run tabs are not persisted at all, so their output must not be either.
        guard tab.surface?.isRunCommandSurface != true else { continue }
        guard Date() < deadline else {
          skipped += 1
          continue
        }
        guard let text = tab.surface?.captureScrollback() else { continue }
        store.writeScrollback(text, forTabKey: tab.id.uuidString)
      }
    }
    if skipped > 0 {
      Self.sessionLogger.notice("scrollback capture ran out of budget — \(skipped) panes skipped")
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
    //
    // Assigned UNCONDITIONALLY, nil included: a saved window that had nothing selected must come back
    // with nothing selected. Overwriting only on non-nil would let the single-slot Defaults key —
    // last written by whichever OTHER window was active — decide this window's selection, which is
    // exactly the per-window authority the session file exists to provide.
    pendingRestoreSelection = claimed.selectedTargetID
  }

  /// Rehydrate the claimed session at the end of `apply(_:)`. One-shot: `apply` runs twice per
  /// bootstrap (`load("none")` then `load("fast")`), and reloads come through it too.
  func restorePersistedSessionIfPending(in projects: [Project]) {
    guard let session = pendingSessionRestore else { return }
    pendingSessionRestore = nil
    defer { projectStore.finishSessionRestore() }

    // Resolved once, not per tab: with the preference off, restore hands every pane a closure that
    // returns nothing, so nothing is read and nothing is replayed. The layout still comes back.
    let coordinator = projectStore.sessionCoordinator
    let readScrollback: (String) -> String? =
      Defaults[.persistScrollback] ? { coordinator.scrollback(forTabKey: $0) } : { _ in nil }

    var restoredTargetIDs: Set<TerminalTarget.ID> = []
    for saved in session.targets {
      // A target that no longer resolves — its workroom was deleted between launches — is dropped
      // whole, the same self-heal `validatedSelection` and `pruneWorkroomSplitToLiveLeaves` apply.
      guard let sid = Self.sidebarID(forTargetID: saved.targetID, in: projects),
        let target = target(for: sid)
      else { continue }
      guard terminals.restore(saved, for: target, scrollback: readScrollback) > 0 else { continue }
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
