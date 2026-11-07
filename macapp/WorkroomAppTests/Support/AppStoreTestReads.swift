import WorkroomDomain

@testable import Workroom

/// Reads that only tests make, kept out of the app so nothing ships that no screen uses.
@MainActor
extension AppStore {
  /// Whether any real (≥2 live members) split group exists at all, regardless of what's selected —
  /// "is this window grouped".
  var workroomSplitActive: Bool {
    workroomSplits.contains { resolvedSplitLeaves(of: $0) != nil }
  }

  /// The progress of the create whose pane `sid` is, or nil when it has none: what its sidebar row
  /// shows (`WorkroomLifecycle.CreateStep(run)` in `ProjectSidebar`).
  func createStep(for sid: SidebarID) -> WorkroomLifecycle.CreateStep? {
    lifecycle.creationRun(for: sid).map(WorkroomLifecycle.CreateStep.init)
  }
}

@MainActor
extension TerminalPanes {
  /// The surface of `tab` while this window holds it, nil for a content tab: `surface(of:)` for a
  /// test that already has the tab value.
  func surface(_ tab: TerminalTab?) -> GhosttySurfaceView? { tab.flatMap { surface(of: $0.id) } }
}
