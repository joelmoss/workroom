import WorkroomDomain

@testable import Workroom

/// A store over `projects` whose terminals mount a `GhosttySurfaceView` that only spawns its PTY
/// once it enters a window, so a unit test can open tabs without starting a shell. The shape most
/// suites need; a suite that needs a fake CLI, a captured command or an inert surface keeps its own.
@MainActor
func makeStore(_ projects: [Project]) -> AppStore {
  let store = AppStore()
  store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
  store.projects = projects
  return store
}
