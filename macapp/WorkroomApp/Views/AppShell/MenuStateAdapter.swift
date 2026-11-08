import SwiftUI

/// Derives and publishes the window's menu-command enablement (`MenuStateValues`, and the Room
/// menu's `RoomCommandStateValues`) for `WorkroomCommands`.
///
/// Its own view, not part of `RootView`'s body, because most of what these values read is
/// Combine-published (the notification list, the Room menu's remote state, the waiting agents) and
/// nothing else in the window renders from them: observing them in `RootView` re-ran the whole
/// window body on every notification and every remote-state step (`RootInvalidationTests`).
/// The store's reads are Observation-tracked here too, so a run starting or the selection moving
/// re-runs this, not `RootView`, unless `RootView` reads it for its own content.
struct MenuStateAdapter: ViewModifier {
  #if DEBUG
    /// How many times the body has run, read by `RootInvalidationTests`.
    static var bodyPasses = 0
  #endif
  let store: AppStore
  @EnvironmentObject private var notifications: NotificationCenterStore
  // Observed so the Room menu's Fetch/Push/Pull items follow `canFetch`/`canPush`/`canPull`, which
  // the store's Observation tracking cannot see.
  @EnvironmentObject private var remoteState: RemoteStateModel
  @EnvironmentObject private var runCommand: RunCommandController
  @ObservedObject private var programStatusAlerts = ProgramStatusAlerts.shared

  func body(content: Content) -> some View {
    #if DEBUG
      Self.bodyPasses += 1
    #endif
    let modals = store.modals
    let modal = modals.hasModalPresentation
    return
      content
      .modifier(RoomCommandStateValues(store: store))
      .modifier(
        MenuStateValues(
          // `workroomSelected`: while a setup script blocks the selected workroom's terminal, report
          // false so ⌘T can't open a (hidden) terminal behind the setup pane (Open/Reveal still work).
          //
          // Every boolean here also ANDs in `!modal`: a menu item's key equivalent fires even while a
          // dialog or sheet is up (⌘T behind the Add Project sheet really did open a tab), and a
          // disabled item drops its key equivalent — the same mechanism `hasProjects` already relies
          // on for ⌘N. Doing it here rather than per-item keeps it to one site, and greying the item
          // out tells the user WHY the key did nothing, which swallowing the event in the key monitor
          // cannot.
          workroomSelected: terminalInteractionAvailable && !modal,
          hasNotifications: !notifications.items.isEmpty && !modal,
          hasWaitingTerminals: !programStatusAlerts.waiting.isEmpty && !modal,
          // `hasProjects`: "New Workroom" (⌘N) disabled with no projects (#81). Deliberately NOT gated
          // on `modal` — ⌘N/⌘O must still work while a picker is open, because raising one picker
          // replaces the other and that's the documented behaviour (issue #94).
          hasProjects: !store.projectStore.projects.isEmpty,
          // `hasWorkroomAnchor`: the two "(split right)" items (⌥⌘N/⌥⌘O, issue #163) need a workroom
          // to split BESIDE. Deliberately NOT gated on `modal`, for the same reason `hasProjects`
          // isn't — a disabled item drops its key equivalent, and these chords must keep working
          // while a picker is up, exactly as their plain ⌘N/⌘O siblings do.
          hasWorkroomAnchor: store.selectedTargetID != nil,
          // Go-menu Back/Forward (issue #26).
          canNavigateBack: store.canGoBack && !modal,
          canNavigateForward: store.canGoForward && !modal,
          // Run/Stop/Restart (issue #7) — run-state lives on the store, so these stay live.
          hasRunCommand: selectedHasRunCommand && !modal,
          runCommandActive: selectedRunCommandActive && !modal,
          // Room menu's Fetch / Push / Pull (⌥⇧⌘F / ⇧⌘P / ⌥⇧⌘P). The model's own `can*` already
          // fold in "a remote exists" and "nothing is in flight"; the tool floor (whether the `git`
          // on PATH can run the remote commands, `VCSToolVersions`) and the modal guard are ANDed
          // here so the menu can't fire an action the toolbar itself would refuse.
          vcsCanFetch: remoteState.canFetch && store.vcsAllowsRemoteActions && !modal,
          vcsCanPush: remoteState.canPush && store.vcsAllowsRemoteActions && !modal,
          vcsCanPull: remoteState.canPull && store.vcsAllowsRemoteActions && !modal,
          hasRunTerminal: runCommand.hasAnyRunTerminal && !modal,
          // Go-menu Previous/Next Workroom Tab (issue #29) — only meaningful with ≥2 tabs.
          multipleWorkroomTabs: store.orderedWorkroomTargets().count > 1 && !modal,
          // Go-menu "Last-Used Workroom" (⌥⇥, issue #132). Counted across every window, so it stays
          // enabled when this window holds the only workroom and another window holds a second one.
          // Observation tracks the other windows' reads too, and they ask only whether each workroom
          // has terminals (`TerminalPanes.activeTargetIDs`), so another window's workroom opening
          // or emptying re-runs this body, and its tabs' titles, agents and progress do not.
          canSwitchWorkrooms: QuickSwitcher.canSwitchWorkrooms() && !modal,
          // Go-menu "Open in…" + ⌘O — enabled only with an editor and a valid selection.
          canOpenInEditor: store.canOpenInEditor && !modal,
          canMoveWorkroom: store.selectedTargetID.map(store.canMoveWorkroom) == true && !modal,
          modalPresented: modal))
  }

  /// True when the selected target can host a terminal right now: it exists, isn't missing, and its
  /// terminal isn't withheld behind its own create (issue #116).
  /// Reads `isCreationBlocking`, the same predicate `TargetTerminalDetail` withholds on, so ⌘T and
  /// its neighbours stay disabled over a create that has no terminal to act on.
  private var terminalInteractionAvailable: Bool {
    guard let target = store.selectedTarget, target.opensTerminals else { return false }
    return !store.lifecycle.isCreationBlocking(target.id)
  }

  /// Whether ⌘R (File ▸ Run) should be live for the selection — the shared `canRunCommand` gate, not a
  /// bare `hasRunCommand`. The menu is one of the callers `startRunCommand`'s guards were written for
  /// (issue #171), so it enables on exactly the conditions under which a run would actually start: a
  /// present directory, no create in flight, and a command configured. The run command is configured
  /// per project and runnable from the root or any workroom (issue #7).
  private var selectedHasRunCommand: Bool {
    guard let path = AppStore.projectPath(of: store.selectedTargetID),
      let target = store.selectedTarget
    else { return false }
    return store.canRunCommand(for: target, inProject: path)
  }

  /// Whether the selected target's run command is currently running.
  private var selectedRunCommandActive: Bool {
    guard let target = store.selectedTarget else { return false }
    return runCommand.isRunCommandRunning(for: target.id)
  }
}

/// Publishes the per-window menu-command enablement values as `focusedSceneValue`s in one place. A
/// `Commands` body doesn't re-evaluate when the shared store mutates, but it does track focused
/// values — so `MenuStateAdapter` recomputes these and the menu reads them via `@FocusedValue` (see
/// `WorkroomCommands`). Its own `ViewModifier` so the chain stays a single, fast-to-type-check
/// expression (a dozen inline `.focusedSceneValue` calls blow the type-checker's budget).
private struct MenuStateValues: ViewModifier {
  let workroomSelected: Bool
  let hasNotifications: Bool
  let hasWaitingTerminals: Bool
  let hasProjects: Bool
  let hasWorkroomAnchor: Bool
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let hasRunCommand: Bool
  let runCommandActive: Bool
  let vcsCanFetch: Bool
  let vcsCanPush: Bool
  let vcsCanPull: Bool
  let hasRunTerminal: Bool
  let multipleWorkroomTabs: Bool
  let canSwitchWorkrooms: Bool
  let canOpenInEditor: Bool
  let canMoveWorkroom: Bool
  /// Published for the items that have no other boolean to fold it into (see `ModalPresentedKey`).
  /// The booleans above already have it ANDed in at the call site, so they need nothing here.
  let modalPresented: Bool

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.modalPresented, modalPresented)
      .focusedSceneValue(\.workroomSelected, workroomSelected)
      .focusedSceneValue(\.hasNotifications, hasNotifications)
      .focusedSceneValue(\.hasWaitingTerminals, hasWaitingTerminals)
      .focusedSceneValue(\.hasProjects, hasProjects)
      .focusedSceneValue(\.hasWorkroomAnchor, hasWorkroomAnchor)
      .focusedSceneValue(\.canNavigateBack, canNavigateBack)
      .focusedSceneValue(\.canNavigateForward, canNavigateForward)
      .focusedSceneValue(\.hasRunCommand, hasRunCommand)
      .focusedSceneValue(\.vcsCanFetch, vcsCanFetch)
      .focusedSceneValue(\.vcsCanPush, vcsCanPush)
      .focusedSceneValue(\.vcsCanPull, vcsCanPull)
      .focusedSceneValue(\.runCommandActive, runCommandActive)
      .focusedSceneValue(\.hasRunTerminal, hasRunTerminal)
      .focusedSceneValue(\.multipleWorkroomTabs, multipleWorkroomTabs)
      .focusedSceneValue(\.canSwitchWorkrooms, canSwitchWorkrooms)
      .focusedSceneValue(\.canOpenInEditor, canOpenInEditor)
      .focusedSceneValue(\.canMoveWorkroom, canMoveWorkroom)
  }
}
