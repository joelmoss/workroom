import WorkroomDomain
import XCTest

@testable import Workroom

/// A store over `projects` whose terminals mount a `GhosttySurfaceView` that only spawns its PTY
/// once it enters a window, so a unit test can open tabs without starting a shell. The shape most
/// suites need; a suite that needs a fake CLI, a captured command or an inert surface keeps its own.
/// A backgrounded run tab is the exception: it spawns off-window (`ensureSurfaceCreated`), and
/// through the app's shared session service into this build's real daemon, so a suite that starts a
/// run, or arms an auto-run, uses an inert surface (`spawnsSurface: false`).
@MainActor
func makeStore(_ projects: [Project]) -> AppStore {
  let store = AppStore()
  store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
  store.projectStore.projects = projects
  return store
}

/// A session service that answers no helper, so only what a test registers on it attaches.
@MainActor
func isolatedPaneSessionService() -> PersistentSessionService {
  PersistentSessionService(
    probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned })
}

/// A window's panes that touch nothing app-wide: no helper (so a new pane gets no session of its
/// own unless `service` registers one), an inert surface (so nothing spawns), and their own
/// program status monitor and recency, so no test writes into the app's singletons.
@MainActor
func makeIsolatedPanes() -> TerminalPanes {
  makeIsolatedPanes(service: isolatedPaneSessionService())
}

/// `makeIsolatedPanes()` over a service the test holds, to register sessions on.
@MainActor
func makeIsolatedPanes(service: PersistentSessionService) -> TerminalPanes {
  let panes = TerminalPanes()
  isolate(panes, service: service)
  return panes
}

/// Make `panes`, which their owner built, touch nothing app-wide, as `makeIsolatedPanes` does.
@MainActor
func isolate(_ panes: TerminalPanes, service: PersistentSessionService) {
  panes.makeView = { _, cwd, _ in
    GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
  }
  panes.sessionService = service
  panes.programStatus = ProgramStatusMonitor()
  panes.recordUnrecognizedTool = { _ in }
  panes.recency = SwitcherRecency()
}

/// A Quick Terminal host over the controller's target, wired as `QuickTerminalController` wires
/// it (no pane leaves for a window of its own), with isolated panes (`isolate`), closes that never
/// prompt and banners that post nowhere unless the test hands in its own `notifier`.
@MainActor
func makeQuickTerminalHost(
  notifications: NotificationCenterStore, service: PersistentSessionService? = nil,
  notifier: SystemNotifying = SilentNotifier()
) -> QuickTerminalHost {
  let host = QuickTerminalHost(
    notifications: notifications, target: QuickTerminalController.target())
  isolate(host.terminals, service: service ?? isolatedPaneSessionService())
  host.terminals.allowsDetach = false
  host.closeFlow.confirmOnCloseOverride = false
  host.services.notifier = notifier
  return host
}

extension TerminalPanes {
  /// Give terminal tab `tabID` the session `addTab` keeps only where persistent sessions are
  /// available, which a test's are not: on its tab, which its surface attaches with.
  func giveSession(_ session: UUID, toTab tabID: TerminalTab.ID, in target: TerminalTarget) {
    guard var tab = tab(tabID, for: target), case .terminal(var state) = tab.content else {
      return XCTFail("no terminal tab \(tabID) in \(target.id)")
    }
    state.sessionID = session
    tab.content = .terminal(state)
    replace(tab, for: target)
  }
}
