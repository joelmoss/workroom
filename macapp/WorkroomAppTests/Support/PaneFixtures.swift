import Foundation

@testable import Workroom

/// No sessions, and an inert surface, so a store's terminals spawn nothing. For the invalidation
/// suites, which open tabs and count the views that re-run, not what runs in them.
@MainActor
func makeInert(_ store: AppStore) {
  store.terminals.sessionService = isolatedPaneSessionService()
  store.terminals.makeView = { _, cwd, command in
    GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
  }
}

/// Report what a working agent reports: OSC 9;4 progress, then a title naming a known agent. What
/// an agent does many times a minute, so the change the invalidation suites measure.
@MainActor
func agentStartsWorking(on surface: GhosttySurfaceView) async throws {
  surface.handleProgressReport(true)
  try await Task.sleep(for: .milliseconds(50))
  surface.foregroundProcessNameForTesting = "codex"
  surface.handleTitleChange("Codex")
}
