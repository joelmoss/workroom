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
  /// shows (`AppStore.CreateStep(run)` in `ProjectSidebar`).
  func createStep(for sid: SidebarID) -> CreateStep? {
    creationRun(for: sid).map(CreateStep.init)
  }
}
