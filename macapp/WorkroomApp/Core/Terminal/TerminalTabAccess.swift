/// What `TerminalPanes`' pane collaborators (`PaneLiveState`, `ProgramStatusBinding`,
/// `RemotePaneLinks`) may do with one window's tabs: read a terminal tab's state, change it, find
/// its surface, and raise one of the sessions' events. The sessions build it over their own
/// layouts and the app's tab records (`TerminalTabs`), so a collaborator reaches only the tabs this
/// window holds, every write still sends `paneWillChange` before it lands, and every event
/// still goes out through their one synchronous `onEvent` channel (ADR 0021). A collaborator holds
/// these closures, never the sessions, so a test can drive one over a plain dictionary.
@MainActor
struct TerminalTabAccess {
  /// `tabID`'s terminal state while `targetID` holds it; nil for a content tab or a tab it does not
  /// hold (closed, reaped or handed to another window).
  var state: @MainActor (TerminalTab.ID, TerminalTarget.ID) -> TerminalState?
  /// Change `tabID`'s terminal state in place. A no-op for a content tab or a tab not held, so a
  /// late answer for a pane that has gone lands nowhere.
  var mutate: @MainActor (TerminalTab.ID, TerminalTarget.ID, (inout TerminalState) -> Void) -> Void
  /// Every terminal tab the window holds, with its state.
  var terminals:
    @MainActor () -> [(target: TerminalTarget.ID, tab: TerminalTab.ID, state: TerminalState)]
  /// `tabID`'s surface while the window holds it.
  var surface: @MainActor (TerminalTab.ID) -> GhosttySurfaceView?
  /// Raise an event to the sessions' owner, inline.
  var raise: @MainActor (TerminalPanes.Event) -> Void
}
