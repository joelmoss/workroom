import WorkroomDomain

@testable import Workroom

/// A store over `projects` whose terminals mount a `GhosttySurfaceView` that only spawns its PTY
/// once it enters a window, so a unit test can open tabs without starting a shell. The shape most
/// suites need; a suite that needs a fake CLI, a captured command or an inert surface keeps its own.
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
  panes.makeView = { _, cwd, _ in
    GhosttySurfaceView(workingDirectory: cwd, spawnsSurface: false)
  }
  panes.sessionService = service
  panes.programStatus = ProgramStatusMonitor()
  panes.recordUnrecognizedTool = { _ in }
  panes.recency = SwitcherRecency()
  return panes
}
